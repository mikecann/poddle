import { convexTest } from "convex-test";
import feedbackTest from "@convex-dev/feedback/test";
import chefCloudTest from "@convex-dev/chef-cloud/test";
import { describe, expect, test } from "vitest";
import { api, internal } from "../convex/_generated/api";
import * as chef from "../convex/chef";
import http from "../convex/http";
import schema from "../convex/schema";
import { MIKE, modules, signedIn } from "./helpers";

// Chef (convex/chef.ts): the board ChefKit and the panel talk to, who it thinks
// is calling, and the routes cloud builds talk back on.

function setupChef() {
  const raw = convexTest(schema, modules);
  feedbackTest.register(raw);
  chefCloudTest.register(raw);
  return signedIn(raw, MIKE);
}

// What ChefKit (the iOS sheet) calls, from its README, plus the web panel's basics.
const PUBLIC = [
  "generateUploadUrl", "submitRequestWithMedia", "submitRequest", "mine", "agentState", "answerRefinement",
  "skipRefinement", "amAdmin", "whoAmI", "awaitingApproval", "review", "whatsNew", "buildCard", "shipCandidate",
  "shipApprove", "approvalSnapshot", "approveSnapshot", "recentRuns", "runStatus",
] as const;
const INTERNAL = [
  "chefSetup", "chefSetupStatus", "chefSetAdmin", "chefEnableCloudBuilds", "chefSetPreviewDeployKey",
  "chefSetDeployKey", "chefRepoSetup", "chefIos", "chefStep",
] as const;

// Loading the components' modules takes a few seconds on a cold run.
describe("chef", { timeout: 30_000 }, () => {
  test("exports what ChefKit and the panel call publicly, and the cloud functions internally", () => {
    const fns = chef as unknown as Record<string, { isPublic?: boolean; isInternal?: boolean }>;
    for (const name of PUBLIC) expect(fns[name]?.isPublic, name).toBe(true);
    for (const name of INTERNAL) expect(fns[name]?.isInternal, name).toBe(true);
  });

  test("signed out: not an admin and nobody", async () => {
    const t = setupChef();
    expect(await t.raw.query(api.chef.amAdmin, {})).toBe(false);
    expect(await t.raw.query(api.chef.whoAmI, {})).toBeNull();
  });

  test("a member's request waits for the admin, who sees it with their name", async () => {
    const t = setupChef();
    const mike = await t.userId();
    const friend = t.as("friend@example.com");
    const friendId = await friend.userId();
    await t.run(async (ctx) => ctx.db.patch("users", friendId, { name: "A Friend" }));

    expect(await t.query(api.chef.amAdmin, {})).toBe(false);
    await t.raw.mutation(internal.chef.chefSetAdmin, { userId: mike });
    expect(await t.query(api.chef.amAdmin, {})).toBe(true);
    expect(await t.query(api.chef.whoAmI, {})).toEqual({ userId: mike, admin: true });
    expect(await friend.query(api.chef.amAdmin, {})).toBe(false);

    await friend.mutation(api.chef.submitRequest, { title: "Change the website footer text" });
    const mine = await friend.query(api.chef.mine, {});
    expect(mine.map((r) => r.title)).toEqual(["Change the website footer text"]);

    const waiting = await t.query(api.chef.awaitingApproval, {});
    expect(waiting.map((r) => [r.title, r.from])).toEqual([["Change the website footer text", "A Friend"]]);
    // Members never see the queue.
    expect(await friend.query(api.chef.awaitingApproval, {})).toEqual([]);
  });

  test("an account merged into Mike's is Mike to Chef", async () => {
    const t = setupChef();
    const mike = await t.userId();
    await t.raw.mutation(internal.chef.chefSetAdmin, { userId: mike });
    const other = t.as("mike-apple@privaterelay.example");
    const otherId = await other.userId();
    await t.run(async (ctx) => ctx.db.patch("users", otherId, { mergedInto: mike }));
    expect(await other.query(api.chef.whoAmI, {})).toEqual({ userId: mike, admin: true });
  });

  test("the runner's routes are mounted next to the site, sign-in and share pages", () => {
    const lookup = (path: string, method: "GET" | "POST") => http.lookup(path, method)?.[2];
    expect(lookup("/chef-agent/run", "GET")).toBe("/chef-agent/run");
    expect(lookup("/chef-agent/ai/v1/messages", "POST")).toBe("/chef-agent/ai/v1/messages");
    expect(lookup("/.well-known/apple-app-site-association", "GET")).toBe("/.well-known/apple-app-site-association");
    expect(lookup("/app/signed-in", "GET")).toBe("/app/signed-in");
    expect(lookup("/e/abc", "GET")).toBe("/e/*");
    expect(lookup("/s/abc", "GET")).toBe("/s/*");
    expect(lookup("/me", "GET")).toBe("/*");
  });
});
