// @vitest-environment jsdom
import { afterEach, describe, expect, test, vi } from "vitest";

// Only real visitors' errors may reach Sentry, so the site starts it in a
// production build on the prod domain and nowhere else (sentry.ts).
const init = vi.hoisted(() => vi.fn());
vi.mock("@sentry/react", () => ({ init }));
const { startSentry } = await import("./sentry");

function onHost(hostname: string) {
  vi.stubGlobal("location", { ...window.location, hostname });
}

afterEach(() => {
  init.mockClear();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("startSentry", () => {
  test("stays off outside a production build, even on the prod domain", () => {
    onHost("poddle.mikecann.app");
    startSentry();
    expect(init).not.toHaveBeenCalled();
  });

  test("stays off in a production build anywhere but the prod domain", () => {
    vi.stubEnv("PROD", true);
    for (const host of ["localhost", "127.0.0.1", "striped-turtle-260.ap-southeast-2.convex.site"]) {
      onHost(host);
      startSentry();
    }
    expect(init).not.toHaveBeenCalled();
  });

  test("starts in a production build on poddle.mikecann.app, errors only, tagged web", () => {
    vi.stubEnv("PROD", true);
    onHost("poddle.mikecann.app");
    startSentry();
    expect(init).toHaveBeenCalledTimes(1);
    expect(init).toHaveBeenCalledWith(expect.objectContaining({
      environment: "production",
      tracesSampleRate: 0,
      initialScope: { tags: { component: "web" } },
    }));
  });
});
