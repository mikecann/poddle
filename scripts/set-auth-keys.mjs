// Puts Convex Auth's signing keys (AUTH_PRIVATE_KEY, AUTH_JWKS) on a deployment.
// Skips if they're already set; --force rotates them, which signs everyone out.
// Nothing secret is printed.
//
// Usage: node scripts/set-auth-keys.mjs <dev|prod> [--force]
import { randomUUID } from "node:crypto";
import { exportJWK, exportPKCS8, generateKeyPair } from "jose";
import { isSet, setEnv, target } from "./convex-env.mjs";

const [where, ...rest] = process.argv.slice(2);
const flags = target(where);
const force = rest.includes("--force");

if (!force && isSet("AUTH_JWKS", flags) && isSet("AUTH_PRIVATE_KEY", flags)) {
  console.log(`AUTH_PRIVATE_KEY and AUTH_JWKS are already set on ${where}, left unchanged.`);
  process.exit(0);
}

const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true });
const keys = {
  AUTH_PRIVATE_KEY: Buffer.from(await exportPKCS8(privateKey)).toString("base64"),
  AUTH_JWKS: JSON.stringify({
    keys: [{ ...(await exportJWK(publicKey)), kid: randomUUID(), alg: "RS256", use: "sig" }],
  }),
};
for (const [name, value] of Object.entries(keys)) setEnv(name, value, flags);
console.log(`Set AUTH_PRIVATE_KEY and AUTH_JWKS on ${where}.`);
