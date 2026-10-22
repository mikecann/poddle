import type { Page } from "@playwright/test";
import { createBdd } from "playwright-bdd";
import { expect, test } from "../fixtures";

const { Given, When, Then } = createBdd(test);

async function testSignIn(page: Page, email: string) {
  await page.goto("/me");
  await page.locator("#test-email").fill(email);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
}

When("they sign in on the website with test sign-in", async ({ page, world }) => {
  await testSignIn(page, world.users.listener);
  await expect(page.getByText(`Signed in as ${world.users.listener}`)).toBeVisible();
});

Given("they're signed in on the website", async ({ page, world }) => {
  await testSignIn(page, world.users.listener);
  await expect(page.getByText(`Signed in as ${world.users.listener}`)).toBeVisible();
});

When("{string} tries test sign-in on the website", async ({ page }, email: string) => {
  await testSignIn(page, email);
});

Then("their Up Next on the website lists {string} then {string}", async ({ page }, a: string, b: string) => {
  const upNext = page.locator("section").filter({ has: page.getByRole("heading", { name: /^Up Next/ }) });
  await expect(upNext.locator("ul.list li")).toHaveCount(2);
  await expect(upNext.locator("ul.list li").nth(0)).toContainText(a);
  await expect(upNext.locator("ul.list li").nth(1)).toContainText(b);
});

Then("their shows on the website include {string}", async ({ page }, show: string) => {
  await expect(page.locator("ul.shows")).toContainText(show);
});

When("they sign out on the website", async ({ page }) => {
  await page.getByRole("button", { name: "Sign out" }).click();
});

Then("the website asks them to sign in", async ({ page }) => {
  await expect(page.getByRole("heading", { name: "Sign in to Poddle" })).toBeVisible({ timeout: 20_000 });
  await expect(page.getByRole("button", { name: "Sign in with Apple" })).toBeVisible();
});

Then("their Up Next isn't on the page", async ({ page }) => {
  await expect(page.getByRole("heading", { name: /^Up Next/ })).toHaveCount(0);
  await expect(page.getByText("Sunrise in A")).toHaveCount(0);
});

Then("the website says Poddle is invite-only", async ({ page }) => {
  await expect(page.locator(".testsignin .error")).toContainText("invite-only");
});

When("they delete their account on the website", async ({ page }) => {
  await page.getByRole("button", { name: "Delete account" }).click();
  await page.getByRole("button", { name: "Continue" }).click();
  await page.getByRole("button", { name: "Delete my account" }).click();
});

Then("the website says their account is deleted", async ({ page }) => {
  await expect(page.getByText("Your account's deleted")).toBeVisible();
  await expect(page).toHaveURL(/\/\?deleted=1$/);
});

Then("the listener has no account any more", async ({ world }) => {
  await expect.poll(async () => (await world.call<{ exists: boolean }>("user", { email: world.users.listener })).exists).toBe(false);
});

When("their session ends while the tab is still open", async ({ page, world }) => {
  // Everything the tab's session stood on goes (as when a deploy resets things or
  // the account goes elsewhere), and the tab only notices on its next refresh.
  await page.clock.install();
  await world.call("reset");
  await page.clock.fastForward("05:00");
});
