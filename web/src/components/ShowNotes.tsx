import { useMemo, type MouseEvent } from "react";
import { prepareShowNotes } from "../lib/showNotes";

/** Sanitised show notes. Timestamps call `onSeek`. */
export function ShowNotes({ html, duration, onSeek }: { html: string; duration?: number; onSeek?: (seconds: number) => void }) {
  const clean = useMemo(() => prepareShowNotes(html, duration), [html, duration]);
  const click = (e: MouseEvent<HTMLDivElement>) => {
    const a = (e.target as HTMLElement).closest<HTMLAnchorElement>("a[data-seek]");
    if (!a || !onSeek) return;
    e.preventDefault();
    onSeek(Number(a.dataset.seek));
  };
  return <div className="notes" onClick={click} dangerouslySetInnerHTML={{ __html: clean }} />;
}
