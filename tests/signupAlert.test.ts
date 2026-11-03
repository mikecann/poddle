import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { internal } from "../convex/_generated/api";
import { MIKE, setup } from "./helpers";

const google = (email: string, name?: string) => ({
  name: "google" as const,
  accountId: email,
  profile: { id: email, email, emailVerified: true, name },
});

describe("telling Mike about sign-ups", () => {
  beforeEach(() => {
    process.env.PODDLE_OPEN_SIGNUP = "1";
    process.env.PODDLE_OWNER_EMAIL = MIKE;
  });
  afterEach(() => {
    delete process.env.PODDLE_OPEN_SIGNUP;
    delete process.env.PODDLE_OWNER_EMAIL;
  });

  const scheduled = (t: ReturnType<typeof setup>) => t.run(async (ctx) => await ctx.db.system.query("_scheduled_functions").collect());

  test("a new person sets off one alert, with their first name and no email", async () => {
    const t = setup();
    await t.userId();
    const userId = await t.raw.mutation(internal.users.createUserGoogle, { provider: google("sam@example.com", "Sam Smith") });
    const jobs = await scheduled(t);
    expect(jobs.map((j) => j.name)).toEqual(["apns:sendSignupAlert"]);
    const alert = await t.run((ctx) => ctx.runQuery(internal.users.signupAlert, { userId }));
    expect(alert).toEqual({ ownerId: await t.userId(), body: "Sam just signed up. That's 2 on Poddle." });
  });

  test("signing in again doesn't", async () => {
    const t = setup();
    await t.as("sam@example.com").userId();
    await t.run(async (ctx) => {
      const sam = await ctx.db.query("users").withIndex("by_email", (q) => q.eq("email", "sam@example.com")).unique();
      await ctx.db.patch(sam!._id, { emailVerified: true });
    });
    await t.raw.mutation(internal.users.createUserGoogle, { provider: google("sam@example.com", "Sam") });
    expect(await scheduled(t)).toEqual([]);
  });

  test("no alert about Mike himself, or when no owner is set", async () => {
    const t = setup();
    const mike = await t.userId();
    expect(await t.run((ctx) => ctx.runQuery(internal.users.signupAlert, { userId: mike }))).toBeNull();
    const sam = await t.as("sam@example.com").userId();
    delete process.env.PODDLE_OWNER_EMAIL;
    expect(await t.run((ctx) => ctx.runQuery(internal.users.signupAlert, { userId: sam }))).toBeNull();
  });
});
