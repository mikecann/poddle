import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// The website: built into web/dist and uploaded to Convex static hosting
// (`npm run web:upload:dev`, README "Website").
export default defineConfig({
  root: import.meta.dirname,
  plugins: [react()],
  build: { outDir: "dist", emptyOutDir: true },
  server: { port: 5174 },
});
