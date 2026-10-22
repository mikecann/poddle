import { ConvexError } from "convex/values";

// Who may make a Poddle account. The one gate: users.ts calls it before
// creating anyone (or bringing back a deleted account).
//
// - PODDLE_OPEN_SIGNUP=1: anyone with a verified Apple or Google email.
// - Otherwise: only the emails in PODDLE_ALLOWED_EMAILS (invite-only).

type Env = Record<string, string | undefined>;

export function allowedEmails(raw = process.env.PODDLE_ALLOWED_EMAILS): Set<string> {
  return new Set(
    (raw ?? "")
      .split(",")
      .map((e) => e.trim().toLowerCase())
      .filter(Boolean),
  );
}

/** Sign-up is open to everyone only when the variable is exactly "1". */
export function signUpIsOpen(env: Env = process.env): boolean {
  return env.PODDLE_OPEN_SIGNUP === "1";
}

export function maySignUp(email: string | undefined, emailVerified: boolean, env: Env = process.env): boolean {
  if (!email?.trim() || !emailVerified) return false;
  return signUpIsOpen(env) || allowedEmails(env.PODDLE_ALLOWED_EMAILS).has(email.trim().toLowerCase());
}

export const INVITE_ONLY = "Poddle is invite-only for now.";

export function assertMaySignUp(email: string | undefined, emailVerified: boolean): void {
  if (!maySignUp(email, emailVerified)) throw new ConvexError({ code: "inviteOnly", message: INVITE_ONLY });
}
