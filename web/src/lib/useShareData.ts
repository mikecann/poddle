import { useEffect } from "react";
import type { SharePage } from "../../../convex/lib/meta";
import { embeddedPage } from "./pageData";

/**
 * A public page's data: the live query's result once it has one, until then
 * what the server embedded in the HTML. undefined while loading, null when not found.
 */
export function withEmbedded<T>(live: T | null | undefined, fromPage: (page: SharePage) => T | null | undefined): T | null | undefined {
  if (live !== undefined) return live;
  const page = embeddedPage(window.location.pathname);
  return page ? fromPage(page) : undefined;
}

/**
 * The page's title, and its canonical link (index.html's points at the home page,
 * which every other page is served from). `noindex` keeps a page out of search.
 */
export function useTitle(title: string | undefined, { noindex = false } = {}) {
  useEffect(() => {
    if (title) document.title = title;
    const canonical = document.querySelector<HTMLLinkElement>('link[rel="canonical"]');
    if (canonical) canonical.href = `${window.location.origin}${window.location.pathname}`;
  }, [title]);
  useEffect(() => {
    if (!noindex) return;
    const robots = document.createElement("meta");
    robots.name = "robots";
    robots.content = "noindex";
    document.head.append(robots);
    return () => robots.remove();
  }, [noindex]);
}
