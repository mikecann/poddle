import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";

// Convex Auth serves its own routes under /auth, /oauth/apple and /oauth/google
// (convex.config.ts). These are the app's.

const http = httpRouter();

// Links the Poddle app to this domain (team ID + bundle ID), for passwords and
// passkeys later. Sign-in doesn't rely on it: it comes back on poddle://.
http.route({
  path: "/.well-known/apple-app-site-association",
  method: "GET",
  handler: httpAction(async () => {
    const association = { webcredentials: { apps: ["4DTAZSZL6B.com.mikecann.poddle"] } };
    return new Response(JSON.stringify(association), { headers: { "Content-Type": "application/json" } });
  }),
});

// Where Apple's and Google's sign-in pages end up, with ?convexAuthCode=... It
// hands the same query on to poddle://signed-in, which the app's sign-in sheet
// catches.
http.route({
  path: "/app/signed-in",
  method: "GET",
  handler: httpAction(async (_ctx, request) => {
    const { search } = new URL(request.url);
    return new Response(null, { status: 302, headers: { Location: `poddle://signed-in${search}` } });
  }),
});

export default http;
