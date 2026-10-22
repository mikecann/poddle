import { ConvexError } from "convex/values";

// Who may make a Poddle account. The one gate: users.ts calls it before
// creating anyone. To open sign-up to everyone, make `maySignUp` return true.

export function allowedEmails(raw = process.env.PODDLE_ALLOWED_EMAILS): Set<string> {
  return new Set(
    (raw ?? "")
      .split(",")
      .map((e) => e.trim().toLowerCase())
      .filter(Boolean),
  );
}

export function maySignUp(email: string | undefined, emailVerified: boolean): boolean {
  return !!email && emailVerified && allowedEmails().has(email.trim().toLowerCase());
}

export const INVITE_ONLY = "Poddle is invite-only for now.";

export function assertMaySignUp(email: string | undefined, emailVerified: boolean): void {
  if (!maySignUp(email, emailVerified)) throw new ConvexError({ code: "inviteOnly", message: INVITE_ONLY });
}
