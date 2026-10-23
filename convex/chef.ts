// Chef: the panel's API (exposeChefApi) and the CLI's admin functions (chefAdmin).
// The feedback board alone, as `npx chef init --no-cloud` writes it, pointed at
// currentUserId (README, "Chef (feature requests)").
import { chefAdmin, exposeChefApi } from "@convex-dev/feedback";
import { components } from "./_generated/api";
import type { QueryCtx } from "./_generated/server";
import { currentUserId } from "./lib/identity";

// The build and ship functions (buildState, buildCard, shipCandidate, ...) stay
// exported even with no cloud builds: ChefKit and the web panel still call them,
// and they answer "cloud builds are off" or nothing rather than failing.
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

// For `npx chef` (through `npx convex run`): name the app's admin, and the
// upgrade step for old agent keys. Internal.
export const {
  chefSetAdmin, chefMigrateAgentKeys,
} = chefAdmin(components.feedback);
