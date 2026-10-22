import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { drain, setup, type T } from "./helpers";
import { BASE, seedInbox, seedShow } from "./seed";

// migrations:retireInbox (decisions.md, 22 Oct 2026): the old Inbox goes to the
// bottom of Up Next, oldest first, and stored `inbox` rules become upNextBottom.

const NOW = BASE + 30 * 86_400_000;

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
});
afterEach(() => vi.useRealTimers());

const titles = async (t: T) => (await t.query(api.queue.upNext, {})).map((r) => `${r.row.podcast.title}/${r.row.episode.title}`);

async function report(t: T, who: T) {
  const rows = await t.run(async (ctx) => await ctx.runQuery(internal.migrations.inboxReport, {}));
  const { userId: _, email: __, ...counts } = rows.find((r) => r.email === who.email)!;
  return counts;
}

async function setRules(t: T, global: "inbox" | "upNextTop" | null, shows: [Id<"podcasts">, "inbox" | "upNextTop"][]) {
  const userId = await t.userId();
  await t.run(async (ctx) => {
    if (global) await ctx.db.insert("globalSettings", { userId, newEpisodes: global, fieldTimes: { newEpisodes: 1 }, updatedAt: 1 });
    for (const [podcastId, rule] of shows) {
      await ctx.db.insert("podcastSettings", { userId, podcastId, newEpisodes: rule, playbackSpeed: 1.5, fieldTimes: { newEpisodes: 1 }, updatedAt: 1 });
    }
  });
}

/**
 * Mike: a show of 6 episodes (Ep 0 oldest). Ep 5 is queued; the Inbox holds
 * Ep 3, Ep 0, Ep 2 (to move), Ep 5 (already queued), Ep 1 (played) and Ep 4
 * (archived). A second show's Ep 0 is in the Inbox too, published in between.
 */
async function seedMike(t: T) {
  const { podcastId, episodeIds: e } = await seedShow(t, 6);
  const other = await seedShow(t, 1, { title: "other" });
  await t.run(async (ctx) => ctx.db.patch(other.episodeIds[0]!, { pubDate: BASE + 1.5 * 86_400_000 }));
  await t.mutation(api.queue.add, { episodeId: e[5]!, position: "bottom", at: BASE });
  await t.mutation(api.episodes.setPlayedState, { episodeId: e[1]!, played: true, at: BASE });
  await t.mutation(api.episodes.setArchivedState, { episodeId: e[4]!, archived: true, at: BASE });
  await seedInbox(t, [e[3]!, e[0]!, e[2]!, e[5]!, e[1]!, e[4]!, other.episodeIds[0]!]);
  return { podcastId, otherId: other.podcastId, e };
}

