import {
  CaretDown,
  ChartBar,
  CheckCircle,
  ClockCounterClockwise,
  DownloadSimple,
  GithubLogo,
  Headphones,
  MagnifyingGlass,
  Play,
  ShieldCheck,
  SlidersHorizontal,
  Waveform,
} from "@phosphor-icons/react/ssr";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { AppStoreBadge } from "../components/AppStoreBadge";
import { Corners } from "../components/Layout";
import {
  APP_STORE_LIVE,
  APP_STORE_URL,
  CONTACT_EMAIL,
  GITHUB_URL,
  PROMO_VIDEO_ID,
  PROMO_VIDEO_TITLE,
  SITE_URL,
} from "../lib/links";
import { Link } from "../lib/router";

// The home page, rebuilt as an experiment that follows the landing-page-design skill
// (elayadesign/ai-design-skills @ 5e57840) as its only brief. Notes on what was applied
// and bent live outside the repo, next to the before and after screenshots.
//
// It takes everything as props and uses no context hooks (only local state and effects),
// so the build can still render it to static HTML (lib/prerender.tsx). HomePage.tsx wires
// it to the session.
//
// Values follow the skill's tokens: Tailwind's type scale only, spacing only from
// 0/2/4/8/12/16/24/32/40/48/64/80/96px (Tailwind 0, 0.5, 1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24),
// Tailwind radii with the nested radius formula, flat backgrounds, and one motion curve
// (`ease-base`, cubic-bezier(0.22, 1, 0.36, 1)).

/** A screenshot from designs/build-shots, made 600px wide (public/screens). */
type Shot = { src: string; alt: string; caption: string };

const SHOT = { width: 600, height: 1304 };

const shots = {
  upNext: { src: "/screens/up-next.webp", caption: "Up Next", alt: "Poddle's Up Next queue, with the speed each episode plays at and the time left" },
  nowPlaying: { src: "/screens/now-playing.webp", caption: "Now Playing", alt: "Now Playing, with the show's artwork, the current chapter and the play controls" },
  speed: { src: "/screens/speed.webp", caption: "Speed", alt: "The playback speed dial at 1.40x for just this show, with Poodle Trim and Even Volume switched on" },
  podcast: { src: "/screens/podcast.webp", caption: "A show", alt: "A show's page with its newest episodes and its settings" },
  showSettings: { src: "/screens/show-settings.webp", caption: "Settings for a show", alt: "Settings for one show: its own speed, Even Volume off and the first 45 seconds skipped" },
  discover: { src: "/screens/discover.webp", caption: "Discover", alt: "Searching Apple Podcasts in Discover, with a button to add a feed by its URL" },
  stats: { src: "/screens/stats.webp", caption: "Stats", alt: "Stats: 612 hours listened this year, 148 hours saved, a 41 day streak and when you listen" },
  yearInReview: { src: "/screens/year-in-review.webp", caption: "Year in Review", alt: "A Year in Review receipt saying Mike listened for 612 hours, ready to share" },
} satisfies Record<string, Shot>;

const gallery: Shot[] = [
  shots.upNext, shots.nowPlaying, shots.speed, shots.podcast, shots.showSettings,
  shots.discover, shots.stats, shots.yearInReview,
];

/** Every transition on the page: the skill's base curve, never a browser default. */
const MOTION = "transition duration-300 ease-base";
/** Hover, active and focus for anything you can press (skill B9). */
const PRESSABLE = `${MOTION} active:scale-98 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-tomato`;

const NAV = [
  { id: "features", label: "Features" },
  { id: "how", label: "How it works" },
  { id: "faq", label: "FAQ" },
] as const;

// ---------------------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------------------

/**
 * A screenshot in a phone. The frame is rounded-4xl (32px) with 8px of padding, so by the
 * skill's nested radius formula the screen inside is 32 − 8 = 24px, rounded-3xl.
 */
