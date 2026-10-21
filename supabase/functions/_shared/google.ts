// Google APIs for Android: push through Firebase Cloud Messaging (FCM v1) and Play subscription checks.
// One Google Cloud service account does both. Its JSON key lives only in the GOOGLE_SERVICE_ACCOUNT secret
// (raw JSON or base64 of it). Auth is a self-signed RS256 JWT exchanged for an OAuth access token.
import { env } from "./platform.ts";

interface ServiceAccount { client_email: string; private_key: string; project_id?: string; token_uri?: string }

export function serviceAccount(): ServiceAccount | null {
  const raw = env("GOOGLE_SERVICE_ACCOUNT");
  if (!raw) return null;
  try {
    const text = raw.trim().startsWith("{") ? raw : atob(raw.replace(/\s+/g, ""));
    const sa = JSON.parse(text) as ServiceAccount;
    return sa.client_email && sa.private_key ? sa : null;
  } catch { return null; }
}

/** The Firebase project that sends to Android phones (FCM_PROJECT_ID, else the service account's own project). */
export const fcmProject = () => env("FCM_PROJECT_ID") ?? serviceAccount()?.project_id ?? "";
export const fcmConfigured = () => !!serviceAccount() && !!fcmProject();
export const androidPackage = () => env("ANDROID_PACKAGE") ?? "app.baget";

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const b64urlText = (t: string) => b64url(new TextEncoder().encode(t));

function pemBody(pem: string): Uint8Array {
  const body = pem.replace(/\\n/g, "\n").replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

const tokens = new Map<string, { token: string; until: number }>();

/** An OAuth access token for the given scope, cached until a few minutes before it expires. */
export async function accessToken(scope: string): Promise<string> {
  const hit = tokens.get(scope);
  if (hit && hit.until > Date.now()) return hit.token;
  const sa = serviceAccount();
  if (!sa) throw new Error("GOOGLE_SERVICE_ACCOUNT is not set");
  const now = Math.floor(Date.now() / 1000);
  const aud = sa.token_uri ?? "https://oauth2.googleapis.com/token";
  const input = `${b64urlText(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${b64urlText(JSON.stringify({ iss: sa.client_email, scope, aud, iat: now, exp: now + 3600 }))}`;
  const key = await crypto.subtle.importKey("pkcs8", pemBody(sa.private_key), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(input)));
  const r = await fetch(aud, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=${encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer")}&assertion=${input}.${b64url(sig)}`,
  });
  if (!r.ok) throw new Error(`Google auth failed: ${r.status} ${(await r.text()).slice(0, 200)}`);
  const j = await r.json() as { access_token: string; expires_in?: number };
  tokens.set(scope, { token: j.access_token, until: Date.now() + ((j.expires_in ?? 3600) - 300) * 1000 });
  return j.access_token;
}

export type FcmResult = "sent" | "drop-token" | "failed";
export let lastFcm: { status: number; reason: string } | null = null;

/**
 * Sends a data message to one Android phone. The app draws the notification itself (title, the line under it,
 * the product photo), the same way whether it's open or closed. High priority so it arrives right away.
 */
export async function sendFcm(token: string, data: Record<string, string>, collapseKey?: string): Promise<FcmResult> {
  const bearer = await accessToken("https://www.googleapis.com/auth/firebase.messaging");
  const message = {
    token,
    data,
    android: { priority: "HIGH", ...(collapseKey ? { collapse_key: collapseKey.slice(0, 64) } : {}), ttl: "86400s" },
  };
  const r = await fetch(`https://fcm.googleapis.com/v1/projects/${fcmProject()}/messages:send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
    body: JSON.stringify({ message }),
  });
  if (r.ok) { lastFcm = { status: r.status, reason: "" }; return "sent"; }
  let reason = "";
  try {
    const j = await r.json() as { error?: { status?: string; details?: { errorCode?: string }[] } };
    reason = j.error?.details?.find((d) => d.errorCode)?.errorCode ?? j.error?.status ?? "";
  } catch { /* empty body */ }
  lastFcm = { status: r.status, reason };
  if (r.status === 404 || reason === "UNREGISTERED" || (r.status === 400 && reason === "INVALID_ARGUMENT")) return "drop-token";
  if (r.status === 401) tokens.clear();
  console.error(`FCM ${r.status} ${reason}`);
  return "failed";
}

export interface PlaySubscription {
  subscriptionState?: string;
  externalAccountIdentifiers?: { obfuscatedExternalAccountId?: string };
  lineItems?: { productId?: string; expiryTime?: string }[];
  acknowledgementState?: string;
  testPurchase?: unknown;
}

/** Looks a Play subscription up with Google (purchases.subscriptionsv2.get). */
export async function playSubscription(packageName: string, purchaseToken: string): Promise<PlaySubscription> {
  const bearer = await accessToken("https://www.googleapis.com/auth/androidpublisher");
  const r = await fetch(`https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(packageName)}/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`,
    { headers: { Authorization: `Bearer ${bearer}` } });
  if (!r.ok) throw new Error(`Play lookup failed: ${r.status} ${(await r.text()).slice(0, 200)}`);
  return await r.json() as PlaySubscription;
}
