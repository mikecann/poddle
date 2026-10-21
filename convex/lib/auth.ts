import { ConvexError, v } from "convex/values";
import {
  customAction,
  customMutation,
  customQuery,
} from "convex-helpers/server/customFunctions";
import { action, mutation, query } from "../_generated/server";

/**
 * Single-user auth. Every public function is built with one of these wrappers,
 * which add a required `token` arg and check it against PODDLE_API_TOKEN.
 * Use `internalQuery` etc. from _generated/server for internal functions.
 */

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

export function assertToken(token: string): void {
  const expected = process.env.PODDLE_API_TOKEN;
  if (!expected) {
    throw new ConvexError({ code: "unconfigured", message: "PODDLE_API_TOKEN is not set" });
  }
  if (!constantTimeEqual(token, expected)) {
    throw new ConvexError({ code: "unauthorized", message: "Bad API token" });
  }
}

const tokenCheck = {
  args: { token: v.string() },
  input: async (_ctx: unknown, { token }: { token: string }) => {
    assertToken(token);
    return { ctx: {}, args: {} };
  },
};

export const userQuery = customQuery(query, tokenCheck);
export const userMutation = customMutation(mutation, tokenCheck);
export const userAction = customAction(action, tokenCheck);
