// Fresh look at one find's store page when someone opens it: price, and whether the page says it's in stock or sold out.
// Each product's page is opened at most once an hour, whoever asks; otherwise the last answer comes back.
import { pageProduct } from "../_shared/images.ts";
import { HttpError, db, enc, handle, json, quota, requireUser } from "../_shared/platform.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
interface Row { id: string; url: string | null; price: number | null; sold_out: boolean; page_checked_at: string | null; stock_seen_at: string | null; tags: string[] | null }

export const handler = handle(async (req) => {
  const user = await requireUser(req);
  await quota(user.id, "check", 120, 600);
  const body = await req.json().catch(() => ({})) as { listing_id?: string };
  const id = body.listing_id ?? "";
  if (!UUID.test(id)) throw new HttpError(400, "listing_id is required");
  const [mine] = await db.select<{ id: string }>("finds", `select=id&user_id=eq.${user.id}&listing_id=eq.${enc(id)}&limit=1`);
  if (!mine) throw new HttpError(404, "That isn't one of your finds");
  const [l] = await db.select<Row>("listings", `select=id,url,price,sold_out,page_checked_at,stock_seen_at,tags&id=eq.${enc(id)}`);
  if (!l) throw new HttpError(404, "Not found");
  const answer = (r: Row) => json({ sold_out: r.sold_out, price: r.price, stock_seen_at: r.stock_seen_at, page_checked_at: r.page_checked_at });
  const now = new Date();
  if (!l.url || (l.tags ?? []).some((t) => t === "intel" || t === "search")) return answer(l);
  if (l.page_checked_at && now.getTime() - Date.parse(l.page_checked_at) < 3600_000) return answer(l);

  const p = await pageProduct(l.url).catch(() => null);
  const patch: Partial<Row> = { page_checked_at: now.toISOString() };
  if (p === "gone") patch.sold_out = true;
  else if (p) {
    if (p.price && (!l.price || Math.abs(p.price - l.price) / l.price > 0.01)) patch.price = p.price;
    if (p.stock === "out") patch.sold_out = true;
    // Back in stock is left to the restock watcher, which texts everyone watching; here it only counts as confirmed.
    if (p.stock === "in") patch.stock_seen_at = now.toISOString();
  }
  await db.update("listings", `id=eq.${l.id}`, patch).catch((e) => console.error("check", e));
  return answer({ ...l, ...patch });
});
