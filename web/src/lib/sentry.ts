import * as Sentry from "@sentry/react";

// Error reporting (Sentry project `poddle`) for the live website only. Mike's agents
// run this site all day in `vite dev`, Playwright and on the dev deployment's
// .convex.site, and an agent watches Sentry and opens a thread for anything serious,
// so only real visitors' errors may get there: a production build served from the
// prod domain. Errors only: no tracing, no replay.

const PROD_HOST = "poddle.mikecann.app";
const DSN = "https://325474d642eb61456018e347930e882c@o4508736647266304.ingest.us.sentry.io/4512336956817408";

export function startSentry(): void {
  if (!import.meta.env.PROD || window.location.hostname !== PROD_HOST) return;
  Sentry.init({
    dsn: DSN,
    environment: "production",
    // The git commit the site was built from (vite.config.ts).
    release: `poddle-web@${import.meta.env.VITE_PODDLE_RELEASE as string}`,
    initialScope: { tags: { component: "web" } },
    tracesSampleRate: 0,
    // No user details, cookies, headers or bodies (Sentry 11's replacement for sendDefaultPii: false).
    dataCollection: { userInfo: false, cookies: false, httpHeaders: false, httpBodies: [] },
    // Leave the site's own fetch errors as they are; only the reports get the hostname.
    enhanceFetchErrorMessages: "report-only",
    // A dropped connection or a flaky network isn't a bug in Poddle.
    ignoreErrors: [
      "Failed to fetch",
      "Load failed",
      "NetworkError when attempting to fetch resource.",
      "The network connection was lost.",
    ],
  });
}