function Phone({ shot, hero = false, first = false, className = "" }: { shot: Shot; hero?: boolean; first?: boolean; className?: string }) {
  return (
    <div className={`shrink-0 rounded-4xl bg-frame p-2 shadow-xl shadow-ink/20 ${className}`}>
      <img
        className="block h-auto w-full rounded-3xl bg-paper-2"
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

/** A section that rises and fades in once as it scrolls into view (skill B7). */
function Section({ id, label, labelledBy, className = "", children }: { id?: string; label?: string; labelledBy?: string; className?: string; children: ReactNode }) {
  return (
    <section id={id} aria-label={label} aria-labelledby={labelledBy} className={`reveal mx-auto w-full max-w-6xl scroll-mt-24 px-6 ${className}`}>
      {children}
    </section>
  );
}

function SectionHeading({ id, children, sub }: { id: string; children: ReactNode; sub?: ReactNode }) {
  return (
    <div className="mx-auto max-w-[680px] text-center">
      <h2 id={id} className="text-3xl font-semibold text-balance text-ink md:text-4xl">{children}</h2>
      {sub && <p className="mt-4 text-lg text-pretty text-body">{sub}</p>}
    </div>
  );
}

/** Watches the page's .reveal sections and the nav's sections, without a scroll listener. */
function useReveals(setActive: (id: string | null) => void) {
  useEffect(() => {
    const root = document.documentElement;
    root.classList.add("reveal-ready");
    const reveal = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue;
          e.target.classList.add("is-in");
          reveal.unobserve(e.target); // once, never replayed on the way back up
        }
      },
      { threshold: 0.12 },
    );
    document.querySelectorAll(".reveal").forEach((el) => reveal.observe(el));

    // Which section is under the middle of the screen, for the nav's current item.
    const spy = new IntersectionObserver(
      (entries) => {
        for (const e of entries) if (e.isIntersecting) setActive(e.target.id);
      },
      { rootMargin: "-45% 0px -50% 0px" },
    );
    const sections = ["top", ...NAV.map((n) => n.id)].map((id) => document.getElementById(id)).filter(Boolean) as Element[];
    sections.forEach((el) => spy.observe(el));
    return () => {
      reveal.disconnect();
      spy.disconnect();
      root.classList.remove("reveal-ready");
    };
  }, [setActive]);
}

// ---------------------------------------------------------------------------------------
// Navigation (skill B7 "Navigation")
// ---------------------------------------------------------------------------------------

function Nav({ signedIn, active }: { signedIn: boolean; active: string | null }) {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("keydown", onKey);
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = "";
    };
  }, [open]);

  const account = signedIn ? "Dashboard" : "Sign in";

  return (
    <header>
      <Corners />
      {/* A compact bar that floats off the top edge, centred and sized to its content, on a
          translucent blurred surface. The bar is rounded-2xl (16px) with 8px padding, so its
          pills are 16 − 8 = 8px, rounded-lg. */}
      <nav
        aria-label="Poddle"
        className="fixed top-4 left-1/2 z-50 flex -translate-x-1/2 items-center gap-2 rounded-2xl border border-ink/10 bg-card/70 p-2 shadow-lg shadow-ink/5 backdrop-blur-md"
      >
        <a href="#top" aria-current="page" className={`flex items-center gap-2 rounded-lg px-2 py-1 text-ink no-underline hover:bg-ink/5 ${PRESSABLE}`}>
          <img src="/icon.png" alt="" width={28} height={28} className="rounded-lg" />
          <span className="text-base font-semibold">Poddle</span>
        </a>
        <ul className="hidden list-none items-center gap-1 md:flex">
          {NAV.map((n) => (
            <li key={n.id}>
              <a
                href={`#${n.id}`}
                aria-current={active === n.id ? "location" : undefined}
                className={`block rounded-lg px-3 py-2 text-sm font-medium no-underline ${PRESSABLE} ${active === n.id ? "bg-ink/10 text-ink" : "text-ink-2 hover:bg-ink/5 hover:text-ink"}`}
              >
                {n.label}
              </a>
            </li>
          ))}
        </ul>
        <Link to="/me" className={`hidden rounded-lg bg-ink px-3 py-2 text-sm font-semibold text-card no-underline hover:bg-ink/85 md:block ${PRESSABLE}`}>
          {account}
        </Link>
        {/* The menu toggle: two lines that turn into a cross rather than swapping icons. */}
        <button
          type="button"
          className={`relative size-10 rounded-lg hover:bg-ink/5 md:hidden ${PRESSABLE}`}
          aria-expanded={open}
          aria-controls="menu"
          aria-label={open ? "Close the menu" : "Open the menu"}
          onClick={() => setOpen((o) => !o)}
        >
          <span aria-hidden className={`absolute top-1/2 left-3 h-0.5 w-4 rounded-full bg-ink transition duration-500 ease-base ${open ? "rotate-45" : "-translate-y-1"}`} />
          <span aria-hidden className={`absolute top-1/2 left-3 h-0.5 w-4 rounded-full bg-ink transition duration-500 ease-base ${open ? "-rotate-45" : "translate-y-1"}`} />
        </button>
      </nav>

      {/* The mobile menu: a full height panel on the page's own surface, nearly opaque and
          heavily blurred. Links step in 60ms apart, capped so the whole run stays under 400ms. */}
      <div
        id="menu"
        className={`fixed inset-0 z-40 flex flex-col bg-paper/95 px-6 pt-24 backdrop-blur-xl transition duration-500 ease-base md:hidden ${open ? "opacity-100" : "pointer-events-none opacity-0"}`}
        aria-hidden={!open}
        inert={!open}
      >
        <ul className="flex list-none flex-col gap-2">
          {[...NAV.map((n) => ({ key: n.id, label: n.label, href: `#${n.id}` })), { key: "me", label: account, href: "/me" }].map((item, i) => (
            <li
              key={item.key}
              className={`transition duration-500 ease-base ${open ? "translate-y-0 opacity-100" : "translate-y-6 opacity-0"}`}
              style={{ transitionDelay: open ? `${Math.min(i * 60, 400)}ms` : "0ms" }}
            >
              {item.href.startsWith("#") ? (
                <a href={item.href} onClick={() => setOpen(false)} className={`block rounded-xl py-3 text-3xl font-semibold text-ink no-underline ${PRESSABLE}`}>
                  {item.label}
                </a>
              ) : (
                <Link to={item.href} className={`block rounded-xl py-3 text-3xl font-semibold text-tomato-d no-underline ${PRESSABLE}`}>
                  {item.label}
                </Link>
              )}
            </li>
          ))}
        </ul>
      </div>
    </header>
  );
}

