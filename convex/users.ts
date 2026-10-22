import { ConvexError, v } from "convex/values";
import { vAppleProfile } from "@convex-dev/auth/methods/apple/server";
import { vGoogleProfile } from "@convex-dev/auth/methods/google/server";
import type { Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, mutation, query, type MutationCtx } from "./_generated/server";
import { deletionInProgress, startDeletion } from "./accountDeletion";
import { assertMaySignUp, signUpIsOpen } from "./lib/allowlist";
import { resolveCaller, vAdmin } from "./lib/auth";
import { currentUserId, userByEmail } from "./lib/identity";
import { testSignInRefusal } from "./lib/testSignIn";

const vApple = v.object({ name: v.literal("apple"), accountId: v.string(), profile: vAppleProfile });
const vGoogle = v.object({ name: v.literal("google"), accountId: v.string(), profile: vGoogleProfile });

type Details = { name?: string; email?: string; emailVerified: boolean };

/**
 * Someone who's already signed in with this email. Apple and Google both vouch for
 * the address, so signing in the other way gets you the same account. Only for
 * verified emails on both sides, or anyone could claim an address and get in.
 * Mike's migrated user is made with his verified email, so his first sign-in lands in it.
 */
async function existingUser(ctx: MutationCtx, details: Details): Promise<Id<"users"> | null> {
  if (!details.email || !details.emailVerified) return null;
  const user = await userByEmail(ctx, details.email);
  return user?.emailVerified ? user._id : null;
}

/** An existing account with this email, or a new one if the email is on the allowlist. */
async function findOrCreate(ctx: MutationCtx, details: Details, extra: { picture?: string } = {}) {
  const existing = await existingUser(ctx, details);
  if (existing) return existing;
  assertMaySignUp(details.email, details.emailVerified);
  return await ctx.db.insert("users", {
    name: details.name,
    email: details.email?.trim().toLowerCase(),
    emailVerified: details.emailVerified,
    ...extra,
  });
}

/**
 * Keeps the user's name and email up to date from what Apple or Google sent.
 * Apple only sends the name the first time, so an empty one never wipes a saved one.
 */
async function saveDetails(ctx: MutationCtx, userId: Id<"users">, details: Details) {
  await reviveIfDeleted(ctx, userId, details);
  const user = await ctx.db.get(userId);
  if (user === null) return;
  await ctx.db.patch(userId, {
    name: user.name ?? details.name,
    email: details.email?.trim().toLowerCase() ?? user.email,
    emailVerified: details.email === undefined ? user.emailVerified : details.emailVerified,
  });
}

/**
 * Someone who deleted their account is signing in again with the same Apple or
 * Google account. Convex Auth still points that account at their old (emptied)
 * user, so it comes back as a fresh, empty account, as long as they could sign
 * up today and the old data has finished going.
 */
async function reviveIfDeleted(ctx: MutationCtx, userId: Id<"users">, details: Details) {
  const user = await ctx.db.get(userId);
  if (user === null) throw new ConvexError({ code: "unknownUser", message: "That account doesn't exist any more." });
  const owner = user.mergedInto ? await ctx.db.get(user.mergedInto) : user;
  const deleted = [...new Set([user, owner])].filter((u) => u != null && u.deletedAt !== undefined) as NonNullable<typeof user>[];
  if (deleted.length === 0) return;
  for (const u of deleted) {
    if (await deletionInProgress(ctx, u._id)) {
      throw new ConvexError({
        code: "accountDeleting",
        message: "Your old account is still being deleted. Give it a few minutes and try again.",
      });
    }
  }
  assertMaySignUp(details.email, details.emailVerified);
  for (const u of deleted) await ctx.db.patch(u._id, { deletedAt: undefined });
}

export { currentUserId };

export const createUserApple = internalMutation({
  args: { provider: vApple },
  returns: v.id("users"),
  handler: async (ctx, { provider: { profile } }) => await findOrCreate(ctx, profile),
});

export const onSignInApple = internalMutation({
  args: { provider: vApple, userId: v.id("users") },
  returns: v.null(),
  handler: async (ctx, { provider: { profile }, userId }) => {
    await saveDetails(ctx, userId, profile);
    return null;
  },
});

export const createUserGoogle = internalMutation({
  args: { provider: vGoogle },
  returns: v.id("users"),
  handler: async (ctx, { provider: { profile } }) => await findOrCreate(ctx, profile, { picture: profile.picture }),
});

