// The e2e world (docs/testing.md): a throwaway local Convex backend, the fixture
// server, and optionally the website uploaded to that backend. Nothing here
// touches dev or prod: the backend runs from a copy of convex/ in a temp folder,
// so the checkout's .env.local is never read or written.
//
//   node e2e/world/world.mjs [--website]   start one and keep it up (Ctrl-C stops it)
//
// The runner scripts and Playwright's global setup call startWorld() instead.

import { spawn, spawnSync } from "node:child_process";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { createWriteStream, existsSync } from "node:fs";
import { cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startFixtureServer } from "./fixtureServer.mjs";
import { worldApi } from "./worldApi.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
export const runtimeDir = path.join(root, "e2e", ".runtime");

/** The test users. Only these can sign up; anyone else is "invite-only". */
export const USERS = { listener: "listener@poddle.test", friend: "friend@poddle.test", stranger: "stranger@poddle.test" };

const ports = {
  convex: Number(process.env.E2E_CONVEX_PORT ?? 3410),
  site: Number(process.env.E2E_SITE_PORT ?? 3411),
  fixtures: Number(process.env.E2E_FIXTURE_PORT ?? 3412),
};

const log = (msg) => console.log(`[e2e world] ${msg}`);

/**
 * Starts the world and returns its addresses plus `stop()`. With `website`, the
 * site is built against the local backend (with the test sign-in form) and
 * uploaded to its static hosting.
 */
export async function startWorld({ website = false } = {}) {
  const started = Date.now();
  await mkdir(runtimeDir, { recursive: true });
  for (const [name, port] of Object.entries(ports)) {
    if (!(await portFree(port))) {
      throw new Error(`Port ${port} (${name}) is busy. Another e2e run, or set E2E_CONVEX_PORT / E2E_SITE_PORT / E2E_FIXTURE_PORT.`);
    }
  }

  const fixtures = await startFixtureServer({ port: ports.fixtures });
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "poddle-e2e-"));
  let convex;
  const stop = async () => {
    await fixtures.close().catch(() => {});
    if (convex) killTree(convex);
    await rm(tempDir, { recursive: true, force: true }).catch(() => {});
  };
  try {
    await cp(path.join(root, "convex"), path.join(tempDir, "convex"), { recursive: true });
    await cp(path.join(root, "package.json"), path.join(tempDir, "package.json"));
    await symlink(path.join(root, "node_modules"), path.join(tempDir, "node_modules"));

    const adminToken = randomBytes(24).toString("base64url");
    const convexUrl = `http://127.0.0.1:${ports.convex}`;
    const siteUrl = `http://127.0.0.1:${ports.site}`;

    convex = spawnConvex(tempDir);
    await waitForOutput(convex, /Convex functions ready|declared as required|Environment variables/, "the local backend to start");
    await waitFor(() => existsSync(path.join(tempDir, ".env.local")), "the local deployment's .env.local");
    const envFile = path.join(tempDir, ".env.e2e");
    await writeFile(envFile, envLines({ adminToken, fixtureUrl: fixtures.url }), { mode: 0o600 });
    const mark = convex.output.length;
    convexCli(tempDir, ["env", "set", "--from-file", envFile, "--force"]);
    await waitForOutput(convex, /Convex functions ready/, "the functions to deploy", mark);

    if (website) {
      const dist = path.join(tempDir, "dist");
      run("npx", ["vite", "build", "web", "--outDir", dist, "--emptyOutDir", "--logLevel", "warn"], {
        cwd: root,
        env: { ...process.env, VITE_CONVEX_URL: convexUrl, VITE_PODDLE_TEST_SIGNIN: "1" },
      });
      run("npx", ["static-hosting", "upload", "--dist", dist], { cwd: tempDir, env: cliEnv() });
    }

    // Ctrl-C (or the runner being stopped) still takes the backend down with it.
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
      process.once(signal, () => {
        if (convex) killTree(convex);
        process.exit(130);
      });
    }
    fixtures.setWorld(worldApi({ convexUrl, adminToken, fixtures }));
    const info = { convexUrl, siteUrl, fixtureUrl: fixtures.url, adminToken, users: USERS };
    await writeFile(path.join(runtimeDir, "world.json"), JSON.stringify(info, null, 2));
    log(`ready in ${((Date.now() - started) / 1000).toFixed(1)} s: backend ${convexUrl}, site ${siteUrl}, fixtures ${fixtures.url}`);
    return { ...info, stop };
  } catch (error) {
    await stop();
    throw error;
  }
}

