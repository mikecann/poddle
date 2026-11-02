import { describe, expect, test } from "vitest";
import { internal } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { setup, type T } from "./helpers";

const today = () => new Date().toISOString().slice(0, 10);
const DAY = 86_400_000;

const counters = { speedSaved: 0, smartSaved: 0, rateContent: 0, episodesStarted: 0 };

async function listened(t: T, userId: Id<"users">, day: string, hours: { live?: number; imported?: number; sessions?: number; completed?: number }) {
  const wall = ((hours.live ?? 0) + (hours.imported ?? 0)) * 3600;
  const shared = {
    ...counters,
    userId,
    wall,
    content: wall,
    estimatedWall: (hours.imported ?? 0) * 3600,
    sessions: hours.sessions ?? 1,
    episodesCompleted: hours.completed ?? 0,
  };
  await t.run(async (ctx) => {
    await ctx.db.insert("statsDays", { ...shared, day, liveHours: new Array(24).fill(0) });
    await ctx.db.insert("statsMonths", { ...shared, month: day.slice(0, 7), heatmap: new Array(7 * 24).fill(0) });
  });
}

describe("adminStats:overview", () => {
  test("counts real people only", async () => {
    const t = setup();
    await t.userId();
    await t.run(async (ctx) => {
      const other = await ctx.db.insert("users", { email: "merged@example.com" });
      await ctx.db.insert("users", { email: "merged2@example.com", mergedInto: other });
      await ctx.db.insert("users", { deletedAt: Date.now() });
      await ctx.db.insert("users", { email: "bot@example.com", isTest: true });
    });
    const stats = await t.run((ctx) => ctx.runQuery(internal.adminStats.overview, {}));
    expect(stats.users).toBe(2);
    expect(stats.newUsers7d).toBe(2);
  });

  test("keeps time really heard apart from Overcast history, and only the first makes someone active", async () => {
    const t = setup();
    const mike = await t.userId();
    const importer = await t.as("importer@example.com").userId();
    await listened(t, mike, today(), { live: 2, sessions: 3, completed: 1 });
    await listened(t, importer, today(), { imported: 50, sessions: 40, completed: 40 });

    const stats = await t.run((ctx) => ctx.runQuery(internal.adminStats.overview, {}));
    expect(stats.last7d).toEqual({ activeUsers: 1, liveHours: 2, listens: 3, completed: 1 });
    expect(stats.allTime).toEqual({ liveHours: 2, importedHours: 50, listens: 43, completed: 41 });
  });

  test("old listening counts towards all time but not the recent windows", async () => {
    const t = setup();
    const mike = await t.userId();
    await listened(t, mike, new Date(Date.now() - 20 * DAY).toISOString().slice(0, 10), { live: 4 });
    await listened(t, mike, new Date(Date.now() - 90 * DAY).toISOString().slice(0, 10), { live: 8 });

    const stats = await t.run((ctx) => ctx.runQuery(internal.adminStats.overview, {}));
    expect(stats.last7d.liveHours).toBe(0);
    expect(stats.last30d).toMatchObject({ activeUsers: 1, liveHours: 4 });
    expect(stats.allTime.liveHours).toBe(12);
  });
});
