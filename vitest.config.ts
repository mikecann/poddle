import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Node so the "use node" actions (feeds, APNs) load as they do on Convex.
    environment: "node",
    include: ["tests/**/*.test.ts"],
    server: { deps: { inline: ["convex-test"] } },
  },
});
