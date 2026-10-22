import { startWorld } from "../world/world.mjs";

// Starts the e2e world with the website uploaded, unless a runner already did
// (scripts/run-e2e.mjs sets PODDLE_E2E_WORLD for both suites).
export default async function globalSetup() {
  if (process.env.PODDLE_E2E_WORLD) return;
  const world = await startWorld({ website: true });
  return async () => await world.stop();
}
