import { useConvexAuth } from "convex/react";
import type { ReactNode } from "react";
import { Link } from "../lib/router";

export function Layout({ children, wide = false }: { children: ReactNode; wide?: boolean }) {
  const { isAuthenticated } = useConvexAuth();
  return (
    <>
      <header className="topbar">
        <Link to="/" className="brand" aria-label="Poddle home">
          <img src="/icon.png" alt="" width={34} height={34} />
          <b>Poddle</b>
        </Link>
        <Link to="/me" className="toplink">{isAuthenticated ? "Your listening" : "Sign in"}</Link>
      </header>
      <main className={wide ? "page wide" : "page"}>{children}</main>
      <footer className="footer">
        <span>Poddle, a podcast player for iPhone, iPad and Mac.</span>
      </footer>
    </>
  );
}

export function Loading() {
  return <div className="loading" aria-label="Loading"><i /><i /><i /></div>;
}

export function NotFound({ what }: { what: "episode" | "show" | "page" }) {
  return (
    <div className="empty">
      <div className="emptyicon" aria-hidden>?</div>
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
