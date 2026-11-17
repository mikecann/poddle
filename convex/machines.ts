import { type AppCtx, defineMachines, deliveryArgs, type InternalCtx, type Machines } from "@convex-dev/state-machines";
import { v } from "convex/values";
import { components, internal } from "./_generated/api";
import type { DataModel } from "./_generated/dataModel";
import { internalMutation, internalQuery, mutation, type MutationCtx } from "./_generated/server";
// Import the machines from here rather than their own modules: sending needs the
// catalog, and importing this loads it.
import { feedFetch } from "./lifecycles/feedFetch";
import { importBatch } from "./lifecycles/importBatch";
import { importShow } from "./lifecycles/importShow";
import schema from "./schema";

// Every state machine in Poddle (@convex-dev/state-machines, vendored in
// vendor/), checked together when the app loads. The rules live in
// convex/lifecycles/, and docs/state-machines.md draws them. The functions that
// move a machine are built with this catalog's builders, whose db can't write a
// machine's state or delete its rows; `server` events need its internalMutation,
// which carries the library's internal brand. The rest of the app stays on
// Convex's own builders (and lib/auth.ts's wrappers of them).
//
export const machines: Machines<typeof schema> = defineMachines(schema, [feedFetch, importBatch, importShow], {
  mutation,
  internalMutation,
  internalQuery,
  deliver: internal.machines.deliver,
  component: components.stateMachines,
});

export { feedFetch, importBatch, importShow };

/** A catalog handler's ctx, for the app's helpers that take Convex's MutationCtx. */
export type MachineCtx = AppCtx<DataModel> & InternalCtx;

/**
 * The app's helpers take Convex's MutationCtx. A catalog handler's db is the
 * guarded one, which still refuses a machine's writes at runtime, so passing it
 * on keeps that check: only the type is widened.
 */
export function asMutationCtx(ctx: object): MutationCtx {
  return ctx as unknown as MutationCtx;
}

// Timers fire through this.
export const deliver = machines.internalMutation({ args: deliveryArgs, handler: machines.deliver });

/** For an operator: timers whose step threw, which stay pending until rearmed. `npx convex run machines:failedTimers` */
export const failedTimers = machines.internalQuery({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, args) => await machines.failedTimers(ctx, args),
});

/** Once the bug is fixed: `npx convex run machines:rearmTimer '{"machine": "...", "id": "...", "event": "..."}'` */
export const rearmTimer = machines.internalMutation({
  args: { machine: v.string(), id: v.string(), event: v.string() },
  returns: v.null(),
  handler: async (ctx, args) => {
    await machines.rearmTimer(ctx, args);
    return null;
  },
});
