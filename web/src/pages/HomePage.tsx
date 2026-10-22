import { useConvexAuth } from "convex/react";
import { Layout } from "../components/Layout";
import { SignIn } from "../components/SignIn";
import { useTitle } from "../lib/useShareData";
import { Link } from "../lib/router";

export function HomePage() {
  const { isAuthenticated, isLoading } = useConvexAuth();
  useTitle("Poddle");
  return (
    <Layout>
      <section className="home">
        <img className="home-mascot" src="/mascots/waving.png" alt="" width={176} height={200} />
        <h1 className="wordmark">Poddle</h1>
        <p className="lede">
          Poddle is my own little podcast player for iPhone, iPad and Mac. I made it to replace Overcast, so it has
          one Up Next queue, Smart Speed and Voice Boost, speeds per show, and stats on how much I actually listen
          (a lot, it turns out).
        </p>
        <p className="lede">
          It's invite-only for now. If someone sent you a link to an episode, you're in the right place: hit play and
          have a listen, no account needed.
        </p>
        <div className="home-signin">
          {isLoading ? null : isAuthenticated ? (
            <Link className="btn primary lg" to="/me">See what you're listening to</Link>
          ) : (
            <SignIn returnTo="/me" />
          )}
        </div>
      </section>
    </Layout>
  );
}
