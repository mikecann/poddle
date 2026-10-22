// The server's "you're not signed in" (lib/auth.ts): ConvexError { code: "unauthenticated" }.
// Convex's client hands it over as a ConvexError with `data`; older builds only
// have it in the message.

export function isSignedOutError(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const data = (error as { data?: unknown }).data;
  if (data && typeof data === "object" && (data as { code?: unknown }).code === "unauthenticated") return true;
  const message = (error as { message?: unknown }).message;
  return typeof message === "string" && /"code":\s*"unauthenticated"/.test(message);
}
