import { useAuthActions } from "@convex-dev/auth/react";
import { useConvexAuth, useQuery } from "convex/react";
import { useState } from "react";
import type { FunctionReturnType } from "convex/server";
import { api } from "../../../convex/_generated/api";
import { Artwork } from "../components/Artwork";
import { ChefAdminPanel } from "../components/ChefAdminPanel";
import { DeleteAccount } from "../components/DeleteAccount";
import { LockIcon } from "../components/Icons";
import { SessionBoundary } from "../components/SessionBoundary";
import { EmptyListening, Layout, Loading } from "../components/Layout";
import { SignIn } from "../components/SignIn";
import { duration, listened, relativeDate } from "../lib/format";
import { episodePath, showPath } from "../lib/links";
import { Link } from "../lib/router";
import { useTitle } from "../lib/useShareData";

// The signed-in page: read-only for now. Everything on it comes from the
// person's own queries, which need their session (lib/auth.ts on the server).

type Row = FunctionReturnType<typeof api.queue.upNext>[number]["row"];

export function MePage() {
  const { isAuthenticated, isLoading } = useConvexAuth();
  const { signOut } = useAuthActions();
  const [leaving, setLeaving] = useState(false);
  useTitle("Your listening · Poddle", { noindex: true });
  if (isLoading) return <Layout><Loading /></Layout>;
  if (!isAuthenticated) {
    return (
      <Layout>
        <section className="me-signin">
          <span className="eyebrow">Your listening</span>
          <h1>Sign in to Poddle</h1>
          <p className="lede">Your Up Next, your shows and what you've been listening to, from the same account as the app.</p>
          <SignIn returnTo="/me" />
        </section>
      </Layout>
    );
  }
  return (
    <Layout wide>
      <SessionBoundary onSignedOut={() => void signOut()}>
        {!leaving && <Dashboard />}
        {!leaving && <ChefAdminPanel />}
        <DeleteAccount onLeaving={setLeaving} />
      </SessionBoundary>
    </Layout>
  );
}

function Dashboard() {
  const me = useQuery(api.users.me);
  const upNext = useQuery(api.queue.upNext, {});
  const shows = useQuery(api.podcasts.list, {});
  const recent = useQuery(api.sessions.recent, { limit: 12 });
  // The cards only need totals, so they skip `stats.summary`: that reads every
  // session and episode in the period and re-runs on each position save.
  const week = useQuery(api.stats.totals, { period: "week" });
  const year = useQuery(api.stats.totals, { period: "year" });
  const { signOut } = useAuthActions();
  const firstName = me?.name?.split(" ")[0];

  return (
    <div className="me">
      <div className="me-head">
        <div>
          <span className="eyebrow">Your listening</span>
          <h1>{firstName ? `Hey ${firstName}` : "Hey there"}</h1>
          {me?.email && <p className="meta">Signed in as {me.email}</p>}
        </div>
        <button className="btn" onClick={() => void signOut()}>Sign out</button>
      </div>

      <section className="stats" aria-label="Stats">
        <StatCard label="This week" s={week} />
        <StatCard label="This year" s={year} />
      </section>

      <div className="me-grid">
        <section>
          <h2>Up Next {upNext && upNext.length > 0 && <em>{upNext.length}</em>}</h2>
          {upNext === undefined ? <Loading /> : upNext.length === 0 ? (
            <EmptyListening>Nothing to listen to. Add an episode in the app.</EmptyListening>
          ) : (
            <ul className="list">
              {upNext.map(({ row }, i) => <EpisodeRowView key={row.episode._id} row={row} playing={i === 0} />)}
            </ul>
          )}
        </section>

        <div>
          <section>
            <h2>Recently listened</h2>
            {recent === undefined ? <Loading /> : recent.length === 0 ? (
              <p className="muted">Nothing yet.</p>
            ) : (
              <ul className="list">
                {recent.map(({ row, lastListenedAt }) => (
                  <EpisodeRowView key={row.episode._id} row={row} when={lastListenedAt} />
                ))}
              </ul>
            )}
          </section>
        </div>
      </div>

      <section>
        <h2>Your shows {shows && shows.length > 0 && <em>{shows.length}</em>}</h2>
        {shows === undefined ? <Loading /> : shows.length === 0 ? (
          <EmptyListening>No shows yet. Subscribe to some in the app.</EmptyListening>
        ) : (
          <ul className="shows">
            {shows.map((p) => {
              const tile = (
                <>
                  <Artwork src={p.artworkUrl} title={p.title} size={120} />
                  <b>{p.title}</b>
                  {p.isPrivate && <span className="priv"><LockIcon /> Private</span>}
                </>
              );
              return (
                <li key={p._id}>
                  {p.isPrivate ? <div className="tile">{tile}</div> : <Link to={showPath(p._id)} className="tile">{tile}</Link>}
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}

function StatCard({ label, s }: { label: string; s: FunctionReturnType<typeof api.stats.totals> | undefined }) {
  return (
    <div className="stat">
      <span className="cap">{label}</span>
      {s === undefined ? <Loading /> : (
        <>
          <b>{listened(s.totals.wall)}</b>
          <p>
            {s.totals.timeSaved > 60 && <>saved {listened(s.totals.timeSaved)} · </>}
            {s.completion.completed} finished
            {s.totals.averageSpeed ? <> · {s.totals.averageSpeed.toFixed(2).replace(/0$/, "")}× avg</> : null}
          </p>
        </>
      )}
    </div>
  );
}

function EpisodeRowView({ row, playing = false, when }: { row: Row; playing?: boolean; when?: number }) {
  const { episode, state, podcast } = row;
  const total = episode.duration ?? 0;
  const position = state && !state.played ? state.position : 0;
  const started = position > 5 && total > 0;
  const progress = started ? Math.min(1, position / total) : 0;
  const left = started ? total - position : total;
  const body = (
    <>
      <Artwork src={episode.artworkUrl ?? podcast.artworkUrl} title={podcast.title} size={56} />
      <div className="rt">
        <span className="qs">
          {playing && <span className="dot" aria-hidden />}
          {playing ? "Playing · " : ""}{podcast.title}
          {podcast.isPrivate && <span className="priv"><LockIcon /> Private</span>}
        </span>
        <b className="qtt">{episode.title}</b>
        <span className="qm">
          {started ? (
            <>
              <span className="prog"><i style={{ width: `${progress * 100}%` }} /></span>
              <b>{duration(left)} left</b>
            </>
          ) : state?.played ? (
            <span>Played</span>
          ) : (
            <span>{duration(total)}</span>
          )}
          {when !== undefined ? <span>· {relativeDate(when)}</span> : episode.pubDate ? <span>· {relativeDate(episode.pubDate)}</span> : null}
        </span>
      </div>
    </>
  );
  // Private feeds have no public page to link to.
  return <li>{podcast.isPrivate ? <div className="row">{body}</div> : <Link to={episodePath(episode._id, started ? position : null)} className="row">{body}</Link>}</li>;
}
