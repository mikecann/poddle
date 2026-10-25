import { v, type Infer } from "convex/values";

// Spec §2.5. Every per-show setting is either "use default" (absent) or an
// explicit value. The effective value is `override ?? global`.

// Where a show's new episodes go. `inbox` is deprecated (decisions.md: there's no
// Inbox any more). It's still accepted so old rows and old clients validate, but
// it always behaves as `upNextBottom`: see `effectiveRule`.
export const vNewEpisodeRule = v.union(
  /** @deprecated Behaves as `upNextBottom`. */
  v.literal("inbox"),
  v.literal("upNextTop"),
  v.literal("upNextBottom"),
  v.literal("none"),
);
export type NewEpisodeRule = Infer<typeof vNewEpisodeRule>;

/** A stored (deprecated) `inbox` rule means `upNextBottom`. */
export function effectiveRule(rule: NewEpisodeRule): Exclude<NewEpisodeRule, "inbox"> {
  return rule === "inbox" ? "upNextBottom" : rule;
}

export const vTimePitch = v.union(v.literal("spectral"), v.literal("timeDomain"));
export const vAutoDownload = v.union(
  v.literal("never"),
  v.literal("upNext"),
  v.literal("allNew"),
);
export const vEpisodeOrder = v.union(v.literal("newestFirst"), v.literal("oldestFirst"));

/**
 * "Keep latest" (decisions.md, 25 Oct 2026): a show's newest N episodes stay in Up Next and on
 * the device, like Overcast's episode limit, or `"all"` for no limit. Old apps read the field
 * with `.number`, so `"all"` looks like "not set" to them and they keep their built-in 3. A
 * number for "all" (0 or -1) would make them delete every download outside Up Next.
 */
export const vKeepLatest = v.union(v.number(), v.literal("all"));
export type KeepLatest = Infer<typeof vKeepLatest>;

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
  /** Per show. The global default lives in `keepLatest`, not here: see `globalKeyFor`. */
  keepLatestDownloaded: vKeepLatest,
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
  /** The default for every show's `keepLatestDownloaded`. */
  keepLatest: vKeepLatest,
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
  newEpisodes: "upNextBottom",
  autoDownload: "upNext",
  // Only old apps read the global row's `keepLatestDownloaded`, for their downloads. It used to
  // be the default for every show, but stored values were set when it only meant downloads, so
  // the default "Keep latest" moved to `keepLatest` (decisions.md, 25 Oct 2026).
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
  keepLatest: "all",
};

/**
 * Where a show setting's default comes from on the global row: the same key, except
 * `keepLatestDownloaded`, whose default is `keepLatest` (see DEFAULT_GLOBAL_SETTINGS).
 */
export function globalKeyFor(key: ShowSettingKey): GlobalSettingKey {
  return key === "keepLatestDownloaded" ? "keepLatest" : key;
}

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
  const g = resolveGlobalSettings(global);
  const out: Record<string, unknown> = {};
  const inherited: ShowSettingKey[] = [];
  for (const key of showSettingKeys) {
    const o = overrides?.[key];
    if (o === undefined || o === null) {
      out[key] = g[globalKeyFor(key)];
      inherited.push(key);
    } else {
      out[key] = key === "newEpisodes" ? effectiveRule(o as NewEpisodeRule) : o;
    }
  }
  return { ...(out as ShowSettings), inherited };
}

/**
 * Defaults with the stored values on top. Only known setting keys are copied, so a
 * stored document's `_id`, `fieldTimes` etc. never leak into a return value.
 */
export function resolveGlobalSettings(global: Partial<GlobalSettings> | null | undefined): GlobalSettings {
  const out: Record<string, unknown> = { ...DEFAULT_GLOBAL_SETTINGS };
  for (const key of Object.keys(DEFAULT_GLOBAL_SETTINGS) as (keyof GlobalSettings)[]) {
    const value = global?.[key];
    if (value !== undefined) out[key] = value;
  }
  out.newEpisodes = effectiveRule(out.newEpisodes as NewEpisodeRule);
  return out as GlobalSettings;
}
