// Claude looks at a taste photo and describes the style in the language of the agent's mission.
// The app shows the result, the person keeps what's right, and the app saves it.
import { type Agent, info, missionLabel } from "../_shared/match.ts";
import { HttpError, claude, db, enc, handle, json, parseJSON, requireUser, textOf } from "../_shared/platform.ts";

const VOCAB: Record<string, [string, string, string]> = {
  sneakers: ["silhouettes, colorways and materials", "brands", "collaborators and designers"],
  apparel: ["fits, fabrics and pieces", "labels", "collaborators and designers"],
  fragrance: ["notes and mood", "houses", "perfumers"],
  watches: ["styles and specs", "manufactures", "designers"],
  cars: ["eras, body styles and specs", "makes", "tuners and builders"],
  furniture: ["periods, materials and forms", "makers", "designers"],
  accessories: ["materials and pieces", "makers", "designers"],
  collectibles: ["sets, grades and formats", "brands and labels", "artists"],
};

export const handler = handle(async (req) => {
  const user = await requireUser(req);
  const body = await req.json().catch(() => ({})) as { agent_id?: string; image_base64?: string; media_type?: string };
  if (!body.agent_id || !body.image_base64) throw new HttpError(400, "agent_id and image_base64 are required");
  if (body.image_base64.length > 2_000_000) throw new HttpError(413, "That photo is too large. Try a smaller one.");
  const media = ["image/jpeg", "image/png", "image/webp"].includes(body.media_type ?? "") ? body.media_type! : "image/jpeg";

  const [a] = await db.select<Agent>("agents", `select=*&id=eq.${enc(body.agent_id)}&user_id=eq.${user.id}`);
  if (!a) throw new HttpError(404, "That agent isn't in your squad");
  const [traits, makers, creators] = VOCAB[a.mission_category ?? ""] ?? ["traits, materials, colors and era", "brands or makers", "creators"];

  const prompt = `You are ${a.name}, a personal shopping agent who hunts ${missionLabel(a)} for this person. They shared this photo to show you their taste.
Describe the style in the language of ${missionLabel(a)}: ${traits}, ${makers}, and ${creators}.
Name a brand, maker or creator only if a logo, label or signature design makes it clearly identifiable; otherwise leave that list empty. Never identify or describe people.
If the photo has nothing to do with ${missionLabel(a)}, still pull out style cues (colors, materials, era, mood) that could carry over.
Reply with only JSON: {"summary": "one friendly sentence in your voice about what you see and what it says about their taste", "traits": ["up to 6 short lowercase descriptors"], "makers": [], "creators": []}`;

  const res = await claude({
    max_tokens: 600,
    messages: [{ role: "user", content: [
      { type: "image", source: { type: "base64", media_type: media, data: body.image_base64 } },
      { type: "text", text: prompt },
    ] }],
  });
  const out = parseJSON<{ summary?: unknown; traits?: unknown; makers?: unknown; creators?: unknown }>(textOf(res.content)) ?? {};
  const list = (v: unknown, n: number, lower = false) => Array.isArray(v)
    ? v.filter((x) => typeof x === "string").map((x) => (lower ? (x as string).toLowerCase() : x as string).trim().slice(0, 40)).filter(Boolean).slice(0, n)
    : [];
  return json({
    summary: typeof out.summary === "string" ? out.summary.slice(0, 300) : "",
    traits: list(out.traits, 6, true),
    makers: list(out.makers, 3),
    creators: list(out.creators, 3),
    noun: info(a.mission_category).traitNoun,
  });
});
