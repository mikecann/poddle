import type { APIRequestContext } from "@playwright/test";
import { createBdd } from "playwright-bdd";
import { expect, test, type World } from "../fixtures";

const { When, Then } = createBdd(test);

async function episodeId(world: World, title: string) {
  const episode = await world.call<{ id: string }>("episode", { email: world.users.listener, title });
  return episode.id;
}

/** The raw HTML a chat app's link preview sees: no JavaScript runs. */
async function previewTags(request: APIRequestContext, path: string) {
  const html = await (await request.get(path)).text();
  const tags: Record<string, string> = {};
  for (const m of html.matchAll(/<meta (?:property|name)="([^"]+)" content="([^"]*)">/g)) tags[m[1]!] = m[2]!.replace(/&amp;/g, "&");
  return { html, tags };
}

When("a visitor opens the share link for {string}", async ({ page, world }, title: string) => {
  world.memo.path = `/e/${await episodeId(world, title)}`;
  await page.goto(world.memo.path);
});

When("a visitor opens the share link for {string} at {int} seconds", async ({ page, world }, title: string, seconds: number) => {
  world.memo.path = `/e/${await episodeId(world, title)}?t=${seconds}`;
  await page.goto(world.memo.path);
});

When("a visitor opens the share link for the show {string}", async ({ page, world }, show: string) => {
  const podcast = await world.call<{ id: string }>("podcast", { email: world.users.listener, show });
  world.memo.path = `/s/${podcast.id}`;
  await page.goto(world.memo.path);
});

Then("the link preview is for the episode {string} with the show's artwork", async ({ request, world }, title: string) => {
  const { tags } = await previewTags(request, world.memo.path!);
  expect(tags["og:title"]).toBe(title);
  expect(tags["og:type"]).toBe("music.song");
  expect(tags["og:url"]).toMatch(new RegExp(`${world.memo.path}$`));
  expect(tags["og:image"]).toBe(`${world.fixtureUrl}/art/morning.png`);
  expect(tags["twitter:title"]).toBe(title);
});

Then("the link preview is for the show {string}", async ({ request, world }, show: string) => {
  const { tags } = await previewTags(request, world.memo.path!);
  expect(tags["og:title"]).toBe(show);
  expect(tags["og:type"]).toBe("music.album");
});

Then("the link preview doesn't mention {string}", async ({ request, world }, title: string) => {
  const { html, tags } = await previewTags(request, world.memo.path!);
  expect(tags["og:title"]).toBe("Episode not found");
  expect(tags.robots).toContain("noindex");
  expect(html).not.toContain(title);
});

Then("the page shows {string} from {string}", async ({ page }, title: string, show: string) => {
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(title);
  await expect(page.locator(".ep-head .eyebrow")).toHaveText(show);
});

When("they press play on the page", async ({ page }) => {
  await page.getByRole("button", { name: "Play" }).click();
});

Then("the episode plays in the browser", async ({ page }) => {
  await expect(page.getByRole("button", { name: "Pause" })).toBeVisible();
  await expect.poll(async () => await page.locator("audio").evaluate((a: HTMLAudioElement) => a.currentTime), { timeout: 15_000 }).toBeGreaterThan(1);
});

Then("the page says it starts at {string}", async ({ page }, clock: string) => {
  await expect(page.locator(".starts")).toHaveText(`Starts at ${clock}`);
});

Then("the player is at {string}", async ({ page }, clock: string) => {
  await expect(page.getByRole("slider", { name: "Position" })).toHaveAttribute("aria-valuetext", new RegExp(`^${clock} of `));
});

Then(
  "the page lists the episodes {string}, {string} and {string}",
  async ({ page }, a: string, b: string, c: string) => {
    await expect(page.locator("ul.list .qtt")).toHaveText([a, b, c]);
  },
);

Then("the page says the episode wasn't found", async ({ page }) => {
  await expect(page.getByRole("heading", { name: "Episode not found" })).toBeVisible();
});
