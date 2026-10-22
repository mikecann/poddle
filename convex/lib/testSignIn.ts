// Test sign-in lets scripts, simulators and later jobs sign in unattended. It
// must never work on prod: it needs PODDLE_TEST_SIGNIN to be exactly "1" (set
// only on dev), and it's refused on prod's own addresses even if someone sets it.

const PROD_HOSTS = ["coordinated-dodo-120.", "poddle.mikecann.app"];

/** Why test sign-in is refused here, or null if it's allowed. */
export function testSignInRefusal(env: Record<string, string | undefined> = process.env): string | null {
  if (env.PODDLE_TEST_SIGNIN !== "1") return "Test sign-in is disabled on this deployment.";
  const site = `${env.CONVEX_SITE_URL ?? ""} ${env.CONVEX_CLOUD_URL ?? ""}`;
  if (PROD_HOSTS.some((h) => site.includes(h))) return "Test sign-in is never allowed on production.";
  return null;
}
