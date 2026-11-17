import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx } from "../_generated/server";

// While the import moves onto state machines (widen, backfill, switch), its
// rows carry their old fields and a `state` worked out from them. Every write
// to those fields mirrors it (mirrorBatch, mirrorShow), and the backfill fills
// rows from before, so the switch finds every row's state current.

export function batchStateFrom(b: Doc<"importBatches">): NonNullable<Doc<"importBatches">["state"]> {
  switch (b.status) {
    case "parsing":
      return { kind: "parsing" };
    case "fetching":
      return { kind: "fetching", worker: b.worker ?? 0, restarts: b.restarts ?? 0 };
    case "done":
      return { kind: "done", finishedAt: b.finishedAt ?? b.updatedAt };
    case "failed":
      return { kind: "failed", finishedAt: b.finishedAt ?? b.updatedAt, error: b.error ?? "The import failed." };
  }
}

export function showStateFrom(r: Doc<"importQueue">): NonNullable<Doc<"importQueue">["state"]> {
  if (r.phase === "match") {
    return {
      kind: "fetched",
      feedOk: r.feedOk ?? false,
      ...(r.oldestFeedPubDate !== undefined ? { oldestFeedPubDate: r.oldestFeedPubDate } : {}),
      ...(r.medianDuration !== undefined ? { medianDuration: r.medianDuration } : {}),
      durations: r.durations ?? [],
    };
  }
  const busyCount = r.busyCount ?? 0;
  return r.claimedAt !== undefined ? { kind: "fetching", claimedAt: r.claimedAt, busyCount } : { kind: "waiting", notBefore: r.notBefore ?? 0, busyCount };
}

/** Brings a batch's `state` (and its empty `stateTimers`) up to date with its old fields. */
export async function mirrorBatch(ctx: MutationCtx, batchId: Id<"importBatches">) {
  const row = await ctx.db.get(batchId);
  if (row) await ctx.db.patch(batchId, { state: batchStateFrom(row), ...(row.stateTimers ? {} : { stateTimers: [] }) });
}

/** Brings a queue row's `state` up to date with its old fields. */
export async function mirrorShow(ctx: MutationCtx, rowId: Id<"importQueue">) {
  const row = await ctx.db.get(rowId);
  if (row) await ctx.db.patch(rowId, { state: showStateFrom(row) });
}
