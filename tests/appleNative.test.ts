import { registerCore } from "@convex-dev/auth/test";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import { afterEach, beforeAll, describe, expect, test, vi } from "vitest";
import { api } from "../convex/_generated/api";
import { APPLE_BUNDLE_ID } from "../convex/lib/appleIdentityToken";
import { setup } from "./helpers";

// The iPhone's own Sign in with Apple sheet hands the app an identity token (a JWT Apple
// signs, for the app's bundle ID), and auth:signInWithAppleNative swaps it for a session.
// Apple's review devices refuse the web sign-in sheet outright (PODDLE-A), so this is the
// way in that doesn't need a browser.

type KeyPair = Awaited<ReturnType<typeof generateKeyPair>>;
let apple: KeyPair;
let stranger: KeyPair;
let privateKey: string;
let jwks: string;

beforeAll(async () => {
  // Ephemeral keys for this test process only: Apple's (the token signer), someone else's,
  // and Convex Auth's own session-signing key.
  apple = await generateKeyPair("RS256");
  stranger = await generateKeyPair("RS256");
  const session = await generateKeyPair("RS256", { extractable: true });
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", session.privateKey as CryptoKey)).toString("base64");
  privateKey = Buffer.from(`-----BEGIN PRIVATE KEY-----\n${der}\n-----END PRIVATE KEY-----`).toString("base64");
  jwks = JSON.stringify({ keys: [{ ...(await exportJWK(session.publicKey)), kid: "test-key" }] });
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

async function setupNative() {
  vi.stubEnv("CONVEX_SITE_URL", "https://striped-turtle-260.ap-southeast-2.convex.site");
  vi.stubEnv("AUTH_PRIVATE_KEY", privateKey);
  vi.stubEnv("AUTH_JWKS", jwks);
  vi.stubEnv("PODDLE_ALLOWED_EMAILS", "friend@example.com");
  // Apple's published signing keys.
  const published = { keys: [{ ...(await exportJWK(apple.publicKey)), kid: "apple-1", alg: "RS256", use: "sig" }] };
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string | URL | Request) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      return url === "https://appleid.apple.com/auth/keys" ? Response.json(published) : new Response("not found", { status: 404 });
    }),
  );
  const t = setup();
  registerCore(t.raw);
  return t;
}

const sha256Hex = async (s: string) =>
  Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))).toString("hex");

/** An identity token like the one ASAuthorizationAppleIDCredential carries. */
async function identityToken(
  opts: { sub?: string; email?: string; nonce?: string; aud?: string; iss?: string; expiresIn?: string; key?: KeyPair } = {},
) {
  const claims: Record<string, unknown> = {
    email: opts.email ?? "friend@example.com",
    email_verified: "true",
    nonce: await sha256Hex(opts.nonce ?? "nonce-1"),
  };
  return await new SignJWT(claims)
    .setProtectedHeader({ alg: "RS256", kid: "apple-1" })
    .setIssuer(opts.iss ?? "https://appleid.apple.com")
    .setAudience(opts.aud ?? APPLE_BUNDLE_ID)
    .setSubject(opts.sub ?? "001234.apple-sub.0001")
    .setIssuedAt()
    .setExpirationTime(opts.expiresIn ?? "10m")
    .sign((opts.key ?? apple).privateKey);
}

const userCount = (t: Awaited<ReturnType<typeof setupNative>>) =>
  t.run(async (ctx) => (await ctx.db.query("users").collect()).filter((u) => u.email === "friend@example.com").length);

describe("native Sign in with Apple", () => {
  test("a token from Apple signs in, and the first time keeps the name the phone passed on", async () => {
    const t = await setupNative();
    const result = await t.raw.action(api.auth.signInWithAppleNative, {
      identityToken: await identityToken(),
      nonce: "nonce-1",
      firstName: " Pat ",
      lastName: "Lee",
    });
    expect(result.status).toBe("complete");
    const user = await t.run(async (ctx) =>
      (await ctx.db.query("users").collect()).find((u) => u.email === "friend@example.com"),
    );
    expect(user?.name).toBe("Pat Lee");
  });

  test("signing in again is the same person, not a second account", async () => {
    const t = await setupNative();
    const first = await t.raw.action(api.auth.signInWithAppleNative, { identityToken: await identityToken(), nonce: "nonce-1" });
    const again = await t.raw.action(api.auth.signInWithAppleNative, {
      identityToken: await identityToken({ nonce: "nonce-2" }),
      nonce: "nonce-2",
    });
    expect(first.status === "complete" && again.status === "complete").toBe(true);
    if (first.status !== "complete" || again.status !== "complete") return;
    expect(again.tokens.userId).toBe(first.tokens.userId);
    expect(await userCount(t)).toBe(1);
  });

  test("someone not invited gets the same invite-only answer as the web sign-in", async () => {
    const t = await setupNative();
    await expect(
      t.raw.action(api.auth.signInWithAppleNative, {
        identityToken: await identityToken({ email: "stranger@example.com", sub: "001234.stranger" }),
        nonce: "nonce-1",
      }),
    ).rejects.toThrow(/invite-only/);
  });

  test.each([
    ["signed by someone other than Apple", { key: "stranger" }],
    ["made for another app", { aud: "com.example.other" }],
    ["from another issuer", { iss: "https://evil.example.com" }],
    ["expired", { expiresIn: "-1m" }],
    ["for a different sign-in attempt (nonce)", { nonce: "someone-elses-nonce" }],
  ])("a token %s is refused and no account is made", async (_why, change) => {
    const t = await setupNative();
    const { key, ...rest } = change as { key?: string; aud?: string; iss?: string; expiresIn?: string; nonce?: string };
    const token = await identityToken({ ...rest, key: key === "stranger" ? stranger : apple });
    await expect(t.raw.action(api.auth.signInWithAppleNative, { identityToken: token, nonce: "nonce-1" })).rejects.toThrow(
      /Apple didn't confirm/,
    );
    expect(await userCount(t)).toBe(0);
  });

  test("garbage instead of a token is refused", async () => {
    const t = await setupNative();
    await expect(t.raw.action(api.auth.signInWithAppleNative, { identityToken: "not-a-jwt", nonce: "nonce-1" })).rejects.toThrow(
      /Apple didn't confirm/,
    );
  });
});
