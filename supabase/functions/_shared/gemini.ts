// The second scout, hunting in tandem with Claude on every hunt from the same brief, steered toward what the first
// scout is likely to miss. Its picks go through every check Claude's do. Off unless GEMINI_API_KEY is set.
//  * While Google's free daily allowance for Search grounding lasts: Gemini Flash with Google Search built in.
//  * After that (or if grounding fails): Gemini Flash-Lite searching through Baget's own search (Serper, ~$0.001 each).
import { db, env, logUsage, parseJSON } from "./platform.ts";
import { hitsText, serperSearch } from "./search.ts";

type FetchFn = typeof fetch;
export const GEMINI_MODEL = () => env("GEMINI_MODEL") ?? "gemini-2.5-flash";
export const GEMINI_LITE = () => env("GEMINI_FALLBACK_MODEL") ?? "gemini-2.5-flash-lite";
export const geminiOn = () => !!env("GEMINI_API_KEY") && env("GEMINI_TANDEM") !== "off";
/** Grounded hunts per day before switching (Google's free allowance is about 1,500; this leaves a margin). */
const GROUNDED_DAILY = () => Number(env("GEMINI_GROUNDED_DAILY") ?? 1400);

export const TANDEM_NOTE = `You are the second scout on this hunt, working alongside another scout who is searching the same brief right now.
Cover what they're likely to miss: smaller and independent brands, other stores and boutiques, international shops that
ship to the US, resale and archive listings, and newer releases. Skip the most obvious first-page results.
Search as much as you need. Only include products whose own product page you found.\n\n`;

let grounded: { at: number; n: number } | null = null;
/** Grounded hunts so far today (Pacific time, when Google's allowance resets). Checked at most once a minute per worker. */
async function groundedToday(): Promise<number> {
  if (grounded && Date.now() - grounded.at < 60_000) return grounded.n;
  const n = await db.rpc<number>("gemini_grounded_today", {}).catch(() => GROUNDED_DAILY());   // unsure: assume used up
  grounded = { at: Date.now(), n: Number(n) || 0 };
  return grounded.n;
}
export function resetGrounded() { grounded = null; }

const endpoint = (model: string) => `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;
type Part = { text?: string; functionCall?: { name: string; args?: Record<string, unknown> }; functionResponse?: unknown };
type Reply = { candidates?: { content?: { role?: string; parts?: Part[] }; groundingMetadata?: { webSearchQueries?: string[] } }[];
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number } };

async function call(model: string, body: Record<string, unknown>, fetchFn: FetchFn): Promise<Reply | null> {
  const r = await fetchFn(endpoint(model), {
    method: "POST", signal: AbortSignal.timeout(60_000),
    headers: { "Content-Type": "application/json", "x-goog-api-key": env("GEMINI_API_KEY")! },
    body: JSON.stringify(body),
  });
  if (!r.ok) { console.error("gemini", model, r.status, (await r.text()).slice(0, 200)); return null; }
  return await r.json() as Reply;
}
const tokens = (u: Reply["usageMetadata"]) => ({ i: u?.promptTokenCount ?? 0, o: (u?.candidatesTokenCount ?? 0) + (u?.thoughtsTokenCount ?? 0) });
const textOfReply = (r: Reply | null) => (r?.candidates?.[0]?.content?.parts ?? []).map((p) => p.text ?? "").join("");

/** Gemini Flash with Google Search grounding: one call. */
async function groundedHunt(prompt: string, fetchFn: FetchFn) {
  const model = GEMINI_MODEL();
  const j = await call(model, { contents: [{ role: "user", parts: [{ text: TANDEM_NOTE + prompt }] }], tools: [{ google_search: {} }],
    generationConfig: { temperature: 0.7, maxOutputTokens: 8192 } }, fetchFn);
  if (!j) return null;
  const t = tokens(j.usageMetadata);
  await logUsage("sweep (tandem)", `${model} (grounded)`, { input_tokens: t.i, output_tokens: t.o,
    server_tool_use: { web_search_requests: j.candidates?.[0]?.groundingMetadata?.webSearchQueries?.length ?? 1 } } as never);
  if (grounded) grounded.n++;
  return parseJSON(textOfReply(j));
}

/** Gemini Flash-Lite calling Baget's own search (Serper) as a tool, up to `maxSearches` searches. */
async function liteHunt(prompt: string, maxSearches: number, fetchFn: FetchFn) {
  const model = GEMINI_LITE();
  const tools = [{ function_declarations: [{ name: "search", description: "Search the web (Google, US). Returns titles, links and snippets.",
    parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } }] }];
  const contents: { role: string; parts: Part[] }[] = [{ role: "user", parts: [{ text: TANDEM_NOTE + prompt }] }];
  let i = 0, o = 0, searches = 0, text = "";
  for (let turn = 0; turn < 8; turn++) {
    const j = await call(model, { contents, tools, generationConfig: { temperature: 0.7, maxOutputTokens: 8192 } }, fetchFn);
    if (!j) break;
    const t = tokens(j.usageMetadata); i += t.i; o += t.o;
    const parts = j.candidates?.[0]?.content?.parts ?? [];
    const calls = parts.filter((p) => p.functionCall?.name === "search");
    text = parts.map((p) => p.text ?? "").join("");
    if (!calls.length) break;
    contents.push({ role: "model", parts });
    const out: Part[] = [];
    for (const c of calls) {
      const q = String(c.functionCall?.args?.query ?? "").trim();
      let res = "No searches left. Reply now with the JSON.";
      if (q && searches < maxSearches) {
        searches++;
        res = await serperSearch(q, fetchFn).then((h) => hitsText(q, h)).catch(() => "Search failed. Try another query or wrap up.");
      }
      out.push({ functionResponse: { name: "search", response: { content: res } } });
    }
    if (searches >= maxSearches) out.push({ text: "That's all the searches for this run. Reply now with only the JSON." });
    contents.push({ role: "user", parts: out });
  }
  await logUsage("sweep (tandem)", `${model} (serper)`, { input_tokens: i, output_tokens: o, server_tool_use: { web_search_requests: searches } } as never);
  return parseJSON(text);
}

/** One tandem hunt. Returns the parsed {listings:[...]} JSON (or null) and never throws. */
export async function geminiHunt(prompt: string, maxSearches = 6, fetchFn: FetchFn = fetch): Promise<unknown | null> {
  if (!env("GEMINI_API_KEY")) return null;
  try {
    if (await groundedToday() < GROUNDED_DAILY()) {
      const r = await groundedHunt(prompt, fetchFn).catch((e) => { console.error("gemini grounded", (e as Error).message); return null; });
      if (r) return r;
    }
    return await liteHunt(prompt, maxSearches, fetchFn);
  } catch (e) {
    console.error("gemini", (e as Error).message);
    return null;
  }
}
