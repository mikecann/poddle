import { ConvexError } from "convex/values";
import { assertAdminToken } from "./auth";

// The end-to-end suites' hooks (testing.ts, the fake Apple directory). They only
// work on a throwaway local backend: PODDLE_E2E must be exactly "1" and the
// deployment's own address must be 127.0.0.1 or localhost, so setting the flag on
// dev or prod by mistake does nothing. docs/testing.md has the whole setup.

type Env = Record<string, string | undefined>;

const LOCAL = /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/?$/;

/** Why the e2e hooks are refused here, or null if they're allowed. */
export function e2eRefusal(env: Env = process.env): string | null {
  if (env.PODDLE_E2E !== "1") return "The e2e hooks are off on this deployment.";
  if (!LOCAL.test(env.CONVEX_CLOUD_URL ?? "") || !LOCAL.test(env.CONVEX_SITE_URL ?? "")) {
    return "The e2e hooks only run on a local backend.";
  }
  return null;
}

/** The e2e hooks need the flag, a local backend and the admin token. */
export function assertE2e(token: string, env: Env = process.env): void {
  const refusal = e2eRefusal(env);
  if (refusal) throw new ConvexError({ code: "e2eDisabled", message: refusal });
  assertAdminToken(token);
}

/** Apple's directory, or the e2e fixture server's stand-in for it (PODDLE_DIRECTORY_URL). */
export function directoryBase(env: Env = process.env): string {
  const override = env.PODDLE_DIRECTORY_URL?.trim();
  if (override && e2eRefusal(env) === null) return override.replace(/\/$/, "");
  return "https://itunes.apple.com";
}
