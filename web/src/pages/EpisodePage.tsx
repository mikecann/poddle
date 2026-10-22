import { useQuery } from "convex/react";
import { useRef } from "react";
import { api } from "../../../convex/_generated/api";
import { Artwork } from "../components/Artwork";
import { AppIcon } from "../components/Icons";
import { Layout, Loading, NotFound } from "../components/Layout";
import { Player, type PlayerHandle } from "../components/Player";
import { ShowNotes } from "../components/ShowNotes";
import { clock, date, duration, parseStart } from "../lib/format";
import { appLink, episodePath, mightHaveApp, showPath } from "../lib/links";
import { Link, navigate, type Location } from "../lib/router";
import { useCopy } from "../lib/useCopy";
import { useTitle, withEmbedded } from "../lib/useShareData";

export function EpisodePage({ id, location }: { id: string; location: Location }) {
  const episode = withEmbedded(useQuery(api.share.episode, { episodeId: id }), (p) =>
    p.kind === "episode" && p.episode._id === id ? p.episode : p.kind === "notFound" ? null : undefined,
  );
  const startAt = parseStart(location.search.get("t"));
  const player = useRef<PlayerHandle>(null);
  const { copied, copy } = useCopy();
  useTitle(episode ? `${episode.title} · ${episode.podcast.title} · Poddle` : episode === null ? "Episode not found · Poddle" : undefined);

  if (episode === undefined) return <Layout><Loading /></Layout>;
  if (episode === null) return <Layout><NotFound what="episode" /></Layout>;

  const art = episode.artworkUrl ?? episode.podcast.artworkUrl;
  const seek = (t: number) => {
    player.current?.seek(t, true);
    navigate(episodePath(id, t), { replace: true });
  };
  const copyAt = (position: number) =>
    copy(new URL(episodePath(id, position), window.location.origin).toString(), `Link at ${clock(position)} copied`);
  const numbering = [episode.season ? `Season ${episode.season}` : "", episode.episodeNumber ? `Episode ${episode.episodeNumber}` : ""]
    .filter(Boolean)
    .join(", ");

  return (
    <Layout>
      <article className="episode">
        <div className="ep-hero">
          <Artwork src={art} title={episode.podcast.title} size={200} className="hero-art" />
          <div className="ep-head">
            <Link to={showPath(episode.podcast._id)} className="eyebrow">{episode.podcast.title}</Link>
            <h1>{episode.title}</h1>
            <p className="meta">
              {[date(episode.pubDate), duration(episode.duration), numbering].filter(Boolean).join(" · ")}
            </p>
            <div className="actions">
              {mightHaveApp() && (
                <a className="btn primary" href={appLink("e", id, startAt)}>
                  <AppIcon /> Open in Poddle
                </a>
              )}
              <Link className="btn" to={showPath(episode.podcast._id)}>More from this show</Link>
            </div>
          </div>
        </div>

        {episode.audioUrl ? (
          <div className="np-card">
            {startAt !== null && <p className="starts">Starts at {clock(startAt)}</p>}
            <Player
              ref={player}
              src={episode.audioUrl}
              type={episode.audioType}
              title={episode.title}
              show={episode.podcast.title}
              artwork={art}
              startAt={startAt}
              duration={episode.duration}
              onCopyLink={copyAt}
            />
          </div>
        ) : (
          <p className="notice">This episode isn't in the feed any more, so there's nothing to play.</p>
        )}

        <section className="notes-wrap">
          <h2>Show notes</h2>
          {episode.showNotesHtml || episode.summary ? (
            <ShowNotes html={episode.showNotesHtml ?? episode.summary ?? ""} duration={episode.duration} onSeek={episode.audioUrl ? seek : undefined} />
          ) : (
            <p className="muted">No show notes for this one.</p>
          )}
        </section>
      </article>
      {copied && <div className="toast" role="status">{copied}</div>}
    </Layout>
  );
}
