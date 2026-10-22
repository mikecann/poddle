import { defineApp } from "convex/server";
import { v } from "convex/values";
import core from "@convex-dev/auth/convex.config.js";
import apple from "@convex-dev/auth/components/apple/convex.config.js";
import google from "@convex-dev/auth/components/google/convex.config.js";
import anonymous from "@convex-dev/auth/components/anonymous/convex.config.js";

const app = defineApp({
  env: {
    // Convex Auth's signing keys. Generate with `node scripts/set-auth-keys.mjs <dev|prod>`.
    AUTH_PRIVATE_KEY: v.string(),
    AUTH_JWKS: v.string(),
    // Provider settings, set by `node scripts/set-oauth-keys.mjs`. Convex Auth's
    // components need every one of them set to deploy, so before Apple and Google
    // are set up, `--placeholders` fills the missing ones with "not-configured":
    // the deployment runs, and signing in with that provider fails until the
    // real values go in.
    // A Services ID made for Poddle, the team ID, and a Sign in with Apple key
    // (its ID and the contents of its AuthKey_<id>.p8 file).
    AUTH_APPLE_CLIENT_ID: v.string(),
    AUTH_APPLE_TEAM_ID: v.string(),
    AUTH_APPLE_KEY_ID: v.string(),
    AUTH_APPLE_PRIVATE_KEY: v.string(),
    // A Google OAuth client of the "Web application" type.
    AUTH_GOOGLE_CLIENT_ID: v.string(),
    AUTH_GOOGLE_CLIENT_SECRET: v.string(),
    // Comma-separated emails allowed to make an account (lib/allowlist.ts).
    PODDLE_ALLOWED_EMAILS: v.optional(v.string()),
    // Unset on production. Only an explicit "1" enables test sign-in (auth.ts).
    PODDLE_TEST_SIGNIN: v.optional(v.string()),
    // Admin path for scripts (lib/auth.ts) and APNs, read with process.env.
    PODDLE_API_TOKEN: v.optional(v.string()),
    APNS_KEY_P8: v.optional(v.string()),
    APNS_KEY_ID: v.optional(v.string()),
    APNS_TEAM_ID: v.optional(v.string()),
    APNS_TOPIC: v.optional(v.string()),
    APNS_ENV: v.optional(v.string()),
  },
});

app.use(core, {
  httpPrefix: "/auth",
  env: {
    AUTH_PRIVATE_KEY: app.env.AUTH_PRIVATE_KEY,
    AUTH_JWKS: app.env.AUTH_JWKS,
  },
});

// Apple and Google send people back to <site>/oauth/apple/callback and
// <site>/oauth/google/callback, so those are the return URLs to register.
app.use(apple, {
  httpPrefix: "/oauth/apple",
  env: {
    CLIENT_ID: app.env.AUTH_APPLE_CLIENT_ID,
    TEAM_ID: app.env.AUTH_APPLE_TEAM_ID,
    KEY_ID: app.env.AUTH_APPLE_KEY_ID,
    PRIVATE_KEY: app.env.AUTH_APPLE_PRIVATE_KEY,
  },
});
app.use(google, {
  httpPrefix: "/oauth/google",
  env: {
    CLIENT_ID: app.env.AUTH_GOOGLE_CLIENT_ID,
    CLIENT_SECRET: app.env.AUTH_GOOGLE_CLIENT_SECRET,
  },
});
// Only for test sign-in on dev; refused unless PODDLE_TEST_SIGNIN=1 (users.ts).
app.use(anonymous);

export default app;
