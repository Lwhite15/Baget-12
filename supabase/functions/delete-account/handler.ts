// Permanently deletes the signed-in person's account: their taste photos in storage, then the account itself.
// Everything else (agents, finds, purchases, notifications, friendships, shares) is removed by the database cascade.
import { HttpError, db, handle, json, requireUser } from "../_shared/platform.ts";

export const handler = handle(async (req) => {
  const user = await requireUser(req);
  const list = await db.raw("/storage/v1/object/list/taste-photos", {
    method: "POST",
    body: JSON.stringify({ prefix: `${user.id}/`, limit: 1000, offset: 0 }),
  });
  if (list.ok) {
    const files = await list.json() as { name: string }[];
    if (files.length) {
      await db.raw("/storage/v1/object/taste-photos", {
        method: "DELETE",
        body: JSON.stringify({ prefixes: files.map((f) => `${user.id}/${f.name}`) }),
      });
    }
  }
  const r = await db.raw(`/auth/v1/admin/users/${user.id}`, { method: "DELETE" });
  if (!r.ok) throw new HttpError(502, "Your account couldn't be deleted just now. Try again in a minute.");
  return json({ deleted: true });
});
