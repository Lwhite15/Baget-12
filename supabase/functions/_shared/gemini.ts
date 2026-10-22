// The second scout: Google's Gemini with Google Search built in. It hunts alongside Claude on every hunt (in tandem),
// from the same brief, steered toward what the first scout is likely to miss. Its picks go through every check
// Claude's do. Off unless GEMINI_API_KEY is set.
import { env, logUsage, parseJSON } from "./platform.ts";

type FetchFn = typeof fetch;
export const GEMINI_MODEL = () => env("GEMINI_MODEL") ?? "gemini-2.5-flash";
export const geminiOn = () => !!env("GEMINI_API_KEY") && env("GEMINI_TANDEM") !== "off";

export const TANDEM_NOTE = `You are the second scout on this hunt, working alongside another scout who is searching the same brief right now.
Cover what they're likely to miss: smaller and independent brands, other stores and boutiques, international shops that
ship to the US, resale and archive listings, and newer releases. Skip the most obvious first-page results.
Use Google Search as much as you need. Only include products whose own product page you found.\n\n`;

/** One tandem hunt. Returns the parsed {listings:[...]} JSON (or null) and never throws. */
export async function geminiHunt(prompt: string, fetchFn: FetchFn = fetch): Promise<unknown | null> {
  const key = env("GEMINI_API_KEY");
  if (!key) return null;
  const model = GEMINI_MODEL();
  try {
    const r = await fetchFn(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
      method: "POST", signal: AbortSignal.timeout(80_000),
      headers: { "Content-Type": "application/json", "x-goog-api-key": key },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: TANDEM_NOTE + prompt }] }],
        tools: [{ google_search: {} }],
        generationConfig: { temperature: 0.7, maxOutputTokens: 8192 },
      }),
    });
    if (!r.ok) { console.error("gemini", r.status, (await r.text()).slice(0, 200)); return null; }
    const j = await r.json() as {
      candidates?: { content?: { parts?: { text?: string }[] }; groundingMetadata?: { webSearchQueries?: string[] } }[];
      usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number };
    };
    const c = j.candidates?.[0];
    const text = (c?.content?.parts ?? []).map((p) => p.text ?? "").join("");
    await logUsage("sweep (tandem)", model, {
      input_tokens: j.usageMetadata?.promptTokenCount ?? 0,
      output_tokens: (j.usageMetadata?.candidatesTokenCount ?? 0) + (j.usageMetadata?.thoughtsTokenCount ?? 0),
      server_tool_use: { web_search_requests: c?.groundingMetadata?.webSearchQueries?.length ?? 0 },
    } as never);
    return parseJSON(text);
  } catch (e) {
    console.error("gemini", (e as Error).message);
    return null;
  }
}