describe("retireInbox", () => {
  test("moves the Inbox to the bottom of Up Next, oldest first, and rewrites inbox rules", async () => {
    const mike = setup();
    const { podcastId, otherId, e } = await seedMike(mike);
    await setRules(mike, "inbox", [
      [podcastId, "inbox"],
      [otherId, "upNextTop"],
    ]);
    expect(await report(mike, mike)).toEqual({ inbox: 7, toMove: 4, upNext: 1, globalInboxRule: true, showInboxRules: 1 });

    await mike.run(async (ctx) => ctx.runMutation(internal.migrations.retireInbox, {}));
    await drain(mike);

    expect(await titles(mike)).toEqual(["Show/Ep 5", "Show/Ep 0", "other/Ep 0", "Show/Ep 2", "Show/Ep 3"]);
    expect(await mike.query(api.episodes.inbox, {})).toEqual([]);
    const states = await mike.run(async (ctx) => ctx.db.query("episodeStates").collect());
    for (const s of states) expect([s.inInbox, s.inboxAt]).toEqual([false, undefined]);
    // Played and archived ones aren't queued.
    const queued = (await mike.query(api.queue.upNext, {})).map((r) => r.item.episodeId);
    expect(queued).not.toContain(e[1]);
    expect(queued).not.toContain(e[4]);

    // Global inbox → upNextBottom; the show's inbox override now equals it, so it's cleared.
    expect((await mike.query(api.settings.getGlobal, {})).newEpisodes).toBe("upNextBottom");
    const show = await mike.query(api.settings.forPodcast, { podcastId });
    expect(show.overrides).toEqual({ playbackSpeed: 1.5 });
    expect((await mike.query(api.settings.forPodcast, { podcastId: otherId })).overrides.newEpisodes).toBe("upNextTop");
    expect(await report(mike, mike)).toEqual({ inbox: 0, toMove: 0, upNext: 5, globalInboxRule: false, showInboxRules: 0 });
  });

  test("an inbox override is rewritten, not cleared, when the global rule differs", async () => {
    const mike = setup();
    const { podcastId } = await seedShow(mike, 1);
    await setRules(mike, "upNextTop", [[podcastId, "inbox"]]);
    await mike.run(async (ctx) => ctx.runMutation(internal.migrations.retireInbox, {}));
    await drain(mike);
    expect((await mike.query(api.settings.forPodcast, { podcastId })).overrides.newEpisodes).toBe("upNextBottom");
    expect((await mike.query(api.settings.getGlobal, {})).newEpisodes).toBe("upNextTop");
  });

  test("is idempotent", async () => {
    const mike = setup();
    await seedMike(mike);
    await mike.run(async (ctx) => ctx.runMutation(internal.migrations.retireInbox, {}));
    await drain(mike);
    const first = await mike.query(api.queue.upNext, {});

    vi.setSystemTime(NOW + 60_000);
    const again = await mike.run(async (ctx) => ctx.runMutation(internal.migrations.retireInboxFor, { userId: await mike.userId() }));
    expect(again).toEqual({ moved: 0, cleared: 0, globalRewritten: false, overridesRewritten: 0, overridesCleared: 0, isDone: true });
    const second = await mike.query(api.queue.upNext, {});
    expect(second.map((r) => [r.item.episodeId, r.item.orderKey, r.item.updatedAt])).toEqual(
      first.map((r) => [r.item.episodeId, r.item.orderKey, r.item.updatedAt]),
    );
  });

  test("each person is migrated on their own; one person's run leaves others untouched", async () => {
    const mike = setup();
    const ana = mike.as("ana@example.com");
    await seedMike(mike);
    const anaShow = await seedShow(ana, 3, { title: "ana" });
    await ana.mutation(api.queue.add, { episodeId: anaShow.episodeIds[0]!, position: "bottom", at: BASE });
    await seedInbox(ana, [anaShow.episodeIds[2]!, anaShow.episodeIds[1]!]);
    await setRules(ana, "upNextTop", [[anaShow.podcastId, "inbox"]]);

    await mike.run(async (ctx) => ctx.runMutation(internal.migrations.retireInboxFor, { userId: await mike.userId() }));
    expect(await report(mike, ana)).toEqual({ inbox: 2, toMove: 2, upNext: 1, globalInboxRule: false, showInboxRules: 1 });
    expect(await titles(ana)).toEqual(["ana/Ep 0"]);
    expect(await titles(mike)).not.toContain("ana/Ep 1");

    await mike.run(async (ctx) => ctx.runMutation(internal.migrations.retireInbox, {}));
    await drain(mike);
    expect(await titles(ana)).toEqual(["ana/Ep 0", "ana/Ep 1", "ana/Ep 2"]);
    expect(await titles(mike)).toEqual(["Show/Ep 5", "Show/Ep 0", "other/Ep 0", "Show/Ep 2", "Show/Ep 3"]);
    expect((await ana.query(api.settings.forPodcast, { podcastId: anaShow.podcastId })).overrides.newEpisodes).toBe("upNextBottom");
  });

  test("a big Inbox goes over in batches, still oldest first", async () => {
    const mike = setup();
    const { episodeIds } = await seedShow(mike, 450);
    await seedInbox(mike, [...episodeIds].reverse());
    await mike.run(async (ctx) => ctx.runMutation(internal.migrations.retireInbox, {}));
    await drain(mike);
    const queue = await mike.query(api.queue.upNext, {});
    expect(queue.map((r) => r.item.episodeId)).toEqual(episodeIds);
    expect(await mike.query(api.episodes.inbox, {})).toEqual([]);
  });

  test("sync:changes delivers the moves to the app", async () => {
    const mike = setup();
    const { podcastId } = await seedMike(mike);
    await setRules(mike, "inbox", [[podcastId, "inbox"]]);
    const since = NOW + 1800_000;
    vi.setSystemTime(NOW + 3600_000);
    await mike.run(async (ctx) => ctx.runMutation(internal.migrations.retireInbox, {}));
    await drain(mike);

    const changes = async (table: "queueItems" | "episodeStates" | "globalSettings" | "podcastSettings") =>
      (await mike.query(api.sync.changes, { table, since, paginationOpts: { cursor: null, numItems: 100 } })).page as Record<string, unknown>[];
    expect(await changes("queueItems")).toHaveLength(4);
    const states = await changes("episodeStates");
    expect(states).toHaveLength(7);
    for (const s of states) expect(s.inInbox).toBe(false);
    expect((await changes("globalSettings"))[0]).toMatchObject({ newEpisodes: "upNextBottom" });
    expect((await changes("podcastSettings"))[0]?.newEpisodes).toBeUndefined();
  });
});
