#!/usr/bin/env node
// Runs on tinker-desk, under lockf ~/.blender-queue.lock. The caller supplies a
// base64 JSON config so SSH never has to interpolate scenario names as shell code.
import { spawn } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, copyFileSync } from "node:fs";
import path from "node:path";
import { command, readJson, verifyPackages, relocatePackages, scenarioResults, copyNightlyScreenshots } from "./e2e-remote-lib.mjs";

const config = process.argv[2] === "--nightly"
  ? { ...readJson(process.argv[3]), nightly: true, suite: "both", args: [], runId: String(Date.now()) }
  : JSON.parse(Buffer.from(process.argv[2], "base64").toString("utf8"));
const { root, repo } = config;
const git = (...args) => command("git", ["-C", repo, ...args]);
mkdirSync(root, { recursive: true });
git("fetch", "--prune", "origin");
const sha = config.nightly ? git("rev-parse", "origin/main") : config.sha;
if (!/^[a-f0-9]{40}$/.test(sha)) throw new Error("Expected a full commit SHA");
if (!git("for-each-ref", `--contains=${sha}`, "--format=%(refname)", "refs/remotes/origin")) throw new Error("Requested commit is not on origin");
const lastNightly = path.join(root, "last-nightly-sha");
if (config.nightly && existsSync(lastNightly) && readFileSync(lastNightly, "utf8").trim() === sha) {
  console.log(`[e2e nightly] origin/main is still ${sha}; skipping`);
  process.exit(0);
}
const checkout = path.join(root, "worktree");
const output = path.join(root, "results", sha, config.runId);
mkdirSync(output, { recursive: true });
const startedAt = new Date().toISOString();
const env = {
  ...process.env, E2E_SIM_RUNTIME: config.simRuntime ?? "27.0",
  E2E_SIM_DEVICE_TYPE: config.simType ?? "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
  PLAYWRIGHT_SKIP_BROWSER_GC: "1",
  PLAYWRIGHT_BROWSERS_PATH: path.join(root, "browsers"),
  PLAYWRIGHT_JSON_OUTPUT_FILE: path.join(checkout, "e2e/.runtime/web-results.json"),
  E2E_SIM_NAME: config.simName ?? "Poddle E2E", E2E_SOURCE_PACKAGES: path.join(root, "SourcePackages"),
  // tinker-desk's /Applications/Xcode.app (26.6) can't build Poddle; it uses a copy of Xcode 27.1.
  ...(config.developerDir && { DEVELOPER_DIR: config.developerDir }),
};
let active;
// Keep the lock until children have exited, including Xcode/backend subprocesses.
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, () => {
  if (active?.pid) process.kill(-active.pid, signal);
  else process.exit(1);
});
function run(cmd, args) {
  console.log(`[e2e remote] ${cmd} ${args.join(" ")}`);
  return new Promise((resolve, reject) => {
    active = spawn(cmd, args, { cwd: checkout, env, stdio: "inherit", detached: true });
    active.on("error", reject);
    active.on("close", (code) => { active = undefined; resolve(code ?? 1); });
  });
}
let error;
let exitCode = 1;
try {
  if (!existsSync(checkout)) git("worktree", "add", "--detach", checkout, sha);
  else {
    if (command("git", ["-C", checkout, "rev-parse", "--path-format=absolute", "--git-common-dir"]) !== git("rev-parse", "--path-format=absolute", "--git-common-dir")) throw new Error("Runner worktree belongs to another repo");
    command("git", ["-C", checkout, "checkout", "--detach", "--force", sha]);
    command("git", ["-C", checkout, "clean", "-ffd"]);
  }
  if (config.nightly && !existsSync(path.join(checkout, "scripts/e2e-remote.mjs"))) {
    console.log("[e2e nightly] Waiting for remote-runner changes to land on origin/main; no suite run yet.");
    process.exit(0);
  }
  rmSync(path.join(checkout, "e2e/.runtime"), { recursive: true, force: true });
  if (await run("npm", ["ci", "--no-audit", "--no-fund"]) !== 0) throw new Error("npm ci failed");
  if (config.suite !== "web") {
    const source = config.source ?? env.E2E_SOURCE_PACKAGES;
    relocatePackages(source);
    verifyPackages(checkout, source);
    if (source !== env.E2E_SOURCE_PACKAGES) {
      rmSync(env.E2E_SOURCE_PACKAGES, { recursive: true, force: true });
      cpSync(source, env.E2E_SOURCE_PACKAGES, { recursive: true });
    }
    relocatePackages(env.E2E_SOURCE_PACKAGES);
    const workspace = path.join(checkout, "Poddle.xcodeproj/project.xcworkspace/xcshareddata/swiftpm");
    mkdirSync(workspace, { recursive: true });
    copyFileSync(path.join(checkout, "Packages/PoddleKit/Package.resolved"), path.join(workspace, "Package.resolved"));
    console.log("[e2e remote] Swift package checkouts match the committed pins");
  }
  if (config.suite !== "ios" && await run("npx", ["playwright", "install", "chromium"]) !== 0) throw new Error("Playwright browser installation failed");
  const script = `test:e2e${config.suite === "both" ? "" : `:${config.suite}`}`;
  exitCode = await run("npm", ["run", script, "--", ...config.args]);
} catch (failure) {
  error = failure.message;
  console.error(`[e2e remote] ${error}`);
}
const runtime = path.join(checkout, "e2e/.runtime");
const scenarios = scenarioResults(runtime);
// A zero-scenario run must never report green (e.g. a misspelled filter).
for (const suite of config.suite === "both" ? ["web", "ios"] : [config.suite]) {
  if (!scenarios.some((s) => s.suite === suite && s.status !== "skipped")) {
    exitCode = 1;
    error ??= `No completed ${suite} scenarios; inspect the setup/build logs`;
  }
}
if (scenarios.some((s) => s.status === "failed")) exitCode = 1;
const report = { sha, status: exitCode === 0 ? "passed" : "failed", suite: config.suite, startedAt, finishedAt: new Date().toISOString(), scenarios, ...(error ? { error } : {}) };
// Copy only useful diagnostics. world.json and backend/auth configuration stay private.
for (const name of ["ios-failures", "ios.xcresult", "xcodebuild-build.log", "xcodebuild-test.log", "web-results.json", "playwright-results", "playwright-report"]) {
  const file = path.join(runtime, name);
  if (existsSync(file)) cpSync(file, path.join(output, name), { recursive: true });
}
writeFileSync(path.join(output, "latest.json"), JSON.stringify(report, null, 2) + "\n");
console.log(`[e2e remote] ${report.status}: ${scenarios.filter((s) => s.status === "passed").length} passed, ${scenarios.filter((s) => s.status === "failed").length} failed; ${output}`);

