import { viewerArgs } from "@convex-dev/state-machines";
import { components } from "./_generated/api";
import { query, type QueryCtx } from "./_generated/server";
import { currentUserId } from "./lib/identity";
import { machines } from "./machines";

// What the website's admin Machines page (/admin/machines) reads: every state
// machine as the backend runs it, with live counts, and each row's state.
// Read-only: there's no `send` or `create`, so nothing here moves a row.
//
// Only Chef's admin (Mike, named with `chef:chefSetAdmin`) reads anything.
// Everyone else, signed in or not, gets null from every query, which the viewer
// shows as off rather than an error. That check needs runQuery (Chef keeps its
// roles in its component), which the library's own `read` check doesn't get, so
// `read` is only a floor under it: whoever calls must at least be signed in.
const viewer = machines.viewer({ read: async (ctx) => (await ctx.auth.getUserIdentity()) !== null });

async function isAdmin(ctx: QueryCtx) {
  const userId = await currentUserId(ctx);
  if (!userId) return false;
  return (await ctx.runQuery(components.feedback.users.get, { userId }))?.role === "admin";
}

async function adminOnly<T>(ctx: QueryCtx, read: () => Promise<T>) {
  return (await isAdmin(ctx)) ? await read() : null;
}

export const overview = query({ args: viewerArgs.overview, handler: (ctx) => adminOnly(ctx, () => viewer.overview(ctx)) });
export const counts = query({ args: viewerArgs.counts, handler: (ctx, args) => adminOnly(ctx, () => viewer.counts(ctx, args)) });
export const rows = query({ args: viewerArgs.rows, handler: (ctx, args) => adminOnly(ctx, () => viewer.rows(ctx, args)) });
export const row = query({ args: viewerArgs.row, handler: (ctx, args) => adminOnly(ctx, () => viewer.row(ctx, args)) });
