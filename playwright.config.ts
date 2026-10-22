import { defineConfig, devices } from "@playwright/test";
import { defineBddConfig } from "playwright-bdd";

// The website's end-to-end suite: features/web/*.feature, run by playwright-bdd
// with the paired e2e/web/steps/<name>.steps.ts, against the e2e world (a local
// Convex backend with the site uploaded, plus the fixture server). docs/testing.md.
//   npm run test:e2e:web
//   npm run test:e2e:web -- -g "scenario name"

const testDir = defineBddConfig({
  features: "features/web/*.feature",
  steps: ["e2e/web/steps/*.steps.ts", "e2e/web/fixtures.ts"],
  outputDir: "e2e/.features-gen/web",
  missingSteps: "fail-on-gen",
});

const sitePort = Number(process.env.E2E_SITE_PORT ?? 3411);

export default defineConfig({
  testDir,
  globalSetup: "./e2e/web/globalSetup.ts",
  outputDir: "e2e/.runtime/playwright-results",
  reporter: [["list"], ["html", { open: "never", outputFolder: "e2e/.runtime/playwright-report" }]],
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  use: {
    ...devices["Desktop Chrome"],
    baseURL: `http://127.0.0.1:${sitePort}`,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
});
