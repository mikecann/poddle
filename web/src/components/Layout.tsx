import { useConvexAuth } from "convex/react";
import type { ReactNode } from "react";
import { CONTACT_EMAIL } from "../lib/links";
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
      <Link to="/" className="brand" aria-label="Poddle home">
        <img src="/icon.png" alt="" width={34} height={34} />
        <b className="wordmark">Poddle</b>
      </Link>
      <Link to="/me" className="toplink">{signedIn ? "Your listening" : "Sign in"}</Link>
    </header>
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
