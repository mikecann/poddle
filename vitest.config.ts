import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Node so the "use node" actions (feeds, APNs) load as they do on Convex.
    // The website's tests that need a DOM say so with `@vitest-environment jsdom`.
    environment: "node",
    include: ["tests/**/*.test.ts", "web/src/**/*.test.ts"],
    server: { deps: { inline: ["convex-test"] } },
  },
});
