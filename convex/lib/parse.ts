// Small parsing helpers shared by the feed and OPML parsers. Pure, no Convex imports.

/**
 * Parse every `itunes:duration` style seen in the wild into seconds:
 * "3600", "3600.5", "59:59", "1:02:03", "01:02:03.250", "1h 2m 3s", "45 min", "PT1H2M".
 */
export function parseDuration(raw: unknown): number | undefined {
  if (raw === undefined || raw === null) return undefined;
  const s = String(raw).trim().toLowerCase();
  if (!s) return undefined;
  if (/^\d+(\.\d+)?$/.test(s)) return roundSecs(Number(s));
  if (/^\d+(:\d+){1,2}(\.\d+)?$/.test(s)) {
    const parts = s.split(":").map(Number);
    let total = 0;
    for (const p of parts) total = total * 60 + p;
    return roundSecs(total);
  }
  const iso = /^p?t?(?:(\d+(?:\.\d+)?)h)?(?:(\d+(?:\.\d+)?)m)?(?:(\d+(?:\.\d+)?)s)?$/.exec(s);
  if (iso && (iso[1] || iso[2] || iso[3]) && s.startsWith("pt")) {
    return roundSecs(Number(iso[1] ?? 0) * 3600 + Number(iso[2] ?? 0) * 60 + Number(iso[3] ?? 0));
  }
  const h = /(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)\b/.exec(s);
  const m = /(\d+(?:\.\d+)?)\s*(?:m|min|mins|minute|minutes)\b/.exec(s);
  const sec = /(\d+(?:\.\d+)?)\s*(?:s|sec|secs|second|seconds)\b/.exec(s);
  if (h || m || sec) {
    return roundSecs(Number(h?.[1] ?? 0) * 3600 + Number(m?.[1] ?? 0) * 60 + Number(sec?.[1] ?? 0));
  }
  return undefined;
}

function roundSecs(n: number): number | undefined {
  if (!Number.isFinite(n) || n <= 0) return undefined;
  return Math.round(n * 1000) / 1000;
}

const TZ_ABBREVIATIONS: Record<string, string> = {
  AEST: "+1000",
  AEDT: "+1100",
  ACST: "+0930",
  ACDT: "+1030",
  AWST: "+0800",
  NZST: "+1200",
  NZDT: "+1300",
  BST: "+0100",
  CET: "+0100",
  CEST: "+0200",
  IST: "+0530",
  JST: "+0900",
  UT: "+0000",
  Z: "+0000",
};

/** RFC 822/2822, ISO 8601 and a few sloppy variants. Returns ms since epoch. */
export function parseDate(raw: unknown): number | undefined {
  if (raw === undefined || raw === null) return undefined;
  let s = String(raw).trim();
  if (!s) return undefined;
  let t = Date.parse(s);
  if (!Number.isNaN(t)) return t;
  // Unknown zone abbreviations ("AEST").
  s = s.replace(/\b([A-Z]{2,5})$/, (abbr) => TZ_ABBREVIATIONS[abbr] ?? abbr);
  t = Date.parse(s);
  if (!Number.isNaN(t)) return t;
  // Drop a localised or wrong weekday ("Thurs, 02 Jan 2025 ...").
  s = s.replace(/^[A-Za-z]+,?\s+/, "");
  t = Date.parse(s);
  if (!Number.isNaN(t)) return t;
  return undefined;
}

export function parseIntOrUndefined(raw: unknown): number | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  const n = Number.parseInt(String(raw).trim(), 10);
  return Number.isFinite(n) ? n : undefined;
}

/** URL without query string or fragment. */
export function stripQuery(url: string | undefined): string | undefined {
  if (!url) return undefined;
  const trimmed = url.trim();
  if (!trimmed) return undefined;
  return trimmed.split("#")[0]!.split("?")[0]!;
}

/**
 * Analytics redirects that wrap the real file URL as a path prefix, e.g.
 * `dts.podtrac.com/redirect.mp3/traffic.megaphone.fm/X.mp3`. Feeds add and
 * drop these over time, so Overcast's stored URL often differs from today's feed.
 */
const TRACKING_PREFIXES = [
  /^(?:dts\.|www\.)?podtrac\.com\/(?:pts\/)?redirect\.[a-z0-9]+\//,
  /^(?:tracking\.)?swap\.fm\/track\/[^/]+\//,
  /^chrt\.fm\/track\/[^/]+\//,
  /^chtbl\.com\/track\/[^/]+\//,
  /^pdst\.fm\/e\//,
  /^pdcn\.co\/e\//,
  /^mgln\.ai\/e\/[^/]+\//,
  /^op3\.dev\/e(?:,[^/]*)?\//,
  /^pfx\.vpixl\.com\/[^/]+\//,
  /^(?:verifi\.podscribe\.com|pscrb\.fm)\/rss\/p\//,
  /^arttrk\.com\/p\/[^/]+\//,
  /^prfx\.byspotify\.com\/e\//,
  /^media\.blubrry\.com\/[^/]+\//,
  /^claritaspod\.com\/measure\//,
];
/** What's left after a prefix must look like a host, so a plain file path is never eaten. */
const LOOKS_LIKE_HOST = /^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?\//i;

