#!/usr/bin/env node
// Both end-to-end suites on one e2e world (docs/testing.md): the website's
// (playwright-bdd) then the app's (XCUITest). Not the default check for small
// changes; see AGENTS.md, "End-to-end cadence".
//
//   npm run test:e2e

import { spawn, spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startWorld } from "../e2e/world/world.mjs";
import { runIos } from "./run-e2e-ios.mjs";
import { webE2eEnv } from "./e2e-remote-lib.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const started = Date.now();
// The shared runner passes a name filter to both harnesses. Build/device flags belong to iOS.
const args = process.argv.slice(2);
const webArgs = [];
for (let i = 0; i < args.length; i++) {
  if (["-g", "--grep", "--scenario"].includes(args[i])) webArgs.push("--grep", args[++i]);
}
const secs = (t) => `${((Date.now() - t) / 1000).toFixed(0)} s`;
// The world's fixture server runs in this process, so the web steps must not block it.
const run = (cmd, cmdArgs, env) => new Promise((resolve) => {
  spawn(cmd, cmdArgs, { cwd: root, stdio: "inherit", env }).on("error", () => resolve(false)).on("close", (code) => resolve(code === 0));
});

const pairing = spawnSync("node", ["scripts/verify-bdd-pairing.mjs"], { cwd: root, stdio: "inherit" });
if (pairing.status !== 0) process.exit(1);

const world = await startWorld({ website: true });
let webOk = false;
let iosOk = false;
try {
  const env = webE2eEnv({ ...process.env, PODDLE_E2E_WORLD: "1" }, root);
  const t = Date.now();
  webOk = (await run("npx", ["bddgen"], env)) && (await run("npx", ["playwright", "test", ...webArgs], env));
  console.log(`[e2e] web ${webOk ? "passed" : "FAILED"} in ${secs(t)}`);
  iosOk = await runIos({ world });
} finally {
  await world.stop();
}
console.log(`[e2e] web ${webOk ? "passed" : "FAILED"}, app ${iosOk ? "passed" : "FAILED"}, ${secs(started)} in all`);
process.exit(webOk && iosOk ? 0 : 1);
