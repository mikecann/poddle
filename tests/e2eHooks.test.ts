import { afterEach, describe, expect, test, vi } from "vitest";
import { api } from "../convex/_generated/api";
import { directoryBase, e2eRefusal } from "../convex/lib/e2e";
import { TOKEN, mockFetch, setup } from "./helpers";
import { seedShow } from "./seed";

// The end-to-end suites' hooks (convex/testing.ts, lib/e2e.ts): only on a local
// backend with PODDLE_E2E=1 and the admin token.

const LOCAL = { PODDLE_E2E: "1", CONVEX_CLOUD_URL: "http://127.0.0.1:3210", CONVEX_SITE_URL: "http://127.0.0.1:3211" };

function local(env: Record<string, string> = LOCAL) {
  for (const [k, v] of Object.entries(env)) vi.stubEnv(k, v);
}

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("e2e hooks", () => {
  test("only run on a local backend with the flag", () => {
    expect(e2eRefusal(LOCAL)).toBeNull();
    expect(e2eRefusal({ ...LOCAL, PODDLE_E2E: "true" })).toMatch(/off/);
    expect(e2eRefusal({ ...LOCAL, CONVEX_CLOUD_URL: "https://striped-turtle-260.ap-southeast-2.convex.cloud" })).toMatch(/local/);
    expect(e2eRefusal({ ...LOCAL, CONVEX_SITE_URL: "https://poddle.mikecann.app" })).toMatch(/local/);
  });

  test("the directory override is ignored anywhere else", () => {
    const fake = { PODDLE_DIRECTORY_URL: "http://127.0.0.1:4310/itunes/" };
    expect(directoryBase({ ...LOCAL, ...fake })).toBe("http://127.0.0.1:4310/itunes");
    expect(directoryBase(fake)).toBe("https://itunes.apple.com");
    expect(directoryBase({ ...LOCAL, ...fake, CONVEX_CLOUD_URL: "https://coordinated-dodo-120.ap-southeast-2.convex.cloud" })).toBe(
      "https://itunes.apple.com",
    );
  });

  test("reset empties every app table, and needs the token", async () => {
    const t = setup();
    await seedShow(t, 3);
    await expect(t.raw.mutation(api.testing.reset, { token: TOKEN })).rejects.toThrow(/off/);
    local();
    await expect(t.raw.mutation(api.testing.reset, { token: "wrong" })).rejects.toThrow(/admin token/i);
    const result = await t.raw.mutation(api.testing.reset, { token: TOKEN });
    expect(result.more).toBe(false);
    expect(result.deleted).toBeGreaterThan(3);
    const left = await t.run(async (ctx) => [
      ...(await ctx.db.query("users").collect()),
      ...(await ctx.db.query("podcasts").collect()),
      ...(await ctx.db.query("episodes").collect()),
    ]);
    expect(left).toEqual([]);
  });

  test("search uses the fixture directory", async () => {
    local({ ...LOCAL, PODDLE_DIRECTORY_URL: "http://127.0.0.1:4310/itunes" });
    const fetch = mockFetch({
      "http://127.0.0.1:4310/itunes/search": JSON.stringify({
        results: [{ collectionId: 1, collectionName: "Morning Tones", artistName: "Poddle", feedUrl: "http://127.0.0.1:4310/feeds/morning.xml" }],
      }),
    });
    const t = setup();
    const results = await t.action(api.directory.search, { term: "tones" });
    expect(results.map((r) => r.title)).toEqual(["Morning Tones"]);
    expect(String(fetch.mock.calls[0]![0])).toMatch(/^http:\/\/127\.0\.0\.1:4310\/itunes\/search\?term=tones/);
  });
});
