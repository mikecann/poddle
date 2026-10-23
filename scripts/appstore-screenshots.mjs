// Uploads App Store screenshots for the iPhone 6.9" display to the version that's being prepared,
// replacing whatever is there, in the order given.
//
// Usage: node scripts/appstore-screenshots.mjs <png> [png...]
//   e.g. node scripts/appstore-screenshots.mjs /tmp/poddle-appstore-shots/{upNext,nowPlaying}.png
// Take the PNGs with scripts/screenshots.sh on "iPhone 17 Pro Max" (1320 x 2868), sample data only.
import { createHash, createPrivateKey, sign } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

const APP_ID = "6825613455";
const LOCALE = "en-AU";
const DISPLAY_TYPE = "APP_IPHONE_67"; // App Store Connect's slot for the 6.9" and 6.7" iPhones
// The App Store Connect API key (as in appstore-metadata.mjs): override with ASC_KEY_ID, ASC_ISSUER_ID
// and ASC_KEY (the .p8 path).
const KEY_ID = process.env.ASC_KEY_ID ?? "7SS6J9F98P";
const ISSUER = process.env.ASC_ISSUER_ID ?? "69a6de6f-a06e-47e3-e053-5b8c7c11a4d1";
const KEY_PATH = process.env.ASC_KEY ?? join(homedir(), ".config/poddle", `AuthKey_${KEY_ID}.p8`);

const files = process.argv.slice(2);
if (!files.length) {
  console.error("Usage: node scripts/appstore-screenshots.mjs <png> [png...]");
  process.exit(1);
}

function token() {
  const key = createPrivateKey(readFileSync(KEY_PATH));
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const head = `${b64({ alg: "ES256", kid: KEY_ID, typ: "JWT" })}.${b64({ iss: ISSUER, iat: now, exp: now + 1200, aud: "appstoreconnect-v1" })}`;
  const sig = sign("sha256", Buffer.from(head), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${head}.${sig}`;
}
const jwt = token();

async function api(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${(await res.text()).slice(0, 400)}`);
  return res.status === 204 ? null : res.json();
}

const versions = await api("GET", `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&limit=10`);
const version = versions.data.find((v) => !["READY_FOR_SALE", "REMOVED_FROM_SALE"].includes(v.attributes.appStoreState)) ?? versions.data[0];
console.log(`version ${version.attributes.versionString} (${version.attributes.appStoreState})`);

const locs = await api("GET", `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`);
const loc = locs.data.find((l) => l.attributes.locale === LOCALE);
if (!loc) throw new Error(`no ${LOCALE} localisation on the version`);

const sets = await api("GET", `/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets`);
let set = sets.data.find((s) => s.attributes.screenshotDisplayType === DISPLAY_TYPE);
if (set) {
  const old = await api("GET", `/v1/appScreenshotSets/${set.id}/appScreenshots`);
  for (const s of old.data) await api("DELETE", `/v1/appScreenshots/${s.id}`);
  if (old.data.length) console.log(`removed ${old.data.length} old screenshot(s)`);
} else {
  set = (await api("POST", "/v1/appScreenshotSets", {
    data: {
      type: "appScreenshotSets",
      attributes: { screenshotDisplayType: DISPLAY_TYPE },
      relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: loc.id } } },
    },
  })).data;
}

for (const file of files) {
  const bytes = readFileSync(file);
  const reserved = (await api("POST", "/v1/appScreenshots", {
    data: {
      type: "appScreenshots",
      attributes: { fileName: basename(file), fileSize: statSync(file).size },
      relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: set.id } } },
    },
  })).data;
  for (const op of reserved.attributes.uploadOperations) {
    const headers = Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value]));
    const res = await fetch(op.url, { method: op.method, headers, body: bytes.subarray(op.offset, op.offset + op.length) });
    if (!res.ok) throw new Error(`upload part of ${file}: ${res.status}`);
  }
  await api("PATCH", `/v1/appScreenshots/${reserved.id}`, {
    data: {
      type: "appScreenshots",
      id: reserved.id,
      attributes: { uploaded: true, sourceFileChecksum: createHash("md5").update(bytes).digest("hex") },
    },
  });
  console.log(`uploaded ${basename(file)}`);
}
console.log(`${files.length} screenshot(s) in the ${DISPLAY_TYPE} set. Apple processes them in a minute or two.`);
