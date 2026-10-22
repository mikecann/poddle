import type { ShareEpisode, ShareShowPage } from "./sharePages";

// Link previews for the website. iMessage, Slack, X and WhatsApp don't run
// JavaScript, so /e/<id> and /s/<id> are served by an HTTP action (http.ts) that
// takes the site's built index.html and swaps the block between the markers
// below for the page's own <title>, Open Graph and Twitter card tags. It also
// embeds the page's data so the app can draw it before its first query returns.

export const META_START = "<!--poddle:meta-->";
export const META_END = "<!--/poddle:meta-->";

export type PageMeta = {
  title: string;
  description: string;
  /** Absolute URL of the page, without `?t=`. */
  url: string;
  image?: string;
  type: "website" | "music.song" | "music.album";
  /** Left out of search engines (not-found pages). */
  noindex?: boolean;
};

export type SharePage =
  | { kind: "episode"; episode: ShareEpisode }
  | { kind: "show"; page: ShareShowPage }
  | { kind: "notFound"; what: "episode" | "show" };

const DESCRIPTION_CHARS = 200;
const DEFAULT_DESCRIPTION = "Poddle is a warm little podcast player for iPhone, iPad and Mac.";

export function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function clip(s: string, n = DESCRIPTION_CHARS): string {
  const one = s.replace(/\s+/g, " ").trim();
  return one.length > n ? `${one.slice(0, n - 1).trimEnd()}…` : one;
}

/** The tags for a page. */
export function metaFor(page: SharePage, origin: string): PageMeta {
  switch (page.kind) {
    case "episode": {
      const e = page.episode;
      return {
        title: e.title,
        description: clip(e.summary ?? `An episode of ${e.podcast.title}.`),
        url: `${origin}/e/${e._id}`,
        image: e.artworkUrl ?? e.podcast.artworkUrl ?? `${origin}/og-default.png`,
        type: "music.song",
      };
    }
    case "show": {
      const s = page.page.show;
      return {
        title: s.title,
        description: clip(s.description ?? (s.author ? `A podcast by ${s.author}.` : "A podcast.")),
        url: `${origin}/s/${s._id}`,
        image: s.artworkUrl ?? `${origin}/og-default.png`,
        type: "music.album",
      };
    }
    case "notFound":
      return {
        title: page.what === "episode" ? "Episode not found" : "Show not found",
        description: DEFAULT_DESCRIPTION,
        image: `${origin}/og-default.png`,
        url: origin,
        type: "website",
        noindex: true,
      };
  }
}

export function metaTags(meta: PageMeta, siteTitleSuffix: string | null): string {
  const siteName = "Poddle";
  const subtitle = siteTitleSuffix ? ` · ${siteTitleSuffix}` : "";
  const tag = (attr: "name" | "property", key: string, value: string | undefined) =>
    value === undefined ? "" : `<meta ${attr}="${key}" content="${escapeHtml(value)}">`;
  return [
    `<title>${escapeHtml(`${meta.title}${subtitle} · ${siteName}`)}</title>`,
    tag("name", "description", meta.description),
    meta.noindex ? `<meta name="robots" content="noindex">` : "",
    `<link rel="canonical" href="${escapeHtml(meta.url)}">`,
    tag("property", "og:site_name", siteName),
    tag("property", "og:type", meta.type),
    tag("property", "og:title", meta.title),
    tag("property", "og:description", meta.description),
    tag("property", "og:url", meta.url),
    tag("property", "og:image", meta.image),
    tag("property", "og:image:alt", meta.image ? meta.title : undefined),
    tag("name", "twitter:card", meta.image?.endsWith("/og-default.png") ? "summary_large_image" : "summary"),
    tag("name", "twitter:title", meta.title),
    tag("name", "twitter:description", meta.description),
    tag("name", "twitter:image", meta.image),
  ]
    .filter(Boolean)
    .join("\n    ");
}

/** JSON that's safe inside a <script> element. */
export function scriptJson(value: unknown): string {
  return JSON.stringify(value).replace(/</g, "\\u003c").replace(/>/g, "\\u003e").replace(/&/g, "\\u0026").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
}

/** A bare page for when the site hasn't been uploaded yet, so previews still work. */
export const FALLBACK_INDEX_HTML = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    ${META_START}<title>Poddle</title>${META_END}
  </head>
  <body><div id="root"></div></body>
</html>`;

/** index.html with this page's tags and data in place of the default block. */
export function renderSharePage(indexHtml: string, page: SharePage, origin: string): string {
  const meta = metaFor(page, origin);
  const suffix = page.kind === "episode" ? page.episode.podcast.title : null;
  const data = `<script id="poddle-page" type="application/json">${scriptJson(page)}</script>`;
  const block = `${META_START}\n    ${metaTags(meta, suffix)}\n    ${data}\n    ${META_END}`;
  const start = indexHtml.indexOf(META_START);
  const end = indexHtml.indexOf(META_END);
  if (start !== -1 && end > start) {
    return indexHtml.slice(0, start) + block + indexHtml.slice(end + META_END.length);
  }
  // No markers (an old build): drop any <title> and put ours at the top of <head>.
  const withoutTitle = indexHtml.replace(/<title>[\s\S]*?<\/title>/i, "");
  return withoutTitle.replace(/<head[^>]*>/i, (m) => `${m}\n    ${block}`);
}
