import { defineMachine } from "@convex-dev/state-machines";
import { v } from "convex/values";
import schema from "../schema";

// Whether a show's feed is being fetched right now. Every fetch claims the feed
// first (feeds.claimFetch): the poller, pull-to-refresh, opening a show and the
// Overcast import. The claim runs out after 5 minutes, so a fetch that died
// doesn't hold the feed for good. Its expiry is its token: only the fetch that
// holds the claim may finish it (feeds.recordFetch), so a fetch that outlived its
// claim can't release the one that took over, or write its older answer over it.
//
// No history: the poller fetches every followed feed every 15 minutes or so, and
// two steps a fetch would swamp it. No timer either: a claim that ran out is
// taken over by the next CLAIM rather than cleared, so a dead fetch's row stays
// `fetching` until then.
export const feedFetch = defineMachine(
  schema,
  {
    name: "feedFetch",
    table: "feedFetches",
    history: false,
    description:
      "Whether a show's feed is being fetched right now, so one feed is never fetched twice at once, and only the fetch holding the claim records how it went.",
    events: {
      server: {
        CLAIM: { lease: v.number() },
        FINISHED: { lease: v.number() },
      },
    },
    guards: {
      claimRanOut: "Another fetch of this feed is running.",
      holdsClaim: "That fetch's claim ran out and another fetch took over.",
    },
    states: {
      start: {
        on: {
          CLAIM: {
            to: "fetching",
            effect: "claim",
            description: "The first fetch of a feed (a new show, or one that was never fetched since claims moved here) claims it.",
          },
        },
      },
      idle: {
        description: "No fetch of this feed is running. The next one to start claims it.",
        on: {
          CLAIM: { to: "fetching", effect: "claim", description: "A fetch starts: the poller's, a refresh, someone opening the show, or an import." },
        },
      },
      fetching: {
        description:
          "A fetch holds the feed until `until`, 5 minutes after it started. Any other fetch that tries now is told the feed is busy.",
        on: {
          CLAIM: {
            guard: "claimRanOut",
            effect: "claim",
            description:
              "The fetch holding it died or ran past its 5 minutes, so a new fetch takes the feed over. The old one's report will be refused.",
          },
          FINISHED: {
            to: "idle",
            guard: "holdsClaim",
            effect: "release",
            description: "The fetch holding the claim has stored what it found (or its error), and lets the feed go.",
          },
        },
      },
    },
  },
  {
    guards: {
      claimRanOut: (_ctx, { state }) => state.until <= Date.now(),
      holdsClaim: (_ctx, { state, event }) => state.until === event.lease,
    },
    effects: {
      claim: async (_ctx, { event }) => ({ kind: "fetching", until: event.lease, startedAt: Date.now() }),
      release: async () => ({ kind: "idle" }),
    },
  },
);
