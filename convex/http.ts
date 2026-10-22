import { httpRouter } from "convex/server";
import { registerStaticRoutes } from "@convex-dev/static-hosting";
import { api, components } from "./_generated/api";
import { httpAction, type ActionCtx } from "./_generated/server";
import { FALLBACK_INDEX_HTML, renderSharePage, type SharePage } from "./lib/meta";

// Convex Auth serves its own routes under /auth, /oauth/apple and /oauth/google
// (convex.config.ts). These are the app's, and the website (web/) is served from
// static hosting underneath them: the exact routes and prefixes here win over its
// catch-all.

const http = httpRouter();

export const APP_ID = "4DTAZSZL6B.com.mikecann.poddle";

/**
 * Universal links for the share pages, plus the app's link to this domain for
 * passwords and passkeys later. Sign-in doesn't rely on it: it comes back on poddle://.
 */
export const appSiteAssociation = {
  applinks: {
    details: [{ appIDs: [APP_ID], components: [{ "/": "/e/*" }, { "/": "/s/*" }] }],
  },
  webcredentials: { apps: [APP_ID] },
};

http.route({
  path: "/.well-known/apple-app-site-association",
  method: "GET",
  handler: httpAction(async () => {
    return new Response(JSON.stringify(appSiteAssociation), {
      headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=3600" },
    });
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

/** The site's public address: PODDLE_SITE_URL on prod (the custom domain), else this request's origin. */
function siteOrigin(request: Request): string {
  const configured = process.env.PODDLE_SITE_URL?.trim();
  return (configured || new URL(request.url).origin).replace(/\/$/, "");
}

/** The uploaded site's index.html, or a bare shell if there isn't one yet (or in tests). */
async function indexHtml(ctx: ActionCtx): Promise<string> {
  try {
    const asset = await ctx.runQuery(components.staticHosting.lib.resolveAssetForHttp, { path: "/index.html" });
    if (asset?.storageUrl) {
      const res = await fetch(asset.storageUrl);
      if (res.ok) return await res.text();
    }
  } catch (error) {
    console.error("Couldn't load index.html for a share page", error);
  }
  return FALLBACK_INDEX_HTML;
}

/** /e/<id> and /s/<id>: the single-page app, with that page's link-preview tags. */
const sharePage = httpAction(async (ctx, request) => {
  const url = new URL(request.url);
  const [, kind, id = ""] = url.pathname.split("/");
  let page: SharePage;
  if (kind === "e") {
    const episode = await ctx.runQuery(api.share.episode, { episodeId: id });
    page = episode ? { kind: "episode", episode } : { kind: "notFound", what: "episode" };
  } else {
    const show = await ctx.runQuery(api.share.show, { podcastId: id });
    page = show ? { kind: "show", page: show } : { kind: "notFound", what: "show" };
  }
  const html = renderSharePage(await indexHtml(ctx), page, siteOrigin(request));
  return new Response(html, {
    status: page.kind === "notFound" ? 404 : 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=60",
      "X-Content-Type-Options": "nosniff",
    },
  });
});

http.route({ pathPrefix: "/e/", method: "GET", handler: sharePage });
http.route({ pathPrefix: "/s/", method: "GET", handler: sharePage });

// Everything else: the website's files, with /me and other app routes falling
// back to index.html.
registerStaticRoutes(http, components.staticHosting);

export default http;
