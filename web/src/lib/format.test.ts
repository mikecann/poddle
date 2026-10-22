import { describe, expect, test } from "vitest";
import { clock, duration, parseStart, relativeDate } from "./format";
import { appLink, episodePath, mightHaveApp, showPath } from "./links";

describe("format", () => {
  test("duration", () => {
    expect(duration(4320)).toBe("1h 12m");
    expect(duration(3600)).toBe("1h");
    expect(duration(2280)).toBe("38m");
    expect(duration(45)).toBe("45s");
    expect(duration(undefined)).toBe("");
  });

  test("clock", () => {
    expect(clock(3723)).toBe("1:02:03");
    expect(clock(754)).toBe("12:34");
    expect(clock(5.9)).toBe("0:05");
    expect(clock(-3)).toBe("0:00");
  });

  test("relativeDate", () => {
    const now = new Date(2026, 9, 22, 12).getTime();
    expect(relativeDate(now - 3600_000, now)).toBe("Today");
    expect(relativeDate(now - 86_400_000, now)).toBe("Yesterday");
    expect(relativeDate(now - 3 * 86_400_000, now)).toBe("3 days ago");
  });

  test.each([
    ["754", 754],
    ["90.5", 90.5],
    ["12:34", 754],
    ["1:02:03", 3723],
    ["1h2m3s", 3723],
    ["90s", 90],
    ["5m", 300],
    ["", null],
    ["soon", null],
    [null, null],
  ])("parseStart(%s)", (raw, want) => {
    expect(parseStart(raw)).toBe(want);
  });
});

describe("links", () => {
  test("share paths and app links", () => {
    expect(episodePath("abc")).toBe("/e/abc");
    expect(episodePath("abc", 754.8)).toBe("/e/abc?t=754");
    expect(episodePath("abc", 0)).toBe("/e/abc");
    expect(showPath("p1")).toBe("/s/p1");
    expect(appLink("e", "abc", 90)).toBe("poddle://e/abc?t=90");
    expect(appLink("s", "p1", 90)).toBe("poddle://s/p1");
  });

  test("only offers the app on Apple devices", () => {
    expect(mightHaveApp("Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X)")).toBe(true);
    expect(mightHaveApp("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")).toBe(true);
    expect(mightHaveApp("Mozilla/5.0 (Linux; Android 15; Pixel 9)")).toBe(false);
  });
});
