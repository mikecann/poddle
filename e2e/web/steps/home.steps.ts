import { createBdd } from "playwright-bdd";
import { expect, test } from "../fixtures";

const { When, Then } = createBdd(test);

When("a visitor opens the home page", async ({ page }) => {
  await page.goto("/");
});

Then("the home page shows Poddle with an App Store badge", async ({ page }) => {
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  // "Coming soon to the App Store" until the app's out, then "Download on the App Store".
  await expect(page.locator(".hero .appstore")).toContainText("App Store");
});

When("they choose to sign in from the home page", async ({ page }) => {
  await page.getByRole("banner").getByRole("link", { name: "Sign in" }).click();
});

When("a visitor opens the home page on a phone", async ({ page }) => {
  // Below the md breakpoint the nav's links move into a full height menu (Landing.tsx Nav).
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
});

When("they open the menu and choose to sign in", async ({ page }) => {
  await page.getByRole("button", { name: "Open the menu" }).click();
  await page.locator("#menu").getByRole("link", { name: "Sign in" }).click();
});

Then("the home page fits the phone's screen", async ({ page }) => {
  // Anything wider than the screen makes a phone zoom the whole page out (the floating nav
  // went off centre on the live site that way), so nothing may stick out sideways.
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow).toBeLessThanOrEqual(0);
});
