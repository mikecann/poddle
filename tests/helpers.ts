import { readFileSync } from "node:fs";
import { convexTest } from "convex-test";
import { vi } from "vitest";
import type { Id } from "../convex/_generated/dataModel";
import { podcastView } from "../convex/lib/library";
import schema from "../convex/schema";

export const modules = import.meta.glob("../convex/**/*.*s");
export const TOKEN = "test-token-0123456789";
export const MIKE = "mike.cann@gmail.com";

const make = () => convexTest(schema, modules);
export type Raw = ReturnType<typeof make>;

/**
 * A test deployment, signed in as `email` (Mike unless told otherwise).
 * `query`/`mutation`/`action` run as that user; `run` and the scheduler helpers
 * are the plain test deployment's. `as(email)` signs in as someone else on the
 * same deployment.
 */
export function setup(email = MIKE) {
  process.env.PODDLE_API_TOKEN = TOKEN;
  process.env.CONVEX_SITE_URL ??= "https://poddle-test.convex.site";
  return signedIn(make(), email);
}

export function signedIn(raw: Raw, email: string) {
  let id: Promise<Id<"users">> | undefined;
  const userId = () =>
    (id ??= raw.run(async (ctx) => {
      const existing = await ctx.db
        .query("users")
        .withIndex("by_email", (q) => q.eq("email", email))
        .first();
      return existing?._id ?? (await ctx.db.insert("users", { email, emailVerified: true }));
    }));
  const me = async () => raw.withIdentity({ subject: await userId() });
  return {
    raw,
    email,
    userId,
    query: (async (...args: unknown[]) => ((await me()).query as (...a: unknown[]) => unknown)(...args)) as Raw["query"],
    mutation: (async (...args: unknown[]) => ((await me()).mutation as (...a: unknown[]) => unknown)(...args)) as Raw["mutation"],
    action: (async (...args: unknown[]) => ((await me()).action as (...a: unknown[]) => unknown)(...args)) as Raw["action"],
    run: raw.run.bind(raw) as Raw["run"],
    finishAllScheduledFunctions: raw.finishAllScheduledFunctions.bind(raw) as Raw["finishAllScheduledFunctions"],
    finishInProgressScheduledFunctions: raw.finishInProgressScheduledFunctions.bind(raw) as Raw["finishInProgressScheduledFunctions"],
    as: (other: string) => signedIn(raw, other),
  };
}

export type T = ReturnType<typeof setup>;

export function fixture(name: string): string {
  return readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");
}

type Reply = string | { status?: number; body?: string; headers?: Record<string, string> };

/** Stub global fetch. Keys are URL prefixes; unmatched URLs get a 404. */
export function mockFetch(routes: Record<string, Reply | ((init?: RequestInit) => Reply)>) {
  const fn = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const key = Object.keys(routes)
      .sort((a, b) => b.length - a.length)
      .find((k) => url.startsWith(k));
    if (!key) return new Response("not found", { status: 404 });
    const route = routes[key]!;
    const reply = typeof route === "function" ? route(init) : route;
    const r = typeof reply === "string" ? { body: reply } : reply;
    const status = r.status ?? 200;
    return new Response(status === 304 ? null : (r.body ?? ""), { status, headers: r.headers });
  });
  vi.stubGlobal("fetch", fn);
  return fn;
}

/** Run everything scheduled (and anything those schedule). Needs fake timers. */
export async function drain(t: T) {
  await t.finishAllScheduledFunctions(() => vi.runAllTimers());
}

/** Every show in `t`'s user's library as the app sees it (shared show + their subscription). */
export async function podcastViews(t: T) {
  const userId = await t.userId();
  return await t.run(async (ctx) => {
    const subs = await ctx.db
      .query("subscriptions")
      .withIndex("by_user_podcast", (q) => q.eq("userId", userId))
      .collect();
    const out = [];
    for (const sub of subs) {
      const p = await ctx.db.get(sub.podcastId);
      if (p) out.push(podcastView(p, sub));
    }
    return out;
  });
}
