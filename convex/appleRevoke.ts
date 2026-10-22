import { v } from "convex/values";
import { SignJWT, importPKCS8 } from "jose";
import { env, internalAction } from "./_generated/server";

// Sign in with Apple token revocation, for account deletion
// (https://developer.apple.com/documentation/sign_in_with_apple/revoke_tokens).
//
// Apple wants apps that use Sign in with Apple to revoke the person's tokens
// when they delete their account. That needs a refresh or access token Apple
// issued for them. Convex Auth v2 (2.0.0-beta.0) doesn't keep one: its Apple
// callback exchanges the code, reads the id_token and drops the rest
// (lib/oauth/callback.ts, `exchangeCode`), and nothing reaches the app. So
// users:deleteAccount has nothing to pass here yet.
//
// What would make it work, either of:
// - Convex Auth hands the token response (Apple's `refresh_token`) to the app's
//   createUser/onSignIn callbacks, and users.ts saves it (encrypted) on the
//   user; deleteAccount then schedules `revokeToken` with it before the user is
//   scrubbed.
// - Or the app asks for a fresh Apple authorization at deletion time
//   (ASAuthorizationAppleIDProvider), exchanges that code at
//   https://appleid.apple.com/auth/token with the app's bundle ID as client_id,
//   and passes the refresh token here.

const REVOKE_URL = "https://appleid.apple.com/auth/revoke";

/** The form Apple's revoke endpoint takes. */
export function revokeRequest(args: { clientId: string; clientSecret: string; token: string; hint: "refresh_token" | "access_token" }) {
  return {
    url: REVOKE_URL,
    init: {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: args.clientId,
        client_secret: args.clientSecret,
        token: args.token,
        token_type_hint: args.hint,
      }).toString(),
    } satisfies RequestInit,
  };
}

/** Apple's client secret: an ES256 JWT signed with the Sign in with Apple key, as Convex Auth's Apple component makes it. */
export async function appleClientSecret(opts: { privateKey: string; teamId: string; keyId: string; clientId: string }) {
  const raw = opts.privateKey.trim().replace(/\\n/g, "\n");
  const pem = raw.startsWith("-----BEGIN")
    ? raw
    : `-----BEGIN PRIVATE KEY-----\n${raw.replace(/\s+/g, "")}\n-----END PRIVATE KEY-----`;
  const key = await importPKCS8(pem, "ES256");
  const now = Math.floor(Date.now() / 1000);
  return await new SignJWT()
    .setProtectedHeader({ alg: "ES256", kid: opts.keyId })
    .setIssuer(opts.teamId)
    .setSubject(opts.clientId)
    .setAudience("https://appleid.apple.com")
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .sign(key);
}

/** Revokes one Apple token. Ready for when there's a token to revoke (see above). */
export const revokeToken = internalAction({
  args: {
    token: v.string(),
    hint: v.union(v.literal("refresh_token"), v.literal("access_token")),
    /** The client the token was issued to: the Services ID (web sign-in, the default) or the bundle ID. */
    clientId: v.optional(v.string()),
  },
  returns: v.boolean(),
  handler: async (_ctx, { token, hint, clientId }) => {
    const client = clientId ?? env.AUTH_APPLE_CLIENT_ID;
    const clientSecret = await appleClientSecret({
      privateKey: env.AUTH_APPLE_PRIVATE_KEY,
      teamId: env.AUTH_APPLE_TEAM_ID,
      keyId: env.AUTH_APPLE_KEY_ID,
      clientId: client,
    });
    const { url, init } = revokeRequest({ clientId: client, clientSecret, token, hint });
    const res = await fetch(url, init);
    if (!res.ok) console.error(`Apple token revocation failed: ${res.status} ${await res.text()}`);
    return res.ok;
  },
});
