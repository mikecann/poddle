import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync, mkdirSync, copyFileSync, writeFileSync, chmodSync } from "node:fs";
import path from "node:path";

// Playwright caches each compiled test file, and its source map, in the system temp folder by
// default. macOS deletes temp files nobody has opened for a few days, and on tinker-desk that
// took the .map beside a cached spec but left the .js, which Playwright kept using: its tests
// got the compiled line numbers, playwright-bdd couldn't match them to the feature, and every
// share page scenario failed with "bddTestData not found" (docs/testing.md). So the web suite
// keeps the cache in its own git-ignored folder. Also inline in package.json's test:e2e:web.
export const PLAYWRIGHT_CACHE_DIR = "e2e/.runtime/playwright-transform-cache";
export const webE2eEnv = (env, root = process.cwd()) => ({ ...env, PWTEST_CACHE_DIR: path.resolve(root, PLAYWRIGHT_CACHE_DIR) });

export const quote = (s) => `'${String(s).replaceAll("'", "'\\''")}'`;
export const readJson = (file) => JSON.parse(readFileSync(file, "utf8"));
export function command(cmd, args, options = {}) {
  const result = spawnSync(cmd, args, { encoding: "utf8", stdio: "pipe", ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${cmd} failed (exit ${result.status}): ${result.stderr ?? "see run log"}`);
  return result.stdout?.trim() ?? "";
}

// The tracked package lock is in PoddleKit. Seed the app workspace lock as well,
// because Xcode otherwise tries to resolve the private ChefKit repository again.
export function packagePins(repo) {
  const pins = readJson(path.join(repo, "Packages/PoddleKit/Package.resolved")).pins;
  const project = readFileSync(path.join(repo, "Poddle.xcodeproj/project.pbxproj"), "utf8");
  const chef = pins.find((p) => p.identity === "chef-cloud");
  if (!chef || !project.includes(`revision = ${chef.state.revision};`)) throw new Error("ChefKit project revision and Package.resolved disagree");
  return pins;
}
// SPM checkouts borrow objects through absolute git alternates. Relocate these
// and binary artifact paths before checking a cache copied from another machine.
export function relocatePackages(source) {
  for (const entry of readdirSync(path.join(source, "checkouts"))) {
    const file = path.join(source, "checkouts", entry, ".git/objects/info/alternates");
    if (!existsSync(file)) continue;
    const lines = readFileSync(file, "utf8").trim().split("\n").map((line) => {
      const suffix = line.match(/\/repositories\/[^/]+\/objects$/)?.[0];
      if (!suffix || !existsSync(source + suffix)) throw new Error(`Cannot relocate git objects for ${entry}`);
      return source + suffix;
    });
    chmodSync(file, statSync(file).mode | 0o200);
    writeFileSync(file, lines.join("\n") + "\n");
  }
  const file = path.join(source, "workspace-state.json");
  const state = readJson(file);
  for (const artifact of state.object.artifacts ?? []) {
    const suffix = artifact.path?.match(/\/(checkouts|artifacts)\/.*$/)?.[0];
    if (suffix) artifact.path = source + suffix;
  }
  writeFileSync(file, JSON.stringify(state, null, 2));
}
export function verifyPackages(repo, source) {
  const state = readJson(path.join(source, "workspace-state.json"));
  for (const pin of packagePins(repo)) {
    const dependency = state.object.dependencies.find((d) => d.packageRef.identity === pin.identity);
    const checkout = path.join(source, "checkouts", pin.identity);
    if (dependency?.state.checkoutState?.revision !== pin.state.revision ||
        command("git", ["-C", checkout, "rev-parse", "HEAD"]) !== pin.state.revision) {
      throw new Error(`Cached ${pin.identity} does not match pin ${pin.state.revision}. Resolve packages on the MacBook and sync again.`);
    }
    if (command("git", ["-C", checkout, "status", "--porcelain", "--untracked-files=no"])) {
      throw new Error(`Cached ${pin.identity} has modified tracked files`);
    }
  }
}

export function filesBelow(directory) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? filesBelow(file) : entry.isFile() ? [file] : [];
  });
}

export function scenarioResults(runtime) {
  const results = [];
  const web = path.join(runtime, "web-results.json");
  if (existsSync(web)) {
    const visit = (suite) => {
      for (const spec of suite.specs ?? []) {
        for (const test of spec.tests ?? []) {
          results.push({ suite: "web", name: spec.title, status: test.status === "expected" ? "passed" : test.status === "skipped" ? "skipped" : "failed" });
        }
      }
      for (const child of suite.suites ?? []) visit(child);
    };
    visit(readJson(web));
  }
  const ios = path.join(runtime, "xcodebuild-test.log");
  if (existsSync(ios)) {
    const regex = /Test [Cc]ase '-\[PoddleUITests\.FeatureTests (test_\S+)\]' (passed|failed) \(([\d.]+) seconds\)/g;
    for (const match of readFileSync(ios, "utf8").matchAll(regex)) {
      results.push({ suite: "ios", name: match[1].replace(/^test_/, "").replace("__", ": ").replaceAll("_", " "), status: match[2], seconds: Number(match[3]) });
    }
  }
  return results;
}

// Publish only screenshots, never world.json (contains disposable auth material),
// raw logs or traces. Large diagnostics stay on tinker-desk / in remote-results.
export function copyNightlyScreenshots(runtime, destination, budget = 5 * 1024 * 1024) {
  const images = filesBelow(runtime).filter((file) => file.endsWith(".png") &&
    (file.includes(`${path.sep}ios-failures${path.sep}`) || file.includes(`${path.sep}playwright-results${path.sep}`)));
  const copied = [];
  for (const file of images) {
    const size = statSync(file).size;
    if (size > budget || copied.length >= 12) continue;
    budget -= size;
    const relative = path.join("screenshots", path.relative(runtime, file));
    const target = path.join(destination, relative);
    mkdirSync(path.dirname(target), { recursive: true });
    copyFileSync(file, target);
    copied.push(relative);
  }
  return { screenshots: copied, omittedScreenshots: images.length - copied.length };
}
