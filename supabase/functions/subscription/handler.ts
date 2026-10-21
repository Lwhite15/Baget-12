// Baget Pro, bought through the App Store (iPhone) or Google Play (Android).
//  * Android sends {platform: "android", product_id, purchase_token}: checked with Google Play, tied to the account
//    by the obfuscated account id the app set at purchase time.
//  * The app (signed in) sends each verified StoreKit transaction: {signed_transaction}. Also on every launch,
//    so renewals and cancellations are picked up even without server notifications.
//  * Apple sends App Store Server Notifications V2 here too: {signedPayload} (no user; matched by original transaction).
// Nothing is trusted until Apple's signature checks out. Only the server can change a person's plan.
import { HttpError, db, env, handle, json, requireUser } from "../_shared/platform.ts";
import { androidPackage, playSubscription, type PlaySubscription } from "../_shared/google.ts";

export const PRODUCTS = ["baget.pro.monthly", "baget.pro.yearly"];
export type Verifier = (jws: string) => Promise<Record<string, unknown>>;

interface Tx {
  bundleId?: string; productId?: string; originalTransactionId?: string; transactionId?: string;
  expiresDate?: number; revocationDate?: number; appAccountToken?: string; environment?: string;
}

const bundleId = () => env("APP_BUNDLE_ID") ?? env("APNS_TOPIC") ?? "";

/** Checks a verified transaction is for Baget Pro and applies it to an account. Returns the new plan state. */
export async function applyTransaction(tx: Tx, userId: string | null, now = Date.now()) {
  if (!tx.bundleId || tx.bundleId !== bundleId()) throw new HttpError(400, "That purchase isn't for Baget.");
  if (!tx.productId || !PRODUCTS.includes(tx.productId)) throw new HttpError(400, "Unknown product.");
  const original = String(tx.originalTransactionId ?? "");
  if (!/^\d{1,40}$/.test(original)) throw new HttpError(400, "Missing transaction.");
  const token = (tx.appAccountToken ?? "").toLowerCase();
  const [owner] = await db.select<{ id: string }>("profiles", `select=id&original_transaction_id=eq.${original}`);
  let target = userId;
  if (!target) target = owner?.id ?? (token || null);      // server notification: whoever holds it
  if (!target) return { applied: false };
  if (userId && token && token !== userId.toLowerCase()) throw new HttpError(409, "This subscription belongs to a different Baget account.");
  if (owner && owner.id !== target) {
    if (token !== target.toLowerCase()) throw new HttpError(409, "This subscription is already linked to another Baget account.");
    await db.update("profiles", `id=eq.${owner.id}`, { original_transaction_id: null, pro_until: null });
  }
  const [p] = await db.select<{ plan: string }>("profiles", `select=plan&id=eq.${target}`);
  if (!p) return { applied: false };
  const expires = tx.revocationDate ? new Date(Math.min(tx.revocationDate, now)) : new Date(tx.expiresDate ?? 0);
  await db.update("profiles", `id=eq.${target}`, {
    plan: p.plan === "comp" ? "comp" : "pro",
    pro_until: expires.toISOString(),
    pro_product: tx.productId,
    pro_environment: String(tx.environment ?? "").slice(0, 20),
    original_transaction_id: original,
  });
  return { applied: true, pro: p.plan === "comp" || expires.getTime() > now, pro_until: expires.toISOString(), product: tx.productId };
}

export type PlayLookup = (packageName: string, token: string) => Promise<PlaySubscription>;

/** Checks a Google Play subscription and applies it to the signed-in account. */
export async function applyPlay(userId: string, productId: string, token: string, lookup: PlayLookup, now = Date.now()) {
  if (!PRODUCTS.includes(productId)) throw new HttpError(400, "Unknown product.");
  if (!/^[A-Za-z0-9._:-]{10,1000}$/.test(token)) throw new HttpError(400, "Missing purchase.");
  const sub = await lookup(androidPackage(), token).catch((e) => { throw new HttpError(400, "Couldn't verify that purchase with Google Play.", String(e)); });
  const owner = sub.externalAccountIdentifiers?.obfuscatedExternalAccountId?.toLowerCase();
  if (owner && owner !== userId.toLowerCase()) throw new HttpError(409, "This subscription belongs to a different Baget account.");
  const line = (sub.lineItems ?? []).find((l) => l.productId === productId) ?? (sub.lineItems ?? [])[0];
  if (!line?.productId || !PRODUCTS.includes(line.productId)) throw new HttpError(400, "That purchase isn't Baget Pro.");
  const [held] = await db.select<{ user_id: string }>("play_subscriptions", `select=user_id&purchase_token=eq.${encodeURIComponent(token)}`);
  if (held && held.user_id !== userId) throw new HttpError(409, "This subscription is already linked to another Baget account.");
  const state = String(sub.subscriptionState ?? "");
  const live = ["SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_IN_GRACE_PERIOD", "SUBSCRIPTION_STATE_CANCELED"].includes(state);
  const expiry = line.expiryTime ? Date.parse(line.expiryTime) : 0;
  const expires = new Date(live ? expiry : Math.min(expiry || now, now));
  const row = { purchase_token: token, user_id: userId, product_id: line.productId, expires_at: expires.toISOString(), state: state.slice(0, 60), updated_at: new Date(now).toISOString() };
  if (held) await db.update("play_subscriptions", `purchase_token=eq.${encodeURIComponent(token)}`, row);
  else await db.insert("play_subscriptions", row, false);
  const [p] = await db.select<{ plan: string; pro_until: string | null }>("profiles", `select=plan,pro_until&id=eq.${userId}`);
  if (!p) return { applied: false };
  // An iPhone subscription on the same account may run longer; keep whichever ends later.
  const other = p.pro_until ? Date.parse(p.pro_until) : 0;
  const until = new Date(Math.max(expires.getTime(), other > now ? other : 0));
  await db.update("profiles", `id=eq.${userId}`, {
    plan: p.plan === "comp" ? "comp" : "pro",
    pro_until: until.toISOString(),
    pro_product: line.productId,
    pro_environment: sub.testPurchase ? "play-test" : "play",
  });
  return { applied: true, pro: p.plan === "comp" || until.getTime() > now, pro_until: until.toISOString(), product: line.productId };
}

export function makeHandler(verify: Verifier, play: PlayLookup = playSubscription) {
  return handle(async (req) => {
    const body = await req.json().catch(() => ({})) as { signed_transaction?: string; signedPayload?: string;
      platform?: string; product_id?: string; purchase_token?: string };
    if (body.platform === "android") {
      const user = await requireUser(req);
      return json(await applyPlay(user.id, String(body.product_id ?? ""), String(body.purchase_token ?? ""), play));
    }
    if (typeof body.signedPayload === "string") {
      // App Store Server Notification V2.
      const note = await verify(body.signedPayload).catch((e) => { throw new HttpError(400, "Invalid notification", String(e)); });
      const data = (note.data ?? {}) as { signedTransactionInfo?: string };
      if (data.signedTransactionInfo) {
        const tx = await verify(data.signedTransactionInfo) as Tx;
        await applyTransaction(tx, null).catch((e) => console.error("notification", e));
      }
      return json({ ok: true });
    }
    const user = await requireUser(req);
    if (typeof body.signed_transaction !== "string" || body.signed_transaction.length > 20000) throw new HttpError(400, "Missing purchase.");
    const tx = await verify(body.signed_transaction).catch((e) => { throw new HttpError(400, "Couldn't verify that purchase with Apple.", String(e)); }) as Tx;
    return json(await applyTransaction(tx, user.id));
  });
}