// ---------------------------------------------------------------------------------------
// 1. Hero
// ---------------------------------------------------------------------------------------

function Hero({ deleted }: { deleted: boolean }) {
  return (
    <section id="top" className="hero mx-auto grid w-full max-w-6xl scroll-mt-24 items-center gap-12 px-6 pt-24 pb-16 lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)]">
      <div className="mx-auto max-w-[680px] text-center lg:mx-0 lg:text-left">
        {/* Light theme hero heading: a left to right #000 → #666 gradient on the text only
            (skill B5). pb-2 keeps the descenders inside the clipped background. */}
        <h1 className="bg-linear-to-r from-black to-[#666666] bg-clip-text pb-2 text-3xl font-semibold tracking-tight text-balance text-transparent sm:text-5xl">
          {/* Broken where the thought breaks (skill B5): the outcome, then the pain it avoids. */}
          Podcasts at{"\u00a0"}2x <br />
          without the chipmunks
        </h1>
        <p className="mt-6 text-lg text-pretty text-body">
          Poddle is a free podcast player for iPhone, made for people who listen a lot. I built it for my own
          listening: one Up Next queue, playback that stays natural at 2x, and settings for every show.
        </p>

        {deleted && (
          <div role="status" className="mt-8 flex items-start gap-3 rounded-2xl border border-ink/10 bg-card p-4 text-left">
            <CheckCircle size={24} weight="duotone" className="shrink-0 text-tomato-d" />
            <p className="text-sm text-body">
              <b className="block text-base font-semibold text-ink">Your account is deleted</b>
              You're signed out, and the rest of your data is being removed now. Thanks for giving Poddle a go.
            </p>
          </div>
        )}

        <div className="mt-8 flex flex-col items-center gap-4 lg:items-start">
          <AppStoreBadge />
          {/* The proof signal. Poddle isn't out yet, so there are no reviews, ratings or user
              counts to show. These two are true; a real testimonial or the App Store rating
              belongs here after launch. */}
          <ul className="flex list-none flex-wrap justify-center gap-x-6 gap-y-2 text-sm text-ink-2 lg:justify-start">
            <li className="flex items-center gap-2">
              <ShieldCheck size={20} weight="duotone" className="text-tomato-d" />
              Free, with no ads or tracking
            </li>
            <li className="flex items-center gap-2">
              <GithubLogo size={20} weight="duotone" className="text-tomato-d" />
              <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className={`rounded-sm text-ink-2 underline decoration-ink/20 underline-offset-4 hover:text-ink hover:decoration-ink ${PRESSABLE}`}>
                The code is open on GitHub
              </a>
            </li>
          </ul>
        </div>
      </div>

      {/* The hero's picture: Up Next behind Now Playing, on a flat disc rather than the old glow. */}
      <div className="relative flex items-center justify-center py-6">
        <div aria-hidden className="absolute size-80 rounded-full bg-paper-2 sm:size-96" />
        <Phone shot={shots.upNext} hero className="relative w-44 translate-x-8 translate-y-6 -rotate-6 sm:w-56" />
        <Phone shot={shots.nowPlaying} hero first className="relative z-10 -ml-16 w-48 rotate-3 sm:w-60" />
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------------------
// 2. Problem to solution (plus the 35 second video)
// ---------------------------------------------------------------------------------------

/**
 * The promo video, unlisted on Mike's YouTube channel. A still with a play button until it's
 * clicked, so the page stays fast and YouTube sets no cookies until then. While the player
 * loads, a skeleton the shape of the video stands in. Without JavaScript it's a plain link.
 */
function PromoVideo() {
  const [playing, setPlaying] = useState(false);
  const [loaded, setLoaded] = useState(false);
  // The frame is rounded-3xl (24px); the video fills it edge to edge, clipped by overflow.
  return (
    <div className="relative mt-12 aspect-video overflow-hidden rounded-3xl border border-ink/10 bg-card">
      {playing ? (
        <>
          {!loaded && <div aria-hidden className="skeleton absolute inset-0 bg-paper-2" />}
          <iframe
            className="absolute inset-0 size-full border-0"
            src={`https://www.youtube-nocookie.com/embed/${PROMO_VIDEO_ID}?autoplay=1&rel=0`}
            title={PROMO_VIDEO_TITLE}
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            referrerPolicy="strict-origin-when-cross-origin"
            allowFullScreen
            onLoad={() => setLoaded(true)}
          />
        </>
      ) : (
        <a
          className={`group absolute inset-0 block ${MOTION} focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-tomato`}
          href={`https://youtu.be/${PROMO_VIDEO_ID}`}
          aria-label={`Play the video: ${PROMO_VIDEO_TITLE}`}
          onClick={(e) => {
            e.preventDefault();
            setPlaying(true);
          }}
        >
          <img className="size-full object-cover" src="/promo-poster.webp" alt="" width={1280} height={720} loading="lazy" decoding="async" />
          <span aria-hidden className={`absolute top-1/2 left-1/2 flex size-16 -translate-1/2 items-center justify-center rounded-full bg-tomato text-card shadow-lg shadow-tomato/30 group-hover:scale-110 group-active:scale-98 sm:size-20 ${MOTION}`}>
            <Play size={32} weight="fill" className="translate-x-0.5" />
          </span>
        </a>
      )}
    </div>
  );
}

function Problem() {
  return (
    <Section labelledBy="problem-title" className="pt-16 md:pt-24">
      <SectionHeading
        id="problem-title"
        sub={
          <>
            Turn a show up to 2x and the hosts start to squeak. Quiet guests vanish under loud ads, and the speed
            that suits a news update is wrong for a slow interview. Poddle fixes each of those, and remembers what
            you picked for every show.
          </>
        }
      >
        Fast playback usually sounds rushed
      </SectionHeading>
      <div className="mx-auto max-w-4xl">
        <PromoVideo />
        <p className="mt-4 text-center text-sm text-ink-2">The 35 second tour, with the poodle.</p>
      </div>
    </Section>
  );
}

// ---------------------------------------------------------------------------------------
// 3. Benefits
// ---------------------------------------------------------------------------------------

type Benefit = { icon: ReactNode; title: string; body: string; media: ReactNode; tint: string };

const benefits: Benefit[] = [
  {
    icon: <Waveform size={24} weight="duotone" />,
    title: "Listen at 2x and still hear people",
    body: "Faster playback is tuned for voices, so even at 2x the host sounds like the host. Poodle Trim snips the little gaps between words, and Even Volume levels out quiet hosts and loud ads.",
    media: <Phone shot={shots.speed} className="w-56 sm:w-60" />,
    tint: "bg-[#F6DCCD]",
  },
  {
    icon: <SlidersHorizontal size={24} weight="duotone" />,
    title: "Set each show once, then forget it",
    body: "Every show can have its own speed, Poodle Trim and Even Volume, skip its intro and outro, and send new episodes to the top or bottom of Up Next, or nowhere at all.",
    media: <Phone shot={shots.showSettings} className="w-56 sm:w-60" />,
    tint: "bg-gold-bg",
  },
  {
    icon: <ClockCounterClockwise size={24} weight="duotone" />,
    title: "Keep every hour you've already listened",
    body: "Import your shows, what you've played, where you're up to, your starred episodes and your whole listening history, so your stats start with everything you've heard.",
    media: <Phone shot={shots.podcast} className="w-56 sm:w-60" />,
    tint: "bg-paper-2",
  },
  {
    icon: <ChartBar size={24} weight="duotone" />,
    title: "See how much you really listen",
    body: "How long you've listened, how much time faster playback and Poodle Trim saved, your top shows and your streaks. At the end of the year there's a Year in Review to share.",
    media: (
      <div className="flex items-start gap-4">
        <Phone shot={shots.stats} className="w-40 sm:w-48" />
        <Phone shot={shots.yearInReview} className="mt-6 w-40 sm:w-48" />
      </div>
    ),
    tint: "bg-[#F6DCCD]",
  },
];

function Benefits() {
  return (
    <Section id="features" labelledBy="features-title" className="pt-24 md:pt-24">
      <SectionHeading id="features-title" sub="Four things it does differently, each one shown in the real app.">
        Made for people who listen every day
      </SectionHeading>
      <div className="mt-12 flex flex-col gap-6">
        {benefits.map((b, i) => (
          // Cards are rounded-3xl (24px). The picture panel sits flush against the card's edge
          // (no gap), so it's simply clipped by the card rather than given its own radius.
          <article key={b.title} className="grid overflow-hidden rounded-3xl border border-ink/10 bg-card md:grid-cols-2">
            <div className={`flex flex-col justify-center p-8 md:p-12 ${i % 2 ? "md:order-2" : ""}`}>
              {/* Icon tile: rounded-xl (12px). Not nested inside a padded shape under 32px, so no formula. */}
              <span className="flex size-12 items-center justify-center rounded-xl bg-tomato/10 text-tomato-d">{b.icon}</span>
              <h3 className="mt-6 text-2xl font-semibold text-balance text-ink">{b.title}</h3>
              <p className="mt-3 max-w-md text-base text-pretty text-body">{b.body}</p>
            </div>
            <div className={`flex items-center justify-center px-6 py-10 ${b.tint}`}>{b.media}</div>
          </article>
        ))}
      </div>
    </Section>
  );
}

// ---------------------------------------------------------------------------------------
// The tagline reveal (skill B11, mandatory)
// ---------------------------------------------------------------------------------------

// Lines, then phrases within each line. A narrow screen may wrap a line, but only between
// phrases, so it never splits "at its own speed" (skill B5 and B11: break where the thought breaks).
const TAGLINE = [
  ["Every show", "at its own speed."],
  ["One queue", "for all of them."],
  ["Voices that still", "sound like people."],
];

/**
 * Large type, separate from the hero. Each word starts at 30% and lights up in reading
 * order as the section rises past a line 80% of the way down the screen. One scroll listener,
 * throttled through requestAnimationFrame, and it only ever moves forward so the words stay lit.
 */
function TaglineReveal() {
  const ref = useRef<HTMLParagraphElement>(null);
  const total = TAGLINE.flat().join(" ").split(" ").length;
  const [lit, setLit] = useState(0);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let frame = 0;
    const measure = () => {
      frame = 0;
      const r = el.getBoundingClientRect();
      const trigger = window.innerHeight * 0.8;
      // 0 when the top of the text reaches the trigger line, 1 once its bottom has passed
      // a little above it, so the last word lights up while it's still well on screen.
      const progress = (trigger - r.top) / (r.height + window.innerHeight * 0.25);
      const count = Math.max(0, Math.min(total, Math.ceil(progress * total)));
      setLit((prev) => Math.max(prev, count));
      if (count >= total) window.removeEventListener("scroll", onScroll);
    };
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    measure();
    return () => {
      window.removeEventListener("scroll", onScroll);
      cancelAnimationFrame(frame);
    };
  }, [total]);

  let n = 0;
  return (
    <section aria-label="What Poddle is for" className="mx-auto w-full max-w-6xl px-6 py-24 md:py-24">
      <p ref={ref} className="mx-auto max-w-[680px] text-center text-4xl font-semibold text-balance text-ink">
        {TAGLINE.map((line, li) => (
          <span key={li} className="block">
            {line.map((phrase, pi) => (
              <span key={pi} className="whitespace-nowrap">
                {phrase.split(" ").map((word, wi, all) => {
                  const index = n++;
                  return (
                    <span key={wi} className={`tw ${index < lit ? "on" : ""}`}>
                      {word}
                      {wi < all.length - 1 ? " " : ""}
                    </span>
                  );
                })}
                {pi < line.length - 1 ? " " : ""}
              </span>
            ))}
          </span>
        ))}
      </p>
    </section>
  );
}

