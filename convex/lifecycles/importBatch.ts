import { defineMachine } from "@convex-dev/state-machines";
import { makeFunctionReference } from "convex/server";
import { v } from "convex/values";
import type { Id } from "../_generated/dataModel";
import schema from "../schema";

// The functions the effects schedule, by name rather than through `internal`:
// those modules import the catalog, which imports this, and the generated types
// would go round in a circle.
const processBatch = makeFunctionReference<"action", { batchId: Id<"importBatches">; worker?: number }>("importActions:processBatch");
const discardScratch = makeFunctionReference<"mutation", { batchId: Id<"importBatches"> }>("overcastImport:discardScratch");

/** No progress for this long and the watchdog starts the worker again. */
export const IMPORT_STALL_MS = 5 * 60_000;
/** Reading the file is one action, which Convex stops after 10 minutes. */
export const PARSE_STALL_MS = 15 * 60_000;
/** Restarts in a row without progress before the import gives up. */
export const MAX_RESTARTS = 3;

// One Overcast import (overcastImport.ts has the whole pipeline). The work runs
// as a chain of scheduled actions (importActions.processBatch), and any of them
// can die, so the batch watches itself: while fetching, a timer checks every 5
// minutes that it's still getting somewhere (its counts, and so `updatedAt`, move
// with every show fetched or matched), starts a new run of the chain if not, and
// gives up after three restarts in a row. Each run has a number, and an older
// run stops at its next step. done and failed are final, so a late result (a
// parse or a run that outlived its batch) can't move it again.
export const importBatch = defineMachine(
  schema,
  {
    name: "importBatch",
    table: "importBatches",
    description:
      "One Overcast import, from reading the file to Up Next being seeded. It restarts itself when its worker stops, and ends once, as done or failed.",
    events: {
      server: {
        START: {},
        PARSED: {},
        FAILED: { error: v.string() },
        ALL_MATCHED: {},
      },
    },
    guards: {
      madeProgress: "The import hasn't got anywhere in the last 5 minutes.",
      canRestart: "The import has been restarted three times in a row without getting anywhere.",
    },
    states: {
      start: {
        on: {
          START: {
            to: "parsing",
            description: "Someone uploads their Overcast export in the app (or a script does), and reading it starts.",
          },
        },
      },
      parsing: {
        description:
          "The file is being read: every show in it is created or found, and its episodes staged to match once its feed is in.",
        timers: {
          READ_STALLED: {
            after: PARSE_STALL_MS,
            description: "15 minutes since reading began, longer than Convex lets the reading action run: it died.",
          },
        },
        on: {
          PARSED: {
            to: "fetching",
            effect: "startWorker",
            description: "Every show is staged: the first run of the worker starts fetching their feeds.",
          },
          FAILED: { to: "failed", effect: "fail", description: "The file couldn't be read (not an OPML file, or the upload's gone)." },
          READ_STALLED: { to: "failed", effect: "readStalled", description: "Reading stopped part way. The person is asked to import again." },
        },
      },
      fetching: {
        description:
          "The worker is fetching each show's feed, a few at a time, then matching each show's staged episodes to it. `worker` is which run of the chain owns it; `restarts`, how many in a row haven't got anywhere.",
        timers: {
          CHECK: {
            after: IMPORT_STALL_MS,
            description: "Every 5 minutes while it's fetching: is it still getting somewhere?",
          },
        },
        on: {
          CHECK: [
            { guard: "madeProgress", effect: "keepGoing", description: "It got somewhere since the last check: carry on." },
            {
              guard: "canRestart",
              effect: "restartWorker",
              description: "Nothing for 5 minutes, so its worker died: a new run starts where it stopped, and the old one stops at its next step.",
            },
            { to: "failed", effect: "gaveUp", description: "Three restarts in a row got nowhere. The person is asked to import again." },
          ],
          ALL_MATCHED: {
            to: "done",
            effect: "finish",
            description: "Every show is fetched and matched, and Up Next has been seeded in Overcast's order.",
          },
        },
      },
      done: { description: "The import finished. Its counts are the receipt the app shows." },
      failed: { description: "The import stopped, with the reason the app shows. Its scratch rows are cleared away." },
    },
  },
  {
    guards: {
      madeProgress: (_ctx, { row }) => row.updatedAt > Date.now() - IMPORT_STALL_MS,
      canRestart: (_ctx, { state }) => state.restarts < MAX_RESTARTS,
    },
    effects: {
      startWorker: async (ctx, { id }) => {
        await ctx.scheduler.runAfter(0, processBatch, { batchId: id, worker: 1 });
        return { kind: "fetching", worker: 1, restarts: 0 };
      },
      keepGoing: async (_ctx, { state }) => ({ ...state, restarts: 0 }),
      restartWorker: async (ctx, { id, state }) => {
        const worker = state.worker + 1;
        console.warn(`Import ${id} made no progress for 5 min: restarting it (run ${worker})`);
        await ctx.scheduler.runAfter(0, processBatch, { batchId: id, worker });
        return { kind: "fetching", worker, restarts: state.restarts + 1 };
      },
      finish: async () => ({ kind: "done", finishedAt: Date.now() }),
      fail: async (ctx, { id, event }) => await failed(ctx, id, event.error),
      readStalled: async (ctx, { id }) => await failed(ctx, id, "Reading the file stopped part way. Try importing it again."),
      gaveUp: async (ctx, { id }) =>
        await failed(ctx, id, "The import stopped part way and couldn't restart. Try importing the file again."),
    },
  },
);

/**
 * Failed, with the reason the app shows; its scratch rows go straight after. Its
 * `updatedAt` moves too: sync:changes pages by it, so a client that has synced
 * past the batch's last progress would otherwise never hear it failed.
 */
async function failed(
  ctx: {
    db: { patch: (table: "importBatches", id: Id<"importBatches">, value: { updatedAt: number }) => Promise<void> };
    scheduler: { runAfter: (ms: number, fn: typeof discardScratch, args: { batchId: Id<"importBatches"> }) => Promise<unknown> };
  },
  id: Id<"importBatches">,
  error: string,
): Promise<{ kind: "failed"; finishedAt: number; error: string }> {
  const now = Date.now();
  await ctx.db.patch("importBatches", id, { updatedAt: now });
  await ctx.scheduler.runAfter(0, discardScratch, { batchId: id });
  return { kind: "failed", finishedAt: now, error };
}
