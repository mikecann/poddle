import { getAuthUserId } from "@convex-dev/auth/server";
import type { Id } from "../_generated/dataModel";
import type { QueryCtx } from "../_generated/server";

/**
 * Who's signed in: the user their session belongs to, or the one that user was
 * merged into. Use this rather than getAuthUserId everywhere.
 */
export async function currentUserId(ctx: QueryCtx): Promise<Id<"users"> | null> {
  const userId = await getAuthUserId(ctx);
  if (userId === null) return null;
  const id = ctx.db.normalizeId("users", userId);
  const user = id && (await ctx.db.get(id));
  if (!user) return null;
  return user.mergedInto ?? user._id;
}

export async function userByEmail(ctx: QueryCtx, email: string) {
  const matches = await ctx.db
    .query("users")
    .withIndex("by_email", (q) => q.eq("email", email.trim().toLowerCase()))
    .collect();
  return matches.find((u) => u.mergedInto === undefined) ?? null;
}