if (config.nightly) {
  await publishNightly();
  // Mark handled only after the results push succeeds; failed pushes retry next launch.
  writeFileSync(lastNightly, sha + "\n");
}
process.exit(exitCode === 0 ? 0 : 1);

async function publishNightly() {
  const publish = path.join(root, "report-worktree");
  rmSync(publish, { recursive: true, force: true });
  mkdirSync(publish, { recursive: true });
  const reportGit = (...args) => command("git", ["-C", publish, ...args]);
  reportGit("init", "--quiet");
  reportGit("remote", "add", "origin", git("remote", "get-url", "origin"));
  const branch = git("ls-remote", "--heads", "origin", "e2e-nightly");
  if (branch) {
    reportGit("fetch", "--depth=1", "origin", "e2e-nightly");
    reportGit("checkout", "-B", "e2e-nightly", "FETCH_HEAD");
    reportGit("rm", "-r", "--ignore-unmatch", ".");
  } else reportGit("checkout", "--orphan", "e2e-nightly");
  const images = copyNightlyScreenshots(runtime, publish);
  mkdirSync(path.join(publish, "results"), { recursive: true });
  writeFileSync(path.join(publish, "results/latest.json"), JSON.stringify({ ...report, ...images }, null, 2) + "\n");
  // push workflows are loaded from the pushed branch, so the orphan branch must
  // include its reporter too. Use the installed fallback until this lands on main.
  const workflow = ".github/workflows/e2e-nightly-report.yml";
  mkdirSync(path.join(publish, ".github/workflows"), { recursive: true });
  copyFileSync(existsSync(path.join(checkout, workflow)) ? path.join(checkout, workflow) : path.join(root, "tools", "e2e-nightly-report.yml"), path.join(publish, workflow));
  reportGit("add", ".");
  reportGit("-c", "user.name=Poddle E2E", "-c", "user.email=e2e@poddle.test", "commit", "-m", `E2E ${report.status}: ${sha}`);
  reportGit("push", "origin", "HEAD:refs/heads/e2e-nightly");
}
