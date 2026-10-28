// The fixture shows the e2e world serves (docs/testing.md). Every feature file
// talks about these by title, so keep the titles stable. Audio is the short tones
// in e2e/fixtures/audio, artwork the swatches in e2e/fixtures/art.

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/**
 * slug → show. `path` is the feed's path on the fixture server (with any query),
 * `episodes` oldest first; `ago` is how long before the world started each one
 * was published. `art` names another show's artwork to borrow (default: its own).
 */
export const SHOWS = {
  morning: {
    title: "Morning Tones",
    author: "Poddle Fixtures",
    genre: "Science",
    appleId: 900001,
    description: "Short sine tones to start the day. A normal show.",
    path: "/feeds/morning.xml",
    episodes: [
      { guid: "morning-1", title: "Sunrise in A", audio: "tone-30s", ago: 3 * DAY },
      { guid: "morning-2", title: "Breakfast in C", audio: "tone-40s", ago: 2 * DAY },
      { guid: "morning-3", title: "Commute in D", audio: "tone-45s", ago: 1 * DAY },
    ],
  },
  pings: {
    title: "Priority Pings",
    author: "Poddle Fixtures",
    genre: "News",
    appleId: 900002,
    description: "Urgent little pings. The show you'd put at the top of Up Next.",
    path: "/feeds/pings.xml",
    episodes: [
      { guid: "pings-1", title: "First Ping", audio: "tone-30s", ago: 4 * DAY },
      { guid: "pings-2", title: "Second Ping", audio: "tone-40s", ago: 2 * DAY + 6 * HOUR },
    ],
  },
  chimes: {
    title: "Chapter Chimes",
    author: "Poddle Fixtures",
    genre: "Music",
    appleId: 900003,
    description: "One long chime with chapters and timestamped show notes.",
    path: "/feeds/chimes.xml",
    episodes: [
      {
        guid: "chimes-1",
        title: "Three Movements",
        audio: "tone-60s",
        ago: 5 * DAY,
        chapters: [
          { startTime: 0, title: "Overture" },
          { startTime: 20, title: "The middle bit" },
          { startTime: 40, title: "Finale" },
        ],
        notes: "<p>Three short movements.</p><ul><li>0:20 The middle bit</li><li>0:40 The finale</li></ul>",
      },
    ],
  },
  evening: {
    title: "Evening Echoes",
    author: "Poddle Fixtures",
    genre: "Arts",
    appleId: 900004,
    description: "Slower tones for the end of the day. The other show in the speed scenarios.",
    path: "/feeds/evening.xml",
    episodes: [
      { guid: "evening-1", title: "Dusk", audio: "tone-45s", ago: 6 * DAY },
      { guid: "evening-2", title: "Twilight", audio: "tone-60s", ago: 1 * DAY + 3 * HOUR },
    ],
  },
  secret: {
    title: "Secret Signals",
    author: "Poddle Fixtures",
    genre: "Technology",
    description: "A private, tokenised feed. It never gets a public page.",
    path: "/feeds/secret.xml?token=fixture-secret-token",
    private: true,
    episodes: [{ guid: "secret-1", title: "Members Only", audio: "tone-30s", ago: 2 * DAY }],
  },
  ...shelf(),
};

/**
 * Seven plain one-episode shows that are only there to make a Library long enough to
 * scroll ("The end of a long Library scrolls clear of the mini player"). They have no
 * `appleId`, so the fake directory never offers them in Discover, and they borrow the
 * other shows' artwork.
 */
function shelf() {
  const titles = ["Kettle Hum", "Lantern Light", "Puddle Jumps", "Quiet Quarry", "Rooftop Rain", "Tidal Tick", "Velvet Valve"];
  const art = ["morning", "pings", "chimes", "evening"];
  return Object.fromEntries(
    titles.map((title, i) => {
      const slug = title.split(" ")[0].toLowerCase();
      return [slug, {
        title,
        author: "Poddle Fixtures",
        genre: "Shelf",
        description: "Filler for a long Library.",
        path: `/feeds/${slug}.xml`,
        art: art[i % art.length],
        episodes: [{ guid: `${slug}-1`, title: `${title} 1`, audio: "tone-30s", ago: (8 + i) * DAY }],
      }];
    }),
  );
}

export const AUDIO_SECONDS = { "tone-30s": 30, "tone-40s": 40, "tone-45s": 45, "tone-60s": 60 };

export function showByTitle(title) {
  const entry = Object.entries(SHOWS).find(([, s]) => s.title === title);
  if (!entry) throw new Error(`No fixture show called "${title}". Known: ${Object.values(SHOWS).map((s) => s.title).join(", ")}`);
  return { slug: entry[0], ...entry[1] };
}
