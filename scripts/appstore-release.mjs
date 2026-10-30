// Releases an approved version of Poddle to the App Store (versions are submitted with a manual release).
//
// Usage: node scripts/appstore-release.mjs <version> [--release]
//   prints the version's App Store state; with --release, and only once Apple has approved it
//   (PENDING_DEVELOPER_RELEASE), asks App Store Connect to release it. Exits 0 once it's released
//   or on its way out, 2 while it's still waiting for review, 1 on anything else.
// The App Store Connect API key (as in appstore-submit.mjs): override with ASC_KEY_ID, ASC_ISSUER_ID
// and ASC_KEY (the .p8 path).
import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const APP_ID = "6825613455";
const KEY_ID = process.env.ASC_KEY_ID ?? "7SS6J9F98P";
const ISSUER = process.env.ASC_ISSUER_ID ?? "69a6de6f-a06e-47e3-e053-5b8c7c11a4d1";
const KEY_PATH = process.env.ASC_KEY ?? join(homedir(), ".config/poddle", `AuthKey_${KEY_ID}.p8`);
const [version] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const release = process.argv.includes("--release");
if (!version) {
  console.error("Usage: node scripts/appstore-release.mjs <version> [--release]");
  process.exit(1);
}

function token() {
  const key = createPrivateKey(readFileSync(KEY_PATH));
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const head = `${b64({ alg: "ES256", kid: KEY_ID, typ: "JWT" })}.${b64({ iss: ISSUER, iat: now, exp: now + 1200, aud: "appstoreconnect-v1" })}`;
  return `${head}.${sign("sha256", Buffer.from(head), { key, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
}

async function api(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${(await res.text()).slice(0, 600)}`);
  return res.status === 204 ? null : res.json();
}

const found = await api("GET", `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&filter[versionString]=${version}`);
const v = found.data[0];
if (!v) {
  console.error(`No iOS version ${version}`);
  process.exit(1);
}
const state = v.attributes.appVersionState ?? v.attributes.appStoreState;
console.log(`${version}: ${state}`);

if (["READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "PROCESSING_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE"].includes(state)) process.exit(0);
if (["WAITING_FOR_REVIEW", "IN_REVIEW", "WAITING_FOR_EXPORT_COMPLIANCE"].includes(state)) process.exit(2);
if (state !== "PENDING_DEVELOPER_RELEASE") process.exit(1); // rejected, or never submitted: needs a person
if (!release) process.exit(0);

await api("POST", "/v1/appStoreVersionReleaseRequests", {
  data: { type: "appStoreVersionReleaseRequests", relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: v.id } } } },
});
console.log(`${version}: release requested. The listing usually updates within a few minutes.`);
