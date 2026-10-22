import { useState } from "react";

/** Square show or episode art with the app's rounded corners. Falls back to a warm tile with the initial. */
export function Artwork({ src, title, size, className = "" }: { src?: string; title: string; size: number; className?: string }) {
  const [broken, setBroken] = useState(false);
  const style = { "--s": `${size}px` } as React.CSSProperties;
  if (!src || broken) {
    return (
      <div className={`art art-fallback ${className}`} style={style} aria-hidden>
        <b>{title.trim().charAt(0).toUpperCase() || "P"}</b>
      </div>
    );
  }
  return <img className={`art ${className}`} style={style} src={src} alt="" width={size} height={size} loading="lazy" onError={() => setBroken(true)} />;
}
