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
