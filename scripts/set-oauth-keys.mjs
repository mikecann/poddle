// Puts the Apple and Google sign-in settings on a Convex deployment without
// printing any of them.
//
// Usage: node scripts/set-oauth-keys.mjs <dev|prod> [path to oauth.json] [--placeholders]
//
// oauth.json (keep it out of git, e.g. in ~/Downloads, and delete it after):
// {
//   "appleServicesId": "com.mikecann.poddle.signin",
//   "appleKeyId": "ABC123DEFG",
//   "appleKeyFile": "/Users/you/Downloads/AuthKey_ABC123DEFG.p8",
//   "googleClientId": "1234-abc.apps.googleusercontent.com",
//   "googleClientSecret": "GOCSPX-..."
// }
// Anything missing from the file is skipped, so a file with just appleKeyId and
// appleKeyFile swaps the Apple key.
//
// Convex Auth won't deploy until every provider variable has a value.
// --placeholders sets each one that isn't set yet to "not-configured", so the
// deployment runs before Apple and Google are set up; signing in with a
// provider that still has placeholders fails, nothing else does.
import { readFileSync } from "node:fs";
import { isSet, setEnv, target } from "./convex-env.mjs";

const args = process.argv.slice(2);
const placeholders = args.includes("--placeholders");
const [where, file] = args.filter((a) => !a.startsWith("--"));
const flags = target(where);
if (!file && !placeholders) {
  console.error("Usage: node scripts/set-oauth-keys.mjs <dev|prod> [oauth.json] [--placeholders]");
  process.exit(1);
}

const config = file ? JSON.parse(readFileSync(file, "utf8")) : {};
const values = {
  AUTH_APPLE_CLIENT_ID: config.appleServicesId,
  AUTH_APPLE_TEAM_ID: config.appleTeamId ?? (file ? "4DTAZSZL6B" : undefined),
  AUTH_APPLE_KEY_ID: config.appleKeyId,
  AUTH_APPLE_PRIVATE_KEY: config.appleKeyFile ? readFileSync(config.appleKeyFile, "utf8").trim() : undefined,
  AUTH_GOOGLE_CLIENT_ID: config.googleClientId,
  AUTH_GOOGLE_CLIENT_SECRET: config.googleClientSecret,
};
for (const [name, value] of Object.entries(values)) {
  if (value) {
    setEnv(name, value, flags);
    console.log(`set ${name} on ${where}`);
  } else if (placeholders && !isSet(name, flags)) {
    setEnv(name, "not-configured", flags);
    console.log(`set ${name} on ${where} to a placeholder`);
  } else {
    console.log(`skipped ${name}`);
  }
}