// ---------------------------------------------------------------------------------------
// 4. How it works
// ---------------------------------------------------------------------------------------

const steps = [
  {
    icon: <DownloadSimple size={24} weight="duotone" />,
    title: "Get Poddle and sign in",
    body: "Install it on your iPhone and sign in with Apple or Google, so your library and stats are kept safe.",
  },
  {
    icon: <MagnifyingGlass size={24} weight="duotone" />,
    title: "Bring your shows",
    body: "Import everything from Overcast, search Apple Podcasts in Discover, or paste a feed's address.",
  },
  {
    icon: <Headphones size={24} weight="duotone" />,
    title: "Press play",
    body: "New episodes land in Up Next by each show's rule, at each show's speed. You just listen.",
  },
];

function HowItWorks() {
  return (
    <Section id="how" labelledBy="how-title" className="pt-16">
      <SectionHeading id="how-title" sub="From the App Store to your first episode in about a minute.">
        How it works
      </SectionHeading>
      <ol className="mt-12 grid list-none gap-6 md:grid-cols-3">
        {steps.map((s, i) => (
          <li key={s.title} className="rounded-3xl border border-ink/10 bg-card p-8">
            <span className="flex size-12 items-center justify-center rounded-xl bg-tomato/10 text-tomato-d">{s.icon}</span>
            <h3 className="mt-6 text-xl font-semibold text-ink">
              <span className="text-ink-2">{i + 1}.</span> {s.title}
            </h3>
            <p className="mt-2 text-base text-pretty text-body">{s.body}</p>
          </li>
        ))}
      </ol>
    </Section>
  );
}

