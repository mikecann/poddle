// Shared by the set-*-keys scripts: set and check Convex env vars on dev or prod
// without ever printing a value. Values go in on stdin: as an argument a .p8
// key's leading "-----" reads as a flag, and the CLI's errors would echo it.
import { spawnSync } from "node:child_process";

export function target(arg) {
  if (arg === "dev") return [];
  if (arg === "prod") return ["--prod"];
  console.error("The first argument must be dev or prod.");
  process.exit(1);
}

export function isSet(name, flags) {
  const r = spawnSync("npx", ["convex", "env", "get", name, ...flags], { encoding: "utf8" });
  return r.status === 0 && r.stdout.trim().length > 0;
}

export function setEnv(name, value, flags) {
  const r = spawnSync("npx", ["convex", "env", "set", name, ...flags], { encoding: "utf8", input: value });
  if (r.status !== 0) {
    console.error(`Couldn't set ${name}:\n${r.stderr.split(value).join("[redacted]")}`);
    process.exit(1);
  }
}
