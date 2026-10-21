import { readFileSync } from "node:fs";
import { convexTest } from "convex-test";
import { vi } from "vitest";
import schema from "../convex/schema";

export const modules = import.meta.glob("../convex/**/*.*s");
export const TOKEN = "test-token-0123456789";

export function setup() {
  process.env.PODDLE_API_TOKEN = TOKEN;
  return convexTest(schema, modules);
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
