// Chef: the panel's API (exposeChefApi) and cloud builds (chefCloud).
// Written by `npx chef init --cloud`, then pointed at currentUserId and given
// Poddle's options (README, "Chef (feature requests)").
import { exposeChefApi } from "@convex-dev/feedback";
import { chefCloud } from "@convex-dev/chef-cloud";
import { components } from "./_generated/api";
import type { QueryCtx } from "./_generated/server";
import { currentUserId } from "./lib/identity";

export const {
  agentState, listPublicItems, submitRequest, upvoteRequest, answerRefinement, skipRefinement,
  generateUploadUrl, submitRequestWithMedia, listAttachments,
  mine, amAdmin, whoAmI, awaitingApproval, review, whatsNew,
  approvalSnapshot, prepareApproval, approveSnapshot, runLogs, skillFeedback,
  approvalRequests, approveApprovalRequest, declineApprovalRequest, runScreenshots,
  runStatus, recentRuns, buildState, buildInCloud,
  shipCandidate, shipDiffChunk, shipApprove,
  retryRun, appLearnings, forgetLearning, buildCosts, applyRepair, buildCard,
  previewDataMode, setPreviewData, splitFromBatch,
} = exposeChefApi(components.feedback, {
  // Who is calling (null = signed out). currentUserId follows merged accounts, so
  // signing in with Apple or Google is the same person to Chef too.
  getUserId: (ctx) => currentUserId(ctx as unknown as QueryCtx),
  getUserName: async (ctx, userId) => {
    const user = await (ctx as unknown as QueryCtx).db.get("users", userId as never);
    return user?.name ?? user?.email ?? null;
  },
});

// Cloud builds: the build steps and sweeps, setup and the on switch, the
// deploy keys, and the app's repo on Code Storage. All internal; the
// workflows, the feedback component and `npx chef` (through `npx convex run`) call them.
export const {
  chefStep, chefSweep, chefCleanup, chefRunStart, chefShipStart, chefReconcile,
  chefSetup, chefSetupStatus, chefEnableCloudBuilds, chefDisableCloudBuilds, chefCreateWorkerKey,
  chefSetAdmin, chefSetPreviewDeployKey, chefSetDeployKey, chefCancelRun, chefMigrateAgentKeys,
  chefRepoSetup, chefRepoUploadUrl, chefRepoPushPack, chefGitCredential, chefRepoRefs, chefRepairApply, chefIos, chefPlanBatches,
} = chefCloud(components.feedback, components.chefCloud, {
  appName: "Poddle",
  repoName: "poddle",
  // The website (web/) is the only thing a build can preview: the iOS app can't
  // compile in the sandbox (`npx chef ios` tries it on the phone instead).
  frontend: { command: ["npm", "run", "web:build"], urlEnvVar: "VITE_CONVEX_URL", distDir: "web/dist" },
  // The live site "Ship it" checks. Chef's default, https://<name>.convex.site,
  // misses the region in Poddle's Sydney URLs: poddle.mikecann.app on prod, the
  // deployment's own site on dev.
  ship: { siteUrl: process.env.PODDLE_SITE_URL || process.env.CONVEX_SITE_URL },
});
