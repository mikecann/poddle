import { renderToString } from "react-dom/server";
import { Landing } from "../pages/Landing";

// The home page as static HTML, put into index.html's #root by the build
// (vite.config.ts), so search engines and link previews see the real page
// without running JavaScript. The app replaces it when it starts, and an inline
// script in index.html clears it on every other page before it's drawn.

export function renderLanding(): string {
  return renderToString(<Landing signedIn={false} />);
}
