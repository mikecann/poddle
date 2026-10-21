import { v, type Infer } from "convex/values";

// Spec §2.5. Every per-show setting is either "use default" (absent) or an
// explicit value. The effective value is `override ?? global`.

export const vNewEpisodeRule = v.union(
  v.literal("inbox"),
  v.literal("upNextTop"),
  v.literal("upNextBottom"),
  v.literal("none"),
);
export type NewEpisodeRule = Infer<typeof vNewEpisodeRule>;

export const vTimePitch = v.union(v.literal("spectral"), v.literal("timeDomain"));
export const vAutoDownload = v.union(
  v.literal("never"),
  v.literal("upNext"),
  v.literal("allNew"),
);
export const vEpisodeOrder = v.union(v.literal("newestFirst"), v.literal("oldestFirst"));

/** Settings a show can override. Keys here are shared with the global row. */
export const showSettingFields = {
  playbackSpeed: v.number(),
  smartSpeed: v.boolean(),
  voiceBoost: v.boolean(),
  timePitch: vTimePitch,
  skipIntroSeconds: v.number(),
  skipOutroSeconds: v.number(),
  newEpisodes: vNewEpisodeRule,
  autoDownload: vAutoDownload,
  keepLatestDownloaded: v.number(),
  notifications: v.boolean(),
  episodeOrder: vEpisodeOrder,
  /** 0 means never. */
  autoArchiveUnplayedAfterDays: v.number(),
  /** Chapter titles (case-insensitive substring) to skip automatically. */
  skipChapterTitles: v.array(v.string()),
};
export type ShowSettings = { [K in keyof typeof showSettingFields]: Infer<(typeof showSettingFields)[K]> };
export type ShowSettingKey = keyof ShowSettings;
export const showSettingKeys = Object.keys(showSettingFields) as ShowSettingKey[];

/** Settings that only exist globally. */
export const globalOnlyFields = {
  skipBackSeconds: v.number(),
  skipForwardSeconds: v.number(),
  remoteNextPrevious: v.union(v.literal("skip"), v.literal("chapter")),
  autoRewind: v.boolean(),
  advanceToNext: v.boolean(),
  upNextAutoDownloadCount: v.number(),
  cellularDownloads: v.union(v.literal("never"), v.literal("ask"), v.literal("always")),
  deletePlayedAfterHours: v.number(),
  storageCapBytes: v.number(),
  sleepFadeOut: v.boolean(),
  shakeToRestartSleep: v.boolean(),
  /** IANA zone used to bucket stats into local days, e.g. "Australia/Sydney". */
  timeZone: v.string(),
};
export const globalSettingFields = { ...showSettingFields, ...globalOnlyFields };
export type GlobalSettings = {
  [K in keyof typeof globalSettingFields]: Infer<(typeof globalSettingFields)[K]>;
};
export type GlobalSettingKey = keyof GlobalSettings;
export const globalSettingKeys = Object.keys(globalSettingFields) as GlobalSettingKey[];

export const DEFAULT_GLOBAL_SETTINGS: GlobalSettings = {
  playbackSpeed: 1.0,
  smartSpeed: true,
  voiceBoost: true,
  timePitch: "timeDomain",
  skipIntroSeconds: 0,
  skipOutroSeconds: 0,
  newEpisodes: "inbox",
  autoDownload: "upNext",
  keepLatestDownloaded: 3,
  notifications: false,
  episodeOrder: "newestFirst",
  autoArchiveUnplayedAfterDays: 0,
  skipChapterTitles: [],
  skipBackSeconds: 15,
  skipForwardSeconds: 30,
  remoteNextPrevious: "skip",
  autoRewind: true,
  advanceToNext: true,
  upNextAutoDownloadCount: 10,
  cellularDownloads: "never",
  deletePlayedAfterHours: 24,
  storageCapBytes: 5 * 1024 * 1024 * 1024,
  sleepFadeOut: true,
  shakeToRestartSleep: true,
  timeZone: "Australia/Sydney",
};

/** Stored per-show overrides: absent = inherit. */
export const podcastOverrideFields = Object.fromEntries(
  showSettingKeys.map((k) => [k, v.optional(showSettingFields[k])]),
) as { [K in ShowSettingKey]: ReturnType<typeof v.optional<(typeof showSettingFields)[K]>> };
export type ShowOverrides = Partial<ShowSettings>;

/** Patch arg for per-show settings: value sets, null clears back to "use default". */
export const podcastSettingsPatch = v.object(
  Object.fromEntries(
    showSettingKeys.map((k) => [k, v.optional(v.union(v.null(), showSettingFields[k]))]),
  ) as {
    [K in ShowSettingKey]: ReturnType<
      typeof v.optional<ReturnType<typeof v.union<[ReturnType<typeof v.null>, (typeof showSettingFields)[K]]>>>
    >;
  },
);
export type ShowSettingsPatch = Infer<typeof podcastSettingsPatch>;

export const globalSettingsPatch = v.object(
  Object.fromEntries(globalSettingKeys.map((k) => [k, v.optional(globalSettingFields[k])])) as {
    [K in GlobalSettingKey]: ReturnType<typeof v.optional<(typeof globalSettingFields)[K]>>;
  },
);
export type GlobalSettingsPatch = Infer<typeof globalSettingsPatch>;

export function resolveShowSettings(
  global: Partial<GlobalSettings> | null | undefined,
  overrides: ShowOverrides | null | undefined,
): ShowSettings & { inherited: ShowSettingKey[] } {
  const g = { ...DEFAULT_GLOBAL_SETTINGS, ...stripUndefined(global ?? {}) };
  const out: Record<string, unknown> = {};
  const inherited: ShowSettingKey[] = [];
  for (const key of showSettingKeys) {
    const o = overrides?.[key];
    if (o === undefined || o === null) {
      out[key] = g[key];
      inherited.push(key);
    } else {
      out[key] = o;
    }
  }
  return { ...(out as ShowSettings), inherited };
}

export function resolveGlobalSettings(global: Partial<GlobalSettings> | null | undefined): GlobalSettings {
  return { ...DEFAULT_GLOBAL_SETTINGS, ...stripUndefined(global ?? {}) };
}

function stripUndefined<T extends object>(obj: T): Partial<T> {
  return Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined)) as Partial<T>;
}
