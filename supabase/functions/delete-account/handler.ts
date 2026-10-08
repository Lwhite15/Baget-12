// Permanently deletes the signed-in person's account: their taste and icon photos in storage, then the account itself.
// Everything else (agents, finds, purchases, notifications, friendships, shares) is removed by the database cascade.
import { HttpError, db, handle, json, requireUser } from "../_shared/platform.ts";

export const handler = handle(async (req) => {
  const user = await requireUser(req);
  // Taste photos sit in <uid>/, icon photos in <uid>/avatars/. Storage lists one folder at a time.
  const paths: string[] = [];
  for (const folder of [`${user.id}/`, `${user.id}/avatars/`]) {
    const list = await db.raw("/storage/v1/object/list/taste-photos", {
      method: "POST",
      body: JSON.stringify({ prefix: folder, limit: 1000, offset: 0 }),
    });
    if (!list.ok) continue;
    const files = await list.json() as { name: string; id?: string | null }[];
    for (const f of files) if (f.id !== null && f.name && !f.name.endsWith("/")) paths.push(`${folder}${f.name}`);
  }
  if (paths.length) {
    await db.raw("/storage/v1/object/taste-photos", { method: "DELETE", body: JSON.stringify({ prefixes: paths }) });
  }
  const r = await db.raw(`/auth/v1/admin/users/${user.id}`, { method: "DELETE" });
  if (!r.ok) throw new HttpError(502, "Your account couldn't be deleted just now. Try again in a minute.");
  return json({ deleted: true });
});
