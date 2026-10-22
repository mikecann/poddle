import { setupConvexAuth } from "@convex-dev/auth/server";
import { setupApple } from "@convex-dev/auth/methods/apple/server";
import { setupGoogle } from "@convex-dev/auth/methods/google/server";
import { setupAnonymous } from "@convex-dev/auth/methods/anonymous/server";
import type { SignInComplete } from "@convex-dev/auth";
import { ConvexError, v } from "convex/values";
import { api, components, internal } from "./_generated/api";
import { env, mutation } from "./_generated/server";
import { testSignInRefusal } from "./lib/testSignIn";

// Convex Auth v2, set up the way Walkies does it: Apple and Google through their
// web sign-in pages, plus a dev-only test sign-in. users.ts makes the users.

const auth = setupConvexAuth({ component: components.auth });
export const { signOut, refreshSession, isAuthenticated } = auth;

export const { signInAnonymously } = setupAnonymous(auth, {
  component: components.authAnonymous,
}).attachUserCallbacks({ createUser: internal.users.createUserAnonymous });

/**
 * Test sign-in (dev only, PODDLE_TEST_SIGNIN=1). With an email it signs in as
 * that user (making a test user if there isn't one), e.g. Mike's migrated
 * account on the dev copy of prod. Without one it makes a fresh test user.
 */
export const signInForTesting = mutation({
  args: { email: v.optional(v.string()) },
  handler: async (ctx, { email }): Promise<SignInComplete> => {
    const refusal = testSignInRefusal();
    if (refusal) throw new ConvexError({ code: "testSignInDisabled", message: refusal });
    const wanted = email?.trim().toLowerCase();
    if (wanted !== undefined && !/^[^\s@]+@[^\s@]+$/.test(wanted)) {
      throw new ConvexError({ code: "badEmail", message: "That doesn't look like an email address." });
    }
    // users:createUserAnonymous picks this up inside the same transaction.
    if (wanted) await ctx.db.insert("testSignIns", { email: wanted });
    return await ctx.runMutation(api.auth.signInAnonymously, {});
  },
});

// The iPhone app runs Apple's and Google's sign-in pages in a secure sheet, which
// ends on this deployment's own site (see http.ts). The website (later) will add
// its own origin here.
const allowedRedirectOrigins = [new URL(env.CONVEX_SITE_URL).origin];

export const { startSignInWithApple, completeSignInWithApple } = setupApple(auth, {
  component: components.authApple,
  allowedRedirectOrigins,
}).attachUserCallbacks({
  createUser: internal.users.createUserApple,
  onSignIn: internal.users.onSignInApple,
});

export const { startSignInWithGoogle, completeSignInWithGoogle } = setupGoogle(auth, {
  component: components.authGoogle,
  allowedRedirectOrigins,
}).attachUserCallbacks({
  createUser: internal.users.createUserGoogle,
  onSignIn: internal.users.onSignInGoogle,
});
