import { describe, expect, test } from "vitest";
import { api } from "../convex/_generated/api";
import { DEFAULT_GLOBAL_SETTINGS, resolveShowSettings } from "../convex/lib/settings";
import { setup, TOKEN } from "./helpers";
import { BASE, seedShow } from "./seed";

describe("resolveShowSettings", () => {
  test("override ?? global, with inherited keys listed", () => {
    const r = resolveShowSettings({ ...DEFAULT_GLOBAL_SETTINGS, playbackSpeed: 1.5 }, { smartSpeed: false, voiceBoost: undefined });
    expect(r.playbackSpeed).toBe(1.5);
    expect(r.smartSpeed).toBe(false);
    expect(r.voiceBoost).toBe(true);
    expect(r.inherited).toContain("playbackSpeed");
    expect(r.inherited).not.toContain("smartSpeed");
  });

  test("defaults from decisions.md", () => {
    const r = resolveShowSettings(null, null);
    expect(r).toMatchObject({ playbackSpeed: 1, smartSpeed: true, voiceBoost: true, newEpisodes: "inbox", notifications: false });
    expect(DEFAULT_GLOBAL_SETTINGS).toMatchObject({ skipBackSeconds: 15, skipForwardSeconds: 30, autoRewind: true, remoteNextPrevious: "skip" });
  });

  test("the speed-up method defaults to the speech-tuned stretcher, and a show can override it", () => {
    expect(resolveShowSettings(null, null).timePitch).toBe("timeDomain");
    const r = resolveShowSettings(null, { timePitch: "spectral" });
    expect(r.timePitch).toBe("spectral");
    expect(r.inherited).not.toContain("timePitch");
  });
});

describe("settings functions", () => {
  test("a show inherits global changes live until it overrides, and null resets", async () => {
    const t = setup();
    const { podcastId } = await seedShow(t, 1);
    await t.mutation(api.settings.updateGlobal, { token: TOKEN, patch: { playbackSpeed: 1.8 }, at: BASE });
    expect((await t.query(api.settings.resolved, { token: TOKEN, podcastId })).playbackSpeed).toBe(1.8);

    await t.mutation(api.settings.updatePodcast, { token: TOKEN, podcastId, patch: { playbackSpeed: 1.25, smartSpeed: false }, at: BASE + 1 });
    await t.mutation(api.settings.updateGlobal, { token: TOKEN, patch: { playbackSpeed: 2.0, smartSpeed: true }, at: BASE + 2 });
    const r = await t.query(api.settings.forPodcast, { token: TOKEN, podcastId });
    expect(r.overrides).toEqual({ playbackSpeed: 1.25, smartSpeed: false });
    expect(r.resolved).toMatchObject({ playbackSpeed: 1.25, smartSpeed: false, voiceBoost: true });

    await t.mutation(api.settings.updatePodcast, { token: TOKEN, podcastId, patch: { playbackSpeed: null }, at: BASE + 3 });
    expect((await t.query(api.settings.resolved, { token: TOKEN, podcastId })).playbackSpeed).toBe(2.0);
  });

  test("per-field last-writer-wins", async () => {
    const t = setup();
    const { podcastId } = await seedShow(t, 1);
    await t.mutation(api.settings.updatePodcast, { token: TOKEN, podcastId, patch: { playbackSpeed: 1.5 }, at: BASE + 10 });
    const applied = await t.mutation(api.settings.updatePodcast, {
      token: TOKEN,
      podcastId,
      patch: { playbackSpeed: 1.1, voiceBoost: false },
      at: BASE + 5,
    });
    expect(applied).toEqual(["voiceBoost"]);
    const r = await t.query(api.settings.forPodcast, { token: TOKEN, podcastId });
    expect(r.overrides).toEqual({ playbackSpeed: 1.5, voiceBoost: false });
    expect((await t.query(api.settings.getGlobal, { token: TOKEN })).timeZone).toBe("Australia/Sydney");
  });
});

describe("settings queries with a stored global row", () => {
  test("getGlobal and forPodcast return only setting fields once the row exists", async () => {
    const t = setup();
    await t.mutation(api.settings.updateGlobal, { token: TOKEN, at: BASE, patch: { playbackSpeed: 2 } });
    const global = await t.query(api.settings.getGlobal, { token: TOKEN });
    expect(global.playbackSpeed).toBe(2);
    expect(global).not.toHaveProperty("_id");
    expect(global).not.toHaveProperty("fieldTimes");
    const { podcastId } = await seedShow(t, 1);
    const show = await t.query(api.settings.forPodcast, { token: TOKEN, podcastId });
    expect(show.resolved.playbackSpeed).toBe(2);
  });
});

