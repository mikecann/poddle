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

export function useTitle(title: string | undefined) {
  useEffect(() => {
    if (title) document.title = title;
  }, [title]);
}
