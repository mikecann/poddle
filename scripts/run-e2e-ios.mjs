#!/usr/bin/env node
// The app's end-to-end suite (docs/testing.md): features/app/*.feature through the
// PoddleUITests XCUITest target, against the e2e world (a throwaway local Convex
// backend and the fixture server).
//
//   npm run test:e2e:ios                                   every scenario
//   npm run test:e2e:ios -- --feature up-next              one feature file
//   npm run test:e2e:ios -- -g "Undo puts it back"         scenarios whose name contains this
//   npm run test:e2e:ios -- --no-build                     reuse the last build
//   npm run test:e2e:ios -- --keep-sim                     leave the simulator booted afterwards
//
// It boots its own simulator ("Poddle E2E", an iPhone 17 Pro made on the newest iOS
// runtime that has one, if it doesn't exist), builds once, runs, then shuts that simulator down. Other simulators
// are left alone. The run's log and xcresult go to e2e/.runtime/.

import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createWriteStream, existsSync, mkdirSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const runtime = path.join(root, "e2e", ".runtime");
const SIM_NAME = process.env.E2E_SIM_NAME ?? "Poddle E2E";
const SIM_TYPE = process.env.E2E_SIM_DEVICE_TYPE ?? "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro";
const SIM_RUNTIME = process.env.E2E_SIM_RUNTIME;

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const value = (...names) => {
  for (const name of names) {
    const i = args.indexOf(name);
    if (i >= 0 && args[i + 1]) return args[i + 1];
  }
  return undefined;
};
const feature = value("--feature");
const scenario = value("-g", "--grep", "--scenario");

export async function runIos({ world } = {}) {
  const started = Date.now();
  mkdirSync(runtime, { recursive: true });
  const udid = ensureSimulator();
  const derivedData = path.join(os.homedir(), "Library/Developer/Xcode/DerivedData", `Poddle-e2e-${createHash("sha1").update(root).digest("hex").slice(0, 8)}`);
  const common = ["-project", "Poddle.xcodeproj", "-scheme", "Poddle", "-configuration", "Debug", "-destination", `id=${udid}`, "-derivedDataPath", derivedData];

  // Reuse resolved private packages on runners without GitHub access to ChefKit.
  if (process.env.E2E_SOURCE_PACKAGES) common.push("-clonedSourcePackagesDirPath", process.env.E2E_SOURCE_PACKAGES, "-disableAutomaticPackageResolution");

  log(`booting ${SIM_NAME} (${udid})`);
  sh("xcrun", ["simctl", "boot", udid], { allowFail: true });
  sh("xcrun", ["simctl", "bootstatus", udid, "-b"]);

  let ownWorld;
  try {
    if (!flag("--no-build")) {
      log("building the app and the UI tests");
      const t = Date.now();
      await xcodebuild([...common, "build-for-testing"], "xcodebuild-build.log");
      log(`built in ${secs(t)}`);
    }
    if (!world) {
      const { startWorld } = await import("../e2e/world/world.mjs");
      ownWorld = await startWorld({ website: false });
    }
    const result = path.join(runtime, "ios.xcresult");
    rmSync(result, { recursive: true, force: true });
    rmSync(path.join(runtime, "ios-failures"), { recursive: true, force: true });
    log(`running ${feature ? `feature ${feature}` : "every feature"}${scenario ? `, scenarios matching "${scenario}"` : ""}`);
    const t = Date.now();
    const ok = await xcodebuild(
      [...common, "test-without-building", "-only-testing:PoddleUITests", "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
        // A hung scenario fails after 4 minutes instead of stalling the run.
        "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "240", "-resultBundlePath", result],
      "xcodebuild-test.log",
      { TEST_RUNNER_PODDLE_E2E_FEATURE: feature ?? "", TEST_RUNNER_PODDLE_E2E_SCENARIO: scenario ?? "" },
      { allowFail: true },
    );
    log(`${ok ? "passed" : "FAILED"}: tests ${secs(t)}, whole run ${secs(started)}`);
    if (!ok) log(`details: e2e/.runtime/xcodebuild-test.log, e2e/.runtime/ios-failures/, ${path.relative(root, result)}`);
    return ok;
  } finally {
    await ownWorld?.stop();
    if (!flag("--keep-sim")) sh("xcrun", ["simctl", "shutdown", udid], { allowFail: true });
  }
}

/**
 * The configured simulator, created if necessary. By default it is a "Poddle E2E"
 * iPhone 17 Pro on the newest iOS runtime that supports one. Some runtimes only offer unusual devices (iOS 27.1 has just the "iPhone Duo"), so
 * the newest runtime with a plain iPhone 17 Pro wins.
 */
function ensureSimulator() {
  const devices = JSON.parse(sh("xcrun", ["simctl", "list", "devices", "-j"])).devices;
  const runtimes = JSON.parse(sh("xcrun", ["simctl", "list", "runtimes", "-j"])).runtimes
    .filter((r) => r.platform === "iOS" && r.isAvailable && (!SIM_RUNTIME || r.identifier === SIM_RUNTIME || r.version === SIM_RUNTIME) && r.supportedDeviceTypes?.some((d) => d.identifier === SIM_TYPE))
    .sort((a, b) => compareVersions(b.version, a.version));
  if (!runtimes.length) throw new Error(`No available iOS runtime ${SIM_RUNTIME ?? "(newest)"} supports ${SIM_TYPE}. Check xcodebuild -checkFirstLaunchStatus and installed runtimes.`);
  const newest = runtimes[0];
  const existing = (devices[newest.identifier] ?? []).find((d) => d.name === SIM_NAME && d.deviceTypeIdentifier === SIM_TYPE && d.isAvailable);
  if (existing) return existing.udid;
  log(`creating ${SIM_NAME} (${SIM_TYPE}, ${newest.name})`);
  return sh("xcrun", ["simctl", "create", SIM_NAME, SIM_TYPE, newest.identifier]).trim();
}

function compareVersions(a, b) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d) return d;
  }
  return 0;
}

