import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// Each feed has its own nextCheckAt (15 min for active shows, backing off for quiet ones).
crons.interval("poll due feeds", { minutes: 15 }, internal.feeds.pollDueFeeds, {});

crons.daily("housekeeping", { hourUTC: 16, minuteUTC: 0 }, internal.maintenance.daily, {});

// Account deletions run as a chain of steps; this restarts any chain that stopped.
crons.interval("resume account deletions", { hours: 1 }, internal.accountDeletion.resumeStalled, {});

// People's own Exa keys pay for "For you", so each person's only refreshes about once a week.
crons.daily("refresh suggestions", { hourUTC: 17, minuteUTC: 0 }, internal.suggestions.refreshDue, {});

export default crons;
