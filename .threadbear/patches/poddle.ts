// Threadbear patch (Threadbear's docs/protocol.md, "Patches"): Poddle's pages one click away, where
// its App Store versions stand, and its Chef requests. Both panels read production or Apple, so they
// keep the answer for 15 minutes rather than asking on every refresh. On a machine without Mike's
// App Store key the App Store panel just doesn't show.

type Ctx = { sh: (command: string) => Promise<string> };
type Version = { version: string; state: string };
type Request = { number: number; title?: string; description?: string; state: string; changelog?: string; completedAt?: number };

const APP_ID = "6825613455";
const CONNECT = `https://appstoreconnect.apple.com/apps/${APP_ID}/distribution`;
const KEEP_MS = 15 * 60 * 1000;

// One fetch at a time and one answer for 15 minutes, however many functions ask.
function kept<T>(load: (sh: Ctx["sh"]) => Promise<T>) {
  let cached: { at: number; value: T } | undefined;
  let pending: Promise<T> | undefined;
  return (sh: Ctx["sh"]): Promise<T> => {
    if (cached && Date.now() - cached.at < KEEP_MS) return Promise.resolve(cached.value);
    pending ??= load(sh)
      .then((value) => {
        cached = { at: Date.now(), value };
        return value;
      })
      .finally(() => {
        pending = undefined;
      });
    return pending;
  };
}

const versions = kept(async (sh) => JSON.parse(await sh(`node scripts/asc-status.mjs ${APP_ID}`)).versions as Version[]);
const requests = kept(async (sh) =>
  (await sh("npx convex data items --component feedback --prod --format jsonLines --limit 200"))
    .split("\n")
    .filter((line) => line.startsWith("{"))
    .map((line) => JSON.parse(line) as Request),
);

const isOpen = (r: Request) => r.state !== "completed" && r.state !== "rejected";
const needsMike = (state: string) => state === "PENDING_DEVELOPER_RELEASE" || state.endsWith("REJECTED");

const WORDS: Record<string, string> = {
  READY_FOR_DISTRIBUTION: "Live",
  PENDING_DEVELOPER_RELEASE: "Approved, waiting for you to release it",
  PENDING_APPLE_RELEASE: "Approved, on its way out",
  WAITING_FOR_REVIEW: "Waiting for review",
  IN_REVIEW: "In review",
  REJECTED: "Rejected",
  METADATA_REJECTED: "Rejected for its listing",
  DEVELOPER_REJECTED: "Pulled from review",
  PREPARE_FOR_SUBMISSION: "Not submitted yet",
};

export default {
  icon: "headphones",
  actions: [
    { title: "Website", icon: "safari", run: "open https://poddle.mikecann.app/" },
    { title: "App Store Connect", icon: "app.badge", run: `open ${CONNECT}` },
    { title: "Sentry", icon: "exclamationmark.triangle", run: "open 'https://mikec.sentry.io/issues/?project=4512336956817408'" },
    {
      // Only there once Apple has said yes. A message rather than a command, as a release also has
      // the checks in the runbook (does the build still work with today's backend, badges).
      title: "Release it",
      icon: "paperplane",
      note: "Shows once Apple has approved a version",
      prompt: "Apple has approved a version of Poddle. Check where it stands with `node scripts/asc-status.mjs 6825613455`, then release it following \"Shipping an update\" in docs/runbooks/appstore-release.md.",
      when: async ({ sh }: Ctx) => (await versions(sh))[0]?.state === "PENDING_DEVELOPER_RELEASE",
    },
    {
      title: "Build the next request",
      icon: "hammer",
      note: "Shows when someone has asked for something in Chef",
      prompt: "Look at the open Chef requests on Poddle's prod (`npx convex data items --component feedback --prod --format jsonLines`), then build the oldest one that's been approved. Ask me if none has.",
      when: async ({ sh }: Ctx) => (await requests(sh)).some(isOpen),
      badge: async ({ sh }: Ctx) => (await requests(sh)).filter(isOpen).length,
    },
  ],
  panels: [
    {
      title: "App Store",
      icon: "app.badge",
      when: async ({ sh }: Ctx) => {
        try {
          return (await versions(sh)).length > 0;
        } catch {
          return false;
        }
      },
      badge: async ({ sh }: Ctx) => ((await versions(sh))[0] && needsMike((await versions(sh))[0].state) ? 1 : 0),
      items: async ({ sh }: Ctx) =>
        (await versions(sh)).slice(0, 3).map((v) => ({
          title: v.version,
          detail: WORDS[v.state] ?? v.state,
          url: CONNECT,
          icon: "app.badge",
          tone: needsMike(v.state) ? "attention" : v.state === "READY_FOR_DISTRIBUTION" ? "done" : undefined,
        })),
    },
    {
      title: "Chef requests",
      icon: "text.bubble",
      badge: async ({ sh }: Ctx) => (await requests(sh)).filter(isOpen).length,
      items: async ({ sh }: Ctx) => {
        const all = await requests(sh);
        const open = all.filter(isOpen).map((r) => ({ title: `#${r.number} ${r.title ?? r.description ?? ""}`.trim(), detail: r.state, icon: "text.bubble", tone: "attention" }));
        const shipped = all
          .filter((r) => r.state === "completed" && r.changelog)
          .sort((a, b) => (b.completedAt ?? 0) - (a.completedAt ?? 0))
          .slice(0, 5)
          .map((r) => ({ title: `#${r.number} ${r.title ?? ""}`.trim(), detail: r.changelog, icon: "checkmark.circle" }));
        return [...(open.length ? open : [{ title: "Nothing waiting", tone: "done" }]), ...shipped];
      },
    },
  ],
  hooks: [
    // After a turn that changed a feature file: under a second, and it catches a scenario whose
    // steps have gone missing long before the end-to-end run does.
    { title: "BDD pairing", on: "turn.end", run: "npm run -s test:bdd-check", edited: "features/**", tell: "failures" },
  ],
};
