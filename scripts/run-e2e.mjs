#!/usr/bin/env node
// Both end-to-end suites on one e2e world (docs/testing.md): the website's
// (playwright-bdd) then the app's (XCUITest). Not the default check for small
// changes; see AGENTS.md, "End-to-end cadence".
//
//   npm run test:e2e

import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startWorld } from "../e2e/world/world.mjs";
import { runIos } from "./run-e2e-ios.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const started = Date.now();
const secs = (t) => `${((Date.now() - t) / 1000).toFixed(0)} s`;

const pairing = spawnSync("node", ["scripts/verify-bdd-pairing.mjs"], { cwd: root, stdio: "inherit" });
if (pairing.status !== 0) process.exit(1);

const world = await startWorld({ website: true });
let webOk = false;
let iosOk = false;
try {
  const env = { ...process.env, PODDLE_E2E_WORLD: "1" };
  const t = Date.now();
  webOk =
    spawnSync("npx", ["bddgen"], { cwd: root, stdio: "inherit", env }).status === 0 &&
    spawnSync("npx", ["playwright", "test"], { cwd: root, stdio: "inherit", env }).status === 0;
  console.log(`[e2e] web ${webOk ? "passed" : "FAILED"} in ${secs(t)}`);
  iosOk = await runIos({ world });
} finally {
  await world.stop();
}
console.log(`[e2e] web ${webOk ? "passed" : "FAILED"}, app ${iosOk ? "passed" : "FAILED"}, ${secs(started)} in all`);
process.exit(webOk && iosOk ? 0 : 1);
