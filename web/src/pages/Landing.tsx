import { AppStoreBadge } from "../components/AppStoreBadge";
import { SiteFooter, SiteHeader } from "../components/Layout";
import { APP_STORE_LIVE, APP_STORE_URL, CONTACT_EMAIL, SITE_URL } from "../lib/links";
import { Link } from "../lib/router";

// The home page's content. It takes everything as props and uses no hooks, so
// the build can also render it to static HTML (lib/prerender.tsx) for search
// engines and a fast first paint. HomePage.tsx wires it to the session.

/** A screenshot from designs/build-shots, made 600px wide (public/screens). */
type Shot = { src: string; alt: string; caption: string };

const SHOT = { width: 600, height: 1304 };

const shots = {
  upNext: { src: "/screens/up-next.webp", caption: "Up Next", alt: "Poddle's Up Next queue, with the speed each episode plays at and the time left" },
  nowPlaying: { src: "/screens/now-playing.webp", caption: "Now Playing", alt: "Now Playing, with the show's artwork, the current chapter and the play controls" },
  speed: { src: "/screens/speed.webp", caption: "Speed", alt: "The playback speed dial at 1.40x for just this show, with Smart Speed and Voice Boost switched on" },
  podcast: { src: "/screens/podcast.webp", caption: "A show", alt: "A show's page with its newest episodes and its settings" },
  showSettings: { src: "/screens/show-settings.webp", caption: "Settings for a show", alt: "Settings for one show: its own speed, Voice Boost off and the first 45 seconds skipped" },
  discover: { src: "/screens/discover.webp", caption: "Discover", alt: "Searching Apple Podcasts in Discover, with a button to add a feed by its URL" },
  importDone: { src: "/screens/import-done.webp", caption: "Moving from Overcast", alt: "The Overcast import finished: 84 podcasts, 3,412 played episodes and 1,920 hours brought over" },
  stats: { src: "/screens/stats.webp", caption: "Stats", alt: "Stats: 612 hours listened this year, 148 hours saved, a 41 day streak and when you listen" },
  yearInReview: { src: "/screens/year-in-review.webp", caption: "Year in Review", alt: "A Year in Review receipt saying Mike listened for 612 hours, ready to share" },
} satisfies Record<string, Shot>;

const gallery: Shot[] = [
  shots.upNext, shots.nowPlaying, shots.speed, shots.podcast, shots.showSettings,
  shots.discover, shots.importDone, shots.stats, shots.yearInReview,
];

/** A screenshot in a phone. Only the hero's load straight away; `first` is the one to fetch first. */
function Phone({ shot, hero = false, first = false, className = "" }: { shot: Shot; hero?: boolean; first?: boolean; className?: string }) {
  return (
    <div className={`phone ${className}`}>
      <img
        src={shot.src}
        alt={shot.alt}
        {...SHOT}
        loading={hero ? "eager" : "lazy"}
        decoding="async"
        fetchPriority={first ? "high" : undefined}
      />
    </div>
  );
}

/** schema.org data for the app, so search engines know what Poddle is. */
function StructuredData() {
  const app = {
    "@context": "https://schema.org",
    "@type": "MobileApplication",
    name: "Poddle",
    description: "A podcast player for iPhone with speed-ups that still sound like people, settings for each show, the full Overcast import and listening stats.",
    operatingSystem: "iOS 18.0 or later",
    applicationCategory: "MultimediaApplication",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    url: `${SITE_URL}/`,
    image: `${SITE_URL}/icon-512.png`,
    screenshot: gallery.map((s) => `${SITE_URL}${s.src}`),
    author: { "@type": "Person", name: "Mike Cann" },
    ...(APP_STORE_LIVE ? { downloadUrl: APP_STORE_URL, installUrl: APP_STORE_URL } : {}),
  };
  const json = JSON.stringify(app).replace(/</g, "\\u003c");
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: json }} />;
}

