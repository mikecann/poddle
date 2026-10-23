import { convexTest } from "convex-test";
import feedbackTest from "@convex-dev/feedback/test";
import { describe, expect, test } from "vitest";
import { api, internal } from "../convex/_generated/api";
import * as chef from "../convex/chef";
import http from "../convex/http";
import schema from "../convex/schema";
import { MIKE, modules, signedIn } from "./helpers";

// Chef (convex/chef.ts): the feedback board ChefKit and the web panel talk to,
// and who it thinks is calling. There are no cloud builds (docs/decisions.md).

function setupChef() {
  const raw = convexTest(schema, modules);
  feedbackTest.register(raw);
  return signedIn(raw, MIKE);
}

// What ChefKit (the iOS sheet) calls, from its README, plus the web panel's basics.
// The build and ship ones are still exported so neither client calls a missing function.
const PUBLIC = [
  "generateUploadUrl", "submitRequestWithMedia", "submitRequest", "mine", "agentState", "answerRefinement",
  "skipRefinement", "amAdmin", "whoAmI", "awaitingApproval", "review", "whatsNew", "listPublicItems",
  "upvoteRequest", "approvalSnapshot", "prepareApproval", "approveSnapshot", "buildState", "buildCard",
  "shipCandidate", "shipApprove", "recentRuns", "runStatus",
] as const;
const INTERNAL = ["chefSetAdmin", "chefMigrateAgentKeys"] as const;
// Cloud builds' own functions, which are gone.
const GONE = ["chefSetup", "chefEnableCloudBuilds", "chefSetDeployKey", "chefRepoSetup", "chefIos", "chefStep"];

// Loading the component's modules takes a few seconds on a cold run.
describe("chef", { timeout: 30_000 }, () => {
  test("exports what ChefKit and the panel call publicly, the admin functions internally, and no cloud functions", () => {
    const fns = chef as unknown as Record<string, { isPublic?: boolean; isInternal?: boolean } | undefined>;
    for (const name of PUBLIC) expect(fns[name]?.isPublic, name).toBe(true);
    for (const name of INTERNAL) expect(fns[name]?.isInternal, name).toBe(true);
    for (const name of GONE) expect(fns[name], name).toBeUndefined();
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

  test("the admin approves a request onto the board, people vote on it, and a rejected one stays off", async () => {
    const t = setupChef();
    await t.raw.mutation(internal.chef.chefSetAdmin, { userId: await t.userId() });
    const friend = t.as("friend@example.com");
    const other = t.as("other@example.com");
    await friend.mutation(api.chef.submitRequest, { title: "Sleep timer to the end of the chapter" });
    await friend.mutation(api.chef.submitRequest, { title: "Make it purple" });
    const waiting = await t.query(api.chef.awaitingApproval, {});
    const idOf = (title: string) => waiting.find((r) => r.title === title)!.id;
    const chapter = idOf("Sleep timer to the end of the chapter");
    const purple = idOf("Make it purple");

    // Only the admin approves, through the snapshot the panel shows.
    await expect(friend.mutation(api.chef.prepareApproval, { id: chapter })).rejects.toThrow();
    const snapshot = await t.mutation(api.chef.prepareApproval, { id: chapter });
    expect(await t.query(api.chef.approvalSnapshot, { snapshotId: snapshot.snapshotId })).toMatchObject({
      title: "Sleep timer to the end of the chapter",
      approved: false,
    });
    await t.mutation(api.chef.approveSnapshot, snapshot);
    await expect(friend.mutation(api.chef.review, { id: purple, approve: false })).rejects.toThrow();
    await t.mutation(api.chef.review, { id: purple, approve: false });
    expect(await t.query(api.chef.awaitingApproval, {})).toEqual([]);

    // One vote each, however many times they press it.
    await other.mutation(api.chef.upvoteRequest, { id: chapter });
    await other.mutation(api.chef.upvoteRequest, { id: chapter });
    await t.mutation(api.chef.upvoteRequest, { id: chapter });
    // The package types this one as any.
    const board: { title: string; voteCount: number }[] = await friend.query(api.chef.listPublicItems, {});
    expect(board.map((r) => [r.title, r.voteCount])).toEqual([["Sleep timer to the end of the chapter", 2]]);

    // With no cloud builds the approved request just waits: nothing claims it.
    expect(await t.query(api.chef.buildState, {})).toMatchObject({ cloudEnabled: false, busy: false });
    expect(await t.mutation(api.chef.buildInCloud, {})).toMatchObject({ outcome: "disabled" });
    expect(await t.query(api.chef.recentRuns, {})).toEqual([]);
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

  test("no build runner routes: /chef-agent/* is just the website", () => {
    const lookup = (path: string, method: "GET" | "POST") => http.lookup(path, method)?.[2];
    expect(lookup("/chef-agent/run", "GET")).toBe("/*");
    expect(lookup("/chef-agent/ai/v1/messages", "POST")).toBeUndefined();
    expect(lookup("/chef-agent/finish", "POST")).toBeUndefined();
    expect(lookup("/.well-known/apple-app-site-association", "GET")).toBe("/.well-known/apple-app-site-association");
    expect(lookup("/app/signed-in", "GET")).toBe("/app/signed-in");
    expect(lookup("/e/abc", "GET")).toBe("/e/*");
    expect(lookup("/s/abc", "GET")).toBe("/s/*");
    expect(lookup("/me", "GET")).toBe("/*");
  });
});
