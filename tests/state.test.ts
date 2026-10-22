import { describe, expect, test } from "vitest";
import { api } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { setup, type T } from "./helpers";
import { BASE, seedInbox, seedShow } from "./seed";

const stateOf = async (t: T, episodeId: Id<"episodes">) =>
  (await t.query(api.episodes.get, { episodeId }))!.row.state!;

describe("position", () => {
  test("last writer wins on the client's positionUpdatedAt", async () => {
    const t = setup();
    const { episodeIds: [ep] } = await seedShow(t, 1);
    const save = (position: number, positionUpdatedAt: number, deviceId: string) =>
      t.mutation(api.episodes.updatePosition, { episodeId: ep!, position, positionUpdatedAt, deviceId });

    expect(await save(100, BASE + 10, "phone")).toBe(true);
    expect(await save(500, BASE + 30, "mac")).toBe(true);
    // The phone's outbox replays an older save after the Mac's newer one.
    expect(await save(200, BASE + 20, "phone")).toBe(false);
    expect(await stateOf(t, ep!)).toMatchObject({ position: 500, positionUpdatedAt: BASE + 30, positionDeviceId: "mac" });
    // Same timestamp: the later arrival wins.
    expect(await save(600, BASE + 30, "phone")).toBe(true);
    expect((await stateOf(t, ep!)).position).toBe(600);
  });
});

describe("played, starred, archived", () => {
  test("each field is LWW on its own timestamp", async () => {
    const t = setup();
    const { episodeIds: [ep] } = await seedShow(t, 1);
    await t.mutation(api.episodes.setStarredState, { episodeId: ep!, starred: true, at: BASE + 50 });
    await t.mutation(api.episodes.setPlayedState, { episodeId: ep!, played: true, at: BASE + 10 });
    // Stale unstar from before the star: ignored. Unplay newer than the play: applied.
    expect(await t.mutation(api.episodes.setStarredState, { episodeId: ep!, starred: false, at: BASE + 40 })).toBe(false);
    expect(await t.mutation(api.episodes.setPlayedState, { episodeId: ep!, played: false, at: BASE + 20 })).toBe(true);
    expect(await stateOf(t, ep!)).toMatchObject({ starred: true, starredAt: BASE + 50, played: false });
  });

  test("marking played takes it out of the Inbox and Up Next", async () => {
    const t = setup();
    const { episodeIds: [ep] } = await seedShow(t, 1);
    await t.mutation(api.queue.add, { episodeId: ep!, position: "bottom", at: BASE + 1 });
    await seedInbox(t, [ep!]);
    await t.mutation(api.episodes.setPlayedState, { episodeId: ep!, played: true, at: BASE + 3 });
    expect(await t.query(api.episodes.inbox, {})).toHaveLength(0);
    expect(await t.query(api.queue.upNext, {})).toHaveLength(0);
  });
});

describe("Inbox leftovers", () => {
  test("archive all older only touches older Inbox episodes of that show", async () => {
    const t = setup();
    const { episodeIds } = await seedShow(t, 5);
    const other = await seedShow(t, 1, { title: "other" });
    await seedInbox(t, [...episodeIds, ...other.episodeIds]);
    const n = await t.mutation(api.episodes.archiveAllOlder, { episodeId: episodeIds[3]!, at: BASE + 1 });
    expect(n).toBe(3);
    const inbox = await t.query(api.episodes.inbox, {});
    expect(inbox.map((r) => `${r.podcast.title}/${r.episode.title}`).sort()).toEqual(["Show/Ep 3", "Show/Ep 4", "other/Ep 0"]);
  });
});
