import { createBdd } from "playwright-bdd";
import { expect, test } from "../fixtures";

// Steps shared by every web feature. Files starting with _ own no feature.

const { Given, Then } = createBdd(test);

Given("the listener follows {string}", async ({ world }, show: string) => {
  await world.call("signUp", { email: world.users.listener });
  await world.call("follow", { email: world.users.listener, show });
});

Given("the listener follows {string} with {string} and {string} in Up Next", async ({ world }, show: string, a: string, b: string) => {
  await world.call("signUp", { email: world.users.listener });
  await world.call("follow", { email: world.users.listener, show, upNext: [a, b] });
});

Then("the website asks them to sign in", async ({ page }) => {
  await expect(page.getByRole("heading", { name: "Sign in to Poddle" })).toBeVisible({ timeout: 20_000 });
  await expect(page.getByRole("button", { name: "Sign in with Apple" })).toBeVisible();
});
