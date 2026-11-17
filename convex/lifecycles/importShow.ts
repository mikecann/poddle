import { defineMachine } from "@convex-dev/state-machines";
import { v } from "convex/values";
import schema from "../schema";

/** A fetch claim older than this belongs to a run that died, and another may take it. */
export const CLAIM_STALE_MS = 3 * 60_000;
/** Another fetch of the feed is running: try again this many times (past its 5-minute claim). */
export const BUSY_LIMIT = 12;

// One show within an Overcast import (an importQueue row): its feed fetched
// fresh, then its staged episodes matched to it. The batch's worker claims a few
// shows at a time, and a claim carries its time as its identity, so a run that
// was only slow can't overwrite a newer run's answer. The row stays until the
// show is matched, so a run that dies part way loses nothing; once matched it's
// purged. No history: an import has hundreds of these, and they're scratch.
export const importShow = defineMachine(
  schema,
  {
    name: "importShow",
    table: "importQueue",
    history: false,
    description:
      "One show in an Overcast import: its feed fetched, then the history staged for it matched to its episodes. It stays queued until that's done, so a worker that dies loses no shows.",
    events: {
      server: {
        QUEUED: {},
        CLAIM: { claimedAt: v.number() },
        FETCHED: {
          claimedAt: v.number(),
          feedOk: v.boolean(),
          oldestFeedPubDate: v.optional(v.number()),
          medianDuration: v.optional(v.number()),
          durations: v.array(v.number()),
        },
        BUSY: { claimedAt: v.number(), retryAt: v.number() },
        MATCHED: {},
      },
    },
    guards: {
      due: "It's waiting for another fetch of its feed to end.",
      claimStale: "A worker run is fetching it now.",
      holdsClaim: "That report is from a run whose claim was taken over, or the feed's already in.",
      canWait: "It's waited long enough for the other fetch of its feed.",
    },
    states: {
      start: {
        on: {
          QUEUED: {
            to: "waiting",
            effect: "queue",
            description: "Reading the export staged this show's episodes (or found them left without a row): it waits for a worker.",
          },
        },
      },
      waiting: {
        description: "Waiting for a worker to fetch its feed, not before `notBefore`. `busyCount`: how often its feed was busy.",
        on: { CLAIM: { to: "fetching", guard: "due", effect: "claim", description: "A worker run takes it and fetches its feed." } },
      },
      fetching: {
        description: "A worker run is fetching its feed, under the claim it took at `claimedAt`.",
        on: {
          CLAIM: {
            guard: "claimStale",
            effect: "claim",
            description: "The run that claimed it 3 minutes ago never reported (it died): a newer run takes it over.",
          },
          FETCHED: {
            to: "fetched",
            guard: "holdsClaim",
            effect: "fetched",
            description: "Its feed is in (or failed for good): what matching needs is noted, and it waits its turn to match.",
          },
          BUSY: [
            {
              to: "waiting",
              guard: "canWait",
              effect: "backOff",
              description:
                "Something else is fetching the feed (the poller, someone adding the show), so its episodes may be half stored. It waits 30 seconds rather than match against them.",
            },
            {
              to: "fetched",
              guard: "holdsClaim",
              effect: "busyTooLong",
              description: "The other fetch never finished: it's matched as a failed feed, its history kept as ghosts.",
            },
          ],
        },
      },
      fetched: {
        description: "Its feed is in. Once every show's is, its staged episodes are matched to the feed's, a page at a time.",
        on: { MATCHED: { to: "matched", description: "Every staged episode has been applied. The row is purged straight after." } },
      },
      matched: { description: "Done. Purged in the same step, so it's only ever seen there." },
    },
  },
  {
    guards: {
      due: (_ctx, { state }) => state.notBefore <= Date.now(),
      claimStale: (_ctx, { state }) => state.claimedAt + CLAIM_STALE_MS <= Date.now(),
      holdsClaim: (_ctx, { state, event }) => state.claimedAt === event.claimedAt,
      canWait: (_ctx, { state, event }) => state.claimedAt === event.claimedAt && state.busyCount + 1 < BUSY_LIMIT,
    },
    effects: {
      queue: async () => ({ kind: "waiting", notBefore: 0, busyCount: 0 }),
      claim: async (_ctx, { state, event }) => ({ kind: "fetching", claimedAt: event.claimedAt, busyCount: state.busyCount }),
      fetched: async (_ctx, { event: { type: _t, claimedAt: _c, ...found } }) => ({ kind: "fetched", ...found }),
      backOff: async (_ctx, { state, event }) => ({ kind: "waiting", notBefore: event.retryAt, busyCount: state.busyCount + 1 }),
      busyTooLong: async () => ({ kind: "fetched", feedOk: false, durations: [] }),
    },
  },
);
