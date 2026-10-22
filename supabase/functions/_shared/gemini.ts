// The second scout, hunting in tandem with Claude on every hunt from the same brief, steered toward what the first
// scout is likely to miss. Its picks go through every check Claude's do. Off unless GEMINI_API_KEY is set.
//  * While Google's free monthly allowance for Search grounding lasts (5,000 searches, shared across Gemini 3 models):
//    Gemini with Google Search built in.
//  * After that (or if grounding fails): the same model searching through Baget's own search (Serper, ~$0.001 each).
// Google retires models for new accounts; each mode tries a short list and remembers the first one that answers.
import { db, env, logUsage, parseJSON } from "./platform.ts";
import { hitsText, serperSearch } from "./search.ts";

type FetchFn = typeof fetch;
const MODELS = () => [...(env("GEMINI_MODEL") ? [env("GEMINI_MODEL")!] : []), "gemini-3.1-flash-lite", "gemini-3.5-flash-lite", "gemini-3.8-flash"];
let working: string | null = null;
export const geminiOn = () => !!env("GEMINI_API_KEY") && env("GEMINI_TANDEM") !== "off";
/** Grounded searches per month before switching (Google's free allowance is 5,000; this leaves a margin). */
const GROUNDED_MONTHLY = () => Number(env("GEMINI_GROUNDED_MONTHLY") ?? 4800);

export const TANDEM_NOTE = `You are the second scout on this hunt, working alongside another scout who is searching the same brief right now.
Cover what they're likely to miss: smaller and independent brands, other stores and boutiques, international shops that
ship to the US, resale and archive listings, and newer releases. Skip the most obvious first-page results.
Search as much as you need. Only include products whose own product page you found.\n\n`;

let grounded: { at: number; n: number } | null = null;
/** Grounded searches so far this month. Checked at most once a minute per worker. */
async function groundedThisMonth(): Promise<number> {
  if (grounded && Date.now() - grounded.at < 60_000) return grounded.n;
  const n = await db.rpc<number>("gemini_grounded_month", {}).catch(() => GROUNDED_MONTHLY());   // unsure: assume used up
  grounded = { at: Date.now(), n: Number(n) || 0 };
  return grounded.n;
}
export function resetGrounded() { grounded = null; working = null; }

const endpoint = (model: string) => `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;
type Part = { text?: string; functionCall?: { name: string; args?: Record<string, unknown> }; functionResponse?: unknown };
type Reply = { candidates?: { content?: { role?: string; parts?: Part[] }; groundingMetadata?: { webSearchQueries?: string[] } }[];
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number } };

async function callOne(model: string, body: Record<string, unknown>, fetchFn: FetchFn): Promise<Reply | "gone" | null> {
  const r = await fetchFn(endpoint(model), {
    method: "POST", signal: AbortSignal.timeout(60_000),
    headers: { "Content-Type": "application/json", "x-goog-api-key": env("GEMINI_API_KEY")! },
    body: JSON.stringify(body),
  });
  if (r.status === 404) { console.error("gemini", model, "not available"); return "gone"; }
  if (!r.ok) { console.error("gemini", model, r.status, (await r.text()).slice(0, 200)); return null; }
  return await r.json() as Reply;
}
/** Calls the model that last worked, or tries the list until one answers. Returns the reply and the model used. */
async function call(body: Record<string, unknown>, fetchFn: FetchFn): Promise<{ j: Reply; model: string } | null> {
  const list = working ? [working, ...MODELS().filter((m) => m !== working)] : MODELS();
  for (const m of list) {
    const j = await callOne(m, body, fetchFn);
    if (j === "gone") { if (working === m) working = null; continue; }
    if (!j) return null;
    working = m;
    return { j, model: m };
  }
  return null;
}
const tokens = (u: Reply["usageMetadata"]) => ({ i: u?.promptTokenCount ?? 0, o: (u?.candidatesTokenCount ?? 0) + (u?.thoughtsTokenCount ?? 0) });
const textOfReply = (r: Reply | null) => (r?.candidates?.[0]?.content?.parts ?? []).map((p) => p.text ?? "").join("");

/** Gemini Flash with Google Search grounding: one call. */
async function groundedHunt(prompt: string, fetchFn: FetchFn) {
  const res = await call({ contents: [{ role: "user", parts: [{ text: TANDEM_NOTE + prompt }] }], tools: [{ google_search: {} }],
    generationConfig: { temperature: 0.7, maxOutputTokens: 8192 } }, fetchFn);
  if (!res) return null;
  const { j, model } = res;
  const t = tokens(j.usageMetadata);
  const searches = j.candidates?.[0]?.groundingMetadata?.webSearchQueries?.length ?? 1;
  await logUsage("sweep (tandem)", `${model} (grounded)`, { input_tokens: t.i, output_tokens: t.o, server_tool_use: { web_search_requests: searches } } as never);
  if (grounded) grounded.n += searches;
  return parseJSON(textOfReply(j));
}

/** Gemini Flash-Lite calling Baget's own search (Serper) as a tool, up to `maxSearches` searches. */
async function liteHunt(prompt: string, maxSearches: number, fetchFn: FetchFn) {
  let model = working ?? MODELS()[0];
  const tools = [{ function_declarations: [{ name: "search", description: "Search the web (Google, US). Returns titles, links and snippets.",
    parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } }] }];
  const contents: { role: string; parts: Part[] }[] = [{ role: "user", parts: [{ text: TANDEM_NOTE + prompt }] }];
  let i = 0, o = 0, searches = 0, text = "";
  for (let turn = 0; turn < 8; turn++) {
    const res = await call({ contents, tools, generationConfig: { temperature: 0.7, maxOutputTokens: 8192 } }, fetchFn);
    if (!res) break;
    const j = res.j; model = res.model;
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
    if (await groundedThisMonth() < GROUNDED_MONTHLY()) {
      const r = await groundedHunt(prompt, fetchFn).catch((e) => { console.error("gemini grounded", (e as Error).message); return null; });
      if (r) return r;
    }
    return await liteHunt(prompt, maxSearches, fetchFn);
  } catch (e) {
    console.error("gemini", (e as Error).message);
    return null;
  }
}
