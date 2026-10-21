import { generateKeyPairSync, verify } from "node:crypto";
import { describe, expect, test } from "vitest";
import { api } from "../convex/_generated/api";
import { apnsConfig, providerToken } from "../convex/apns";
import { constantTimeEqual } from "../convex/lib/auth";
import { setup, TOKEN, type T } from "./helpers";
import { BASE, seedShow } from "./seed";

describe("auth", () => {
  test("constant-time compare", () => {
    expect(constantTimeEqual("abc", "abc")).toBe(true);
    expect(constantTimeEqual("abd", "abc")).toBe(false);
    expect(constantTimeEqual("ab", "abc")).toBe(false);
    expect(constantTimeEqual("", "abc")).toBe(false);
    expect(constantTimeEqual("abcd", "abc")).toBe(false);
  });

  test("every kind of public function checks the token", async () => {
    const t = setup();
    await expect(t.mutation(api.queue.clear, { token: "x", at: 1 })).rejects.toThrow(/Bad API token/);
    await expect(t.action(api.directory.search, { token: "x", term: "a" })).rejects.toThrow(/Bad API token/);
    delete process.env.PODDLE_API_TOKEN;
    await expect(t.query(api.episodes.inbox, { token: TOKEN })).rejects.toThrow(/not set/);
  });
});

async function pull(t: T, table: "queueItems" | "deletions" | "episodeStates", since: number) {
  const r = await t.query(api.sync.changes, { token: TOKEN, table, since, paginationOpts: { cursor: null, numItems: 100 } });
  return r;
}

describe("sync.changes", () => {
  test("pages changes since a cursor and reports deletions", async () => {
    const t = setup();
    const { episodeIds } = await seedShow(t, 3);
    const full = await pull(t, "queueItems", 0);
    expect(full.page).toHaveLength(0);

    for (const id of episodeIds) await t.mutation(api.queue.add, { token: TOKEN, episodeId: id, position: "bottom", at: BASE });
    const snap = await pull(t, "queueItems", 0);
    expect(snap.page).toHaveLength(3);
    expect(snap.isDone).toBe(true);
    const cursor = snap.maxUpdatedAt!;

    await t.mutation(api.queue.remove, { token: TOKEN, episodeId: episodeIds[1]!, at: BASE + 1 });
    const del = await pull(t, "deletions", cursor);
    expect(del.page).toHaveLength(1);
    expect(del.page[0]).toMatchObject({ table: "queueItems", episodeId: episodeIds[1] });
  });
});

describe("APNs", () => {
  test("no-op config when env is missing", () => {
    delete process.env.APNS_KEY_P8;
    expect(apnsConfig()).toBeNull();
  });

  test("ES256 provider token verifies with the key's public half", () => {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
    process.env.APNS_KEY_P8 = pem.replace(/\n/g, "\\n");
    process.env.APNS_KEY_ID = "ABC123DEFG";
    process.env.APNS_TEAM_ID = "4DTAZSZL6B";
    process.env.APNS_TOPIC = "com.mikecann.poddle";
    process.env.APNS_ENV = "sandbox";
    const cfg = apnsConfig()!;
    expect(cfg.env).toBe("sandbox");
    const jwt = providerToken(cfg, 1_700_000_000_000);
    const [h, p, s] = jwt.split(".");
    expect(JSON.parse(Buffer.from(h!, "base64url").toString())).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(JSON.parse(Buffer.from(p!, "base64url").toString())).toEqual({ iss: "4DTAZSZL6B", iat: 1_700_000_000 });
    const ok = verify("sha256", Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(s!, "base64url"));
    expect(ok).toBe(true);
    for (const k of ["APNS_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "APNS_ENV"]) delete process.env[k];
  });
});
