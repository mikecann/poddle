import { describe, expect, test } from "vitest";
import { APP_STORE_LIVE } from "./links";
import { renderLanding } from "./prerender";

describe("the prerendered home page", () => {
  const html = renderLanding();

  test("has one h1 and the App Store badge", () => {
    expect(html.match(/<h1[\s>]/g)).toHaveLength(1);
    expect(html).toContain(APP_STORE_LIVE ? "Download on the" : "Coming soon to the");
    expect(html.includes("https://apps.apple.com/app/id6825613455")).toBe(APP_STORE_LIVE);
  });

  test("every screenshot has alt text and a size, and only the hero's two phones load straight away", () => {
    const images = [...html.matchAll(/<img [^>]*>/g)].map((m) => m[0]);
    for (const img of images) {
      expect(img).toMatch(/ alt="/);
      expect(img).toMatch(/ width="\d+"/);
      expect(img).toMatch(/ height="\d+"/);
    }
    const screens = images.filter((img) => img.includes("/screens/"));
    expect(screens.length).toBeGreaterThan(5);
    for (const img of screens) expect(img).not.toMatch(/ alt=""/);
    expect(screens.filter((img) => !img.includes(`loading="lazy"`))).toHaveLength(2);
  });

  test("links to sign-in and carries the app's structured data", () => {
    expect(html).toContain(`href="/me"`);
    const json = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/.exec(html)![1]!;
    const data = JSON.parse(json);
    expect(data["@type"]).toBe("MobileApplication");
    expect(data.operatingSystem).toMatch(/iOS/);
    expect(data.offers.price).toBe("0");
    expect(data.author.name).toBe("Mike Cann");
  });
});
