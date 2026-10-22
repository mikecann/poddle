import DOMPurify from "dompurify";

// Show notes come from the feed as HTML. They're sanitised here before they
// go anywhere near the page, then timestamps ("12:34", "1:02:03") become links
// that seek the player.

const ALLOWED_TAGS = [
  "a", "b", "strong", "i", "em", "u", "s", "p", "br", "ul", "ol", "li", "blockquote",
  "h1", "h2", "h3", "h4", "h5", "h6", "code", "pre", "hr", "img", "span", "div", "small", "sup", "sub",
];
const ALLOWED_ATTR = ["href", "src", "alt", "title"];

const LOOKS_LIKE_HTML = /<\/?(p|br|a|div|span|ul|ol|li|b|i|em|strong|h[1-6]|img|blockquote|pre|code|hr)\b[^>]*>/i;
const TIMESTAMP = /(?<![\d:])(?:(\d{1,2}):)?(\d{1,2}):([0-5]\d)(?![\d:])/g;

function toSeconds(h: string | undefined, m: string, s: string): number {
  return Number(h ?? 0) * 3600 + Number(m) * 60 + Number(s);
}

/** Links the feed already made around a timestamp (often `#t=…` anchors, dead off their own site) seek instead. */
function claimTimestampLinks(root: ParentNode, maxSeconds: number | undefined): void {
  for (const a of root.querySelectorAll("a")) {
    const m = /^\s*(?:(\d{1,2}):)?(\d{1,2}):([0-5]\d)\s*$/.exec(a.textContent ?? "");
    if (!m) continue;
    const seconds = toSeconds(m[1], m[2]!, m[3]!);
    if (maxSeconds !== undefined && seconds > maxSeconds + 60) continue;
    a.setAttribute("href", `?t=${seconds}`);
    a.removeAttribute("target");
    a.removeAttribute("rel");
    a.className = "ts";
    a.dataset.seek = String(seconds);
  }
}

function linkTimestamps(root: ParentNode, doc: Document, maxSeconds: number | undefined): void {
  const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const texts: Text[] = [];
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    if (!(n.parentElement?.closest("a"))) texts.push(n as Text);
  }
  for (const text of texts) {
    const value = text.data;
    TIMESTAMP.lastIndex = 0;
    if (!TIMESTAMP.test(value)) continue;
    TIMESTAMP.lastIndex = 0;
    const frag = doc.createDocumentFragment();
    let last = 0;
    for (const m of value.matchAll(TIMESTAMP)) {
      const seconds = toSeconds(m[1], m[2]!, m[3]!);
      // "Recorded 9:30" in a 20-minute episode isn't a timestamp.
      if (maxSeconds !== undefined && seconds > maxSeconds + 60) continue;
      frag.append(value.slice(last, m.index));
      const a = doc.createElement("a");
      a.href = `?t=${seconds}`;
      a.className = "ts";
      a.dataset.seek = String(seconds);
      a.textContent = m[0];
      frag.append(a);
      last = m.index! + m[0].length;
    }
    if (last === 0) continue;
    frag.append(value.slice(last));
    text.replaceWith(frag);
  }
}

/** Plain-text notes (no tags at all) as paragraphs. */
function textToHtml(text: string): string {
  const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return text
    .split(/\n{2,}/)
    .map((p) => `<p>${esc(p).replace(/\n/g, "<br>")}</p>`)
    .join("");
}

/** Safe HTML for the notes, with links opening in a new tab and timestamps that seek. */
export function prepareShowNotes(raw: string, durationSeconds?: number): string {
  const html = LOOKS_LIKE_HTML.test(raw) ? raw : textToHtml(raw);
  const purify = DOMPurify(window);
  purify.addHook("afterSanitizeAttributes", (node) => {
    if (node.tagName === "A") {
      const href = node.getAttribute("href") ?? "";
      if (!/^(https?:|mailto:)/i.test(href)) node.removeAttribute("href");
      node.setAttribute("target", "_blank");
      node.setAttribute("rel", "noopener noreferrer nofollow");
    }
    if (node.tagName === "IMG") {
      const src = node.getAttribute("src") ?? "";
      if (!/^https:/i.test(src)) node.remove();
      else node.setAttribute("loading", "lazy");
    }
  });
  const clean = purify.sanitize(html, { ALLOWED_TAGS, ALLOWED_ATTR, RETURN_DOM_FRAGMENT: true });
  claimTimestampLinks(clean, durationSeconds);
  linkTimestamps(clean, document, durationSeconds);
  const box = document.createElement("div");
  box.append(clean);
  return box.innerHTML;
}
