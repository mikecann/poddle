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
