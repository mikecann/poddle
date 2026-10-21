/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as apns from "../apns.js";
import type * as crons from "../crons.js";
import type * as devices from "../devices.js";
import type * as directory from "../directory.js";
import type * as directoryCache from "../directoryCache.js";
import type * as episodes from "../episodes.js";
import type * as feedActions from "../feedActions.js";
import type * as feeds from "../feeds.js";
import type * as importActions from "../importActions.js";
import type * as lib_auth from "../lib/auth.js";
import type * as lib_feedFetch from "../lib/feedFetch.js";
import type * as lib_feedParser from "../lib/feedParser.js";
import type * as lib_ingest from "../lib/ingest.js";
import type * as lib_opml from "../lib/opml.js";
import type * as lib_parse from "../lib/parse.js";
import type * as lib_queue from "../lib/queue.js";
import type * as lib_rollups from "../lib/rollups.js";
import type * as lib_rows from "../lib/rows.js";
import type * as lib_settings from "../lib/settings.js";
import type * as lib_settingsDb from "../lib/settingsDb.js";
import type * as lib_state from "../lib/state.js";
import type * as lib_statsMath from "../lib/statsMath.js";
import type * as lib_validators from "../lib/validators.js";
import type * as maintenance from "../maintenance.js";
import type * as overcastImport from "../overcastImport.js";
import type * as podcasts from "../podcasts.js";
import type * as queue from "../queue.js";
import type * as sessions from "../sessions.js";
import type * as settings from "../settings.js";
import type * as stats from "../stats.js";
import type * as sync from "../sync.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  apns: typeof apns;
  crons: typeof crons;
  devices: typeof devices;
  directory: typeof directory;
  directoryCache: typeof directoryCache;
  episodes: typeof episodes;
  feedActions: typeof feedActions;
  feeds: typeof feeds;
  importActions: typeof importActions;
  "lib/auth": typeof lib_auth;
  "lib/feedFetch": typeof lib_feedFetch;
  "lib/feedParser": typeof lib_feedParser;
  "lib/ingest": typeof lib_ingest;
  "lib/opml": typeof lib_opml;
  "lib/parse": typeof lib_parse;
  "lib/queue": typeof lib_queue;
  "lib/rollups": typeof lib_rollups;
  "lib/rows": typeof lib_rows;
  "lib/settings": typeof lib_settings;
  "lib/settingsDb": typeof lib_settingsDb;
  "lib/state": typeof lib_state;
  "lib/statsMath": typeof lib_statsMath;
  "lib/validators": typeof lib_validators;
  maintenance: typeof maintenance;
  overcastImport: typeof overcastImport;
  podcasts: typeof podcasts;
  queue: typeof queue;
  sessions: typeof sessions;
  settings: typeof settings;
  stats: typeof stats;
  sync: typeof sync;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