// ---------------------------------------------------------------------------------------
// 5. Proof
// ---------------------------------------------------------------------------------------

/**
 * The skill wants testimonials or a case study here. Poddle isn't out, so there are none,
 * and inventing them isn't on. What's true instead: every screen of the real app, and the
 * code, which anyone can read. GAP: real quotes or the App Store rating go here after launch.
 */
function Proof() {
  return (
    <Section labelledBy="proof-title" className="pt-24">
      <SectionHeading id="proof-title" sub="Screens from the app itself. Scroll sideways to see them all.">
        Have a look around
      </SectionHeading>
      <ul className="-mx-6 mt-12 flex list-none snap-x snap-mandatory gap-6 overflow-x-auto px-6 pb-6">
        {gallery.map((shot) => (
          <li key={shot.src} className="shrink-0 snap-center">
            <figure className="flex flex-col items-center gap-4">
              <Phone shot={shot} className="w-48" />
              <figcaption className="text-sm font-medium text-ink-2">{shot.caption}</figcaption>
            </figure>
          </li>
        ))}
      </ul>
      <div className="mx-auto mt-8 flex max-w-[680px] flex-col items-center gap-4 rounded-3xl border border-ink/10 bg-card p-8 text-center sm:flex-row sm:text-left">
        <span className="flex size-12 shrink-0 items-center justify-center rounded-xl bg-ink text-card">
          <GithubLogo size={24} weight="fill" />
        </span>
        <p className="text-base text-pretty text-body">
          <b className="font-semibold text-ink">Nothing hidden.</b> Poddle's app, website and backend are all on GitHub,
          so you can check exactly what it does with your listening.{" "}
          <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className={`rounded-sm font-semibold text-tomato-d underline underline-offset-4 hover:text-ink ${PRESSABLE}`}>
            Read the code
          </a>
        </p>
      </div>
    </Section>
  );
}

