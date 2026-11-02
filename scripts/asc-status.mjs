// Prints the newest iOS App Store versions of an app as JSON, reading only. Threadbear's App Store
// panels call it for Poddle, Walkies, Stash It and Threadbear: they're all on one team and one
// team-wide API key, so it lives here rather than as a copy in each repo.
//
// Usage: node scripts/asc-status.mjs <appId>
//   {"versions":[{"version":"1.0.5","state":"READY_FOR_SALE","created":"2026-10-30T..."}]}
// Override the key as appstore-release.mjs does: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY (the .p8 path).
import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const KEY_ID = process.env.ASC_KEY_ID ?? "7SS6J9F98P";
const ISSUER = process.env.ASC_ISSUER_ID ?? "69a6de6f-a06e-47e3-e053-5b8c7c11a4d1";
const KEY_PATH = process.env.ASC_KEY ?? join(homedir(), ".config/poddle", `AuthKey_${KEY_ID}.p8`);
const appId = process.argv[2];
if (!/^\d+$/.test(appId ?? "")) {
  console.error("Usage: node scripts/asc-status.mjs <appId>");
  process.exit(1);
}

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const head = `${b64({ alg: "ES256", kid: KEY_ID, typ: "JWT" })}.${b64({ iss: ISSUER, iat: now, exp: now + 300, aud: "appstoreconnect-v1" })}`;
const signature = sign("sha256", Buffer.from(head), { key: createPrivateKey(readFileSync(KEY_PATH)), dsaEncoding: "ieee-p1363" }).toString("base64url");

const res = await fetch(`https://api.appstoreconnect.apple.com/v1/apps/${appId}/appStoreVersions?filter[platform]=IOS&limit=4`, {
  headers: { Authorization: `Bearer ${head}.${signature}` },
});
if (!res.ok) {
  console.error(`App Store Connect said ${res.status}: ${(await res.text()).slice(0, 300)}`);
  process.exit(1);
}
const { data } = await res.json();
const versions = data
  .map((v) => ({ version: v.attributes.versionString, state: v.attributes.appVersionState ?? v.attributes.appStoreState, created: v.attributes.createdDate }))
  .sort((a, b) => b.created.localeCompare(a.created));
console.log(JSON.stringify({ versions }));
