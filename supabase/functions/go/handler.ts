// Buy links: /functions/v1/go?l=<listing id>&s=<where it was tapped>&u=<account id>
// Logs the tap, then forwards to the listing's own store page, through an affiliate network when one is configured:
//   SKIMLINKS_ID (Skimlinks publisher id) or SOVRN_KEY (Sovrn Commerce / VigLink key) cover thousands of stores,
//   AMAZON_TAG adds an Amazon Associates tag to amazon.com links.
// Only ever redirects to a URL already stored for that listing, so it can't be used as an open redirect.
import { db, env } from "../_shared/platform.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function affiliateURL(url: string): { url: string; via: string } {
  let host = "";
  try { host = new URL(url).hostname.toLowerCase(); } catch { return { url, via: "" }; }
  const amazon = env("AMAZON_TAG");
  if (amazon && /(^|\.)amazon\.com$/.test(host)) {
    const u = new URL(url);
    u.searchParams.set("tag", amazon);
    return { url: u.toString(), via: "amazon" };
  }
  const skim = env("SKIMLINKS_ID");
  if (skim) return { url: `https://go.skimresources.com/?id=${encodeURIComponent(skim)}&xs=1&url=${encodeURIComponent(url)}`, via: "skimlinks" };
  const sovrn = env("SOVRN_KEY");
  if (sovrn) return { url: `https://redirect.viglink.com?key=${encodeURIComponent(sovrn)}&u=${encodeURIComponent(url)}`, via: "sovrn" };
  return { url, via: "" };
}

export async function handler(req: Request): Promise<Response> {
  const q = new URL(req.url).searchParams;
  const id = q.get("l") ?? "";
  if (!UUID.test(id)) return new Response("Not found", { status: 404 });
  const [l] = await db.select<{ url: string | null }>("listings", `select=url&id=eq.${id}`).catch(() => []);
  if (!l?.url || !/^https?:\/\//.test(l.url)) return new Response("Not found", { status: 404 });
  const out = affiliateURL(l.url);
  const user = UUID.test(q.get("u") ?? "") ? q.get("u") : null;
  await db.insert("buy_clicks", { listing_id: id, user_id: user, source: (q.get("s") ?? "").slice(0, 20), affiliate: out.via }, false)
    .catch((e) => console.error("buy_clicks", e));
  return new Response(null, { status: 302, headers: { Location: out.url, "Cache-Control": "no-store" } });
}