function envLines({ adminToken, fixtureUrl }) {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const pem = privateKey.export({ type: "pkcs8", format: "pem" });
  const jwk = publicKey.export({ format: "jwk" });
  const vars = {
    AUTH_PRIVATE_KEY: Buffer.from(pem).toString("base64"),
    AUTH_JWKS: JSON.stringify({ keys: [{ ...jwk, kid: randomUUID(), alg: "RS256", use: "sig" }] }),
    AUTH_APPLE_CLIENT_ID: "not-configured",
    AUTH_APPLE_TEAM_ID: "not-configured",
    AUTH_APPLE_KEY_ID: "not-configured",
    AUTH_APPLE_PRIVATE_KEY: "not-configured",
    AUTH_GOOGLE_CLIENT_ID: "not-configured",
    AUTH_GOOGLE_CLIENT_SECRET: "not-configured",
    PODDLE_TEST_SIGNIN: "1",
    PODDLE_ALLOWED_EMAILS: `${USERS.listener},${USERS.friend}`,
    PODDLE_API_TOKEN: adminToken,
    PODDLE_E2E: "1",
    PODDLE_DIRECTORY_URL: `${fixtureUrl}/itunes`,
  };
  return Object.entries(vars).map(([k, v]) => `${k}='${v}'`).join("\n") + "\n";
}

function cliEnv() {
  return { ...process.env, CI: "1", CONVEX_AGENT_MODE: "anonymous", CONVEX_DEPLOYMENT: undefined, CONVEX_DEPLOY_KEY: undefined };
}

function spawnConvex(cwd) {
  const logFile = createWriteStream(path.join(runtimeDir, "convex.log"));
  const child = spawn(
    "npx",
    ["convex", "dev", "--local-cloud-port", String(ports.convex), "--local-site-port", String(ports.site), "--typecheck", "disable", "--tail-logs", "always"],
    { cwd, env: cliEnv(), detached: true, stdio: ["ignore", "pipe", "pipe"] },
  );
  child.output = "";
  const take = (chunk) => {
    child.output += chunk.toString();
    logFile.write(chunk);
  };
  child.stdout.on("data", take);
  child.stderr.on("data", take);
  return child;
}

function convexCli(cwd, args) {
  // stdout is dropped: nothing secret is printed, but keep env values out of logs anyway.
  const r = spawnSync("npx", ["convex", ...args], { cwd, env: cliEnv(), encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  if (r.status !== 0) throw new Error(`npx convex ${args[0]} ${args[1] ?? ""} failed:\n${r.stderr}`);
}

function run(cmd, args, opts) {
  const r = spawnSync(cmd, args, { ...opts, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(" ")} failed:\n${r.stdout}\n${r.stderr}`);
}

function killTree(child) {
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {}
  // The local backend binary sometimes outlives the CLI's SIGTERM.
  setTimeout(() => {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {}
  }, 1500).unref();
}

async function waitForOutput(child, pattern, what, from = 0, timeoutMs = 180_000) {
  await waitFor(
    () => {
      if (child.exitCode !== null) throw new Error(`convex dev exited while waiting for ${what}:\n${child.output.slice(-3000)}`);
      return pattern.test(child.output.slice(from));
    },
    what,
    timeoutMs,
  );
}

async function waitFor(check, what, timeoutMs = 120_000) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if (await check()) return;
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`Timed out waiting for ${what}`);
}

/** Free on every interface: the local backend listens on all of them, not just 127.0.0.1. */
async function portFree(port) {
  for (const host of ["127.0.0.1", "0.0.0.0"]) {
    const free = await new Promise((resolve) => {
      const s = net.createServer();
      s.once("error", () => resolve(false));
      s.listen(port, host, () => s.close(() => resolve(true)));
    });
    if (!free) return false;
  }
  return true;
}

export async function readWorld() {
  return JSON.parse(await readFile(path.join(runtimeDir, "world.json"), "utf8"));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const world = await startWorld({ website: process.argv.includes("--website") });
  const quit = async () => {
    await world.stop();
    process.exit(0);
  };
  process.on("SIGINT", quit);
  process.on("SIGTERM", quit);
  log("Ctrl-C to stop.");
}
