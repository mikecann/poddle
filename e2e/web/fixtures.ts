import { expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test as base } from "playwright-bdd";

// The web suite's fixtures: `world` arranges and inspects the backend through the
// world API (e2e/world/worldApi.mjs), and every scenario starts from a reset one.

type WorldInfo = { convexUrl: string; siteUrl: string; fixtureUrl: string; users: Record<"listener" | "friend" | "stranger", string> };

export type World = WorldInfo & {
  call: <T = Record<string, unknown>>(op: string, body?: Record<string, unknown>) => Promise<T>;
  /** Shared between a scenario's steps: the episode or show it's about. */
  memo: Record<string, string>;
};

function readWorld(): WorldInfo {
  return JSON.parse(readFileSync(path.join(process.cwd(), "e2e", ".runtime", "world.json"), "utf8"));
}

export const test = base.extend<{ world: World }>({
  world: async ({}, use) => {
    const info = readWorld();
    const call = async <T,>(op: string, body: Record<string, unknown> = {}): Promise<T> => {
      const res = await fetch(`${info.fixtureUrl}/_world/${op}`, { method: "POST", body: JSON.stringify(body) });
      const text = await res.text();
      if (!res.ok) throw new Error(`world ${op}: ${text}`);
      return JSON.parse(text) as T;
    };
    await call("reset");
    await use({ ...info, call, memo: {} });
  },
});

export { expect };
