import { useQuery } from "convex/react";
import { useState } from "react";
import { api } from "../../../convex/_generated/api";
import { Artwork } from "../components/Artwork";
import { AppIcon } from "../components/Icons";
import { Layout, Loading, NotFound } from "../components/Layout";
import { duration, relativeDate } from "../lib/format";
import { appLink, episodePath, mightHaveApp } from "../lib/links";
import { Link } from "../lib/router";
import { useCopy } from "../lib/useCopy";
import { useTitle, withEmbedded } from "../lib/useShareData";

export function ShowPage({ id }: { id: string }) {
  const data = withEmbedded(useQuery(api.share.show, { podcastId: id }), (p) =>
    p.kind === "show" && p.page.show._id === id ? p.page : p.kind === "notFound" ? null : undefined,
  );
  const [expanded, setExpanded] = useState(false);
  const { copied, copy } = useCopy();
  useTitle(data ? `${data.show.title} · Poddle` : data === null ? "Show not found · Poddle" : undefined);

  if (data === undefined) return <Layout><Loading /></Layout>;
  if (data === null) return <Layout><NotFound what="show" /></Layout>;
  const { show, episodes } = data;
  const long = (show.description?.length ?? 0) > 320;

  return (
    <Layout>
      <article className="show">
        <div className="ep-hero">
          <Artwork src={show.artworkUrl} title={show.title} size={200} className="hero-art" />
          <div className="ep-head">
            <span className="eyebrow">Podcast</span>
            <h1>{show.title}</h1>
            {show.author && <p className="meta author">{show.author}</p>}
            <p className="meta">
              {[`${show.episodeCount} episode${show.episodeCount === 1 ? "" : "s"}`, show.latestEpisodeAt ? `latest ${relativeDate(show.latestEpisodeAt).toLowerCase()}` : ""]
                .filter(Boolean)
                .join(" · ")}
            </p>
            <div className="actions">
              {mightHaveApp() && (
                <a className="btn primary" href={appLink("s", id)}>
                  <AppIcon /> Open in Poddle
                </a>
              )}
              {show.link && <a className="btn" href={show.link} target="_blank" rel="noopener noreferrer nofollow">Website</a>}
            </div>
          </div>
        </div>

        {show.description && (
          <div className={`description ${long && !expanded ? "clamped" : ""}`}>
            <p>{show.description}</p>
            {long && !expanded && <button className="more" onClick={() => setExpanded(true)}>More</button>}
          </div>
        )}

        <div className="feed">
          <label className="cap" htmlFor="feed-url">Feed URL</label>
          <div className="feedrow">
            <input id="feed-url" readOnly value={show.feedUrl} onFocus={(e) => e.currentTarget.select()} />
            <button className="btn" onClick={() => copy(show.feedUrl, "Feed URL copied")}>Copy</button>
          </div>
        </div>

        <section>
          <h2>Recent episodes</h2>
          {episodes.length === 0 ? (
            <p className="muted">No episodes to show yet.</p>
          ) : (
            <ul className="list">
              {episodes.map((e) => (
                <li key={e._id}>
                  <Link to={episodePath(e._id)} className="row">
                    <div className="rt">
                      <span className="qs">{[relativeDate(e.pubDate), duration(e.duration)].filter(Boolean).join(" · ")}</span>
                      <b className="qtt">{e.title}</b>
                      {e.summary && <p className="sum">{e.summary}</p>}
                    </div>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </section>
      </article>
      {copied && <div className="toast" role="status">{copied}</div>}
    </Layout>
  );
}
