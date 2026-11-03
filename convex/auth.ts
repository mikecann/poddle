import { setupConvexAuth } from "@convex-dev/auth/server";
import { normalizeAppleProfile, setupApple, type AppleProfile } from "@convex-dev/auth/methods/apple/server";
import { setupGoogle } from "@convex-dev/auth/methods/google/server";
import { setupAnonymous } from "@convex-dev/auth/methods/anonymous/server";
import type { SignInComplete, TokenBundle } from "@convex-dev/auth";
import type { ObjectType, PropertyValidators } from "convex/values";
import type { RegisteredAction } from "convex/server";
import { ConvexError, v } from "convex/values";
import { api, components, internal } from "./_generated/api";
import { env, mutation, type ActionCtx } from "./_generated/server";
import { testSignInRefusal } from "./lib/testSignIn";
import { appleName, verifyAppleIdentityToken } from "./lib/appleIdentityToken";

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
// ends on this deployment's own site (see http.ts). The website comes back to
// whichever page started the sign-in: the deployment's own site, or its public
// address (PODDLE_SITE_URL, the custom domain on prod).
const allowedRedirectOrigins = [
  ...new Set([env.CONVEX_SITE_URL, env.PODDLE_SITE_URL].flatMap((u) => (u ? [new URL(u).origin] : []))),
];

// Native Sign in with Apple (below) has to sign people into the same accounts as the web
// flow, and Convex Auth keys accounts by provider name plus Apple's `sub`. A second provider
// can't take the name "apple" (bindProvider refuses duplicates), so this hands setupApple a
// core that keeps the "apple" binding's function builders for signInWithAppleNative too.
// bindProvider is marked internal in 2.0.0-beta.0: check this still works when upgrading.
type AppleHelpers = {
  resolveUserId(providerAccountId: string): Promise<string | null>;
  completeSignUp(args: { providerAccountId: string; profile: AppleProfile }): Promise<TokenBundle>;
  completeSignIn(args: { providerAccountId: string; profile: AppleProfile }): Promise<TokenBundle>;
};
type AppleBuilders = {
  authAction<Args extends PropertyValidators, Result>(fn: {
    args: Args;
    handler: (ctx: ActionCtx & { convexAuth: AppleHelpers }, args: ObjectType<Args>) => Promise<Result>;
  }): RegisteredAction<"public", ObjectType<Args>, Promise<Result>>;
};
type CoreWithBind = typeof auth & { bindProvider(options: unknown): AppleBuilders };
let appleBuilders: AppleBuilders | undefined;
const appleCore = {
  ...auth,
  bindProvider: (options: unknown) => (appleBuilders = (auth as CoreWithBind).bindProvider(options)),
} as typeof auth;

export const { startSignInWithApple, completeSignInWithApple } = setupApple(appleCore, {
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

if (!appleBuilders) throw new Error("setupApple didn't bind its provider: native Sign in with Apple can't share its accounts");

/**
 * Sign in with the iPhone's own Apple sheet: the app sends the identity token Apple gave it,
 * the nonce it made for this attempt, and (first time only) the name Apple passed on. Apple's
 * App Review devices refuse the web sign-in sheet outright (PODDLE-A), and this needs no
 * browser. Same accounts, allowlist and user callbacks as the web flow, since it's the same
 * "apple" provider and Apple's `sub` is the same for the app and the website.
 */
export const signInWithAppleNative = appleBuilders.authAction({
  args: {
    identityToken: v.string(),
    nonce: v.string(),
    firstName: v.optional(v.string()),
    lastName: v.optional(v.string()),
  },
  handler: async (ctx, args): Promise<SignInComplete> => {
    const claims = await verifyAppleIdentityToken(args.identityToken, args.nonce);
    const profile = normalizeAppleProfile(claims, appleName(args.firstName, args.lastName));
    // Like Convex Auth's own completion: a first sign-in makes the account, a return visit finds it.
    const existing = await ctx.convexAuth.resolveUserId(profile.id);
    const tokens =
      existing === null
        ? await ctx.convexAuth.completeSignUp({ providerAccountId: profile.id, profile })
        : await ctx.convexAuth.completeSignIn({ providerAccountId: profile.id, profile });
    return { status: "complete", tokens };
  },
});
