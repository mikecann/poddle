import react from "@vitejs/plugin-react";
import { readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { createServer, defineConfig, type Plugin } from "vite";
import { LANDING_END, LANDING_START } from "../convex/lib/meta";

/**
 * Puts the home page, rendered to HTML (src/lib/prerender.tsx), into the built
 * index.html between the landing markers, so it's there without JavaScript.
 */
function prerenderLanding(): Plugin {
  let outDir = "";
  return {
    name: "poddle:prerender-landing",
    apply: "build",
    configResolved(config) {
      outDir = path.resolve(config.root, config.build.outDir);
    },
    async closeBundle() {
      const server = await createServer({
        root: import.meta.dirname,
        configFile: false,
        logLevel: "error",
        appType: "custom",
        server: { middlewareMode: true, hmr: false, ws: false },
        // It only renders once, so nothing needs pre-bundling, and any cache it
        // writes goes to a temp folder rather than node_modules.
        cacheDir: path.join(tmpdir(), "poddle-prerender"),
        optimizeDeps: { noDiscovery: true, include: [] },
        plugins: [react()],
      });
      try {
        const { renderLanding } = (await server.ssrLoadModule("/src/lib/prerender.tsx")) as { renderLanding: () => string };
        const file = path.join(outDir, "index.html");
        const html = await readFile(file, "utf8");
        const slot = `${LANDING_START}${LANDING_END}`;
        if (!html.includes(slot)) throw new Error(`index.html has no empty ${slot} to prerender the home page into`);
        await writeFile(file, html.replace(slot, `${LANDING_START}${renderLanding()}${LANDING_END}`));
      } finally {
        await server.close();
      }
    },
  };
}

// The website: built into web/dist and uploaded to Convex static hosting
// (`npm run web:upload:dev`, README "Website").
export default defineConfig({
  root: import.meta.dirname,
  plugins: [react(), prerenderLanding()],
  build: { outDir: "dist", emptyOutDir: true },
  server: { port: 5174 },
});