export function Landing({ signedIn, deleted = false }: { signedIn: boolean; deleted?: boolean }) {
  return (
    <>
      <SiteHeader signedIn={signedIn} />
      <main className="landing">
        <section className="hero">
          <div className="hero-copy">
            <img className="hero-icon" src="/icon-192.png" alt="" width={76} height={76} />
            <p className="eyebrow">A podcast player for iPhone</p>
            <h1>Faster podcasts, no chipmunks</h1>
            <p className="lede">
              Poddle is a podcast player I made for myself after years of using Overcast. It has one Up Next queue,
              speed-ups that still sound like people, and stats on how much you actually listen (a lot, in my case).
            </p>
            {deleted && (
              <div className="notice" role="status">
                <b>Your account's deleted</b>
                You're signed out, and the rest of your data is being removed now. Thanks for giving Poddle a go.
              </div>
            )}
            <div className="hero-cta">
              <AppStoreBadge />
              <p className="muted">Free, with no ads and no tracking.</p>
            </div>
            <p className="hero-signin">
              {signedIn ? (
                <Link to="/me">See what you're listening to</Link>
              ) : (
                <>Already using Poddle? <Link to="/me">Sign in on the web</Link></>
              )}
            </p>
          </div>
          {/* The hero's picture. A video can take this box's place later. */}
          <div className="hero-media">
            <Phone shot={shots.upNext} className="back" hero />
            <Phone shot={shots.nowPlaying} className="front" hero first />
          </div>
        </section>

        <section className="features" aria-labelledby="features-title">
          <h2 id="features-title" className="section-title">What it does</h2>

          <article className="feature">
            <div className="feature-copy">
              <h3>Speed without the chipmunks</h3>
              <p>
                Poddle's Speech-tuned speed-up is made for voices, so 2x still sounds like the person talking. Smart
                Speed trims the silences between words, and Voice Boost evens out quiet hosts and loud ads.
              </p>
            </div>
            <div className="feature-media"><Phone shot={shots.speed} /></div>
          </article>

          <article className="feature flip">
            <div className="feature-copy">
              <h3>Settings for each show</h3>
              <p>
                Every show can have its own speed, Smart Speed, Voice Boost, intro and outro skips, and where its new
                episodes go. Or leave them on your defaults and forget about it.
              </p>
            </div>
            <div className="feature-media"><Phone shot={shots.showSettings} /></div>
          </article>

          <article className="feature">
            <div className="feature-copy">
              <h3>Bring everything from Overcast</h3>
              <p>
                Export "All data" from Overcast and Poddle brings over your shows, what you've played, where you're up
                to, your starred episodes and your whole listening history, so your stats start with everything you've
                already heard.
              </p>
            </div>
            <div className="feature-media"><Phone shot={shots.importDone} /></div>
          </article>

          <article className="feature flip">
            <div className="feature-copy">
              <h3>Stats, and a Year in Review</h3>
              <p>
                See how long you've listened, how much time speed and Smart Speed saved you, your top shows and your
                streaks. At the end of the year there's a Year in Review you can share.
              </p>
            </div>
            <div className="feature-media pair">
              <Phone shot={shots.stats} />
              <Phone shot={shots.yearInReview} />
            </div>
          </article>

          <div className="bits">
            <article className="bit">
              <h3>Downloads that look after your data</h3>
              <p>
                Poddle only downloads on Wi-Fi unless you say otherwise. Out and about and want something now? Allow
                mobile downloads for an hour, three hours or until tomorrow, and it goes back to Wi-Fi only by itself.
              </p>
            </article>
            <article className="bit">
              <h3>Share links</h3>
              <p>
                Share an episode or a show and your friend gets a page that plays it in their browser, from the bit you
                meant, or opens it in Poddle if they have it.
              </p>
            </article>
            <article className="bit">
              <h3>No ads and no tracking</h3>
              <p>
                You sign in with Apple or Google so your library stays in sync, and that's about it. If you ever want
                out, you can delete your account from the app.
              </p>
            </article>
            <article className="bit poodle">
              <img src="/mascots/waving.png" alt="Poddle's mascot, a fluffy cartoon poodle in red headphones, waving" width={176} height={200} loading="lazy" decoding="async" />
              <div>
                <h3>And a poodle</h3>
                <p>
                  Poddle sounds like poodle, so there's a fluffy cartoon poodle in headphones who keeps you company round
                  the app. If it's a bit much you can turn the animation off in Profile.
                </p>
              </div>
            </article>
          </div>
        </section>

        <section className="gallery" aria-labelledby="gallery-title">
          <h2 id="gallery-title" className="section-title">Have a look around</h2>
          <ul className="strip">
            {gallery.map((shot) => (
              <li key={shot.src}>
                <figure>
                  <Phone shot={shot} />
                  <figcaption>{shot.caption}</figcaption>
                </figure>
              </li>
            ))}
          </ul>
        </section>

        <section className="closing" aria-labelledby="closing-title">
          <h2 id="closing-title">Give it a go</h2>
          <p className="lede">
            Poddle's free on iPhone, and iPad and Mac will come a bit later. If you find a bug or have an idea, give me a
            shout at <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>.
          </p>
          <AppStoreBadge />
        </section>
      </main>
      <SiteFooter />
      <StructuredData />
    </>
  );
}