// ---------------------------------------------------------------------------------------
// 6. FAQ
// ---------------------------------------------------------------------------------------

const faq: { q: string; a: ReactNode; text: string }[] = [
  {
    q: "How much does Poddle cost?",
    text: "Nothing. Poddle is free, with no ads, no subscription and no tracking.",
    a: "Nothing. Poddle is free, with no ads, no subscription and no tracking.",
  },
  {
    q: "When can I get it?",
    text: "Soon. Poddle is on its way to the App Store, and the badge on this page becomes a download link the day it's out.",
    a: "Soon. Poddle is on its way to the App Store, and the badge on this page becomes a download link the day it's out.",
  },
  {
    q: "Which devices does it run on?",
    text: "iPhone, on iOS 18 or later. iPad and Mac versions are planned but aren't out yet.",
    a: "iPhone, on iOS 18 or later. iPad and Mac versions are planned but aren't out yet.",
  },
  {
    q: "Can I bring my shows and history from Overcast?",
    text: "Yes. Download the \"All data\" export from your Overcast account and import it from Profile. Poddle brings over your shows, what you've played, where you're up to, your starred episodes and your listening history. Coming from Apple Podcasts, search for your shows in Discover or paste a feed's address.",
    a: (
      <>
        Yes. Download the "All data" export from your Overcast account and import it from Profile. Poddle brings over
        your shows, what you've played, where you're up to, your starred episodes and your listening history. Coming
        from Apple Podcasts, search for your shows in Discover or paste a feed's address.
      </>
    ),
  },
  {
    q: "Will it eat my mobile data?",
    text: "Not unless you let it. Downloads wait for WiFi. When you're out and want something now, you can allow mobile downloads for an hour, three hours or until tomorrow, and it goes back to WiFi only by itself.",
    a: "Not unless you let it. Downloads wait for WiFi. When you're out and want something now, you can allow mobile downloads for an hour, three hours or until tomorrow, and it goes back to WiFi only by itself.",
  },
  {
    q: "Can I share an episode with someone who doesn't have Poddle?",
    text: "Yes. They get a page that plays it right in their browser, starting from the moment you picked. If they have Poddle, it opens in the app instead.",
    a: "Yes. They get a page that plays it right in their browser, starting from the moment you picked. If they have Poddle, it opens in the app instead.",
  },
  {
    q: "Why do I need an account?",
    text: "You sign in with Apple or Google so your library, queue and stats are kept safe and show up on the website too. You can delete your account from inside the app whenever you like.",
    a: "You sign in with Apple or Google so your library, queue and stats are kept safe and show up on the website too. You can delete your account from inside the app whenever you like.",
  },
  {
    q: "What's with the poodle?",
    text: "Poddle sounds a bit like poodle, so a fluffy cartoon poodle in headphones keeps you company round the app. If it gets a bit much, you can turn its animations off in Profile.",
    a: "Poddle sounds a bit like poodle, so a fluffy cartoon poodle in headphones keeps you company round the app. If it gets a bit much, you can turn its animations off in Profile.",
  },
  {
    q: "Who makes it?",
    text: `Mike Cann, for his own listening. Found a bug or have an idea? Email ${CONTACT_EMAIL} or tap "Suggest a feature" in the app.`,
    a: (
      <>
        Mike Cann, for his own listening. Found a bug or have an idea? Email{" "}
        <a href={`mailto:${CONTACT_EMAIL}`} className={`rounded-sm font-medium text-tomato-d underline underline-offset-4 hover:text-ink ${PRESSABLE}`}>
          {CONTACT_EMAIL}
        </a>{" "}
        or tap "Suggest a feature" in the app.
      </>
    ),
  },
];