/**
 * Key for matching an enclosure across sources: no query or fragment, no scheme
 * (http and https match), tracking redirect prefixes peeled off, host lowercased.
 * Anchor's `/play/<id>/https%3A%2F%2F…` wrapper is unwrapped too.
 */
export function enclosureKey(url: string | undefined): string | undefined {
  const stripped = stripQuery(url);
  if (!stripped) return undefined;
  let s: string = stripped;
  const anchor = /\/play\/\d+\/(https?%3A%2F%2F.+)$/i.exec(s);
  if (anchor) {
    try {
      s = stripQuery(decodeURIComponent(anchor[1]!)) ?? s;
    } catch {
      // Keep the wrapped URL.
    }
  }
  s = s.replace(/^[a-z]+:\/\//i, "");
  for (let peeled = true; peeled; ) {
    peeled = false;
    for (const prefix of TRACKING_PREFIXES) {
      const m = prefix.exec(s.toLowerCase());
      if (!m) continue;
      const rest: string = s.slice(m[0].length).replace(/^[a-z]+:\/\//i, "");
      if (!LOOKS_LIKE_HOST.test(rest)) continue;
      s = rest;
      peeled = true;
    }
  }
  const slash = s.indexOf("/");
  return slash < 0 ? s.toLowerCase() : s.slice(0, slash).toLowerCase() + s.slice(slash);
}

export function normalizeFeedUrl(raw: string): string {
  let s = raw.trim();
  if (/^feed:\/\//i.test(s)) s = "https://" + s.slice(7);
  else if (/^(itpc|pcast|podcast):\/\//i.test(s)) s = "https://" + s.replace(/^[a-z]+:\/\//i, "");
  else if (!/^https?:\/\//i.test(s)) s = "https://" + s;
  try {
    const u = new URL(s);
    u.hostname = u.hostname.toLowerCase();
    u.hash = "";
    return u.toString();
  } catch {
    return s;
  }
}

/** Token-in-URL or Basic-auth feeds are private (spec §2.1). */
export function looksPrivate(feedUrl: string): boolean {
  try {
    const u = new URL(feedUrl);
    if (u.username || u.password) return true;
    for (const key of u.searchParams.keys()) {
      if (/token|key|auth|secret|private|pass|sig/i.test(key)) return true;
    }
    return /\/private\//i.test(u.pathname);
  } catch {
    return false;
  }
}

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  rsquo: "’",
  lsquo: "‘",
  rdquo: "”",
  ldquo: "“",
  hellip: "…",
  mdash: "—",
  ndash: "–",
};

export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, body: string) => {
    if (body[0] === "#") {
      const code = body[1]?.toLowerCase() === "x" ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : m;
    }
    return NAMED_ENTITIES[body.toLowerCase()] ?? m;
  });
}

export function htmlToText(html: string): string {
  return decodeEntities(
    html
      .replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
      .replace(/<br\s*\/?>|<\/p>|<\/li>/gi, "\n")
      .replace(/<[^>]+>/g, " "),
  )
    .replace(/[ \t\f\v\r]+/g, " ")
    .replace(/\s*\n\s*/g, "\n")
    .trim();
}

export function snippet(html: string | undefined, max = 280): string | undefined {
  if (!html) return undefined;
  const text = htmlToText(html).replace(/\n+/g, " ");
  if (!text) return undefined;
  return text.length > max ? truncate(text, max - 1).trimEnd() + "…" : text;
}

/** First `max` UTF-16 units, never splitting an emoji's surrogate pair (Convex rejects lone surrogates). */
export function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  const code = s.charCodeAt(max - 1);
  return s.slice(0, code >= 0xd800 && code <= 0xdbff ? max - 1 : max);
}

/** Pull an Apple ID out of a podcasts.apple.com link, an overcast.fm/itunes link, or a bare number. */
export function parseAppleId(input: string): number | undefined {
  const s = input.trim();
  const patterns = [/^(\d{5,})$/, /podcasts\.apple\.com\/.*?\/id(\d+)/i, /itunes\.apple\.com\/.*?\/id(\d+)/i, /overcast\.fm\/itunes(\d+)/i, /[?&]id=(\d+)/];
  for (const re of patterns) {
    const m = re.exec(s);
    if (m?.[1]) return Number(m[1]);
  }
  return undefined;
}
