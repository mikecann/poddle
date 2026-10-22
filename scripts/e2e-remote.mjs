#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { command, quote, verifyPackages } from "./e2e-remote-lib.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
function option(name, fallback) {
  const index = args.indexOf(name);
  if (index < 0) return fallback;
  if (!args[index + 1] || args[index + 1].startsWith("-")) throw new Error(`${name} needs a value`);
  return args.splice(index, 2)[1];
}
const host = option("--host", process.env.E2E_REMOTE_HOST ?? "tinker-desk");
const commit = option("--commit", "HEAD");
const suite = option("--suite", "both");
if (!["both", "ios", "web"].includes(suite)) throw new Error("--suite must be both, ios or web");
const dryRun = args.includes("--dry-run");
if (dryRun) args.splice(args.indexOf("--dry-run"), 1);
if (args.includes("--feature") && suite !== "ios") throw new Error("Use --suite ios with --feature (the web harness has no feature flag)");
const sha = command("git", ["rev-parse", "--verify", `${commit}^{commit}`], { cwd: root });
const results = path.join(root, "e2e/.remote-results", sha);
const source = process.env.E2E_SOURCE_PACKAGES ?? "/tmp/poddle-dd-check/SourcePackages";
console.log(`[e2e remote] ${sha}, ${suite}, on ${host}`);
console.log(`  Fetch origin, verify commit is pushed, create an isolated worktree, npm ci${suite === "web" ? "" : ", verify and sync pinned Swift packages"}.`);
console.log(`  Take ~/.blender-queue.lock (shared with render-box); run npm run test:e2e${suite === "both" ? "" : `:${suite}`} ${args.map(quote).join(" ")}`);
console.log(`  Xcode ${process.env.E2E_DEVELOPER_DIR ?? "~/Applications/Xcode-27.1.app"}, iOS runtime ${process.env.E2E_SIM_RUNTIME ?? "18.1"}, device ${process.env.E2E_SIM_DEVICE_TYPE ?? "com.apple.CoreSimulator.SimDeviceType.iPhone-16"}.`);
console.log(`  Download scenario results, failure screenshots, accessibility dumps and reports to ${results}`);
if (dryRun) process.exit(0);

// Fetch first so a stale local origin ref cannot make an unpushed commit look available.
command("git", ["fetch", "--prune", "origin"], { cwd: root });
if (!command("git", ["for-each-ref", `--contains=${sha}`, "--format=%(refname)", "refs/remotes/origin"], { cwd: root })) {
  throw new Error(`Commit ${sha} is not pushed to origin. Push it first, then rerun test:e2e:remote.`);
}
if (suite !== "web") verifyPackages(root, source);
const sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=6"];
const ssh = (script) => command("ssh", [...sshOptions, host, script]);
const home = ssh("printf '%s' \"$HOME\"");
const remoteRoot = process.env.E2E_REMOTE_ROOT ?? `${home}/.local/share/poddle-e2e`;
const id = `${Date.now()}-${process.pid}`;
const upload = `${remoteRoot}/incoming/${id}`;
const node = process.env.E2E_REMOTE_NODE ?? `${home}/.nvm/versions/node/v24.12.0/bin/node`;
const config = {
  sha, suite, args, runId: id, root: remoteRoot, repo: process.env.E2E_REMOTE_REPO ?? `${home}/dev/me/poddle`,
  source: suite === "web" ? null : `${upload}/SourcePackages`,
  simName: process.env.E2E_SIM_NAME ?? "Poddle E2E",
  simRuntime: process.env.E2E_SIM_RUNTIME ?? "18.1",
  simType: process.env.E2E_SIM_DEVICE_TYPE ?? "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
  developerDir: process.env.E2E_DEVELOPER_DIR ?? `${home}/Applications/Xcode-27.1.app/Contents/Developer`,
};
ssh(`mkdir -p ${quote(upload)}`);
const rsync = (from, to) => command("rsync", ["-az", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=15", from, `${host}:${quote(to)}`], { stdio: "inherit" });
for (const file of ["e2e-remote-worker.mjs", "e2e-remote-lib.mjs"]) rsync(path.join(root, "scripts", file), `${upload}/${file}`);
if (config.source) rsync(`${source}/`, `${config.source}/`);
const encoded = Buffer.from(JSON.stringify(config)).toString("base64");
const invocation = `PATH=${quote(`${path.dirname(node)}:/usr/bin:/bin:/usr/sbin:/sbin`)} /usr/bin/lockf -t 0 -k ${quote(`${home}/.blender-queue.lock`)} /usr/bin/caffeinate -i ${quote(node)} ${quote(`${upload}/e2e-remote-worker.mjs`)} ${quote(encoded)}`;
// Clear the previous report for this SHA so a failed setup cannot display an old pass.
rmSync(results, { recursive: true, force: true });
const run = spawnSync("ssh", [...sshOptions, host, invocation], { stdio: "inherit" });
mkdirSync(results, { recursive: true });
// Collect even if a test/build failed. Do not copy world.json or the disposable backend.
const copy = spawnSync("rsync", ["-az", "-e", "ssh -o BatchMode=yes", `${host}:${quote(`${remoteRoot}/results/${sha}/${id}/`)}`, `${results}/`], { stdio: "inherit" });
ssh(`rm -rf ${quote(upload)}`);
if (run.status === 75) console.error("[e2e remote] tinker-desk is busy: another e2e/render-box job holds ~/.blender-queue.lock. Try again later.");
try {
  const report = JSON.parse(readFileSync(path.join(results, "latest.json"), "utf8"));
  console.log(`[e2e remote] ${report.status}: ${report.scenarios.filter((s) => s.status === "passed").length} passed, ${report.scenarios.filter((s) => s.status === "failed").length} failed. Results: ${results}`);
} catch { console.error("[e2e remote] No report was returned; check SSH and the remote run output."); }
process.exit(run.status === 0 && copy.status === 0 ? 0 : 1);
