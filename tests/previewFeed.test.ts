import { ConvexError } from "convex/values";
import { afterEach, describe, expect, test, vi } from "vitest";
import { api } from "../convex/_generated/api";
import { fixture, mockFetch, setup } from "./helpers";

// Adding a show by its link (Discover's URL field). When the address can't be reached,
// the person gets a message they can act on, not an uncaught "fetch failed" that prod
// hides behind "Server Error" (PODDLE-E), and the logs say which host and why.

const FEED = "https://feeds.example.com/odd.xml";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

/** What Node's fetch throws when it never gets a response: a TypeError whose `cause` says why. */
function networkFailure(code: string) {
  const cause = Object.assign(new Error(`getaddrinfo ${code} feeds.example.com`), { code });
  return vi.fn(async () => {
    throw new TypeError("fetch failed", { cause });
  });
}

async function refusal(promise: Promise<unknown>): Promise<{ code: string; message: string }> {
  const error = await promise.then(
    () => undefined,
    (e: unknown) => e,
  );
  expect(error).toBeInstanceOf(ConvexError);
  return (error as ConvexError<{ code: string; message: string }>).data;
}

describe("feedActions:previewFeed", () => {
  test("previews a feed", async () => {
    const t = setup();
    mockFetch({ [FEED]: fixture("odd-feed.xml") });
    const preview = await t.action(api.feedActions.previewFeed, { url: FEED });
    expect(preview).toMatchObject({ feedUrl: FEED, title: "The Odd Show", subscribed: false, episodeCount: 4 });
  });

  test("a host that doesn't exist says so, and logs the host and the cause", async () => {
    const t = setup();
    vi.stubGlobal("fetch", networkFailure("ENOTFOUND"));
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    const data = await refusal(t.action(api.feedActions.previewFeed, { url: FEED }));
    expect(data).toEqual({ code: "feedUnreachable", message: "Couldn't find feeds.example.com. Check the address and try again." });
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("feeds.example.com"), expect.stringContaining("ENOTFOUND"));
  });

  test("a host that won't answer is a 'couldn't reach' message", async () => {
    const t = setup();
    vi.stubGlobal("fetch", networkFailure("ECONNREFUSED"));
    vi.spyOn(console, "warn").mockImplementation(() => {});

    const data = await refusal(t.action(api.feedActions.previewFeed, { url: FEED }));
    expect(data).toEqual({ code: "feedUnreachable", message: "Couldn't reach feeds.example.com. Try again later." });
  });

  test("the log keeps a private feed's token out", async () => {
    const t = setup();
    vi.stubGlobal("fetch", networkFailure("ECONNRESET"));
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    await refusal(t.action(api.feedActions.previewFeed, { url: "https://feeds.example.com/private.xml?token=s3cret" }));
    expect(JSON.stringify(warn.mock.calls)).not.toContain("s3cret");
  });

  test("a word that isn't a web address is refused without fetching anything", async () => {
    const t = setup();
    const fetchMock = mockFetch({});

    const data = await refusal(t.action(api.feedActions.previewFeed, { url: "https://joe rogan" }));
    expect(data.code).toBe("badUrl");
    expect((await refusal(t.action(api.feedActions.previewFeed, { url: "https://joerogan" }))).code).toBe("badUrl");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("a host that answers with an error says which", async () => {
    const t = setup();
    mockFetch({ [FEED]: { status: 404, body: "nope" } });

    const data = await refusal(t.action(api.feedActions.previewFeed, { url: FEED }));
    expect(data).toEqual({ code: "feedHttp", message: "feeds.example.com answered with an error (HTTP 404)." });
  });

  test("a page with no feed on it says so", async () => {
    const t = setup();
    mockFetch({ "https://example.com/": "<html><head><title>Hi</title></head><body>Just a website</body></html>" });

    const data = await refusal(t.action(api.feedActions.previewFeed, { url: "https://example.com/" }));
    expect(data).toEqual({ code: "notAFeed", message: "There's no podcast feed at that address." });
  });

  test("Apple being unreachable for an Apple link is its own message", async () => {
    const t = setup();
    vi.stubGlobal("fetch", networkFailure("UND_ERR_CONNECT_TIMEOUT"));
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    const data = await refusal(t.action(api.feedActions.previewFeed, { url: "https://podcasts.apple.com/au/podcast/x/id617416468" }));
    expect(data).toEqual({ code: "appleUnreachable", message: "Couldn't reach Apple Podcasts. Try again later." });
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("itunes.apple.com"), expect.stringContaining("UND_ERR_CONNECT_TIMEOUT"));
  });

  test("Apple answering with an error is the same message", async () => {
    const t = setup();
    mockFetch({ "https://itunes.apple.com/lookup": { status: 503, body: "busy" } });

    const data = await refusal(t.action(api.feedActions.previewFeed, { url: "617416468" }));
    expect(data.code).toBe("appleUnreachable");
  });
});

describe("directory search when Apple can't be reached", () => {
  test("is a plain message, not an uncaught fetch failure", async () => {
    const t = setup();
    vi.stubGlobal("fetch", networkFailure("ETIMEDOUT"));
    vi.spyOn(console, "warn").mockImplementation(() => {});

    const data = await refusal(t.action(api.directory.search, { term: "tones" }));
    expect(data).toEqual({ code: "appleUnreachable", message: "Couldn't reach Apple Podcasts. Try again later." });
  });
});