function Faq() {
  return (
    <Section id="faq" labelledBy="faq-title" className="pt-24">
      <SectionHeading id="faq-title">Questions people ask</SectionHeading>
      {/* The list is rounded-3xl (24px) with 8px padding, so each row inside is 24 − 8 = 16px, rounded-2xl. */}
      <div className="mx-auto mt-12 flex max-w-3xl flex-col gap-2 rounded-3xl border border-ink/10 bg-card p-2">
        {faq.map((item) => (
          <details key={item.q} className="group rounded-2xl open:bg-paper">
            <summary className={`flex cursor-pointer list-none items-center justify-between gap-4 rounded-2xl px-6 py-4 text-base font-semibold text-ink hover:bg-paper [&::-webkit-details-marker]:hidden ${MOTION} focus-visible:outline-2 focus-visible:outline-tomato`}>
              <span className="text-balance">{item.q}</span>
              <CaretDown size={20} weight="bold" className="shrink-0 text-ink-2 transition duration-500 ease-base group-open:rotate-180" />
            </summary>
            <p className="px-6 pb-6 text-base text-pretty text-body">{item.a}</p>
          </details>
        ))}
      </div>
    </Section>
  );
}

// ---------------------------------------------------------------------------------------
// 7. Risk reversal and the final CTA
// ---------------------------------------------------------------------------------------

