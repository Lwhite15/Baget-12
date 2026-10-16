// Baget Pro, bought through the App Store.
//  * The app (signed in) sends each verified StoreKit transaction: {signed_transaction}. Also on every launch,
//    so renewals and cancellations are picked up even without server notifications.
//  * Apple sends App Store Server Notifications V2 here too: {signedPayload} (no user; matched by original transaction).
// Nothing is trusted until Apple's signature checks out. Only the server can change a person's plan.
import { HttpError, db, env, handle, json, requireUser } from "../_shared/platform.ts";

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

export function makeHandler(verify: Verifier) {
  return handle(async (req) => {
    const body = await req.json().catch(() => ({})) as { signed_transaction?: string; signedPayload?: string };
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
