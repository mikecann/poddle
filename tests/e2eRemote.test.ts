import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, chmodSync } from "node:fs";
import path from "node:path";
import { copyNightlyScreenshots, packagePins, scenarioResults, quote, relocatePackages, PLAYWRIGHT_CACHE_DIR, webE2eEnv } from "../scripts/e2e-remote-lib.mjs";

const scratch = path.resolve("e2e/.runtime/remote-tests");
const folders: string[] = [];
function temp() {
  mkdirSync(scratch, { recursive: true });
  const folder = mkdtempSync(path.join(scratch, "case-"));
  folders.push(folder);
  return folder;
}
afterEach(() => { for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true }); });

describe("the web suite's Playwright cache", () => {
  // macOS deletes files in the system temp folder that haven't been opened for a few days.
  // It took the .map beside a cached share-pages spec on tinker-desk, and Playwright kept
  // using the .js without it, so every test there got the wrong line and failed with
  // "bddTestData not found". The cache has to live somewhere macOS leaves alone.
  it("lives under e2e/.runtime, not the system temp folder", () => {
    expect(PLAYWRIGHT_CACHE_DIR.startsWith("e2e/.runtime/")).toBe(true);
    expect(webE2eEnv({ HOME: "/x" })).toEqual({ HOME: "/x", PWTEST_CACHE_DIR: path.resolve(PLAYWRIGHT_CACHE_DIR) });
  });
  it("is used by every way of running the web suite", () => {
    const pkg = JSON.parse(readFileSync("package.json", "utf8"));
    expect(pkg.scripts["test:e2e:web"]).toContain(`PWTEST_CACHE_DIR=${PLAYWRIGHT_CACHE_DIR} playwright test`);
    expect(readFileSync("scripts/run-e2e.mjs", "utf8")).toContain("webE2eEnv(");
  });
});

describe("remote e2e reporting", () => {
  it("keeps web and app failures alongside passing and skipped scenarios", () => {
    const runtime = temp();
    writeFileSync(path.join(runtime, "web-results.json"), JSON.stringify({ suites: [{ suites: [{ specs: [
      { title: "Sign in", tests: [{ status: "expected" }] },
      { title: "Expired tab", tests: [{ status: "unexpected" }] },
      { title: "Pending", tests: [{ status: "skipped" }] },
    ] }] }] }));
    writeFileSync(path.join(runtime, "xcodebuild-test.log"), [
      "Test Case '-[PoddleUITests.FeatureTests test_auth__sign_in]' passed (1.123 seconds).",
      "Test Case '-[PoddleUITests.FeatureTests test_queue__undo]' failed (4.321 seconds).",
      "** TEST FAILED **",
    ].join("\n"));
    expect(scenarioResults(runtime)).toEqual([
      { suite: "web", name: "Sign in", status: "passed" },
      { suite: "web", name: "Expired tab", status: "failed" },
      { suite: "web", name: "Pending", status: "skipped" },
      { suite: "ios", name: "auth: sign in", status: "passed", seconds: 1.123 },
      { suite: "ios", name: "queue: undo", status: "failed", seconds: 4.321 },
    ]);
  });
  it("only publishes bounded failure screenshots, leaving auth files and dumps private", () => {
    const runtime = temp();
    const output = temp();
    mkdirSync(path.join(runtime, "ios-failures"));
    writeFileSync(path.join(runtime, "ios-failures/small.png"), "123");
    writeFileSync(path.join(runtime, "ios-failures/large.png"), "1234567");
    writeFileSync(path.join(runtime, "ios-failures/tree.txt"), "accessibility");
    writeFileSync(path.join(runtime, "world.json"), "private");
    writeFileSync(path.join(runtime, "unrelated.png"), "private");
    expect(copyNightlyScreenshots(runtime, output, 5)).toEqual({
      screenshots: ["screenshots/ios-failures/small.png"], omittedScreenshots: 1,
    });
  });
  it("relocates read-only SPM git alternates and binary artifacts after a machine copy", () => {
    const source = temp();
    const info = path.join(source, "checkouts/convex-swift/.git/objects/info");
    mkdirSync(info, { recursive: true });
    mkdirSync(path.join(source, "repositories/convex-swift-123/objects"), { recursive: true });
    const alternates = path.join(info, "alternates");
    writeFileSync(alternates, "/tmp/old/SourcePackages/repositories/convex-swift-123/objects\n");
    chmodSync(alternates, 0o444);
    writeFileSync(path.join(source, "workspace-state.json"), JSON.stringify({ object: {
      artifacts: [{ path: "/tmp/old/SourcePackages/checkouts/convex-swift/library.xcframework" }],
    } }));
    relocatePackages(source);
    expect(readFileSync(alternates, "utf8")).toBe(`${source}/repositories/convex-swift-123/objects\n`);
    const state = JSON.parse(readFileSync(path.join(source, "workspace-state.json"), "utf8"));
    expect(state.object.artifacts[0].path).toBe(`${source}/checkouts/convex-swift/library.xcframework`);
  });
  it("rejects a ChefKit project pin that disagrees with the package lock", () => {
    const repo = temp();
    mkdirSync(path.join(repo, "Packages/PoddleKit"), { recursive: true });
    mkdirSync(path.join(repo, "Poddle.xcodeproj"));
    writeFileSync(path.join(repo, "Packages/PoddleKit/Package.resolved"), JSON.stringify({ pins: [{ identity: "chef-cloud", state: { revision: "abc" } }] }));
    writeFileSync(path.join(repo, "Poddle.xcodeproj/project.pbxproj"), "revision = def;");
    expect(() => packagePins(repo)).toThrow("disagree");
  });
  it("quotes SSH arguments containing apostrophes and shell substitutions literally", () => {
    expect(quote("Mike's $(touch bad) `whoami`")).toBe("'Mike'\\''s $(touch bad) `whoami`'");
  });
});
