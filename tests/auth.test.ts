import { registerCore } from "@convex-dev/auth/test";
import { registerAnonymousProvider } from "@convex-dev/auth/components/anonymous/test";
import { afterEach, beforeAll, describe, expect, test, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import { allowedEmails } from "../convex/lib/allowlist";
import { testSignInRefusal } from "../convex/lib/testSignIn";
import { MIKE, setup } from "./helpers";
import { seedShow } from "./seed";

let privateKey: string;
let jwks: string;

beforeAll(async () => {
  // Ephemeral keys for this test process only. Never read deployment credentials.
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  privateKey = Buffer.from(`-----BEGIN PRIVATE KEY-----\n${der}\n-----END PRIVATE KEY-----`).toString("base64");
  jwks = JSON.stringify({ keys: [{ ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "test-key" }] });
});

afterEach(() => vi.unstubAllEnvs());

function setupAuth(env: Record<string, string | undefined> = {}) {
  vi.stubEnv("CONVEX_SITE_URL", "https://striped-turtle-260.ap-southeast-2.convex.site");
  vi.stubEnv("AUTH_PRIVATE_KEY", privateKey);
  vi.stubEnv("AUTH_JWKS", jwks);
  vi.stubEnv("PODDLE_ALLOWED_EMAILS", "Mike.Cann@gmail.com, friend@example.com");
  for (const [k, val] of Object.entries(env)) vi.stubEnv(k, val);
  const t = setup();
  registerCore(t.raw);
  registerAnonymousProvider(t.raw);
  return t;
}

const users = (t: ReturnType<typeof setup>) => t.run(async (ctx) => await ctx.db.query("users").collect());

const google = (email: string, emailVerified = true) => ({
  name: "google" as const,
  accountId: `g-${email}`,
  profile: { id: `g-${email}`, email, emailVerified, name: "G User", picture: "https://example.com/me.png" },
});
const apple = (email: string | undefined, emailVerified = true) => ({
  name: "apple" as const,
  accountId: `a-${email}`,
  profile: { id: `a-${email}`, email, emailVerified },
});

describe("allowlist", () => {
  test("parses the env var case- and space-insensitively", () => {
    expect([...allowedEmails(" A@x.com,b@Y.com ,, ")]).toEqual(["a@x.com", "b@y.com"]);
    expect(allowedEmails(undefined).size).toBe(0);
  });

  test("only allowlisted, verified emails can make an account", async () => {
    const t = setupAuth();
    await expect(t.raw.mutation(internal.users.createUserGoogle, { provider: google("stranger@example.com") })).rejects.toThrow(
      /invite-only/,
    );
    await expect(t.raw.mutation(internal.users.createUserApple, { provider: apple("friend@example.com", false) })).rejects.toThrow(
      /invite-only/,
    );
    await expect(t.raw.mutation(internal.users.createUserApple, { provider: apple(undefined) })).rejects.toThrow(/invite-only/);
    // Only the user `setup()` made for its own calls exists.
    expect((await users(t)).map((u) => u.email)).toEqual([]);
    const id = await t.raw.mutation(internal.users.createUserGoogle, { provider: google("friend@example.com") });
    expect((await t.run((ctx) => ctx.db.get(id)))?.email).toBe("friend@example.com");
  });

  test("nobody new gets in when the variable is unset", async () => {
    const t = setupAuth({ PODDLE_ALLOWED_EMAILS: undefined });
    await expect(t.raw.mutation(internal.users.createUserGoogle, { provider: google(MIKE) })).rejects.toThrow(/invite-only/);
  });
});

describe("Apple and Google are one person", () => {
  test("the same verified email lands in the same user, whichever comes first", async () => {
    const t = setupAuth();
    const viaApple = await t.raw.mutation(internal.users.createUserApple, { provider: apple("friend@example.com") });
    const viaGoogle = await t.raw.mutation(internal.users.createUserGoogle, { provider: google("FRIEND@example.com") });
    expect(viaGoogle).toBe(viaApple);
    await t.raw.mutation(internal.users.onSignInGoogle, { provider: google("friend@example.com"), userId: viaGoogle });
    const user = await t.run((ctx) => ctx.db.get(viaApple));
    expect(user).toMatchObject({ email: "friend@example.com", emailVerified: true, picture: "https://example.com/me.png" });
  });

  test("Mike's migrated user is the one his first Apple or Google sign-in finds", async () => {
    const t = setupAuth({ PODDLE_ALLOWED_EMAILS: "" });
    const ownerId = await t.raw.mutation(internal.migrations.ensureOwner, {});
    // Even with the allowlist emptied: he already has an account.
    expect(await t.raw.mutation(internal.users.createUserGoogle, { provider: google(MIKE) })).toBe(ownerId);
    expect(await t.raw.mutation(internal.users.createUserApple, { provider: apple(MIKE) })).toBe(ownerId);
    // An unverified claim to his address doesn't get in.
    await expect(t.raw.mutation(internal.users.createUserApple, { provider: apple(MIKE, false) })).rejects.toThrow(/invite-only/);
  });
});

describe("test sign-in", () => {
  test.each([undefined, "", "0", "true", "01"])("is refused, wrapper and direct, when the flag is %s", async (flag) => {
    const t = setupAuth({ PODDLE_TEST_SIGNIN: flag });
    await expect(t.raw.mutation(api.auth.signInForTesting, { email: MIKE })).rejects.toThrow(/disabled/);
    await expect(t.raw.mutation(api.auth.signInAnonymously, {})).rejects.toThrow(/disabled/);
    await expect(
      t.raw.mutation(internal.users.createUserAnonymous, { provider: { name: "anonymous", accountId: "forged", profile: {} } }),
    ).rejects.toThrow(/disabled/);
    expect(await users(t)).toEqual([]);
  });

  test("is refused on prod's addresses even with the flag set", async () => {
    for (const site of [
      "https://coordinated-dodo-120.ap-southeast-2.convex.site",
      "https://poddle.mikecann.app",
    ]) {
      expect(testSignInRefusal({ PODDLE_TEST_SIGNIN: "1", CONVEX_SITE_URL: site })).toMatch(/never allowed on production/);
      const t = setupAuth({ PODDLE_TEST_SIGNIN: "1", CONVEX_SITE_URL: site });
      await expect(t.raw.mutation(api.auth.signInForTesting, { email: MIKE })).rejects.toThrow(/production/);
      await expect(t.raw.mutation(api.auth.signInAnonymously, {})).rejects.toThrow(/production/);
      expect(await users(t)).toEqual([]);
    }
    expect(testSignInRefusal({ PODDLE_TEST_SIGNIN: "1", CONVEX_SITE_URL: "https://striped-turtle-260.ap-southeast-2.convex.site" })).toBeNull();
  });

  test("signs in as a chosen email: an existing user is reused, a new one is made", async () => {
    const t = setupAuth({ PODDLE_TEST_SIGNIN: "1" });
    const ownerId = await t.raw.mutation(internal.migrations.ensureOwner, {});
    const { episodeIds } = await seedShow(t, 1);
    await t.mutation(api.queue.add, { episodeId: episodeIds[0]!, position: "bottom", at: 1 });

    const asMike = await t.raw.mutation(api.auth.signInForTesting, { email: " Mike.Cann@gmail.com " });
    expect(asMike.status).toBe("complete");
    expect(asMike.tokens.userId).toBe(ownerId);
    expect(asMike.tokens.accessToken).toBeTruthy();
    const mike = t.raw.withIdentity({ subject: asMike.tokens.userId });
    expect(await mike.query(api.users.me, {})).toMatchObject({ userId: ownerId, email: MIKE });
    expect(await mike.query(api.queue.upNext, {})).toHaveLength(1);

    const second = await t.raw.mutation(api.auth.signInForTesting, { email: "second@poddle.test" });
    expect(second.tokens.userId).not.toBe(ownerId);
    const other = t.raw.withIdentity({ subject: second.tokens.userId });
    expect(await other.query(api.queue.upNext, {})).toEqual([]);
    expect(await other.query(api.podcasts.list, {})).toEqual([]);

    // Signing in again as the same email is the same user, and refresh keeps it.
    const again = await t.raw.mutation(api.auth.signInForTesting, { email: "second@poddle.test" });
    expect(again.tokens.userId).toBe(second.tokens.userId);
    const rotated = await t.raw.mutation(api.auth.refreshSession, { refreshToken: again.tokens.refreshToken });
    expect(rotated.kind).toBe("rotated");
    if (rotated.kind === "rotated") expect(rotated.tokens.userId).toBe(second.tokens.userId);

    // Without an email it's a fresh test user each time.
    const fresh = await t.raw.mutation(api.auth.signInForTesting, {});
    expect(fresh.tokens.userId).not.toBe(second.tokens.userId);
    await expect(t.raw.mutation(api.auth.signInForTesting, { email: "not an email" })).rejects.toThrow(/email/);
  });
});