/** Runs xcodebuild, logging everything to e2e/.runtime/<logName> and echoing test results. */
function xcodebuild(xargs, logName, env = {}, { allowFail = false } = {}) {
  return new Promise((resolve, reject) => {
    const logFile = createWriteStream(path.join(runtime, logName));
    const child = spawn("xcodebuild", xargs, { cwd: root, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
    let buffer = "";
    // xcodebuild sometimes sits for minutes after the last test; once the suite has a verdict,
    // give it a minute to write the result bundle, then end it and go by the verdict.
    let verdict = null;
    let watchdog;
    const take = (chunk) => {
      logFile.write(chunk);
      buffer += chunk.toString();
      let nl;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        echo(line);
        const done = /^Test Suite 'All tests' (passed|failed)/.exec(line);
        if (done && !watchdog) {
          verdict = done[1] === "passed";
          watchdog = setTimeout(() => child.kill("SIGTERM"), 60_000);
        }
      }
    };
    child.stdout.on("data", take);
    child.stderr.on("data", take);
    child.on("close", (code) => {
      clearTimeout(watchdog);
      logFile.end();
      if (verdict !== null && code !== 0 && code !== 65) return resolve(verdict);
      if (code === 0) resolve(true);
      else if (allowFail) resolve(false);
      else reject(new Error(`xcodebuild ${xargs.at(-1)} failed (exit ${code}). See e2e/.runtime/${logName}`));
    });
  });
}

/** Only what a person wants to see: each scenario's result and real errors. */
function echo(line) {
  const m = /Test [Cc]ase '-\[PoddleUITests\.FeatureTests (test_\S+)\]' (passed|failed) \(([\d.]+) seconds\)/.exec(line);
  if (m) return console.log(`  ${m[2] === "passed" ? "✓" : "✘"} ${m[1].replace(/^test_/, "").replace("__", ": ").replace(/_/g, " ")} (${Number(m[3]).toFixed(1)} s)`);
  if (/error: |\*\* (BUILD|TEST) .*FAILED|: error:/.test(line) && !/^\s*$/.test(line)) console.log(`  ${line.trim()}`);
}

function sh(cmd, xargs, { allowFail = false } = {}) {
  const r = spawnSync(cmd, xargs, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  if (r.status !== 0 && !allowFail) throw new Error(`${cmd} ${xargs.join(" ")} failed:\n${r.stderr}`);
  return r.stdout;
}

const secs = (t) => `${((Date.now() - t) / 1000).toFixed(0)} s`;
const log = (msg) => console.log(`[e2e ios] ${msg}`);

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  if (!existsSync(path.join(root, "node_modules"))) throw new Error("Run npm install first");
  const ok = await runIos();
  process.exit(ok ? 0 : 1);
}
