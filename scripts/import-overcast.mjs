// Import an Overcast "All data" OPML export into a Poddle deployment.
// Usage: node scripts/import-overcast.mjs <deployment url> <opml file> [assumedSpeed] [email]
// Imports into the library of the user with that email (default Mike's), using the
// admin path: the PODDLE_API_TOKEN from ~/.config/poddle/api-token, checked on the server.
import { ConvexHttpClient } from "convex/browser";
import { anyApi } from "convex/server";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const [url, file, speed = "1.0", email = "mike.cann@gmail.com"] = process.argv.slice(2);
const admin = { token: readFileSync(`${homedir()}/.config/poddle/api-token`, "utf8").trim(), email };
const client = new ConvexHttpClient(url);
const api = anyApi;

const uploadUrl = await client.mutation(api.overcastImport.generateUploadUrl, { admin });
const res = await fetch(uploadUrl, { method: "POST", headers: { "Content-Type": "text/xml" }, body: readFileSync(file) });
const { storageId } = await res.json();
const batchId = await client.mutation(api.overcastImport.startOvercastImport, { admin, storageId, assumedSpeed: Number(speed) });
console.log("batch", batchId);

for (;;) {
  const b = await client.query(api.overcastImport.getImport, { admin, batchId });
  const { status, podcasts, podcastsProcessed, feedsFailed, episodes, episodesMatched, ghostEpisodes, playedEpisodes, sessions, estimatedListenSeconds } = b ?? {};
  console.log(new Date().toISOString().slice(11, 19), JSON.stringify({ status, podcasts, podcastsProcessed, feedsFailed, episodes, episodesMatched, ghostEpisodes, playedEpisodes, sessions, hours: Math.round((estimatedListenSeconds ?? 0) / 3600) }));
  if (b && (b.status === "done" || b.status === "failed" || (podcasts && podcastsProcessed === podcasts && b.finishedAt))) { console.log(JSON.stringify(b, null, 1).slice(0, 1500)); break; }
  await new Promise((r) => setTimeout(r, 10000));
}
