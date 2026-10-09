// Delivers notifications to iPhones.
//  * {note_id}: called by the database the moment a notification is saved.
//  * {release: true}: called hourly by the scheduler to send notes held overnight by quiet hours.
import { apnsConfigured, lastApns, pemToDer, sendPush, signJWT } from "../_shared/apns.ts";
import { HttpError, db, env, handle, isScheduler, json } from "../_shared/platform.ts";
import { morningDigest, watchCheck } from "../_shared/daily.ts";

interface Note { id: string; user_id: string; body: string; sender_name: string; kind: string; find_id: string | null; held_for_morning: boolean; pushed_at: string | null }

export async function deliver(noteId: string): Promise<number> {
  const [n] = await db.select<Note>("notes", `select=*&id=eq.${noteId}`);
  if (!n || n.held_for_morning || n.pushed_at) return 0;
  if (n.kind === "learned") {   // the app already showed it; just mark it handled
    await db.update("notes", `id=eq.${n.id}`, { pushed_at: new Date().toISOString() });
    return 0;
  }
  const tokens = await db.select<{ token: string; environment: string }>("device_tokens", `select=token,environment&user_id=eq.${n.user_id}`);
  if (!tokens.length) return 0;
  const unread = await db.select<{ id: string }>("notes", `select=id&user_id=eq.${n.user_id}&read=eq.false&limit=99`);
  const payload = {
    aps: { alert: { title: n.sender_name || "Baget", body: n.body }, sound: "default", badge: unread.length, "thread-id": n.kind === "friend" ? "friends" : "finds" },
    noteID: n.id,
    findID: n.find_id,
  };
  let sent = 0, failed = 0;
  for (const t of tokens) {
    const r = await sendPush(t.token, t.environment, payload, n.id);
    if (r === "sent") sent++;
    if (r === "failed") failed++;
    if (r === "drop-token") await db.remove("device_tokens", `token=eq.${t.token}`);
  }
  // Only mark it done if it reached a phone (or there's nothing left to try); otherwise the hourly job retries it.
  if (sent > 0 || failed === 0) await db.update("notes", `id=eq.${n.id}`, { pushed_at: new Date().toISOString() });
  return sent;
}

/** For the Diagnose workflow: is the push key usable? Reports shapes and errors, never the key. */
async function diagnose() {
  const p8 = env("APNS_KEY_P8") ?? "", kid = env("APNS_KEY_ID") ?? "", team = env("APNS_TEAM_ID") ?? "";
  const out: Record<string, unknown> = { keyChars: p8.length, keyIdLength: kid.length, teamIdLength: team.length, topic: env("APNS_TOPIC") ?? null };
  try {
    out.derBytes = pemToDer(p8).length;
    await signJWT(p8, kid, team, Math.floor(Date.now() / 1000));
    out.signs = true;
    // Send one real test notification to each registered device and report what Apple said.
    const devices = await db.select<{ token: string; environment: string }>("device_tokens", "select=token,environment&limit=3");
    out.tests = [];
    for (const d of devices) {
      const r = await sendPush(d.token, d.environment, { aps: { alert: { title: "Baget", body: "Notifications are on. Your squad will text you here." }, sound: "default" } });
      (out.tests as unknown[]).push({ environment: d.environment, tokenLength: d.token.length, result: r, apple: lastApns });
    }
  } catch (e) {
    out.signs = false;
    out.error = String((e as Error).message).slice(0, 200);
  }
  return out;
}

export const handler = handle(async (req) => {
  if (!isScheduler(req)) throw new HttpError(401, "Not allowed");
  if (!apnsConfigured()) return json({ sent: 0, note: "APNs not configured" });
  const body = await req.json().catch(() => ({})) as { note_id?: string; release?: boolean; diagnose?: boolean };
  if (body.diagnose) return json(await diagnose());
  if (body.release) {
    const ids = await db.rpc<string[]>("release_held_notes", {});
    let sent = 0, failed = 0;
    const tryDeliver = async (id: string) => { try { sent += await deliver(id); } catch (e) { failed++; console.error("push", (e as Error).message); } };
    for (const id of (ids ?? []).slice(0, 200)) await tryDeliver(typeof id === "string" ? id : (id as { release_held_notes: string }).release_held_notes);
    // Retry the newest few texts from the last 12 hours that never went out (for example while the push key was being fixed).
    const since = new Date(Date.now() - 12 * 3600_000).toISOString();
    const stuck = await db.select<{ id: string }>("notes",
      `select=id&pushed_at=is.null&held_for_morning=eq.false&kind=neq.learned&created_at=gt.${since}&order=created_at.desc&limit=5`);
    for (const n of stuck) await tryDeliver(n.id);
    // Hourly extras: the 8am "Today's Drop" text, and price checks on watched finds (each saves a note that pushes itself).
    const digests = await morningDigest().catch((e) => { console.error("digest", e); return 0; });
    const watch = await watchCheck().catch((e) => { console.error("watch", e); return { checked: 0, drops: 0 }; });
    return json({ released: ids?.length ?? 0, retried: stuck.length, sent, failed, digests, watch });
  }
  if (!body.note_id || !/^[0-9a-f-]{36}$/i.test(body.note_id)) throw new HttpError(400, "note_id required");
  return json({ sent: await deliver(body.note_id) });
});