function FinalCta() {
  return (
    <Section labelledBy="closing-title" className="pt-24 pb-16">
      <div className="flex flex-col items-center rounded-3xl bg-ink px-6 py-16 text-center md:py-20">
        <img src="/mascots/waving.png" alt="Poddle's mascot, a fluffy cartoon poodle in red headphones, waving" width={176} height={200} loading="lazy" decoding="async" className="h-auto w-24" />
        <h2 id="closing-title" className="mt-6 max-w-[680px] text-3xl font-semibold text-balance text-card md:text-4xl">
          Podcasts at{"\u00a0"}2x <br />
          without the chipmunks
        </h2>
        <p className="mt-4 max-w-xl text-lg text-pretty text-card/70">
          Free on iPhone. iPad and Mac are planned for later.
        </p>
        <div className="mt-8">
          <AppStoreBadge />
        </div>
        {/* Risk reversal (skill A4): all three are true of Poddle today. */}
        <ul className="mt-8 flex list-none flex-wrap justify-center gap-x-6 gap-y-2 text-sm text-card/70">
          <li className="flex items-center gap-2"><CheckCircle size={20} weight="duotone" className="text-tomato" />Free, no subscription</li>
          <li className="flex items-center gap-2"><CheckCircle size={20} weight="duotone" className="text-tomato" />No ads or tracking</li>
          <li className="flex items-center gap-2"><CheckCircle size={20} weight="duotone" className="text-tomato" />Delete your account any time</li>
        </ul>
      </div>
    </Section>
  );
}

function Footer() {
  const link = `rounded-sm text-ink-2 no-underline hover:text-ink ${PRESSABLE}`;
  return (
    <footer className="mx-auto flex w-full max-w-6xl flex-col items-center justify-between gap-4 px-6 pt-8 pb-12 text-sm text-ink-2 sm:flex-row">
      <span>Poddle is made by Mike Cann.</span>
      <nav aria-label="About Poddle" className="flex flex-wrap justify-center gap-x-6 gap-y-2">
        <Link to="/support" className={link}>Support</Link>
        <Link to="/privacy" className={link}>Privacy</Link>
        {/* GAP: the skill wants a terms link here too. Poddle has no terms page yet. */}
        <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className={link}>GitHub</a>
        <a href={`mailto:${CONTACT_EMAIL}`} className={link}>{CONTACT_EMAIL}</a>
      </nav>
    </footer>
  );
}

// ---------------------------------------------------------------------------------------
// Structured data
// ---------------------------------------------------------------------------------------

/** schema.org data for the app, the video and the FAQ (skill A7, FAQ schema for AEO). */
function StructuredData() {
  const app = {
    "@context": "https://schema.org",
    "@type": "MobileApplication",
    name: "Poddle",
    description: "A free podcast player for iPhone that Mike Cann made for himself, with faster playback that still sounds like people talking, settings for each show, importing your listening history and listening stats.",
    operatingSystem: "iOS 18.0 or later",
    applicationCategory: "MultimediaApplication",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    url: `${SITE_URL}/`,
    image: `${SITE_URL}/icon-512.png`,
    screenshot: gallery.map((s) => `${SITE_URL}${s.src}`),
    author: { "@type": "Person", name: "Mike Cann" },
    ...(APP_STORE_LIVE ? { downloadUrl: APP_STORE_URL, installUrl: APP_STORE_URL } : {}),
  };
  const video = {
    "@context": "https://schema.org",
    "@type": "VideoObject",
    name: PROMO_VIDEO_TITLE,
    description: "Poddle's poodle shows you round the app: faster playback, settings for each show, importing your history and your listening stats.",
    thumbnailUrl: `${SITE_URL}/promo-poster.webp`,
    uploadDate: "2026-10-23",
    duration: "PT35S",
    embedUrl: `https://www.youtube.com/embed/${PROMO_VIDEO_ID}`,
  };
  const questions = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: faq.map((f) => ({ "@type": "Question", name: f.q, acceptedAnswer: { "@type": "Answer", text: f.text } })),
  };
  const json = JSON.stringify([app, video, questions]).replace(/</g, "\\u003c");
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: json }} />;
}

// ---------------------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------------------

export function Landing({ signedIn, deleted = false }: { signedIn: boolean; deleted?: boolean }) {
  const [active, setActive] = useState<string | null>(null);
  useReveals(setActive);
  return (
    <div className="landing-v2 relative flex flex-1 flex-col bg-paper font-sans text-ink">
      <a href="#main" className="fixed top-4 left-4 z-[60] -translate-y-24 rounded-lg bg-ink px-3 py-2 text-sm font-semibold text-card no-underline focus:translate-y-0 transition duration-300 ease-base">
        Skip to content
      </a>
      <Nav signedIn={signedIn} active={active} />
      <main id="main" className="flex-1">
        <Hero deleted={deleted} />
        <Problem />
        <Benefits />
        <TaglineReveal />
        <HowItWorks />
        <Proof />
        <Faq />
        <FinalCta />
      </main>
      <Footer />
      <StructuredData />
    </div>
  );
}
