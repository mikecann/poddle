import type { SharePage } from "../../../convex/lib/meta";

// /e/<id> and /s/<id> arrive with their data embedded (convex/lib/meta.ts), so
// the first paint doesn't wait for the websocket. It's only good for the page
// it came with.

let embedded: { path: string; page: SharePage } | null | undefined;

function read(): { path: string; page: SharePage } | null {
  if (embedded !== undefined) return embedded;
  embedded = null;
  const el = document.getElementById("poddle-page");
  if (el?.textContent) {
    try {
      embedded = { path: window.location.pathname, page: JSON.parse(el.textContent) as SharePage };
    } catch {
      embedded = null;
    }
  }
  return embedded;
}

/** The embedded page for this path: the data, null if the server said not found, undefined if none. */
export function embeddedPage(path: string): SharePage | undefined {
  const e = read();
  return e && e.path === path ? e.page : undefined;
}
