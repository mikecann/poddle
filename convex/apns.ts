"use node";

import { createPrivateKey, sign } from "node:crypto";
import http2 from "node:http2";
import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { internalAction, type ActionCtx } from "./_generated/server";
import { userAction } from "./lib/auth";

// APNs over HTTP/2 with a token-based (ES256 JWT) auth key.
// Env: APNS_KEY_P8 (the .p8 contents, PEM or bare base64), APNS_KEY_ID,
// APNS_TEAM_ID, APNS_TOPIC (bundle id), APNS_ENV ("sandbox" | "production").
// Without them every send is a logged no-op.

type ApnsConfig = { key: string; keyId: string; teamId: string; topic: string; env: "sandbox" | "production" };

export function apnsConfig(): ApnsConfig | null {
  const { APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC, APNS_ENV } = process.env;
  if (!APNS_KEY_P8 || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_TOPIC) return null;
  return {
    key: toPem(APNS_KEY_P8),
    keyId: APNS_KEY_ID,
    teamId: APNS_TEAM_ID,
    topic: APNS_TOPIC,
    env: APNS_ENV === "production" ? "production" : "sandbox",
  };
}

function toPem(raw: string): string {
  const s = raw.replace(/\\n/g, "\n").trim();
  if (s.includes("BEGIN PRIVATE KEY")) return s;
  const body = s.replace(/\s+/g, "").match(/.{1,64}/g)?.join("\n") ?? "";
  return `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----`;
}

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url");

let cachedJwt: { token: string; issuedAt: number; keyId: string } | null = null;

/** Provider token. Apple wants it refreshed at most every 20 min and at least hourly. */
export function providerToken(cfg: ApnsConfig, nowMs = Date.now()): string {
  if (cachedJwt && cachedJwt.keyId === cfg.keyId && nowMs - cachedJwt.issuedAt < 50 * 60_000) return cachedJwt.token;
  const iat = Math.floor(nowMs / 1000);
  const input = `${b64url(JSON.stringify({ alg: "ES256", kid: cfg.keyId }))}.${b64url(JSON.stringify({ iss: cfg.teamId, iat }))}`;
  const signature = sign("sha256", Buffer.from(input), { key: createPrivateKey(cfg.key), dsaEncoding: "ieee-p1363" });
  const token = `${input}.${b64url(signature)}`;
  cachedJwt = { token, issuedAt: nowMs, keyId: cfg.keyId };
  return token;
}

type SendResult = { token: string; status: number; reason?: string };

function sendOne(session: http2.ClientHttp2Session, cfg: ApnsConfig, jwt: string, token: string, payload: string): Promise<SendResult> {
  return new Promise((resolve) => {
    const req = session.request({
      ":method": "POST",
      ":path": `/3/device/${token}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": cfg.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    });
    let status = 0;
    let body = "";
    req.setEncoding("utf8");
    req.on("response", (headers) => (status = Number(headers[":status"] ?? 0)));
    req.on("data", (chunk: string) => (body += chunk));
    req.on("end", () => {
      let reason: string | undefined;
      try {
        reason = body ? (JSON.parse(body) as { reason?: string }).reason : undefined;
      } catch {
        reason = body || undefined;
      }
      resolve({ token, status, reason });
    });
    req.on("error", (e) => resolve({ token, status: 0, reason: e.message }));
    req.setTimeout(10_000, () => {
      req.close();
      resolve({ token, status: 0, reason: "timeout" });
    });
    req.end(payload);
  });
}

async function sendAlertToUser(
  ctx: ActionCtx,
  userId: Id<"users">,
  alert: { title: string; body: string; threadId?: string; data?: Record<string, string> },
): Promise<{ sent: number; failed: number; skipped?: string }> {
  const cfg = apnsConfig();
  if (!cfg) {
    console.log(`[apns] not configured, skipping: ${alert.title}: ${alert.body}`);
    return { sent: 0, failed: 0, skipped: "unconfigured" };
  }
  const targets: { token: string; environment?: "sandbox" | "production" }[] = await ctx.runQuery(internal.devices.pushTargets, { userId });
  if (!targets.length) return { sent: 0, failed: 0, skipped: "noDevices" };
  const payload = JSON.stringify({
    aps: { alert: { title: alert.title, body: alert.body }, sound: "default", "thread-id": alert.threadId },
    ...alert.data,
  });
  const jwt = providerToken(cfg);
  let sent = 0;
  let failed = 0;
  for (const env of ["sandbox", "production"] as const) {
    const tokens = targets.filter((t) => (t.environment ?? cfg.env) === env).map((t) => t.token);
    if (!tokens.length) continue;
    const host = env === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
    const session = http2.connect(host);
    session.on("error", (e) => console.error(`[apns] session error: ${e.message}`));
    try {
      const results = await Promise.all(tokens.map((t) => sendOne(session, cfg, jwt, t, payload)));
      for (const r of results) {
        if (r.status === 200) sent++;
        else {
          failed++;
          console.warn(`[apns] ${r.status} ${r.reason ?? ""} for …${r.token.slice(-6)}`);
          if (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered") {
            await ctx.runMutation(internal.devices.dropToken, { token: r.token });
          }
        }
      }
    } finally {
      session.close();
    }
  }
  return { sent, failed };
}

const vSendResult = v.object({ sent: v.number(), failed: v.number(), skipped: v.optional(v.string()) });

export const sendNewEpisodeAlert = internalAction({
  args: { episodeId: v.id("episodes"), userId: v.id("users") },
  returns: vSendResult,
  handler: async (ctx, { episodeId, userId }): Promise<{ sent: number; failed: number; skipped?: string }> => {
    const alert: { title: string; body: string; podcastId: string } | null = await ctx.runQuery(
      internal.devices.alertForEpisode,
      { episodeId },
    );
    if (!alert) return { sent: 0, failed: 0, skipped: "missingEpisode" };
    return await sendAlertToUser(ctx, userId, {
      title: alert.title,
      body: alert.body,
      threadId: alert.podcastId,
      data: { episodeId, podcastId: alert.podcastId },
    });
  },
});

/** Send a test notification to every device you're signed in on. */
export const sendTestPush = userAction({
  args: { message: v.optional(v.string()) },
  returns: vSendResult,
  handler: async (ctx, { message }) => await sendAlertToUser(ctx, ctx.userId, { title: "Poddle", body: message ?? "Test notification" }),
});
