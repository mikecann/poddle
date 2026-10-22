#!/usr/bin/env node
// The cheap BDD drift check (docs/testing.md): no browsers, no simulators.
//
//   - App: every step in features/app/*.feature matches exactly one step registered in
//     PoddleUITests/Steps/*.steps.swift, using the same Cucumber-expression rules as the
//     Swift runner (PoddleUITests/Gherkin). Unused Swift steps are listed as warnings.
//   - Web: `bddgen` (playwright-bdd) generates the specs, which fails on any step in
//     features/web/*.feature without a definition.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** The Swift runner's Gherkin subset: steps per scenario, with Scenario Outline rows expanded. */
export function featureSteps(text, file) {
  const steps = [];
  let outline = null;
  let header = null;
  text.split(/\r?\n/).forEach((raw, i) => {
    const line = raw.trim();
    if (!line || line.startsWith("#") || line.startsWith("@")) return;
    if (/^(Scenario Outline|Scenario Template):/.test(line)) {
      outline = [];
      header = null;
      return;
    }
    if (/^(Feature|Background|Scenario|Example|Rule):/.test(line)) {
      outline = null;
      return;
    }
    if (/^(Examples|Scenarios):/.test(line)) {
      header = null;
      return;
    }
    const step = /^(Given|When|Then|And|But|\*) (.+)$/.exec(line);
    if (step) {
      const entry = { text: step[2].trim(), where: `${file}:${i + 1}` };
      if (outline) outline.push(entry);
      else steps.push(entry);
      return;
    }
    if (line.startsWith("|") && outline) {
      const cells = line.replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
      if (!header) {
        header = cells;
        return;
      }
      for (const s of outline) {
        steps.push({ text: header.reduce((t, h, k) => t.replaceAll(`<${h}>`, cells[k]), s.text), where: `${file}:${i + 1}` });
      }
    }
  });
  return steps;
}

/** `s.given("…")`, `s.when("…")`, `s.then("…")` in a Swift step file. */
export function swiftExpressions(source, file) {
  const out = [];
  for (const m of source.matchAll(/\bs\.(given|when|then)\("((?:[^"\\]|\\.)*)"/g)) {
    const line = source.slice(0, m.index).split("\n").length;
    out.push({ expression: m[2].replace(/\\"/g, '"').replace(/\\\\/g, "\\"), where: `${file}:${line}` });
  }
  return out;
}

const PARAMS = { "{string}": '"([^"]*)"', "{int}": "(-?\\d+)", "{float}": "(-?\\d+(?:\\.\\d+)?)", "{word}": "([^\\s]+)" };

/** Same translation as `StepDefinition.regex(for:)` in PoddleUITests/Gherkin/Steps.swift. */
export function expressionRegex(expression) {
  let pattern = "^";
  let rest = expression;
  while (rest) {
    const token = Object.keys(PARAMS).find((p) => rest.startsWith(p));
    if (token) {
      pattern += PARAMS[token];
      rest = rest.slice(token.length);
    } else {
      pattern += rest[0].replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      rest = rest.slice(1);
    }
  }
  return new RegExp(`${pattern}$`);
}

export function appDrift() {
  const errors = [];
  const stepsDir = path.join(root, "PoddleUITests", "Steps");
  const defs = fs
    .readdirSync(stepsDir)
    .filter((f) => f.endsWith(".steps.swift"))
    .flatMap((f) => swiftExpressions(fs.readFileSync(path.join(stepsDir, f), "utf8"), `PoddleUITests/Steps/${f}`))
    .map((d) => ({ ...d, regex: expressionRegex(d.expression), used: 0 }));
  const seen = new Map();
  for (const d of defs) {
    if (seen.has(d.expression)) errors.push(`"${d.expression}" is defined twice: ${seen.get(d.expression)} and ${d.where}`);
    seen.set(d.expression, d.where);
  }
  const featuresDir = path.join(root, "features", "app");
  for (const f of fs.readdirSync(featuresDir).filter((f) => f.endsWith(".feature"))) {
    for (const step of featureSteps(fs.readFileSync(path.join(featuresDir, f), "utf8"), `features/app/${f}`)) {
      const matches = defs.filter((d) => d.regex.test(step.text));
      if (!matches.length) errors.push(`${step.where}: no step matches "${step.text}"`);
      if (matches.length > 1) errors.push(`${step.where}: "${step.text}" matches ${matches.map((m) => m.where).join(" and ")}`);
      for (const m of matches) m.used++;
    }
  }
  const unused = defs.filter((d) => !d.used).map((d) => `${d.where}: "${d.expression}" isn't used by any feature`);
  return { errors, unused, steps: defs.length };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const { errors, unused, steps } = appDrift();
  for (const u of unused) console.warn(`warning: ${u}`);
  if (errors.length) {
    console.error(`App BDD drift:\n  ${errors.join("\n  ")}`);
    process.exit(1);
  }
  console.log(`App BDD steps OK (${steps} Swift step definitions).`);
  const bddgen = spawnSync("npx", ["bddgen"], { cwd: root, stdio: "inherit" });
  if (bddgen.status !== 0) {
    console.error("Web BDD drift: bddgen failed (see above).");
    process.exit(1);
  }
  console.log("Web BDD steps OK (bddgen).");
}
