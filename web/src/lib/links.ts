// The site's own URLs, and the poddle:// ones that open the app.
//
// The https links (/e/<id>, /s/<id>) are universal links: tapped in Messages,
// Slack or Mail they open Poddle if it's installed. iOS never opens a universal
// link from a page on the same site, though, so the "Open in Poddle" button
// uses the app's own poddle:// scheme, which the app reads the same way.

export function episodePath(id: string, at?: number | null): string {
  const t = at && at > 0 ? `?t=${Math.floor(at)}` : "";
  return `/e/${id}${t}`;
}

export function showPath(id: string): string {
  return `/s/${id}`;
}

export function appLink(kind: "e" | "s", id: string, at?: number | null): string {
  const t = kind === "e" && at && at > 0 ? `?t=${Math.floor(at)}` : "";
  return `poddle://${kind}/${id}${t}`;
}

/** Whether this browser is on an Apple device, where Poddle might be installed. */
export function mightHaveApp(userAgent = typeof navigator === "undefined" ? "" : navigator.userAgent): boolean {
  return /iPhone|iPad|iPod|Macintosh/.test(userAgent);
}

export const CONTACT_EMAIL = "poddle@mikecann.app";

export const GITHUB_URL = "https://github.com/mikecann/poddle";

/** The promo video, unlisted on Mike's personal YouTube channel. */
export const PROMO_VIDEO_ID = "cs5NGfffivc";
export const PROMO_VIDEO_TITLE = "Poddle, a podcast player I made for myself";

/** The site's public address, for canonical links and structured data. */
export const SITE_URL = "https://poddle.mikecann.app";

/** The home page's title, also in index.html. */
export const HOME_TITLE = "Poddle · A podcast player for iPhone";

export const APP_STORE_URL = "https://apps.apple.com/app/id6825613455";

/**
 * Poddle went out on the App Store on 27 Oct 2026. Set this to false and every
 * App Store badge on the site says "Coming soon" and isn't a link.
 */
export const APP_STORE_LIVE = true;
