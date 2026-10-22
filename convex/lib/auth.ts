import { ConvexError, v } from "convex/values";
import {
  customAction,
  customMutation,
  customQuery,
} from "convex-helpers/server/customFunctions";
import { internal } from "../_generated/api";
import type { Id } from "../_generated/dataModel";
import { action, mutation, query, type MutationCtx, type QueryCtx } from "../_generated/server";
import { currentUserId, userByEmail } from "./identity";

/**
 * Every public function is built with one of these wrappers. They put the
 * caller's user id on `ctx.userId`, and every read and write is scoped to it.
 *
 * The caller is whoever is signed in with Convex Auth. Scripts (the Overcast
 * importer, the orchestrator) can instead pass `admin: { token, email }`: the
 * token is checked against PODDLE_API_TOKEN in constant time and the call acts
 * as the user with that email.
 *
 * Use `internalQuery` etc. from _generated/server for internal functions, and
 * `asUser(ctx, userId)` when an internal function works for one person.
 */

export type UserQueryCtx = QueryCtx & { userId: Id<"users"> };
export type UserMutationCtx = MutationCtx & { userId: Id<"users"> };

export function asUser<C extends QueryCtx>(ctx: C, userId: Id<"users">): C & { userId: Id<"users"> } {
  return { ...ctx, userId };
}

/** Constant-time string compare: runtime depends only on the expected length. */
export function constantTimeEqual(provided: string, expected: string): boolean {
  const enc = new TextEncoder();
  const a = enc.encode(provided);
  const b = enc.encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) {
    diff |= (a[i % Math.max(a.length, 1)] ?? 0) ^ (b[i] ?? 0);
  }
  return diff === 0;
}

export function assertAdminToken(token: string): void {
  const expected = process.env.PODDLE_API_TOKEN;
  if (!expected) {
    throw new ConvexError({ code: "unconfigured", message: "PODDLE_API_TOKEN is not set" });
  }
  if (!constantTimeEqual(token, expected)) {
    throw new ConvexError({ code: "unauthorized", message: "Bad admin token" });
  }
}

export const vAdmin = v.optional(v.object({ token: v.string(), email: v.string() }));
export type Admin = { token: string; email: string } | undefined;

export async function resolveCaller(ctx: QueryCtx, admin: Admin): Promise<Id<"users">> {
  if (admin) {
    assertAdminToken(admin.token);
    const user = await userByEmail(ctx, admin.email);
    if (!user) throw new ConvexError({ code: "unknownUser", message: `No user with email ${admin.email}` });
    return user._id;
  }
  const userId = await currentUserId(ctx);
  if (!userId) throw new ConvexError({ code: "unauthenticated", message: "Sign in first" });
  return userId;
}

const callerArgs = { admin: vAdmin };

export const userQuery = customQuery(query, {
  args: callerArgs,
  input: async (ctx, { admin }) => ({ ctx: { userId: await resolveCaller(ctx, admin) }, args: {} }),
});

export const userMutation = customMutation(mutation, {
  args: callerArgs,
  input: async (ctx, { admin }) => ({ ctx: { userId: await resolveCaller(ctx, admin) }, args: {} }),
});

export const userAction = customAction(action, {
  args: callerArgs,
  input: async (ctx, { admin }) => {
    const userId: Id<"users"> = await ctx.runQuery(internal.users.callerId, { admin });
    return { ctx: { userId }, args: {} };
  },
});