export const onSignInGoogle = internalMutation({
  args: { provider: vGoogle, userId: v.id("users") },
  returns: v.null(),
  handler: async (ctx, { provider: { profile }, userId }) => {
    await saveDetails(ctx, userId, profile);
    if (profile.picture) await ctx.db.patch(userId, { picture: profile.picture });
    return null;
  },
});

/**
 * Test sign-in (dev only). Every anonymous sign-in calls this, including direct
 * calls that bypass `auth:signInForTesting`, so the gate is here, before any user
 * or session exists. `signInForTesting` leaves the email it wants in
 * `testSignIns`; that user is reused (Mike's migrated one, say) or made, if
 * that email could sign up (the allowlist, or open sign-up).
 * A bare anonymous sign-in gets a fresh test user with no email.
 */
export const createUserAnonymous = internalMutation({
  args: { provider: v.object({ name: v.literal("anonymous"), accountId: v.string(), profile: v.object({}) }) },
  returns: v.id("users"),
  handler: async (ctx) => {
    const refusal = testSignInRefusal();
    if (refusal) throw new ConvexError({ code: "testSignInDisabled", message: refusal });
    const request = await ctx.db.query("testSignIns").order("desc").first();
    if (request) await ctx.db.delete(request._id);
    if (request) {
      const existing = await userByEmail(ctx, request.email);
      if (existing) return existing._id;
      // A new person goes through the same gate as Apple and Google, so test sign-in
      // shows what they'd see (the e2e suites' invite-only scenario).
      assertMaySignUp(request.email, true);
      return await ctx.db.insert("users", { email: request.email, emailVerified: true, name: request.email, isTest: true });
    }
    const suffix = crypto.randomUUID().slice(0, 4).toUpperCase();
    return await ctx.db.insert("users", { name: `Test listener ${suffix}`, isTest: true });
  },
});

/** The signed-in user's name, email and Google photo, or null when signed out. */
export const me = query({
  args: {},
  returns: v.union(
    v.null(),
    v.object({
      userId: v.id("users"),
      name: v.union(v.string(), v.null()),
      email: v.union(v.string(), v.null()),
      picture: v.union(v.string(), v.null()),
    }),
  ),
  handler: async (ctx) => {
    const userId = await currentUserId(ctx);
    if (userId === null) return null;
    const user = await ctx.db.get(userId);
    if (user === null) return null;
    return { userId, name: user.name ?? null, email: user.email ?? null, picture: user.picture ?? null };
  },
});

/** Whether anyone with a verified Apple or Google email can make an account (PODDLE_OPEN_SIGNUP). */
export const signUpOpen = query({
  args: {},
  returns: v.boolean(),
  handler: async () => signUpIsOpen(),
});

/**
 * Deletes the signed-in person's account (App Store Guideline 5.1.1(v)). They're
 * signed out straight away: the user row loses its name, email and photo and
 * becomes a tombstone that every session treats as signed out. Their library,
 * queue, history, stats, settings, devices, imports and Chef requests are then
 * deleted in the background (accountDeletion.ts). The app also calls
 * auth:signOut to end its own session. Not on the admin path: only the person
 * themselves, signed in, can do this.
 */
export const deleteAccount = mutation({
  args: {},
  returns: v.object({ deletionId: v.id("accountDeletions") }),
  handler: async (ctx) => {
    const userId = await currentUserId(ctx);
    if (userId === null) throw new ConvexError({ code: "unauthenticated", message: "Sign in first" });
    const now = Date.now();
    const scrub = { deletedAt: now, name: undefined, email: undefined, emailVerified: undefined, picture: undefined };
    await ctx.db.patch(userId, scrub);
    // Older user rows folded into this one (the same person through another provider).
    const merged = await ctx.db
      .query("users")
      .withIndex("by_mergedInto", (q) => q.eq("mergedInto", userId))
      .collect();
    for (const m of merged) await ctx.db.patch(m._id, scrub);
    // Convex Auth v2 keeps no Apple tokens to revoke (appleRevoke.ts says what's missing).
    const deletionId = await startDeletion(ctx, userId);
    return { deletionId };
  },
});

/** For actions: who's calling (see lib/auth.ts). */
export const callerId = internalQuery({
  args: { admin: vAdmin },
  returns: v.id("users"),
  handler: async (ctx, { admin }) => await resolveCaller(ctx, admin),
});
