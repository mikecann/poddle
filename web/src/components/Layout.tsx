import { useConvexAuth } from "convex/react";
import type { ReactNode } from "react";
import { CONTACT_EMAIL, GITHUB_URL } from "../lib/links";
import { Link } from "../lib/router";

export function Layout({ children, wide = false }: { children: ReactNode; wide?: boolean }) {
  const { isAuthenticated } = useConvexAuth();
  return (
    <>
      <SiteHeader signedIn={isAuthenticated} />
      <main className={wide ? "page wide" : "page"}>{children}</main>
      <SiteFooter />
    </>
  );
}

/** The top bar. No hooks, so the prerendered landing page (lib/prerender.tsx) can draw it too. */
export function SiteHeader({ signedIn }: { signedIn: boolean }) {
  return (
    <header className="topbar">
      <Corners />
      <Link to="/" className="brand" aria-label="Poddle home">
        <img src="/icon.png" alt="" width={34} height={34} />
        <b className="wordmark">Poddle</b>
      </Link>
      <Link to="/me" className="toplink">{signedIn ? "Dashboard" : "Sign in"}</Link>
    </header>
  );
}

/**
 * "Made with Convex" in the top-left corner and the GitHub repo in the top-right, the same
 * corner triangles as video-to-markdown.com. They sit in the page (not fixed) so they
 * scroll away rather than covering the content.
 */
export function Corners() {
  return (
    <>
      <a className="corner convex" href="https://convex.dev" target="_blank" rel="noopener noreferrer" aria-label="Made with Convex" title="Made with Convex">
        <svg viewBox="0 0 250 250" aria-hidden="true"><path d="M0,0 L250,0 L0,250 Z" /></svg>
        <img src="/convex.svg" alt="" width={28} height={28} />
      </a>
      <a className="corner github" href={GITHUB_URL} target="_blank" rel="noopener noreferrer" aria-label="View Poddle's code on GitHub" title="View the code on GitHub">
        <svg viewBox="0 0 250 250" aria-hidden="true">
          <path d="M0,0 L115,115 L130,115 L142,142 L250,250 L250,0 Z" />
          <path className="octo arm" d="M128.3,109.0 C113.8,99.7 119.0,89.6 119.0,89.6 C122.0,82.7 120.5,78.6 120.5,78.6 C119.2,72.0 123.4,76.3 123.4,76.3 C127.3,80.9 125.5,87.3 125.5,87.3 C122.9,97.6 130.6,101.9 134.4,103.2" />
          <path className="octo" d="M115.0,115.0 C114.9,115.1 118.7,116.5 119.8,115.4 L133.7,101.6 C136.9,99.2 139.9,98.4 142.2,98.6 C133.8,88.0 127.5,74.4 143.8,58.0 C148.5,53.4 154.0,51.2 159.7,51.0 C160.3,49.4 163.2,43.6 171.4,40.1 C171.4,40.1 176.1,42.5 178.8,56.2 C183.1,58.6 187.2,61.8 190.9,65.4 C194.5,69.0 197.7,73.2 200.1,77.6 C213.8,80.2 216.3,84.9 216.3,84.9 C212.7,93.1 206.9,96.0 205.4,96.6 C205.1,102.4 203.0,107.8 198.3,112.5 C181.9,128.9 168.3,122.5 157.7,114.1 C157.9,116.9 156.7,120.9 152.7,124.9 L141.0,136.5 C139.8,137.7 141.6,141.9 141.8,141.8 Z" />
        </svg>
      </a>
    </>
  );
}

export function SiteFooter() {
  return (
    <footer className="footer">
      <span>Poddle is made by Mike Cann.</span>
      <nav aria-label="About Poddle">
        <Link to="/support">Support</Link>
        <Link to="/privacy">Privacy</Link>
        <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>
      </nav>
    </footer>
  );
}

export function Loading() {
  return <div className="loading" aria-label="Loading"><i /><i /><i /></div>;
}

export function NotFound({ what }: { what: "episode" | "show" | "page" }) {
  return (
    <div className="empty">
      <img className="empty-mascot" src="/mascots/confused.png" alt="" width={134} height={180} />
      <h1>{what === "episode" ? "Episode not found" : what === "show" ? "Show not found" : "Nothing here"}</h1>
      <p>
        {what === "page"
          ? "That link doesn't go anywhere, sorry."
          : `This ${what} doesn't exist, or it's from a private feed, which never gets a public page.`}
      </p>
      <Link className="btn" to="/">Go to Poddle</Link>
    </div>
  );
}

export function EmptyListening({ children }: { children: ReactNode }) {
  return (
    <div className="empty-listening">
      <img src="/mascots/empty.png" alt="" width={180} height={108} loading="lazy" />
      <p className="muted">{children}</p>
    </div>
  );
}
