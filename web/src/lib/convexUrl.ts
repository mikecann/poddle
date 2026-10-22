// The deployment the site talks to. `static-hosting upload --build` sets
// VITE_CONVEX_URL; otherwise a .convex.site page uses its own deployment, and a
// local `npm run web:dev` uses dev.

const DEV = "https://striped-turtle-260.ap-southeast-2.convex.cloud";

export function convexUrl(): string {
  const fromBuild = import.meta.env.VITE_CONVEX_URL as string | undefined;
  if (fromBuild) return fromBuild;
  const host = window.location.hostname;
  if (host.endsWith(".convex.site")) return `https://${host.replace(/\.convex\.site$/, ".convex.cloud")}`;
  return DEV;
}

/** Built with the dev-only test sign-in button (`npm run web:upload:dev`). The server refuses it on prod anyway. */
export const testSignInEnabled = import.meta.env.VITE_PODDLE_TEST_SIGNIN === "1";
