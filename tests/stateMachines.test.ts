import { readFileSync, writeFileSync } from "node:fs";
import { explainTransitions, linkedDiagram, missingDescriptions, stateDiagram } from "@convex-dev/state-machines";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { internal } from "../convex/_generated/api";
import { machines } from "../convex/machines";
import { drain, setup } from "./helpers";

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
  // The backfill wrote each batch's state directly, so one it left fetching has no
  // CHECK timer, and nothing would notice its worker had died.
  test("arming a backfilled batch's timers lets it notice its dead worker", async () => {
    const t = setup();
    const userId = await t.userId();
    const batchId = await t.run(async (ctx) =>
      ctx.db.insert("importBatches", {
        userId, source: "overcast", state: { kind: "fetching", worker: 3, restarts: 0 }, stateTimers: [],
        assumedSpeed: 2, startedAt: NOW, counts, playlists: [], updatedAt: NOW,
      }),
    );
    expect(await t.mutation(internal.migrations.armImportTimers, {})).toBe(1);
    expect(await t.mutation(internal.migrations.armImportTimers, {})).toBe(0); // already armed
    // Its queue is empty, so the restarted run finds nothing left and finishes it.
    await drain(t);
    const batch = await t.run(async (ctx) => await ctx.db.get(batchId));
    expect(batch?.state).toMatchObject({ kind: "done" });
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
