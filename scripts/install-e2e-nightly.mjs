#!/usr/bin/env node
// Run on tinker-desk with Node from nvm. No sudo, tokens or changes to the main checkout.
import { mkdirSync, copyFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { command } from "./e2e-remote-lib.mjs";
const scripts = path.dirname(fileURLToPath(import.meta.url));
const home = os.homedir();
const root = process.env.E2E_REMOTE_ROOT ?? path.join(home, ".local/share/poddle-e2e");
const tools = path.join(root, "tools");
const logs = path.join(home, "Library/Logs/Poddle E2E");
for (const directory of [tools, logs]) mkdirSync(directory, { recursive: true });
for (const name of ["e2e-remote-worker.mjs", "e2e-remote-lib.mjs"]) {
  const target = path.join(tools, name);
  if (path.join(scripts, name) !== target) copyFileSync(path.join(scripts, name), target);
}
const workflow = process.env.E2E_REPORT_WORKFLOW ?? path.resolve(scripts, "../.github/workflows/e2e-nightly-report.yml");
if (workflow !== path.join(tools, "e2e-nightly-report.yml")) copyFileSync(workflow, path.join(tools, "e2e-nightly-report.yml"));
const config = path.join(root, "nightly.json");
writeFileSync(config, JSON.stringify({
  root, repo: process.env.E2E_REMOTE_REPO ?? path.join(home, "dev/me/poddle"),
  simName: process.env.E2E_SIM_NAME ?? "Poddle E2E",
  simRuntime: process.env.E2E_SIM_RUNTIME ?? "27.0",
  simType: process.env.E2E_SIM_DEVICE_TYPE ?? "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
  developerDir: process.env.E2E_DEVELOPER_DIR ?? path.join(home, "Applications/Xcode-27.1.app/Contents/Developer"),
}, null, 2) + "\n");
const label = "com.mikecann.poddle-e2e-nightly";
const tag = "# poddle-e2e-nightly";
const quote = (s) => `'${String(s).replaceAll("'", "'\\''")}'`;
const argv = ["/usr/bin/lockf", "-t", "0", "-k", path.join(home, ".blender-queue.lock"), "/usr/bin/caffeinate", "-i", process.execPath, path.join(tools, "e2e-remote-worker.mjs"), "--nightly", config];
const line = `0 3 * * * PATH=${quote(`${path.dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`)} ${argv.map(quote).join(" ")} >> ${quote(path.join(logs, "nightly.log"))} 2>> ${quote(path.join(logs, "nightly.error.log"))} ${tag}`;
// cron, not launchd: tinker-desk has no GUI login, and launchd never fires calendar
// jobs in the Background user domain without one (runs = 0 after 03:00, 23 Oct).
let existing = "";
try { existing = command("crontab", ["-l"]); } catch { /* No crontab yet. */ }
const kept = existing.split("\n").filter((l) => l && !l.endsWith(tag));
command("crontab", ["-"], { input: [...kept, line].join("\n") + "\n" });
// Remove the launch agent earlier installs used.
try { command("launchctl", ["bootout", `user/${process.getuid()}/${label}`]); } catch { /* Not loaded. */ }
rmSync(path.join(home, "Library/LaunchAgents", `${label}.plist`), { force: true });
console.log(command("crontab", ["-l"]).split("\n").filter((l) => l.endsWith(tag)).join("\n"));
console.log(`Installed nightly run at 03:00 local (crontab). Logs: ${logs}. No suite started.`);
