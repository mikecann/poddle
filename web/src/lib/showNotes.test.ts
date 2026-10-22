// @vitest-environment jsdom
import { describe, expect, test } from "vitest";
import { prepareShowNotes } from "./showNotes";

function dom(html: string): HTMLDivElement {
  const div = document.createElement("div");
  div.innerHTML = html;
  return div;
}

describe("prepareShowNotes", () => {
  test("strips scripts, handlers, styles and javascript: links", () => {
    const out = dom(
      prepareShowNotes(
        `<p onclick="steal()" style="color:red">Hi <script>alert(1)</script><a href="javascript:alert(1)">bad</a> <img src=x onerror="alert(1)"><iframe src="https://evil.test"></iframe></p>`,
      ),
    );
    expect(out.querySelector("script, iframe, [onclick], [onerror], [style]")).toBeNull();
    expect(out.querySelector("a")!.hasAttribute("href")).toBe(false);
    // Only https images survive.
    expect(out.querySelector("img")).toBeNull();
    expect(out.textContent).toContain("Hi");
  });

  test("links open in a new tab without the opener", () => {
    const a = dom(prepareShowNotes(`<a href="https://example.com">site</a>`)).querySelector("a")!;
    expect(a.getAttribute("href")).toBe("https://example.com");
    expect(a.getAttribute("target")).toBe("_blank");
    expect(a.getAttribute("rel")).toBe("noopener noreferrer nofollow");
  });

  test("timestamps become seek links", () => {
    const out = dom(prepareShowNotes(`<p>(00:00) Intro<br>(12:34) The good bit<br>1:02:03 Outro</p>`, 4000));
    const seeks = [...out.querySelectorAll<HTMLAnchorElement>("a.ts")].map((a) => [a.textContent, a.dataset.seek]);
    expect(seeks).toEqual([
      ["00:00", "0"],
      ["12:34", "754"],
      ["1:02:03", "3723"],
    ]);
    expect(out.querySelector("a.ts")!.getAttribute("href")).toBe("?t=0");
  });

  test("leaves times past the end of the episode, and ones already in links, alone", () => {
    const out = dom(prepareShowNotes(`<p>Recorded at 9:30:00. <a href="https://x.test">see 12:34</a></p>`, 1200));
    expect(out.querySelectorAll("a.ts")).toHaveLength(0);
  });

  test("timestamp links the feed made itself seek too", () => {
    const out = dom(prepareShowNotes(`<ul><li><a href="#t=01:10">01:10</a> Intro</li><li><a href="https://x.test">Site</a></li></ul>`, 4000));
    const a = out.querySelector<HTMLAnchorElement>("a.ts")!;
    expect([a.textContent, a.dataset.seek, a.getAttribute("href"), a.getAttribute("target")]).toEqual(["01:10", "70", "?t=70", null]);
    expect(out.querySelectorAll("a.ts")).toHaveLength(1);
  });

  test("plain text notes become paragraphs, escaped", () => {
    const out = dom(prepareShowNotes("First line\nsecond <line>\n\nNext para at 1:00"));
    expect(out.querySelectorAll("p")).toHaveLength(2);
    expect(out.querySelector("p")!.innerHTML).toBe("First line<br>second &lt;line&gt;");
    expect(out.querySelector("a.ts")!.textContent).toBe("1:00");
  });
});
