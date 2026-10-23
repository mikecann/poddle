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
    description: "A podcast player for iPhone that Mike Cann made to replace Overcast, with speed-ups that still sound like people talking, settings for each show, the full Overcast import and listening stats.",
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
            <h1>A podcast player I made for myself</h1>
            <p className="lede">
              I used Overcast for years and Poddle is what I made to replace it. It's got one Up Next queue, speed-ups
              that still sound like people talking, settings for each show and stats on how much I actually listen (a
              lot, it turns out). Hopefully you like it too!
            </p>
            {deleted && (
              <div className="notice" role="status">
                <b>Your account's deleted</b>
                You're signed out, and the rest of your data is being removed now. Thanks for giving Poddle a go.
              </div>
            )}
            <div className="hero-cta">
              <AppStoreBadge />
              <p className="muted">It's free, and there's no ads or tracking.</p>
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
              <h3>Speed-ups without the chipmunks</h3>
              <p>
                The speed-up in Poddle is tuned for voices, so even at 2x it still sounds like the person talking. Smart
                Speed trims the little gaps between words too, and Voice Boost evens out quiet hosts and loud ads.
              </p>
            </div>
            <div className="feature-media"><Phone shot={shots.speed} /></div>
          </article>

          <article className="feature flip">
            <div className="feature-copy">
              <h3>Settings for each show</h3>
              <p>
                Every show can have its own speed, Smart Speed and Voice Boost, skip its intros and outros, and choose
                whether its new episodes go to the top or bottom of Up Next (or don't get added at all). Or you can
                just leave them all on your defaults and forget about it.
              </p>
            </div>
            <div className="feature-media"><Phone shot={shots.showSettings} /></div>
          </article>

          <article className="feature">
            <div className="feature-copy">
              <h3>Bring everything over from Overcast</h3>
              <p>
                If you're coming from Overcast like me, export "All data" from your Overcast account and Poddle brings
                over your shows, what you've played, where you're up to, your starred episodes and your whole
                listening history. So your stats start with everything you've already heard.
              </p>
            </div>
            <div className="feature-media"><Phone shot={shots.importDone} /></div>
          </article>

          <article className="feature flip">
            <div className="feature-copy">
              <h3>Stats, and a Year in Review</h3>
              <p>
                You can see how long you've listened, how much time the speed-ups and Smart Speed have saved you, your
                top shows and your streaks, and then at the end of the year there's a Year in Review you can share.
              </p>
            </div>
            <div className="feature-media pair">
              <Phone shot={shots.stats} />
              <Phone shot={shots.yearInReview} />
            </div>
          </article>

          <div className="bits">
            <article className="bit">
              <h3>Wi-Fi only downloads</h3>
              <p>
                Poddle only downloads on Wi-Fi unless you tell it otherwise. If you're out and want something now you
                can allow mobile downloads for an hour, three hours or until tomorrow, then it goes back to Wi-Fi only
                by itself.
              </p>
            </article>
            <article className="bit">
              <h3>Share links</h3>
              <p>
                When you share an episode or a show your friend gets a page that plays it right there in their browser,
                starting from the bit you meant. If they've got Poddle it opens in the app instead.
              </p>
            </article>
            <article className="bit">
              <h3>No ads or tracking</h3>
              <p>
                You sign in with Apple or Google so your library stays in sync, and if you ever want out you can delete
                your account from inside the app.
              </p>
            </article>
            <article className="bit poodle">
              <img src="/mascots/waving.png" alt="Poddle's mascot, a fluffy cartoon poodle in red headphones, waving" width={176} height={200} loading="lazy" decoding="async" />
              <div>
                <h3>And a poodle</h3>
                <p>
                  Poddle sounds a bit like poodle, so of course there's a fluffy cartoon poodle in headphones keeping you
                  company round the app. If it gets a bit much you can turn the animations off in Profile.
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
            Poddle's free on iPhone and hopefully iPad and Mac won't be too far behind. If you find a bug or have an
            idea for it, drop me an email at <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> or tap "Suggest a
            feature" in the app.
          </p>
          <AppStoreBadge />
        </section>
      </main>
      <SiteFooter />
      <StructuredData />
    </>
  );
}
