#!/usr/bin/env node
// Run on tinker-desk with Node from nvm. No sudo, tokens or changes to the main checkout.
import { mkdirSync, copyFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { command } from "./e2e-remote-lib.mjs";
const scripts = path.dirname(fileURLToPath(import.meta.url));
const home = os.homedir();
const root = process.env.E2E_REMOTE_ROOT ?? path.join(home, ".local/share/poddle-e2e");
const tools = path.join(root, "tools");
const logs = path.join(home, "Library/Logs/Poddle E2E");
const agents = path.join(home, "Library/LaunchAgents");
for (const directory of [tools, logs, agents]) mkdirSync(directory, { recursive: true });
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
const escape = (s) => String(s).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
const label = "com.mikecann.poddle-e2e-nightly";
const plist = path.join(agents, `${label}.plist`);
const argv = ["/usr/bin/lockf", "-t", "0", "-k", path.join(home, ".blender-queue.lock"), "/usr/bin/caffeinate", "-i", process.execPath, path.join(tools, "e2e-remote-worker.mjs"), "--nightly", config];
writeFileSync(plist, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${label}</string>
<key>ProgramArguments</key><array>${argv.map((a) => `<string>${escape(a)}</string>`).join("")}</array>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>${escape(path.dirname(process.execPath))}:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
<key>LimitLoadToSessionType</key><string>Background</string>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>
<key>StandardOutPath</key><string>${escape(path.join(logs, "nightly.log"))}</string>
<key>StandardErrorPath</key><string>${escape(path.join(logs, "nightly.error.log"))}</string>
</dict></plist>\n`);
command("plutil", ["-lint", plist]);
// Background is available over SSH even before a GUI login. The calendar job
// does not need an Aqua session, and must not depend on a GUI domain existing.
const domain = `user/${process.getuid()}`;
try { command("launchctl", ["bootout", `${domain}/${label}`]); } catch { /* First install has no existing agent. */ }
command("launchctl", ["bootstrap", domain, plist]);
console.log(command("launchctl", ["print", `${domain}/${label}`]));
console.log(`Installed nightly run at 03:00 local. Logs: ${logs}. No suite started.`);
