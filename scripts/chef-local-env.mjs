#!/usr/bin/env node
// Written by `npx chef init`. Throwaway values for the env vars
// convex/convex.config.ts requires, on the build sandbox's local backend,
// which starts with none: Chef's runner runs this after each local backend
// start, through package.json's `chef:local-env` script (chefCloud's
// localEnv "auto"), with CONVEX_SELF_HOSTED_URL and
// CONVEX_SELF_HOSTED_ADMIN_KEY pointing the CLI at that backend.
//
//   npm run chef:local-env
//
// Every value is made up here: a fresh signing keypair for each
// *_PRIVATE_KEY / *_JWKS pair, a placeholder for emails and URLs, random
// strings for the rest. Values go to the CLI on stdin, never in argv, and
// only names are printed. Vars already set are left alone. When you add a
// required env var, add it below.
import { execFileSync } from "node:child_process";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";

const VARS = [
  ["AUTH_PRIVATE_KEY", "keypair"],
  ["AUTH_JWKS", "keypair"],
  ["AUTH_APPLE_CLIENT_ID", "random"],
  ["AUTH_APPLE_TEAM_ID", "random"],
  ["AUTH_APPLE_KEY_ID", "random"],
  ["AUTH_APPLE_PRIVATE_KEY", "random"],
  ["AUTH_GOOGLE_CLIENT_ID", "random"],
  ["AUTH_GOOGLE_CLIENT_SECRET", "random"],
];

const url = process.env.CONVEX_SELF_HOSTED_URL ?? "";
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/?$/.test(url) || !process.env.CONVEX_SELF_HOSTED_ADMIN_KEY) {
  console.error("chef-local-env: CONVEX_SELF_HOSTED_URL (a local backend) and CONVEX_SELF_HOSTED_ADMIN_KEY must be set");
  process.exit(2);
}

function convex(args, input) {
  return execFileSync("npx", ["convex", ...args], {
    encoding: "utf8",
    // stdout is captured and dropped: `env list` holds values.
    stdio: ["pipe", "pipe", "inherit"],
    ...(input === undefined ? {} : { input }),
  });
}

const have = new Set(
  convex(["env", "list"])
    .split("\n")
    .map((l) => /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(l)?.[1])
    .filter(Boolean),
);

const pairs = new Map();
function keypair(prefix) {
  if (!pairs.has(prefix)) {
    const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
    const pem = privateKey.export({ type: "pkcs8", format: "pem" });
    const jwk = publicKey.export({ format: "jwk" });
    pairs.set(prefix, {
      privateKey: Buffer.from(pem).toString("base64"),
      jwks: JSON.stringify({ keys: [{ ...jwk, kid: randomUUID(), alg: "RS256", use: "sig" }] }),
    });
  }
  return pairs.get(prefix);
}

function value(name, kind) {
  if (kind === "keypair") {
    const kp = keypair(name.replace(/_?(PRIVATE_KEY|JWKS)$/, ""));
    return name.endsWith("JWKS") ? kp.jwks : kp.privateKey;
  }
  if (kind === "email") return "owner@example.test";
  if (kind === "url") return "https://example.test";
  return randomBytes(32).toString("base64url");
}

// A keypair is set as a pair, so a half-set pair gets both halves fresh.
const missing = new Set(VARS.filter(([n]) => !have.has(n)).map(([n]) => n));
for (const [n, kind] of VARS) {
  if (kind !== "keypair" || !missing.has(n)) continue;
  const prefix = n.replace(/_?(PRIVATE_KEY|JWKS)$/, "");
  for (const [m, k] of VARS) if (k === "keypair" && m.replace(/_?(PRIVATE_KEY|JWKS)$/, "") === prefix) missing.add(m);
}
const set = [];
for (const [name, kind] of VARS) {
  if (!missing.has(name)) continue;
  convex(["env", "set", name], value(name, kind));
  set.push(name);
}
console.log(set.length ? `chef-local-env: set ${set.join(", ")}` : "chef-local-env: all set already");
