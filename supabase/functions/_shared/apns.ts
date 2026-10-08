// Apple Push Notification service, token-based auth (ES256 JWT signed with your APNs .p8 key).
import { env } from "./platform.ts";

let cached: { jwt: string; at: number } | null = null;

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const b64urlText = (t: string) => b64url(new TextEncoder().encode(t));

/** Accepts the .p8 key as PEM text (with real or escaped newlines), base64 of the whole PEM file,
 *  or just the base64 body between the BEGIN/END lines. */
export function pemToDer(raw: string): Uint8Array {
  // Phones "smart punctuate" pasted keys: dashes become en/em dashes, quotes curl. Undo that first.
  let text = raw.trim().replace(/\\n/g, "\n").replace(/[\u2010-\u2015\u2212]/g, "-");
  if (!text.includes("BEGIN")) {
    try {
      const decoded = atob(text.replace(/\s+/g, ""));
      if (decoded.includes("BEGIN")) text = decoded.replace(/[\u2010-\u2015\u2212]/g, "-");   // base64 of the whole file
    } catch { /* already the bare body */ }
  }
  // Decoding base64 of a file pasted with smart dashes leaves UTF-8 bytes for them; drop the header and footer by their words.
  const body = text
    .replace(/[^\x20-\x7e\n]+/g, "-")
    .replace(/-*\s*(BEGIN|END)\s+[A-Z ]*KEY\s*-*/g, "")
    .replace(/[^A-Za-z0-9+/=]/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function signJWT(p8: string, keyId: string, teamId: string, nowSec: number): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(p8), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64urlText(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64urlText(JSON.stringify({ iss: teamId, iat: nowSec }));
  const input = `${head}.${claims}`;
  // WebCrypto returns the raw r||s signature, which is exactly the JWS ES256 format.
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input)));
  return `${input}.${b64url(sig)}`;
}

async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  // Apple wants a fresh token at most hourly and no more often than every 20 minutes.
  if (cached && now - cached.at < 45 * 60) return cached.jwt;
  const p8 = env("APNS_KEY_P8"), kid = env("APNS_KEY_ID"), team = env("APNS_TEAM_ID");
  if (!p8 || !kid || !team) throw new Error("APNs is not configured");
  cached = { jwt: await signJWT(p8, kid, team, now), at: now };
  return cached.jwt;
}

export function apnsConfigured(): boolean {
  return !!(env("APNS_KEY_P8") && env("APNS_KEY_ID") && env("APNS_TEAM_ID") && env("APNS_TOPIC"));
}

export type PushResult = "sent" | "drop-token" | "failed";

export async function sendPush(token: string, environment: string, payload: Record<string, unknown>, collapseId?: string): Promise<PushResult> {
  const host = environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const headers: Record<string, string> = {
    authorization: `bearer ${await providerToken()}`,
    "apns-topic": env("APNS_TOPIC")!,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "content-type": "application/json",
  };
  if (collapseId) headers["apns-collapse-id"] = collapseId.slice(0, 64);
  const r = await fetch(`${host}/3/device/${token}`, { method: "POST", headers, body: JSON.stringify(payload) });
  if (r.ok) return "sent";
  let reason = "";
  try { reason = (await r.json())?.reason ?? ""; } catch { /* empty body */ }
  if (r.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic") return "drop-token";
  if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") cached = null;
  console.error(`APNs ${r.status} ${reason}`);
  return "failed";
}
