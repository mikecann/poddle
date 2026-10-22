import { createBdd } from "playwright-bdd";
import { test } from "../fixtures";

// Steps shared by every web feature. Files starting with _ own no feature.

const { Given } = createBdd(test);

Given("the listener follows {string}", async ({ world }, show: string) => {
  await world.call("signUp", { email: world.users.listener });
  await world.call("follow", { email: world.users.listener, show });
});

Given("the listener follows {string} with {string} and {string} in Up Next", async ({ world }, show: string, a: string, b: string) => {
  await world.call("signUp", { email: world.users.listener });
  await world.call("follow", { email: world.users.listener, show, upNext: [a, b] });
});
