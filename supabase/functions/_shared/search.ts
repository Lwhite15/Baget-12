// Web search for hunts through Serper (Google results), about 10x cheaper than Claude's built-in web search.
// Claude calls it as a "search" tool inside the hunt; Baget runs the query and hands back titles, links and snippets.
import { alertOwner, env } from "./platform.ts";

type FetchFn = typeof fetch;
export interface WebHit { title: string; link: string; snippet: string; date?: string }

export const SEARCH_TOOL = {
  name: "search",
  description: "Search the web (Google, US). Returns up to 8 results with title, link and snippet. Use specific queries: model names, style codes, " +
    "store names, and site: filters (site:grailed.com, site:ebay.com/itm, site:reddit.com/r/sneakermarket). Call it many times with different queries.",
  input_schema: { type: "object", properties: { query: { type: "string", description: "The search query" } }, required: ["query"] },
};

let healthy: { ok: boolean; at: number } | null = null;

/** One Google search through Serper. Throws when Serper refuses (out of credits, bad key). */
export async function serperSearch(query: string, fetchFn: FetchFn = fetch): Promise<WebHit[]> {
  const key = env("SERPER_API_KEY");
  if (!key) throw new Error("no Serper key");
  const r = await fetchFn("https://google.serper.dev/search", {
    method: "POST", signal: AbortSignal.timeout(10000),
    headers: { "X-API-KEY": key, "Content-Type": "application/json" },
    body: JSON.stringify({ q: query.slice(0, 300), gl: "us", hl: "en", num: 10 }),
  });
  if (!r.ok) {
    const text = (await r.text()).slice(0, 200);
    if (/credit/i.test(text) || r.status === 401 || r.status === 403) {
      healthy = { ok: false, at: Date.now() };
      await alertOwner("serper", "Search (Serper) stopped working: " + (/credit/i.test(text) ? "it's out of credits. Top up at serper.dev." : "the key was refused.") +
        " Hunts are using Claude's built-in search meanwhile, which costs about 10x more.");
    }
    throw new Error(`serper ${r.status}: ${text}`);
  }
  const j = await r.json() as { organic?: { title?: string; link?: string; snippet?: string; date?: string }[] };
  return (j.organic ?? []).filter((o) => o.title && o.link).slice(0, 8)
    .map((o) => ({ title: o.title!.slice(0, 160), link: o.link!.slice(0, 400), snippet: (o.snippet ?? "").slice(0, 280), ...(o.date ? { date: o.date } : {}) }));
}

/** Can hunts use Serper right now? Checked at most every 10 minutes (one cheap search). */
export async function serperUsable(fetchFn: FetchFn = fetch): Promise<boolean> {
  if (!env("SERPER_API_KEY")) return false;
  if (healthy && Date.now() - healthy.at < 10 * 60_000) return healthy.ok;
  try {
    await serperSearch("new sneaker releases", fetchFn);
    healthy = { ok: true, at: Date.now() };
  } catch {
    healthy = { ok: false, at: Date.now() };
  }
  return healthy.ok;
}

export function resetSerperHealth() { healthy = null; }

/** Results as compact text for Claude. */
export function hitsText(query: string, hits: WebHit[]): string {
  if (!hits.length) return `No results for "${query}". Try different wording.`;
  return hits.map((h, i) => `${i + 1}. ${h.title}\n   ${h.link}${h.date ? ` (${h.date})` : ""}\n   ${h.snippet}`).join("\n");
}
