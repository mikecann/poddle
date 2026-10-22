#!/usr/bin/env node
// Every feature file is owned by exactly one step module, paired by name
// (docs/testing.md):
//
//   features/app/<name>.feature  ↔  PoddleUITests/Steps/<name>.steps.swift   (XCUITest)
//   features/web/<name>.feature  ↔  e2e/web/steps/<name>.steps.ts            (playwright-bdd)
//
// Step files starting with "_" hold shared steps and own no feature. Fails on a
// feature with no step module, or a step module with no feature.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export const HARNESSES = [
  { name: "app", features: "features/app", steps: "PoddleUITests/Steps", suffix: ".steps.swift" },
  { name: "web", features: "features/web", steps: "e2e/web/steps", suffix: ".steps.ts" },
];

const list = (dir, suffix) =>
  fs.existsSync(path.join(root, dir)) ? fs.readdirSync(path.join(root, dir)).filter((f) => f.endsWith(suffix)).sort() : [];

export function pairingErrors() {
  const errors = [];
  for (const h of HARNESSES) {
    const features = list(h.features, ".feature").map((f) => f.slice(0, -".feature".length));
    const owners = list(h.steps, h.suffix)
      .filter((f) => !f.startsWith("_"))
      .map((f) => f.slice(0, -h.suffix.length));
    for (const f of features) {
      if (!owners.includes(f)) errors.push(`${h.features}/${f}.feature has no step module: add ${h.steps}/${f}${h.suffix}`);
    }
    for (const o of owners) {
      if (!features.includes(o)) errors.push(`${h.steps}/${o}${h.suffix} claims ${h.features}/${o}.feature, which doesn't exist`);
    }
    if (!features.length) errors.push(`No features in ${h.features}`);
  }
  return errors;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const errors = pairingErrors();
  if (errors.length) {
    console.error(`BDD pairing failed:\n  ${errors.join("\n  ")}`);
    process.exit(1);
  }
  console.log("BDD pairing OK: every feature has exactly one step module.");
}
