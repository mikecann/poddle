import type { AuthConfig } from "convex/server";
import { env } from "./_generated/server";

// Convex Auth signs its own JWTs. They're issued by, and verified against, this
// deployment's site URL, so a custom domain for HTTP actions (CONVEX_SITE_URL
// overridden to https://poddle.mikecann.app) changes the issuer: everyone signs
// in again once, and the provider return URLs move with it (docs/api.md).
export default {
  providers: [
    {
      type: "customJwt",
      applicationID: "convex",
      issuer: env.CONVEX_SITE_URL,
      jwks: `${env.CONVEX_SITE_URL}/auth/.well-known/jwks.json`,
      algorithm: "RS256",
    },
  ],
} satisfies AuthConfig;
