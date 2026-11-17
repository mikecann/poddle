import { readFileSync, writeFileSync } from "node:fs";
import { explainTransitions, linkedDiagram, missingDescriptions, stateDiagram } from "@convex-dev/state-machines";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import { machines } from "../convex/machines";
import { drain, fixture, mockFetch, setup } from "./helpers";

const NOW = Date.UTC(2025, 9, 15);
beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
});
afterEach(() => vi.useRealTimers());

const counts = {
  podcasts: 0, subscribedPodcasts: 0, podcastsProcessed: 0, feedsFailed: 0, episodes: 0, episodesMatched: 0, ghostEpisodes: 0,
  playedEpisodes: 0, inProgressEpisodes: 0, starredEpisodes: 0, sessions: 0, estimatedDurationSessions: 0, estimatedListenSeconds: 0,
};

describe("moving the import onto state machines", () => {
  test("the backfill gives every old batch and queue row the state its old fields describe", async () => {
    const t = setup();
    const userId = await t.userId();
    const ids = await t.run(async (ctx) => {
      const batch = (status: "parsing" | "fetching" | "done" | "failed", extra = {}) =>
        ctx.db.insert("importBatches", { userId, source: "overcast", status, assumedSpeed: 2, startedAt: NOW, counts, playlists: [], updatedAt: NOW, ...extra });
      const podcastId = await ctx.db.insert("podcasts", { feedUrl: "https://x.example.com/rss", title: "X", isPrivate: false, episodeCount: 0, createdAt: NOW, updatedAt: NOW });
      const fetching = await batch("fetching", { worker: 2, restarts: 1 });
      return {
        parsing: await batch("parsing"),
        fetching,
        done: await batch("done", { finishedAt: NOW + 5 }),
        failed: await batch("failed", { error: "Boom" }),
        waiting: await ctx.db.insert("importQueue", { batchId: fetching, podcastId, phase: "fetch" }),
        claimed: await ctx.db.insert("importQueue", { batchId: fetching, podcastId, phase: "fetch", claimedAt: NOW - 1, busyCount: 2 }),
        fetched: await ctx.db.insert("importQueue", { batchId: fetching, podcastId, phase: "match", feedOk: true, medianDuration: 60, durations: [60] }),
      };
    });
    await t.mutation(internal.migrations.backfillImportStates, {});
    await drain(t);
    const state = (id: string) => t.run(async (ctx) => (await ctx.db.get(id as never) as { state?: unknown } | null)?.state);
    expect(await state(ids.parsing)).toEqual({ kind: "parsing" });
    expect(await t.run(async (ctx) => (await ctx.db.get(ids.parsing))?.stateTimers)).toEqual([]); // the switch requires it
    expect(await state(ids.fetching)).toEqual({ kind: "fetching", worker: 2, restarts: 1 });
    expect(await state(ids.done)).toEqual({ kind: "done", finishedAt: NOW + 5 });
    expect(await state(ids.failed)).toEqual({ kind: "failed", finishedAt: NOW, error: "Boom" });
    expect(await state(ids.waiting)).toEqual({ kind: "waiting", notBefore: 0, busyCount: 0 });
    expect(await state(ids.claimed)).toEqual({ kind: "fetching", claimedAt: NOW - 1, busyCount: 2 });
    expect(await state(ids.fetched)).toEqual({ kind: "fetched", feedOk: true, medianDuration: 60, durations: [60] });
    expect(await t.query(internal.migrations.importStatesLeft, {})).toEqual({ importBatches: 0, importQueue: 0 });
  });

  // From a Codex review: rows backfilled while an import was running went stale as
  // it moved on, so the switch would have found a finished import still "parsing".
  test("an import running before the switch keeps its state current at every step", async () => {
    const t = setup();
    mockFetch({
      "https://feeds.example.com/techtalk.xml": fixture("techtalk-feed.xml"),
      "https://feeds.example.com/oldfav.xml": fixture("oldfav-feed.xml"),
    });
    const batchId = await t.mutation(api.overcastImport.startOvercastImport, { opml: fixture("overcast-all-data.opml"), assumedSpeed: 1.5 });
    const row = () => t.run(async (ctx) => await ctx.db.get(batchId));
    expect((await row())?.state).toEqual({ kind: "parsing" });
    vi.runOnlyPendingTimers();
    await t.finishInProgressScheduledFunctions();
    expect((await row())?.state).toEqual({ kind: "fetching", worker: 1, restarts: 0 });
    const shows = await t.run(async (ctx) => await ctx.db.query("importQueue").collect());
    expect(shows.map((s) => s.state)).toEqual(shows.map(() => ({ kind: "waiting", notBefore: 0, busyCount: 0 })));
    await drain(t);
    expect(await row()).toMatchObject({ status: "done", state: { kind: "done" }, stateTimers: [] });
    expect(await t.query(internal.migrations.importStatesLeft, {})).toEqual({ importBatches: 0, importQueue: 0 });
  });
});

// docs/state-machines.md is drawn from the rules the backend runs (convex/machines.ts),
// so this fails when a rule changes and the doc doesn't. `npm run machines:diagrams` rewrites it.
describe("the machines' rules", () => {
  const docPath = new URL("../docs/state-machines.md", import.meta.url);
  const fence = (code: string) => ["```mermaid", code, "```"].join("\n");

  function renderDiagrams() {
    const manifests = machines.manifests;
    return [
      "# State machines",
      "",
      "Generated from each machine's rules by `npm run machines:diagrams`, and checked by `npm test` (`tests/stateMachines.test.ts`). Don't edit it by hand. The live version, with real rows in each state, is the website's admin Machines page (`/admin/machines`, Chef's admin only).",
      "",
      "The rules live in `convex/lifecycles/`, and every machine is in the catalog in `convex/machines.ts`. Under each state are its own data fields. `[*] -->` is how a row is born and `--> [*]` marks a final state. Each event says who sends it: `(server)` for internal code, or its timer. The notes and the list under each diagram are the rules' own descriptions.",
      "",
      ...(manifests.length > 1 ? ["## Every machine", "", fence(linkedDiagram(manifests)), ""] : []),
      ...manifests.flatMap((manifest) => [
        `## \`${manifest.name}\`, on \`${manifest.table}.${manifest.field}\``,
        "",
        ...(manifest.description ? [manifest.description, ""] : []),
        fence(stateDiagram(manifest, manifests)),
        "",
        explainTransitions(manifest),
        "",
      ]),
    ].join("\n");
  }

  test("every machine, state, transition and timer says what it means", () => {
    expect(missingDescriptions(machines.manifests)).toEqual([]);
  });

  test("docs/state-machines.md is drawn from the rules the backend runs", () => {
    const markdown = renderDiagrams();
    if (process.env.UPDATE_MACHINE_DIAGRAMS === "1") writeFileSync(docPath, markdown);
    expect(readFileSync(docPath, "utf8"), "docs/state-machines.md is out of date: run `npm run machines:diagrams`").toBe(markdown);
  });
});
