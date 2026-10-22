import { useCallback, useEffect, useRef, useState } from "react";

/** Copy text to the clipboard; `copied` is the label to show for a moment afterwards. */
export function useCopy(): { copied: string | null; copy: (text: string, label?: string) => Promise<void> } {
  const [copied, setCopied] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);
  const copy = useCallback(async (text: string, label = "Copied") => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(label);
    } catch {
      setCopied("Couldn't copy");
    }
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setCopied(null), 2200);
  }, []);
  return { copied, copy };
}
