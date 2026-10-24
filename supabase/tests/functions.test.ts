// Tests for the edge functions, run with: node --experimental-strip-types supabase/tests/functions.test.ts
// Claude, Supabase and Apple are replaced by a fake fetch that records every request.
import assert from "node:assert/strict";

process.env.SUPABASE_URL = "https://proj.supabase.co";
process.env.SUPABASE_SERVICE_ROLE_KEY = "eyJservice";
process.env.ANTHROPIC_API_KEY = "sk-test";
process.env.BAGET_CRON_SECRET = "s3cret-value";

type Route = (url: URL, init: RequestInit, body: any) => Response | Promise<Response>;
let routes: [RegExp, Route][] = [];
let calls: { method: string; url: string; body: any; headers: Record<string, string> }[] = [];
const ok = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
(globalThis as any).fetch = async (input: string, init: RequestInit = {}) => {
  const url = new URL(input);
  const body = init.body ? (() => { try { return JSON.parse(String(init.body)); } catch { return init.body; } })() : undefined;
  const headers = Object.fromEntries(Object.entries((init.headers ?? {}) as Record<string, string>).map(([k, v]) => [k.toLowerCase(), v]));
  calls.push({ method: init.method ?? "GET", url: url.toString(), body, headers });
  for (const [re, fn] of routes) if (re.test(`${init.method ?? "GET"} ${url.toString()}`)) return fn(url, init, body);
  throw new Error(`unexpected fetch ${init.method ?? "GET"} ${url}`);
};
const reset = (r: [RegExp, Route][]) => { routes = r; calls = []; };
const post = (path: string, body: unknown, headers: Record<string, string> = {}) =>
  new Request(`https://proj.supabase.co/functions/v1/${path}`, { method: "POST", body: JSON.stringify(body), headers: { "Content-Type": "application/json", ...headers } });

let passed = 0;
async function test(name: string, fn: () => unknown) {
  try { await fn(); passed++; console.log(`PASS ${name}`); } catch (e) { console.log(`FAIL ${name}\n  ${(e as Error).stack}`); process.exitCode = 1; }
}

const M = await import("../functions/_shared/match.ts");
const P = await import("../functions/_shared/platform.ts");
const A = await import("../functions/_shared/apns.ts");
const sweep = await import("../functions/sweep/handler.ts");
const chat = await import("../functions/chat/handler.ts");
const photo = await import("../functions/read-photo/handler.ts");
const push = await import("../functions/push/handler.ts");
const del = await import("../functions/delete-account/handler.ts");
const hunt = await import("../functions/hunt/handler.ts");
const daily = await import("../functions/_shared/daily.ts");

const jumpman = {
  id: "11111111-1111-1111-1111-111111111111", user_id: "aaaaaaaa-0000-0000-0000-000000000001", name: "Jumpman Scout",
  mission_category: "sneakers", mission_custom: null, keywords: ["aj1"], traits: ["suede", "low top"], makers: ["Jordan"],
  creators: ["Travis Scott"], size: "US M 10.5", mode: "ask", voice: "hype",
  learned: {}, price_note: 0,
} as any;
const ts = { title: "Travis Scott x Air Jordan 1 Low OG", brand: "Jordan", category: "sneakers", price: 150, market: 610, source: "Nike SNKRS",
  creator: "Travis Scott", traits: ["suede", "low top", "reverse swoosh"], tags: ["aj1"], sizes_in_stock: ["9", "10.5", "11"] } as any;

// ── shared logic ──
await test("match: strong fit with reasons and size", () => {
  const m = M.match(jumpman, ts, ["suede"])!;
  assert.ok(m.score >= 70, `score ${m.score}`);
  assert.ok(m.why.some((w) => w.startsWith("Matches your keywords")));
  assert.ok(m.why.includes("Made with Travis Scott, a collaborator you follow"));
  assert.ok(m.why.includes("Like your taste photos: suede"));
  assert.ok(m.why.includes("Shares your low top details"));
  assert.ok(m.why.includes("In stock in your size, US M 10.5"));
});
await test("match: not in your size is excluded", () => {
  const m = M.match(jumpman, { ...ts, sizes_in_stock: ["8", "9"] })!;
  assert.equal(m.notInSize, true);
});
await test("match: no size yet still finds sneakers (fit unknown), never says it's in your size", () => {
  const m = M.match({ ...jumpman, size: "" }, ts)!;
  assert.ok(m && !m.notInSize && m.score >= 45);
  assert.ok(!m.why.some((w) => w.includes("your size")));
});
await test("sizes convert across systems", () => {
  assert.equal(M.shoeUS("EU 44.5"), 10.5);
  assert.equal(M.shoeUS("UK 9.5"), 10.5);
  assert.equal(M.shoeUS("US W 12"), 10.5);
  assert.equal(M.topSize("l · 32x32"), "L");
});
await test("a typed-in mission trusts its own hunt", () => {
  const gear = { ...jumpman, mission_category: null, mission_custom: "outdoor gear", keywords: [], traits: [], makers: [], creators: [], size: "" };
  const pack = { ...ts, title: "Unbound 40L Backpack", brand: "Hyperlite Mountain Gear", category: "other", traits: ["ultralight"], tags: [], creator: null, sizes_in_stock: null };
  assert.equal(M.match(gear, pack), null, "a product it didn't hunt still needs the mission's words");
  const m = M.match(gear, pack, [], { own: true })!;
  assert.ok(m && m.score >= 45, "but its own find counts");
});
await test("custom mission matches by words", () => {
  const vinyl = { ...jumpman, mission_category: null, mission_custom: "first press vinyl", size: "" };
  assert.ok(M.covers(vinyl, { ...ts, category: "collectibles", title: "Daft Punk Discovery first press 2xLP", traits: ["vinyl"] }));
  assert.ok(!M.covers(vinyl, ts));
});
await test("friend voice and quiet hours", () => {
  const now = new Date("2026-10-08T03:30:00Z"); // 11:30pm in New York
  const line = M.friendLine(jumpman, "release", { ...ts, drop_at: "2026-10-11T14:00:00Z" }, 85, now.getTime());
  assert.match(line, /^Yo! The Travis Scott x Air Jordan 1 Low OG drops this week at Nike SNKRS\. Total suede energy\./);
  assert.equal(M.heldForMorning("available", ts, "America/New_York", true, now), true);
  assert.equal(M.heldForMorning("restock", ts, "America/New_York", true, now), false);
  assert.equal(M.heldForMorning("available", ts, "America/New_York", false, now), false);
  assert.equal(M.heldForMorning("available", ts, "Asia/Tokyo", true, now), false); // 12:30pm there
});
await test("parseJSON handles fences, prose and bare JSON", () => {
  assert.deepEqual(P.parseJSON('Here you go:\n```json\n{"a":1}\n```'), { a: 1 });
  assert.deepEqual(P.parseJSON('I found two. {"listings":[]} Hope that helps.'), { listings: [] });
  assert.deepEqual(P.parseJSON('[1,2]'), [1, 2]);
  assert.equal(P.parseJSON("no json here"), null);
});
await test("cleanListings drops anything without a real URL", () => {
  const out = sweep.cleanListings({ listings: [
    { title: "Real one", url: "https://www.nike.com/launch/t/x", price: 150, category: "sneakers", traits: ["Suede"], sizes_in_stock: ["10.5"] },
    { title: "Made up", url: "not a url" },
    { title: "", url: "https://x.com" },
    { title: "Wrong category", url: "https://kith.com/p", category: "spaceships", drop_at: "2026-10-12T15:00:00Z" },
  ] }, "sneakers");
  assert.equal(out.length, 2);
  assert.equal(out[0].fingerprint, "nike.com|real one");
  assert.deepEqual(out[0].traits, ["suede"]);
  assert.equal(out[1].category, "sneakers");
  assert.equal(out[1].drop_at, "2026-10-12T15:00:00.000Z");
});

// ── APNs signing ──
await test("APNs JWT is a valid ES256 signature", async () => {
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----`;
  for (const form of [pem, pem.replace(/\n/g, "\\n"), btoa(pem)]) {
    const jwt = await A.signJWT(form, "KEY123", "TEAM456", 1_790_000_000);
    const [h, c, s] = jwt.split(".");
    const dec = (x: string) => JSON.parse(atob(x.replace(/-/g, "+").replace(/_/g, "/")));
    assert.deepEqual(dec(h), { alg: "ES256", kid: "KEY123" });
    assert.deepEqual(dec(c), { iss: "TEAM456", iat: 1_790_000_000 });
    const sig = Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "==".slice((s.length * 3) % 4 ? 0 : 2)), (ch) => ch.charCodeAt(0));
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, kp.publicKey, sig.slice(0, 64), new TextEncoder().encode(`${h}.${c}`));
    assert.ok(valid, "signature verifies");
  }
});

// ── sweep ──
// The drop is always a couple of days out, so the test doesn't age into a "steal".
const soon = new Date(Date.now() + 2 * 86400_000).toISOString().slice(0, 10) + "T14:00:00Z";
const listingJSON = '```json\n{"listings":[{"title":"Travis Scott x Air Jordan 1 Low OG","brand":"Jordan","category":"sneakers","price":150,"market":610,"source":"Nike SNKRS","url":"https://www.nike.com/launch/t/ts-aj1","drop_at":"' + soon + '","sold_out":false,"creator":"Travis Scott","traits":["suede","low top"],"sizes_in_stock":["10.5","11"],"sku":"DM7866-140"},{"title":"Jordan 4 Bred","brand":"Jordan","category":"sneakers","price":215,"source":"Kith","url":"https://kith.com/aj4","traits":["leather"],"sizes_in_stock":["8","9"]}]}\n```';

await test("scheduled hunt (one scout, own worker): web search, continue a paused turn, score, notify", async () => {
  let claudeCalls = 0;
  reset([
    [/api\.anthropic\.com/, () => {
      claudeCalls++;
      return claudeCalls === 1
        ? ok({ content: [{ type: "server_tool_use", id: "srv1", name: "web_search", input: { query: "travis scott jordan 1 low release" } }], stop_reason: "pause_turn", usage: { input_tokens: 900, output_tokens: 40, server_tool_use: { web_search_requests: 2 } } })
        : ok({ content: [{ type: "text", text: "Found a couple.\n" + listingJSON }], stop_reason: "end_turn", usage: { input_tokens: 2000, output_tokens: 300, server_tool_use: { web_search_requests: 1 } } });
    }],
    [/rpc\/upsert_listings/, (_u, _i, b) => ok(b.p_listings.map((l: any, i: number) => ({ fingerprint: l.fingerprint, id: `0000000${i}-0000-0000-0000-000000000000`, already_found: false })))],
    [/rest\/v1\/taste_photos/, () => ok([{ tags: ["suede"] }])],
    [/rpc\/record_finds/, (_u, _i, b) => ok(b.p_finds.length)],
    [/rest\/v1\/sweep_runs/, () => new Response(null, { status: 201 })],
  ]);
  const res = await sweep.handler(post("sweep", { one: { ...jumpman, tz: "America/New_York", settings: { quietHours: false }, last_swept_at: null } },
    { "x-baget-secret": "s3cret-value" }));
  const out = await res.json();
  assert.equal(res.status, 200, JSON.stringify(out));
  assert.deepEqual(out, { swept: 1, found: 1, error: null });
  const claudeReq = calls.filter((c) => c.url.includes("anthropic"));
  assert.equal(claudeReq[0].headers["x-api-key"], "sk-test");
  assert.equal(claudeReq[0].body.tools[0].type, "web_search_20250305");
  assert.equal(claudeReq[0].body.tools[0].max_uses, 12, "deep search budget (no plan given counts as Pro)");
  assert.equal(claudeReq[0].body.tools[1].name, "web_fetch", "opens product pages to check them");
  assert.equal(claudeReq[1].body.messages.length, 2, "paused turn continued");
  assert.deepEqual(claudeReq[0].body.cache_control, { type: "ephemeral" }, "sweeps use prompt caching");
  assert.equal(claudeReq[0].body.cache, undefined, "the internal flag never reaches the API");
  assert.equal(claudeReq[0].body.purpose, undefined, "nor does the stats label");
  const usage = calls.filter((c) => c.url.includes("claude_usage")).map((c) => c.body);
  assert.equal(usage.length, 2, "each Claude call is logged for the stats screen");
  assert.equal(usage[0].fn, "sweep");
  assert.equal(usage[0].searches, 2);
  const rec = calls.find((c) => c.url.includes("record_finds"))!.body;
  assert.equal(rec.p_finds.length, 1, "the AJ4 isn't in his size, so only one find");
  assert.equal(rec.p_finds[0].note, undefined, "no photo yet, so no text: it waits until the photo is found");
  assert.ok(rec.p_finds[0].why.includes("Like your taste photos: suede"));
  const runLog = calls.find((c) => c.url.includes("sweep_runs") && c.body)!.body;
  assert.equal(runLog.searches, 3);
  assert.equal(runLog.input_tokens, 2900);
});
await test("scheduler claims due scouts and starts each hunt in its own worker", async () => {
  const started: any[] = [];
  reset([
    [/rpc\/claim_sweeps/, (_u, _i, b) => { assert.equal(b.p_limit, 20); return ok([{ ...jumpman, id: "a1" }, { ...jumpman, id: "a2" }]); }],
    [/rpc\/send_release_reminders/, () => ok(2)],
    [/POST .*functions\/v1\/sweep/, (_u, init, b) => { started.push({ b, secret: (init.headers as any)["x-baget-secret"] }); return ok({ swept: 1, found: 0 }); }],
  ]);
  const res = await sweep.handler(post("sweep", { mode: "scheduled" }, { "x-baget-secret": "s3cret-value" }));
  assert.deepEqual(await res.json(), { dispatched: 2, failed: 0, reminders: 2 });
  assert.deepEqual(started.map((x) => x.b.one.id), ["a1", "a2"]);
  assert.ok(started.every((x) => x.secret === "s3cret-value"), "each worker call is signed");
  const one = await sweep.handler(post("sweep", { one: { id: "x" } }, { "x-baget-secret": "wrong" }));
  assert.equal(one.status, 401, "a single hunt can't be started from outside");
});
await test("upkeep runs on its own and one failing step doesn't stop the rest", async () => {
  reset([
    [/GET .*rest\/v1\/listings\?select=id,url/, () => ok({ message: "boom" }, 500)],
    [/GET .*rest\/v1\/listings/, () => ok([])],
    [/rpc\/brands_needing_blurbs/, () => ok([])],
    [/rpc\/apply_brand_blurbs/, () => ok(0)],
  ]);
  process.env.CLAUDE_BATCH = "off";
  const out = await (await sweep.handler(post("sweep", { maintain: true }, { "x-baget-secret": "s3cret-value" }))).json();
  delete process.env.CLAUDE_BATCH;
  assert.equal(out.images, null);
  assert.deepEqual(out.about, { checked: 0, written: 0 });
  assert.deepEqual(out.brands, { brands: 0, written: 0, applied: 0 });
});
await test("sweep refuses callers without the secret or a session", async () => {
  reset([[/auth\/v1\/user/, () => ok({ msg: "bad jwt" }, 401)]]);
  const res = await sweep.handler(post("sweep", {}, { "x-baget-secret": "wrong" }));
  assert.equal(res.status, 401);
});
await test("manual sweep honors the cooldown", async () => {
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/rpc\/sweep_candidates/, (_u, _i, b) => { assert.equal(b.p_user, jumpman.user_id); return ok([]); }],
  ]);
  const res = await sweep.handler(post("sweep", { agent_id: jumpman.id }, { Authorization: "Bearer user-jwt" }));
  assert.equal(res.status, 200);
  assert.match((await res.json()).message, /swept recently/);
});
await test("no Claude key gives a clear message", async () => {
  delete process.env.ANTHROPIC_API_KEY;
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/rpc\/sweep_candidates/, () => ok([{ ...jumpman, tz: "UTC", settings: {}, last_swept_at: null }])],
    [/rest\/v1\/sweep_runs/, () => new Response(null, { status: 201 })],
  ]);
  const res = await sweep.handler(post("sweep", {}, { Authorization: "Bearer user-jwt" }));
  assert.equal(res.status, 503);
  assert.match((await res.json()).error, /API key/);
  process.env.ANTHROPIC_API_KEY = "sk-test";
});

// ── chat ──
await test("chat: updates the profile, flags a web find, replies in voice", async () => {
  let round = 0;
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/GET .*rest\/v1\/agents/, (u) => { assert.match(u.search, /user_id=eq\.aaaaaaaa/); return ok([jumpman]); }],
    [/GET .*rest\/v1\/finds\?select=status/, () => ok([{ status: "acquired", pass_reason: null, listing: { title: "Nike Dunk Low" } }])],
    [/GET .*rest\/v1\/taste_photos/, () => ok([{ summary: "Earthy suede", tags: ["suede", "brown"] }])],
    [/api\.anthropic\.com/, (_u, _i, b) => {
      round++;
      if (round === 1) {
        assert.match(b.system, /You are Jumpman Scout/);
        assert.equal(b.messages[0].content, "I'm really into earth tones lately. Anything new?");
        return ok({ stop_reason: "tool_use", content: [
          { type: "text", text: "Let me look." },
          { type: "tool_use", id: "t1", name: "update_profile", input: { add_traits: ["Earth Tones"] } },
          { type: "tool_use", id: "t2", name: "flag_find", input: { reason: "Earthy suede, your lane.", title: "Air Jordan 1 Low Mocha", url: "https://www.nike.com/t/aj1-mocha", price: 140, source: "Nike", brand: "Jordan", traits: ["suede", "brown"] } },
        ] });
      }
      const results = b.messages[b.messages.length - 1].content;
      assert.equal(results.length, 2);
      assert.ok(!results.some((r: any) => r.is_error), JSON.stringify(results));
      return ok({ stop_reason: "end_turn", content: [{ type: "text", text: "Earth tones, noted. The AJ1 Low Mocha is in your Finds." }] });
    }],
    [/PATCH .*rest\/v1\/agents/, (u, _i, b) => { assert.match(u.search, /user_id=eq\.aaaaaaaa/); assert.ok(b.traits.includes("earth tones")); return new Response(null, { status: 204 }); }],
    [/rpc\/upsert_listings/, (_u, _i, b) => { assert.equal(b.p_listings[0].fingerprint, "nike.com|air jordan 1 low mocha"); return ok([{ fingerprint: b.p_listings[0].fingerprint, id: "22222222-0000-0000-0000-000000000000", already_found: false }]); }],
    [/GET .*rest\/v1\/listings/, () => ok([{ id: "22222222-0000-0000-0000-000000000000", title: "Air Jordan 1 Low Mocha" }])],
    [/GET .*rest\/v1\/finds\?select=id&/, () => ok([])],
    [/POST .*rest\/v1\/finds/, (_u, _i, b) => { assert.equal(b.user_id, jumpman.user_id); return ok([{ id: "33333333-0000-0000-0000-000000000000" }], 201); }],
  ]);
  const res = await chat.handler(post("chat", { agent_id: jumpman.id, messages: [{ role: "user", content: "I'm really into earth tones lately. Anything new?" }] }, { Authorization: "Bearer user-jwt" }));
  const out = await res.json();
  assert.equal(res.status, 200, JSON.stringify(out));
  assert.equal(out.reply, "Earth tones, noted. The AJ1 Low Mocha is in your Finds.");
  assert.deepEqual(out.actions.map((x: any) => x.type), ["profile_updated", "find"]);
});
await test("chat: someone else's agent is refused", async () => {
  reset([[/auth\/v1\/user/, () => ok({ id: "bbbbbbbb-0000-0000-0000-000000000002" })], [/rest\/v1\/agents/, () => ok([])]]);
  const res = await chat.handler(post("chat", { agent_id: jumpman.id, messages: [{ role: "user", content: "hi" }] }, { Authorization: "Bearer other" }));
  assert.equal(res.status, 404);
});

// ── photo reading ──
await test("read-photo: sends the image, returns cleaned tags", async () => {
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/rest\/v1\/agents/, () => ok([jumpman])],
    [/api\.anthropic\.com/, (_u, _i, b) => {
      assert.equal(b.messages[0].content[0].type, "image");
      assert.equal(b.messages[0].content[0].source.media_type, "image/jpeg");
      assert.equal(b.cache_control, undefined, "one-shot calls skip caching");
      return ok({ stop_reason: "end_turn", content: [{ type: "text", text: '{"summary":"Earthy suede low-tops.","traits":["Suede","Earth Tones","low top"],"makers":["Jordan"],"creators":[]}' }] });
    }],
  ]);
  const res = await photo.handler(post("read-photo", { agent_id: jumpman.id, image_base64: "AAAA", media_type: "image/jpeg" }, { Authorization: "Bearer user-jwt" }));
  const out = await res.json();
  assert.deepEqual(out.traits, ["suede", "earth tones", "low top"]);
  assert.deepEqual(out.makers, ["Jordan"]);
});

// ── push ──
await test("push: delivers to each phone and drops dead tokens", async () => {
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
  Object.assign(process.env, { APNS_KEY_P8: btoa(String.fromCharCode(...der)), APNS_KEY_ID: "K1", APNS_TEAM_ID: "T1", APNS_TOPIC: "com.larry.baget" });
  const good = "a".repeat(64), dead = "b".repeat(64);
  reset([
    [/GET .*rest\/v1\/notes\?select=\*/, () => ok([{ id: "44444444-0000-0000-0000-000000000000", user_id: jumpman.user_id, body: "Yo! It drops tomorrow.", sender_name: "Jumpman Scout", kind: "release", find_id: null, held_for_morning: false, pushed_at: null }])],
    [/rest\/v1\/profiles\?select=settings/, () => ok([{ settings: { pushLevel: "all" } }])],
    [/rest\/v1\/device_tokens\?select/, () => ok([{ token: good, environment: "production" }, { token: dead, environment: "sandbox" }])],
    [/GET .*rest\/v1\/notes\?select=id/, () => ok([{ id: "x" }, { id: "y" }])],
    [/api\.push\.apple\.com/, (_u, init) => { const h = init.headers as any; assert.match(h.authorization, /^bearer ey/); assert.equal(h["apns-topic"], "com.larry.baget"); return new Response(null, { status: 200 }); }],
    [/api\.sandbox\.push\.apple\.com/, () => ok({ reason: "Unregistered" }, 410)],
    [/DELETE .*device_tokens/, (u) => { assert.ok(u.search.includes(dead)); return new Response(null, { status: 204 }); }],
    [/PATCH .*rest\/v1\/notes/, () => new Response(null, { status: 204 })],
  ]);
  const res = await push.handler(post("push", { note_id: "44444444-0000-0000-0000-000000000000" }, { "x-baget-secret": "s3cret-value" }));
  assert.deepEqual(await res.json(), { sent: 1 });
  const apns = calls.find((c) => c.url.includes("api.push.apple.com"))!;
  assert.equal(apns.body.aps.badge, 2);
  assert.equal(apns.body.aps.alert.title, "Jumpman Scout");
  assert.ok(calls.some((c) => c.method === "PATCH" && c.url.includes("notes")), "marked as pushed");
});

// ── account deletion ──
await test("delete-account removes photos then the account", async () => {
  let fbGone: string[] = [];
  reset([
    [/auth\/v1\/user$/, () => ok({ id: jumpman.user_id })],
    [/object\/list\/taste-photos/, (_u, _i, b) => b.prefix === `${jumpman.user_id}/`
      ? ok([{ name: "p1.jpg", id: "f1" }, { name: "avatars", id: null }])
      : (assert.equal(b.prefix, `${jumpman.user_id}/avatars/`), ok([{ name: "me.jpg", id: "f2" }]))],
    [/DELETE .*object\/taste-photos/, (_u, _i, b) => { assert.deepEqual(b.prefixes, [`${jumpman.user_id}/p1.jpg`, `${jumpman.user_id}/avatars/me.jpg`]); return ok([]); }],
    [/object\/list\/feedback/, () => ok([{ name: "shot.jpg", id: "f3" }])],
    [/DELETE .*object\/feedback/, (_u, _i, b) => { fbGone = b.prefixes; return ok([]); }],
    [/DELETE .*admin\/users/, (u) => { assert.ok(u.pathname.endsWith(jumpman.user_id)); return ok({}); }],
  ]);
  const res = await del.handler(post("delete-account", {}, { Authorization: "Bearer user-jwt" }));
  assert.deepEqual(await res.json(), { deleted: true });
  assert.deepEqual(fbGone, [`${jumpman.user_id}/shot.jpg`], "feedback screenshots go too");
});

// ── product photos ──
const I = await import("../functions/_shared/images.ts");
const html = (body: string) => new Response(body, { headers: { "content-type": "text/html" } });
const jpeg = (kb = 20) => new Response(new Uint8Array(kb * 1024), { headers: { "content-type": "image/jpeg" } });
const claudeSays = (match: number | null) => ok({ content: [{ type: "text", text: JSON.stringify({ match }) }], stop_reason: "end_turn" });

await test("imageCandidates: product schema first, logos and banners dropped", () => {
  const page = `<head><meta property="og:image" content="https://cdn.shop.com/share/og-default.jpg">
    <meta name="twitter:image" content="/img/p1.jpg?w=1200&amp;h=1200">
    <meta property="og:image" content="https://cdn.shop.com/assets/logo.png"></head>
    <body><script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"Organization","logo":"https://cdn.shop.com/l.png"},
      {"@type":"Product","name":"Hwyl","image":[{"@type":"ImageObject","url":"https:\\/\\/cdn.shop.com\\/products\\/hwyl-50ml.jpg"}]}]}</script></body>`;
  assert.deepEqual(I.imageCandidates(page, "https://shop.com/p/1"), ["https://cdn.shop.com/products/hwyl-50ml.jpg", "https://shop.com/img/p1.jpg?w=1200&h=1200"]);
  assert.equal(I.extractImage(`<meta property="og:image" content="//cdn.x.com/a.png">`, "https://x.com/p"), "https://cdn.x.com/a.png");
  assert.equal(I.extractImage(`<meta property="og:image" content="http://insecure.com/a.jpg">`, "https://x.com"), null);
  assert.equal(I.extractImage(`<meta property="og:image" content="https://x.com/logo.svg">`, "https://x.com"), null);
  assert.equal(I.extractImage(`<meta property="og:image" content="https://x.com/static/favicon-512.png">`, "https://x.com"), null);
});
await test("safePublicUrl refuses internal and odd addresses", () => {
  for (const bad of ["http://shop.com/p", "https://localhost/p", "https://169.254.169.254/latest", "https://10.0.0.1/",
                     "https://[::1]/", "https://shop.com:8443/p", "https://user:pw@shop.com/", "https://intranet/", "https://db.internal/"]) {
    assert.equal(I.safePublicUrl(bad), null, bad);
  }
  assert.ok(I.safePublicUrl("https://www.aesop.com/hwyl"));
});
await test("pages follow safe redirects only", async () => {
  const fake = async (u: string) => u.includes("/old")
    ? new Response(null, { status: 301, headers: { location: "/new" } })
    : u.includes("evil") ? new Response(null, { status: 302, headers: { location: "https://127.0.0.1/admin" } })
    : html(`<head><meta property="og:image" content="https://cdn.shop.com/p.jpg"></head>`);
  assert.equal(await I.findImage("https://shop.com/old", fake as never), "https://cdn.shop.com/p.jpg");
  assert.equal(await I.findImage("https://evil.com/x", fake as never), null);
  assert.equal(await I.findImage("https://192.168.1.1/x", fake as never), null);
});
await test("Claude picks the photo that shows the product, or none", async () => {
  const fake = async (u: string) => u.endsWith(".jpg") ? jpeg() : new Response("", { status: 404 });
  let sent: any;
  const pick2 = async (b: any) => { sent = b; return { content: [{ type: "text", text: '{"match": 2}' }], stop_reason: "end_turn" }; };
  assert.equal((await I.chooseImage({ title: "Hwyl", brand: "Aesop" }, ["https://c.com/a.jpg", "https://c.com/b.jpg"], fake as never, pick2 as never))?.source, "https://c.com/b.jpg");
  assert.equal(sent.messages[0].content.filter((c: any) => c.type === "image").length, 2);
  assert.match(sent.model, /haiku/);
  const none = async () => ({ content: [{ type: "text", text: '{"match": null}' }], stop_reason: "end_turn" });
  assert.equal(await I.chooseImage({ title: "Hwyl" }, ["https://c.com/a.jpg"], fake as never, none as never), null);
  const broken = async () => { throw new Error("overloaded"); };
  assert.equal(await I.chooseImage({ title: "Hwyl" }, ["https://c.com/a.jpg"], fake as never, broken as never), null);
  const tiny = async () => jpeg(1);
  assert.equal(await I.chooseImage({ title: "Hwyl" }, ["https://c.com/a.jpg"], tiny as never, pick2 as never), null);
});
await test("addImages drops a photo shared by two different products", async () => {
  const fake = async (u: string) => u.endsWith(".jpg") ? jpeg() : html(`<meta property="og:image" content="https://cdn.s.com/store-hero.jpg">`);
  const yes = async () => ({ content: [{ type: "text", text: '{"match": 1}' }], stop_reason: "end_turn" });
  const ls = [{ title: "A", url: "https://s.com/a", image_url: null }, { title: "B", url: "https://s.com/b", image_url: null }];
  await I.addImages(ls as never, fake as never, yes as never);
  assert.deepEqual(ls.map((l) => l.image_url), [null, null]);
});
await test("sweep saves only verified product photos", async () => {
  let saved: any[] = [];
  reset([
    [/api\.anthropic\.com/, (_u, _i, b) => !b.tools
      ? claudeSays(JSON.stringify(b).includes("Travis") ? 1 : null)
      : ok({ content: [{ type: "text", text: listingJSON }], stop_reason: "end_turn", usage: { input_tokens: 10, output_tokens: 10 } })],
    [/GET https:\/\/www\.nike\.com\/launch/, () => html(`<head><meta property="og:image" content="https://static.nike.com/ts.jpg"></head>`)],
    [/GET https:\/\/static\.nike\.com\/ts\.jpg/, () => jpeg()],
    [/GET https:\/\/kith\.com\/cdn/, () => jpeg()],
    [/GET https:\/\/kith\.com/, () => html(`<head><meta property="og:image" content="https://kith.com/cdn/aj4.jpg"></head>`)],
    [/POST .*storage\/v1\/object\/product-photos\//, () => ok({ Key: "x" })],
    [/rpc\/upsert_listings/, (_u, _i, b) => { saved = b.p_listings; return ok(saved.map((l: any, i: number) => ({ fingerprint: l.fingerprint, id: `l${i}`, already_found: false }))); }],
    [/taste_photos/, () => ok([])],
    [/rpc\/record_finds/, () => ok(1)],
    [/sweep_runs/, () => ok({})],
  ]);
  await sweep.sweepAgent({ ...jumpman, settings: {}, tz: "America/New_York" } as never, "manual");
  assert.match(saved.find((l) => l.url.includes("nike")).image_url, /^https:\/\/proj\.supabase\.co\/storage\/v1\/object\/public\/product-photos\/[0-9a-f]{32}\.jpg$/);
  assert.equal(saved.find((l) => l.url.includes("kith")).image_url, null, "Claude said the Kith photo isn't the product");
  assert.ok(calls.some((c) => c.url.includes("kith.com/cdn/aj4.jpg")), "the Kith photo was downloaded and shown to Claude");
});

await test("image search query drops mileage, sizes, item numbers and seller notes", () => {
  assert.equal(I.searchQuery("2026 Porsche 911 GT3 Coupe (Certified, 1,280 mi)", "Porsche"), "2026 Porsche 911 GT3 Coupe");
  assert.equal(I.searchQuery("Supreme Chino Pant (26SS) Black - 818989", "Supreme"), "Supreme Chino Pant Black");
  assert.equal(I.searchQuery("SS26 Supreme Chino Pant Playboy Black - Size 38", "Supreme"), "SS26 Supreme Chino Pant Playboy Black");
  assert.equal(I.searchQuery("Oud for Greatness Eau de Parfum 90ml", "Initio Parfums Privés"), "Initio Parfums Privés Oud for Greatness Eau de Parfum 90ml");
});
await test("search pages aren't products", () => {
  for (const bad of ["https://www.ebay.com/shop/supreme-chino?_nkw=supreme+chino", "https://www.ebay.com/sch/i.html?_nkw=x",
                     "https://www.amazon.com/s?k=oud", "https://www.harrods.com/en-us/search?q=oud", "https://www.nike.com/"]) {
    assert.equal(sweep.isSearchPage(bad), true, bad);
  }
  for (const good of ["https://www.ebay.com/itm/388812345678", "https://www.harrods.com/en-us/p/initio-oud-for-greatness-edp-90ml-000000000006433113",
                      "https://www.edmunds.com/inventory/vin.html?vin=WP0AC2A99TS260000"]) {
    assert.equal(sweep.isSearchPage(good), false, good);
  }
});
await test("image search through Serper, falling back to Google's thumbnail when the store blocks the full photo", async () => {
  process.env.SERPER_API_KEY = "serper-test";
  try {
    let asked: any;
    const fake = async (u: string, init: any = {}) => {
      if (u === "https://google.serper.dev/images") {
        asked = JSON.parse(init.body);
        return ok({ images: [
          { imageUrl: "https://blocked.com/gt3.jpg", thumbnailUrl: "https://encrypted-tbn0.gstatic.com/images?q=tbn:gt3", imageWidth: 1600, imageHeight: 900 },
          { imageUrl: "https://tiny.com/x.jpg", imageWidth: 100, imageHeight: 80 },
        ] });
      }
      if (u.includes("blocked.com")) return new Response("no", { status: 403 });
      if (u.includes("gstatic")) return jpeg(6);
      return new Response("", { status: 404 });
    };
    const hits = await I.imageSearch("2026 Porsche 911 GT3 Coupe", fake as never);
    assert.equal(asked.q, "2026 Porsche 911 GT3 Coupe");
    assert.equal(hits.length, 1, "tiny images are skipped");
    const yes = async () => ({ content: [{ type: "text", text: '{"match": 1}' }], stop_reason: "end_turn" });
    const chosen = await I.chooseImage({ title: "2026 Porsche 911 GT3 Coupe", category: "cars" }, hits, fake as never, yes as never);
    assert.equal(chosen?.source, "https://encrypted-tbn0.gstatic.com/images?q=tbn:gt3");
  } finally { delete process.env.SERPER_API_KEY; }
});
await test("made-up links (404) are dropped from a sweep", async () => {
  assert.equal(await I.linkIsDead("https://us.supreme.com/products/fake", (async () => new Response("", { status: 404 })) as never), true);
  assert.equal(await I.linkIsDead("https://www.edmunds.com/x", (async () => new Response("", { status: 403 })) as never), false);
});

await test("likes, buys and style passes steer the next web search", async () => {
  reset([[/rest\/v1\/finds/, (u) => {
    if (!/status=in/.test(u.search)) return ok([{ listing: { title: "Air Jordan 1 Low OG Mocha" } }, { listing: { title: "Dunk Low Panda" } }]);
    assert.match(u.search, /status=in\.\(liked,acquired,passed\)/);
    return ok([
      { status: "liked", pass_reason: null, listing: { title: "Air Jordan 1 Low OG Mocha", brand: "Jordan" } },
      { status: "acquired", pass_reason: null, listing: { title: "Jordan 4 Bred", brand: "Jordan" } },
      { status: "passed", pass_reason: "not my style", listing: { title: "Dunk Low Panda", brand: "Nike" } },
      { status: "passed", pass_reason: "too pricey", listing: { title: "Off-White Jordan 1", brand: "Jordan" } },
    ]);
  }]]);
  const r = await sweep.reactionsFor("agent-1");
  assert.deepEqual(r, { liked: ["Air Jordan 1 Low OG Mocha"], bought: ["Jordan 4 Bred"], passed: ["Nike Dunk Low Panda"],
                        seen: ["Air Jordan 1 Low OG Mocha", "Dunk Low Panda"] });
  const prompt = sweep.sweepPrompt({ ...jumpman, learned: { suede: 3, "patent leather": -2 } } as never, "2026-10-08", r);
  assert.match(prompt, /They liked: Air Jordan 1 Low OG Mocha/);
  assert.match(prompt, /They passed on as not their style: Nike Dunk Low Panda/);
  assert.match(prompt, /Leaning into lately.*suede/);
  assert.match(prompt, /find more in that spirit/);
  assert.doesNotMatch(prompt, /Off-White/, "a price pass isn't a taste signal");
  assert.doesNotMatch(prompt, /Max price|monthly/i);
  assert.match(prompt, /Already shown to them \(find different things\): Air Jordan 1 Low OG Mocha; Dunk Low Panda/);
  assert.match(prompt, /at least two discovery picks/);
});
await test("each sweep hunts from different angles", () => {
  const t0 = new Date("2026-10-08T12:00:00Z");
  const a1 = sweep.anglesFor("agent-1", t0), a2 = sweep.anglesFor("agent-1", new Date(t0.getTime() + 3 * 3600_000));
  assert.equal(a1.length, 3);
  assert.equal(new Set(a1).size, 3, "three different angles");
  assert.notDeepEqual(a1, a2, "the next run uses different angles");
  const seen = new Set<string>();
  for (let i = 0; i < 8; i++) seen.add(sweep.anglesFor("agent-1", new Date(t0.getTime() + i * 3 * 3600_000))[0]);
  assert.equal(seen.size, sweep.ANGLES.length, "a day of runs covers every angle");
});
await test("discovery picks keep the agent's own pitch and text you about it", async () => {
  const disc = '```json\n{"listings":[{"title":"Salehe Bembury x New Balance 2002R","brand":"New Balance","category":"sneakers","price":160,"source":"New Balance","url":"https://www.newbalance.com/pd/salehe-2002r/M2002R.html","traits":["suede"],"sizes_in_stock":["10.5"],"discovery":true,"pitch":"Same earthy suede you liked on the Mocha 1s, from a designer you have not tried yet."}]}\n```';
  let recorded: any[] = [];
  reset([
    [/api\.anthropic\.com/, (_u, _i, b) => !b.tools ? claudeSays(1)
      : ok({ content: [{ type: "text", text: disc }], stop_reason: "end_turn", usage: { input_tokens: 10, output_tokens: 10 } })],
    [/rest\/v1\/finds/, () => ok([])],
    [/rpc\/upsert_listings/, (_u, _i, b) => ok(b.p_listings.map((l: any) => ({ fingerprint: l.fingerprint, id: "l1", already_found: false })))],
    [/taste_photos/, () => ok([])],
    [/rpc\/record_finds/, (_u, _i, b) => { recorded = b.p_finds; return ok(recorded.length); }],
    [/sweep_runs/, () => ok({})],
    [/GET https:\/\/www\.newbalance\.com\/pd/, () => html(`<head><meta property="og:image" content="https://nb.scene7.com/2002r.jpg"></head>`)],
    [/GET https:\/\/nb\.scene7\.com/, () => jpeg()],
    [/POST .*storage\/v1\/object\/product-photos\//, () => ok({ Key: "x" })],
    [/newbalance\.com/, () => html("<head></head>")],
  ]);
  await sweep.sweepAgent({ ...jumpman, settings: {}, tz: "America/New_York" } as never, "manual", new Date("2026-10-08T15:00:00Z"));
  assert.equal(recorded.length, 1);
  assert.match(recorded[0].why[0], /earthy suede/);
  assert.match(recorded[0].why[1], /^Discovery/);
  assert.match(recorded[0].note.body, /didn't ask for but I think you'll love: Salehe Bembury/);
  const asked = calls.find((c) => /anthropic/.test(c.url) && c.body.tools);
  assert.equal(asked!.body.tools[0].max_uses, 12);
});

await test("Claude hiccups are retried, and people see a plain message if it keeps failing", async () => {
  let n = 0;
  reset([[/api\.anthropic\.com/, () => (++n === 1 ? new Response("overloaded", { status: 529 }) : ok({ content: [{ type: "text", text: "hi" }], stop_reason: "end_turn" }))]]);
  const r = await P.claude({ max_tokens: 10, messages: [{ role: "user", content: "x" }] });
  assert.equal(r.content[0].text, "hi");
  assert.equal(n, 2, "retried once after a 529");
  let logged: any;
  reset([
    [/api\.anthropic\.com/, () => new Response("upstream reset", { status: 500 })],
    [/rest\/v1\/function_errors/, (_u, _i, b) => { logged = b; return ok({}); }],
    [/auth\/v1\/user$/, () => ok({ id: jumpman.user_id })],
    [/rest\/v1\/agents/, () => ok([jumpman])],
    [/rest\/v1\/finds/, () => ok([])],
    [/rest\/v1\/taste_photos/, () => ok([])],
  ]);
  const res = await chat.handler(post("chat", { agent_id: jumpman.id, messages: [{ role: "user", content: "hey" }] }, { Authorization: "Bearer user-jwt" }));
  assert.equal(res.status, 502);
  assert.equal((await res.json()).error, "Your agent couldn't reach Claude just now. Try again in a moment.");
  assert.equal(calls.filter((c) => /anthropic/.test(c.url)).length, 3, "three attempts");
  assert.match(logged.message, /Claude 500 upstream reset/);
  assert.equal(logged.fn, "chat");
});

await test("chat keeps the same instructions for every step of a reply, even after learning something", async () => {
  const systems: string[] = [];
  let step = 0;
  reset([
    [/auth\/v1\/user$/, () => ok({ id: jumpman.user_id })],
    [/rest\/v1\/agents/, (_u, init) => (init.method === "PATCH" ? ok([]) : ok([jumpman]))],
    [/rest\/v1\/finds/, () => ok([])],
    [/rest\/v1\/taste_photos/, () => ok([])],
    [/api\.anthropic\.com/, (_u, _i, b) => {
      systems.push(b.system);
      assert.deepEqual(b.cache_control, { type: "ephemeral" }, "chat turns use prompt caching");
      step++;
      if (step === 1) return ok({ content: [{ type: "thinking", thinking: "...", signature: "sig" },
        { type: "tool_use", id: "t1", name: "update_profile", input: { add_traits: ["mocha suede"] } }], stop_reason: "tool_use" });
      return ok({ content: [{ type: "text", text: "Noted: mocha suede." }], stop_reason: "end_turn" });
    }],
  ]);
  const res = await chat.handler(post("chat", { agent_id: jumpman.id, messages: [{ role: "user", content: "I love mocha suede" }] }, { Authorization: "Bearer user-jwt" }));
  assert.equal(res.status, 200);
  assert.equal(systems.length, 2);
  assert.equal(systems[0], systems[1], "instructions unchanged after update_profile (so the cached prefix is reused)");
});
await test("a rejected thinking block is dropped and the step retried", async () => {
  let step = 0, retried: any;
  reset([
    [/auth\/v1\/user$/, () => ok({ id: jumpman.user_id })],
    [/rest\/v1\/agents/, (_u, init) => (init.method === "PATCH" ? ok([]) : ok([jumpman]))],
    [/rest\/v1\/finds/, () => ok([])],
    [/rest\/v1\/taste_photos/, () => ok([])],
    [/api\.anthropic\.com/, (_u, _i, b) => {
      step++;
      if (step === 1) return ok({ content: [{ type: "thinking", thinking: "...", signature: "sig" },
        { type: "tool_use", id: "t1", name: "update_profile", input: { size: "10.5" } }], stop_reason: "tool_use" });
      if (step === 2) return new Response('{"error":{"message":"messages.1.content.0: Invalid `signature` in `thinking` block"}}', { status: 400 });
      retried = b;
      return ok({ content: [{ type: "text", text: "Got your size." }], stop_reason: "end_turn" });
    }],
  ]);
  const res = await chat.handler(post("chat", { agent_id: jumpman.id, messages: [{ role: "user", content: "I'm a 10.5" }] }, { Authorization: "Bearer user-jwt" }));
  assert.equal(res.status, 200);
  assert.equal((await res.json()).reply, "Got your size.");
  assert.ok(!JSON.stringify(retried.messages).includes('"thinking"'), "thinking blocks removed on retry");
});

// ── extra data sources ──
const SRC = await import("../functions/_shared/sources.ts");
await test("search phrases come from what the agent knows and rotate between runs", () => {
  const a = { ...jumpman, makers: ["Jordan", "Nike"], keywords: ["aj1"], traits: ["suede"], creators: ["Travis Scott"] } as never;
  const t = new Date("2026-10-09T12:00:00Z");
  const q1 = SRC.queriesFor(a, ["Air Jordan 1 Low OG Mocha"], t), q2 = SRC.queriesFor(a, [], new Date(t.getTime() + 3 * 3600_000));
  assert.equal(q1.length, 2);
  assert.ok(q1.every((q: string) => q.length > 2));
  assert.notDeepEqual(q1, q2);
  const chatty = { ...jumpman, makers: ["Nike"], keywords: ["upcoming nike releases", "wants updates on every nike snkrs drop", "dunk"], traits: [], creators: [] } as never;
  const qs = new Set<string>();
  for (let i = 0; i < 6; i++) for (const q of SRC.queriesFor(chatty, [], new Date(t.getTime() + i * 3 * 3600_000))) qs.add(q);
  assert.ok(![...qs].some((q) => /wants|every/.test(q)), [...qs].join(" | "));
  assert.ok(![...qs].some((q) => /Nike nike/i.test(q)), "no doubled maker");
});
await test("sizes are read from eBay titles", () => {
  assert.deepEqual(SRC.sizesFromTitle("Nike Air Jordan 1 Low Mocha Size 10.5 DS", "sneakers"), ["10.5"]);
  assert.deepEqual(SRC.sizesFromTitle("Supreme Box Logo Hoodie Black Sz L FW25", "apparel"), ["L"]);
  assert.equal(SRC.sizesFromTitle("Porsche 911 GT3 2024", "cars"), null);
});
await test("eBay listings join a sweep with their own item page and photo", async () => {
  process.env.EBAY_CLIENT_ID = "id"; process.env.EBAY_CLIENT_SECRET = "secret";
  try {
    let saved: any[] = [], searched: URL | undefined;
    reset([
      [/identity\/v1\/oauth2\/token/, (_u, init) => { assert.match(String((init.headers as any).Authorization), /^Basic /); return ok({ access_token: "tok", expires_in: 7200 }); }],
      [/buy\/browse\/v1\/item_summary\/search/, (u) => { searched = u; return ok({ itemSummaries: [
        { itemId: "v1|1", title: "Air Jordan 1 Low OG Mocha Size 10.5 DS", itemWebUrl: "https://www.ebay.com/itm/388812345678?hash=x", price: { value: "189.99", currency: "USD" },
          image: { imageUrl: "https://i.ebayimg.com/images/g/abc/s-l1600.jpg" }, condition: "New with box" },
        { itemId: "v1|2", title: "Jordan 1 Low Size 8", itemWebUrl: "https://www.ebay.com/itm/388800000000", price: { value: "120", currency: "USD" } },
      ] }); }],
      [/api\.anthropic\.com/, () => ok({ content: [{ type: "text", text: '```json\n{"listings":[]}\n```' }], stop_reason: "end_turn", usage: {} })],
      [/rest\/v1\/finds/, () => ok([])],
      [/rpc\/upsert_listings/, (_u, _i, b) => { saved = b.p_listings; return ok(saved.map((l: any, i: number) => ({ fingerprint: l.fingerprint, id: `l${i}`, already_found: false }))); }],
      [/taste_photos/, () => ok([])],
      [/rpc\/record_finds/, (_u, _i, b) => ok(b.p_finds.length)],
      [/sweep_runs/, () => ok({})],
    ]);
    await sweep.sweepAgent({ ...jumpman, settings: {}, tz: "America/New_York" } as never, "scheduled", new Date("2026-10-09T15:00:00Z"));
    assert.equal(searched!.searchParams.get("category_ids"), "15709");
    assert.match(searched!.searchParams.get("filter")!, /FIXED_PRICE/);
    const mocha = saved.find((l) => l.title.includes("Mocha"));
    assert.equal(mocha.url, "https://www.ebay.com/itm/388812345678");
    assert.equal(mocha.image_url, "https://i.ebayimg.com/images/g/abc/s-l1600.jpg");
    assert.equal(mocha.price, 189.99);
    assert.deepEqual(mocha.sizes_in_stock, ["10.5"]);
    assert.equal(mocha.source, "eBay");
    assert.ok(!calls.some((c) => c.url.includes("i.ebayimg.com")), "eBay photos aren't re-checked");
  } finally { delete process.env.EBAY_CLIENT_ID; delete process.env.EBAY_CLIENT_SECRET; }
});
await test("Google Shopping leads go into the agent's brief, to be verified", async () => {
  process.env.SERPER_API_KEY = "serper-test";
  try {
    reset([[/google\.serper\.dev\/shopping/, () => ok({ shopping: [
      { title: "Amouage Material Eau de Parfum 100ml", source: "Neiman Marcus", price: "$385.00", link: "https://www.google.com/shopping/product/1" },
      { title: "Amouage Material EDP 100 ml", source: "Saks", price: "$385.00" },
    ] })]]);
    const leads = await SRC.shoppingLeads(["Amouage oud"]);
    assert.equal(leads.length, 2);
    const prompt = sweep.sweepPrompt(jumpman as never, "2026-10-09", undefined, undefined, leads);
    assert.match(prompt, /Leads from Google Shopping right now \(unverified/);
    assert.match(prompt, /Amouage Material Eau de Parfum 100ml \| Neiman Marcus \| \$385\.00/);
  } finally { delete process.env.SERPER_API_KEY; }
});

// ── UX overhaul: hunt box, deal prices, watches, morning digest ──
await test("one sentence becomes an agent", async () => {
  let inserted: any;
  reset([
    [/auth\/v1\/user$/, () => ok({ id: jumpman.user_id })],
    [/api\.anthropic\.com/, () => ok({ content: [{ type: "text", text: '{"name":"Oud Hunter","category":"fragrance","custom":null,"keywords":["oud"],"makers":["Frederic Malle","Amouage"],"traits":["oud","saffron","a very very long trait that should be dropped because it is way too long"],"creators":["Dominique Ropion"],"size":"","voice":"chill","intro":"On it: oud in the Frederic Malle lane."}' }], stop_reason: "end_turn" })],
    [/POST .*rest\/v1\/agents/, (_u, _i, b) => { inserted = b; return ok([{ id: "new-agent" }]); }],
  ]);
  const res = await hunt.handler(post("hunt", { text: "oud fragrances like Frederic Malle" }, { Authorization: "Bearer user-jwt" }));
  const out = await res.json();
  assert.equal(res.status, 200);
  assert.equal(out.agent_id, "new-agent");
  assert.equal(out.intro, "On it: oud in the Frederic Malle lane.");
  assert.equal(inserted.user_id, jumpman.user_id);
  assert.equal(inserted.mission_category, "fragrance");
  assert.deepEqual(inserted.makers, ["Frederic Malle", "Amouage"]);
  assert.deepEqual(inserted.traits, ["oud", "saffron"]);
  assert.equal(out.needs_size, false);
});
await test("a hunt that fits no category becomes a custom mission; sneakers without a size ask for one", () => {
  const custom = hunt.cleanPlan({ name: "Nest Finder", category: null, custom: "high-rise apartments in McLean" }, "apartments");
  assert.equal(custom.category, null);
  assert.equal(custom.custom, "high-rise apartments in McLean");
  const bad = hunt.cleanPlan({ category: "spaceships" }, "a rocket");
  assert.equal(bad.category, null);
  assert.equal(bad.custom, "a rocket");
  assert.equal(hunt.cleanPlan({ category: "sneakers" }, "jordans", "US M 10.5").size, "US M 10.5");
});
await test("other stores' prices: same product only, cheapest first", async () => {
  process.env.SERPER_API_KEY = "serper-test";
  try {
    const fake = async () => ok({ shopping: [
      { title: "Amouage Material Eau de Parfum 100ml", source: "Saks", price: "$385.00" },
      { title: "Amouage Material EDP 100 ml Eau de Parfum", source: "FragranceNet", price: "$1,299.99" },
      { title: "Amouage Material Eau de Parfum 100ml", source: "Jomashop", price: "$299.00" },
      { title: "Totally different candle", source: "Target", price: "$12.00" },
      { title: "Amouage Material Eau de Parfum 100ml", source: "Saks", price: "$390.00" },
    ] });
    const offers = await SRC.shoppingOffers("Amouage Material Eau de Parfum 100ml", fake as never);
    assert.deepEqual(offers.map((o: any) => o.store), ["Jomashop", "Saks", "FragranceNet"]);
    assert.equal(offers[0].price, 299);
    assert.equal(offers[2].price, 1299.99);
  } finally { delete process.env.SERPER_API_KEY; }
});
await test("other stores' prices skip samples, decants and odd low prices", async () => {
  process.env.SERPER_API_KEY = "serper-test";
  try {
    const fake = async () => ok({ shopping: [
      { title: "Nasomatto Pardon Extrait de Parfum Sample Vial", source: "Nicchia Luxury", price: "$6.00" },
      { title: "Nasomatto Pardon Extrait de Parfum 2ml", source: "CologneCurators", price: "$9.99" },
      { title: "Nasomatto Pardon Extrait de Parfum 5ml Decant", source: "Scents Angel", price: "$30.00" },
      { title: "Nasomatto Pardon Extrait de Parfum", source: "DecantX", price: "$35.09" },
      { title: "Nasomatto Pardon Extrait de Parfum 30ml", source: "Luckyscent", price: "$175.00" },
      { title: "Nasomatto Pardon Extrait de Parfum", source: "Nordstrom", price: "$180.00" },
      { title: "Nasomatto Pardon Extrait de Parfum", source: "Some Shop", price: "$18.00" },
      { title: "Nasomatto Pardon Extrait de Parfum", source: "FragranceNet", price: "$150.00" },
    ] });
    const offers = await SRC.shoppingOffers("Pardon Extrait de Parfum", fake as never);
    assert.deepEqual(offers.map((o: any) => o.store), ["FragranceNet", "Luckyscent", "Nordstrom"]);
    assert.equal(SRC.partialSize("Amouage Material 100ml", "Amouage Material Eau de Parfum 100ml"), false);
    assert.equal(SRC.partialSize("Amouage Material 10ml travel", "Amouage Material Eau de Parfum 100ml"), true);
  } finally { delete process.env.SERPER_API_KEY; }
});
await test("watched finds text you when the price drops 5% or more", async () => {
  process.env.SERPER_API_KEY = "serper-test";
  try {
    let note: any, newWatch: any;
    reset([
      [/GET .*rest\/v1\/finds/, () => ok([
        { id: "f1", user_id: "u1", agent_id: "a1", watch_price: 400, agent: { name: "Mr smellgoods" },
          listing: { id: "l1", title: "Amouage Material Eau de Parfum 100ml", price: 400, low_price: 400, offers_checked_at: null } },
        { id: "f2", user_id: "u1", agent_id: "a1", watch_price: null, agent: { name: "Mr smellgoods" },
          listing: { id: "l2", title: "Fresh one", price: 100, low_price: null, offers_checked_at: new Date().toISOString() } },
      ])],
      [/google\.serper\.dev\/shopping/, () => ok({ shopping: [{ title: "Amouage Material Eau de Parfum 100ml", source: "Jomashop", price: "$299.00" }] })],
      [/PATCH .*rest\/v1\/listings/, () => ok([])],
      [/PATCH .*rest\/v1\/finds/, (_u, _i, b) => { newWatch = b; return ok([]); }],
      [/POST .*rest\/v1\/notes/, (_u, _i, b) => { note = b; return ok([]); }],
    ]);
    const r = await daily.watchCheck(6, new Date(), fetch as never);
    assert.deepEqual(r, { checked: 1, drops: 1 }, "the item checked an hour ago waits");
    assert.equal(note.kind, "drop");
    assert.equal(note.find_id, "f1");
    assert.match(note.body, /just dropped to \$299 at Jomashop\. That's \$101 off/);
    assert.equal(newWatch.watch_price, 299);
  } finally { delete process.env.SERPER_API_KEY; }
});
await test("Today's Drop goes out once, at 8am local time", async () => {
  let notes: any[] = [], marked: any;
  const route = (people: any[]) => reset([
    [/GET .*rest\/v1\/profiles/, () => ok(people)],
    [/GET .*rest\/v1\/finds/, () => ok([{ id: "f9", score: 91, listing: { title: "2023 Porsche 911 Carrera T" }, agent: { name: "Porsche Boy" } },
                                         { id: "f8", score: 80, listing: { title: "Lumen 2BR" }, agent: { name: "HomWrecka" } }])],
    [/PATCH .*rest\/v1\/profiles/, (_u, _i, b) => { marked = b; return ok([]); }],
    [/POST .*rest\/v1\/notes/, (_u, _i, b) => { notes.push(b); return ok([]); }],
  ]);
  const eightNY = new Date("2026-10-09T12:15:00Z");   // 8:15am in New York
  route([{ id: "u1", tz: "America/New_York", last_digest_on: null }, { id: "u2", tz: "America/Los_Angeles", last_digest_on: null }]);
  assert.equal(await daily.morningDigest(eightNY), 1);
  assert.equal(notes[0].kind, "digest");
  assert.equal(notes[0].user_id, "u1");
  assert.match(notes[0].body, /Your squad found 2 things for you: 2023 Porsche 911 Carrera T and Lumen 2BR\./);
  assert.equal(marked.last_digest_on, "2026-10-09");
  notes = [];
  route([{ id: "u1", tz: "America/New_York", last_digest_on: "2026-10-09" }]);
  assert.equal(await daily.morningDigest(eightNY), 0, "already sent today");
});

await test("onboarding: picked interests plus photos become a tuned squad", async () => {
  const inserted: any[] = [];
  let sent: any;
  reset([
    [/auth\/v1\/user$/, () => ok({ id: jumpman.user_id })],
    [/api\.anthropic\.com/, (_u, _i, b) => { sent = b; return ok({ content: [{ type: "text", text: JSON.stringify({ agents: [
      { name: "Oud Hunter", category: "fragrance", makers: ["Frederic Malle"], traits: ["oud"], voice: "chill", intro: "On it." },
    ] }) }], stop_reason: "end_turn" }); }],
    [/GET .*rest\/v1\/agents/, () => ok([])],
    [/rest\/v1\/agents/, (_u, _i, b) => { inserted.push(b); return ok([{ id: `a${inserted.length}` }]); }],
  ]);
  const res = await hunt.handler(post("hunt", { categories: ["fragrance", "sneakers", "nonsense"], text: "dark woody stuff",
    images: [{ media_type: "image/jpeg", data: "AAAA" }, { media_type: "image/gif", data: "BBBB" }] }, { Authorization: "Bearer user-jwt" }));
  const body = await res.json();
  assert.equal(res.status, 200);
  assert.equal(body.agents.length, 2, "fragrance from Claude, sneakers filled in");
  assert.deepEqual(inserted.map((r) => r.mission_category).sort(), ["fragrance", "sneakers"]);
  assert.equal(body.agents.find((a: any) => a.category === "sneakers").needs_size, true);
  const content = sent.messages[0].content;
  assert.equal(content.filter((c: any) => c.type === "image").length, 1, "only supported photo types are sent");
  assert.match(content.at(-1).text, /fragrance, sneakers/);
});

await test("how often Baget texts you: best, all and daily", async () => {
  const note = (kind: string, find_id: string | null = "f1") => ({ id: "n1", user_id: jumpman.user_id, body: "x", sender_name: "A", kind, find_id, held_for_morning: false, pushed_at: null });
  const setup = (level: string | null, score: number, sentToday: number) => reset([
    [/rest\/v1\/profiles/, () => ok([{ settings: level ? { pushLevel: level } : {} }])],
    [/rest\/v1\/finds/, () => ok([{ score }])],
    [/rest\/v1\/notes/, () => ok(Array.from({ length: sentToday }, (_, i) => ({ id: `p${i}` })))],
  ]);
  setup(null, 90, 0); assert.equal(await push.shouldText(note("available") as never), true, "default is best; strong match texts");
  setup(null, 70, 0); assert.equal(await push.shouldText(note("available") as never), false, "weak match stays in the inbox");
  setup("best", 95, 6); assert.equal(await push.shouldText(note("available") as never), false, "best caps at 6 a day");
  setup("all", 40, 50); assert.equal(await push.shouldText(note("available") as never), true);
  setup("daily", 99, 0); assert.equal(await push.shouldText(note("release") as never), false);
  setup("daily", 0, 0);
  for (const k of ["digest", "drop", "restock", "friend", "bought"]) assert.equal(await push.shouldText(note(k, null) as never), true, k);
});

await test("per-agent switches: off and paused never text, quiet only top finds", async () => {
  const note = { id: "n1", user_id: jumpman.user_id, agent_id: "a1", body: "x", sender_name: "A", kind: "available", find_id: "f1", held_for_morning: false, pushed_at: null };
  const setup = (alerts: string, paused: boolean, score: number) => reset([
    [/rest\/v1\/agents/, () => ok([{ alerts, paused }])],
    [/rest\/v1\/profiles/, () => ok([{ settings: { pushLevel: "all" } }])],
    [/rest\/v1\/finds/, () => ok([{ score }])],
    [/rest\/v1\/notes/, () => ok([])],
  ]);
  setup("off", false, 99); assert.equal(await push.shouldText(note as never), false, "off");
  setup("normal", true, 99); assert.equal(await push.shouldText(note as never), false, "paused");
  setup("quiet", false, 88); assert.equal(await push.shouldText(note as never), false, "quiet skips good-not-great");
  setup("quiet", false, 92); assert.equal(await push.shouldText(note as never), true, "quiet texts top finds");
  setup("normal", false, 40); assert.equal(await push.shouldText(note as never), true, "normal follows the account (all)");
  setup("off", false, 99); assert.equal(await push.shouldText({ ...note, kind: "drop" } as never), true, "price drops you watch still text");
});

await test("personal texts: the agent writes them, with your name and taste; templates are the fallback", async () => {
  const daily = await import("../functions/_shared/daily.ts");
  assert.equal(sweep.firstName("Larry White"), "Larry");
  assert.equal(sweep.firstName("The Larry"), "Larry");
  assert.equal(sweep.firstName("lw_1567"), "", "handles aren't names");
  assert.equal(sweep.firstName(""), "");
  const prompt = sweep.sweepPrompt({ ...jumpman, voice: "hype" } as never, "2026-10-12", undefined, undefined, [], "Larry");
  assert.match(prompt, /"text"/);
  assert.match(prompt, /Use their name, Larry/);
  assert.match(prompt, /since you liked/);
  assert.doesNotMatch(sweep.sweepPrompt(jumpman as never, "2026-10-12"), /Use their name/);
  const raw = { listings: [{ title: "Air Jordan 1 Low Mocha", url: "https://www.nike.com/t/aj1-mocha", price: 140, source: "Nike",
    text: "“Larry, Nike just put the Mocha 1 Lows back up for $140. Same suede you loved on the Travis pair.”" }] };
  const [l] = sweep.cleanListings(raw, "sneakers");
  assert.equal(l.text, "Larry, Nike just put the Mocha 1 Lows back up for $140. Same suede you loved on the Travis pair.", "quotes trimmed");
  assert.equal(sweep.cleanText("ok"), "", "too short to be a real text");
  assert.equal(sweep.cleanText(42), "");
  assert.equal(daily.digestText("Larry", ["A", "B", "C"]), "Morning Larry! Your squad found 3 things for you: A, B and 1 more. Take a look when you have a sec.");
  assert.match(daily.digestText("", ["Seiko SPB143"], "Watch Desk"), /^Morning! Watch Desk found something for you: Seiko SPB143\./);
  reset([[/rest\/v1\/finds/, () => ok([{ listing: { title: "Travis Scott x Air Jordan 1 Low OG Reverse Mocha Sail Ridgerock", price: 1500, source: "StockX", image_url: "https://proj.supabase.co/storage/v1/object/public/product-photos/x.jpg" } }])]]);
  assert.equal(await push.findSubtitle("f1"), "Travis Scott x Air Jordan 1 Low OG Reverse… · $1,500 · StockX");
  assert.equal((await push.findInfo("f1")).image, "https://proj.supabase.co/storage/v1/object/public/product-photos/x.jpg", "the photo rides along for the notification extension");
  reset([]);
  assert.equal(await push.findSubtitle("f1"), "", "no subtitle if the lookup fails");
});

await test("buy links: logged, forwarded to the listing's own page, affiliate-wrapped when configured", async () => {
  const go = await import("../functions/go/handler.ts");
  const lid = "11111111-2222-3333-4444-555555555555";
  const clicks: any[] = [];
  reset([
    [/rest\/v1\/listings/, () => ok([{ url: "https://www.nike.com/t/aj1-mocha" }])],
    [/rest\/v1\/buy_clicks/, (_u, _i, b) => { clicks.push(b); return new Response(null, { status: 201 }); }],
  ]);
  let r = await go.handler(new Request(`https://proj.supabase.co/functions/v1/go?l=${lid}&s=find`));
  assert.equal(r.status, 302);
  assert.equal(r.headers.get("location"), "https://www.nike.com/t/aj1-mocha");
  assert.equal(clicks[0].source, "find");
  assert.equal(clicks[0].affiliate, "");
  process.env.SKIMLINKS_ID = "123X456";
  r = await go.handler(new Request(`https://proj.supabase.co/functions/v1/go?l=${lid}&s=for_you`));
  assert.equal(r.headers.get("location"), "https://go.skimresources.com/?id=123X456&xs=1&url=https%3A%2F%2Fwww.nike.com%2Ft%2Faj1-mocha");
  assert.equal(clicks[1].affiliate, "skimlinks");
  delete process.env.SKIMLINKS_ID;
  process.env.AMAZON_TAG = "baget-20";
  assert.equal(go.affiliateURL("https://www.amazon.com/dp/B0X?th=1").url, "https://www.amazon.com/dp/B0X?th=1&tag=baget-20");
  delete process.env.AMAZON_TAG;
  r = await go.handler(new Request("https://proj.supabase.co/functions/v1/go?l=https://evil.example"));
  assert.equal(r.status, 404, "only listing ids, never raw URLs");
});

await test("onboarding: taste-check picks shape the briefs, and each agent says hi", async () => {
  let prompt = "";
  const notes: any[] = [];
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/api\.anthropic\.com/, (_u, _i, b) => { prompt = b.messages[0].content.at(-1).text;
      return ok({ stop_reason: "end_turn", content: [{ type: "text", text: '{"agents":[{"name":"Mocha Hunter","category":"sneakers","intro":"I\'m on earthy suede Jordans."}]}' }] }); }],
    [/rest\/v1\/agents/, () => ok([{ id: "a1" }])],
    [/rest\/v1\/profiles/, () => ok([{ display_name: "Larry White" }])],
    [/POST .*rest\/v1\/notes/, (_u, _i, b) => { notes.push(...b); return new Response(null, { status: 201 }); }],
  ]);
  const res = await hunt.handler(post("hunt", { categories: ["sneakers"], text: "", liked: ["Air Jordan 1 Low Mocha"], passed: ["Crocs Classic Clog"] }, { Authorization: "Bearer user-jwt" }));
  assert.equal(res.status, 200);
  assert.match(prompt, /hearted: Air Jordan 1 Low Mocha/);
  assert.match(prompt, /passed on: Crocs Classic Clog/);
  assert.equal(notes.length, 1);
  assert.equal(notes[0].kind, "learned", "intro shows in the inbox without buzzing the phone");
  assert.match(notes[0].body, /^Hey Larry, Mocha Hunter here\. I'm on earthy suede Jordans\./);
});

await test("Pro: verified App Store purchases unlock it; forged, foreign or shared ones don't", async () => {
  const sub = await import("../functions/subscription/handler.ts");
  process.env.APNS_TOPIC = "com.larry.baget";
  const tx = (o: Record<string, unknown> = {}) => ({ bundleId: "com.larry.baget", productId: "baget.pro.monthly", originalTransactionId: "2000000123",
    expiresDate: Date.now() + 30 * 86400_000, appAccountToken: jumpman.user_id, environment: "Sandbox", ...o });
  let current: any = tx();
  const handler = sub.makeHandler(async (jws: string) => { if (jws === "forged") throw new Error("bad signature"); return current; });
  const patches: any[] = [];
  let owner: any[] = [];
  const routes = (): [RegExp, any][] => [
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/rest\/v1\/profiles\?select=id&original_transaction_id/, () => ok(owner)],
    [/GET .*rest\/v1\/profiles\?select=plan/, () => ok([{ plan: "free" }])],
    [/PATCH .*rest\/v1\/profiles/, (_u: any, _i: any, b: any) => { patches.push(b); return new Response(null, { status: 204 }); }],
    [/rest\/v1\/function_errors/, () => new Response(null, { status: 201 })],
  ];
  reset(routes());
  let r = await handler(post("subscription", { signed_transaction: "ok" }, { Authorization: "Bearer user-jwt" }));
  let out = await r.json();
  assert.equal(r.status, 200, JSON.stringify(out));
  assert.equal(out.pro, true);
  assert.equal(patches[0].plan, "pro");
  assert.equal(patches[0].original_transaction_id, "2000000123");

  r = await handler(post("subscription", { signed_transaction: "forged" }, { Authorization: "Bearer user-jwt" }));
  assert.equal(r.status, 400, "a forged purchase is refused");

  current = tx({ bundleId: "com.someone.else" });
  r = await handler(post("subscription", { signed_transaction: "ok" }, { Authorization: "Bearer user-jwt" }));
  assert.equal(r.status, 400, "another app's purchase is refused");

  current = tx({ appAccountToken: "99999999-0000-0000-0000-000000000000" });
  r = await handler(post("subscription", { signed_transaction: "ok" }, { Authorization: "Bearer user-jwt" }));
  assert.equal(r.status, 409, "someone else's subscription can't be claimed");

  current = tx({ appAccountToken: undefined });
  owner = [{ id: "88888888-0000-0000-0000-000000000000" }];
  r = await handler(post("subscription", { signed_transaction: "ok" }, { Authorization: "Bearer user-jwt" }));
  assert.equal(r.status, 409, "one subscription, one account");

  owner = [{ id: jumpman.user_id }];
  current = tx({ expiresDate: Date.now() - 1000 });
  patches.length = 0;
  r = await handler(post("subscription", { signed_transaction: "ok" }, { Authorization: "Bearer user-jwt" }));
  out = await r.json();
  assert.equal(out.pro, false, "an expired subscription doesn't unlock Pro");

  current = { data: { signedTransactionInfo: "ok" } };
  const inner = tx({ revocationDate: Date.now() - 5000 });
  const handler2 = sub.makeHandler(async (jws: string) => jws === "note" ? current : inner);
  patches.length = 0;
  r = await handler2(post("subscription", { signedPayload: "note" }));
  assert.equal(r.status, 200);
  assert.ok(Date.parse(patches[0].pro_until) < Date.now(), "a refund from Apple ends Pro");
});

await test("Pro on Android: a Google Play purchase unlocks it; someone else's doesn't", async () => {
  const sub = await import("../functions/subscription/handler.ts");
  const later = new Date(Date.now() + 30 * 86400_000).toISOString();
  let current: any = { subscriptionState: "SUBSCRIPTION_STATE_ACTIVE", externalAccountIdentifiers: { obfuscatedExternalAccountId: jumpman.user_id },
    lineItems: [{ productId: "baget.pro.yearly", expiryTime: later }] };
  const handler = sub.makeHandler(async () => { throw new Error("not apple"); }, async (pkg: string, token: string) => {
    assert.equal(pkg, "app.baget"); assert.equal(token, "play-token-123456"); return current;
  });
  const patches: any[] = [];
  let held: any[] = [];
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/GET .*rest\/v1\/play_subscriptions/, () => ok(held)],
    [/POST .*rest\/v1\/play_subscriptions/, () => new Response(null, { status: 201 })],
    [/PATCH .*rest\/v1\/play_subscriptions/, () => new Response(null, { status: 204 })],
    [/GET .*rest\/v1\/profiles\?select=plan/, () => ok([{ plan: "free", pro_until: null }])],
    [/PATCH .*rest\/v1\/profiles/, (_u: any, _i: any, b: any) => { patches.push(b); return new Response(null, { status: 204 }); }],
    [/rest\/v1\/function_errors/, () => new Response(null, { status: 201 })],
  ]);
  const body = { platform: "android", product_id: "baget.pro.yearly", purchase_token: "play-token-123456" };
  let r = await handler(post("subscription", body, { Authorization: "Bearer user-jwt" }));
  let out = await r.json();
  assert.equal(r.status, 200, JSON.stringify(out));
  assert.equal(out.pro, true);
  assert.equal(patches[0].plan, "pro");
  assert.equal(patches[0].pro_until, later);

  current = { ...current, externalAccountIdentifiers: { obfuscatedExternalAccountId: "99999999-0000-0000-0000-000000000000" } };
  r = await handler(post("subscription", body, { Authorization: "Bearer user-jwt" }));
  assert.equal(r.status, 409, "a purchase made from another Baget account can't be claimed");

  current = { ...current, externalAccountIdentifiers: {} };
  held = [{ user_id: "88888888-0000-0000-0000-000000000000" }];
  r = await handler(post("subscription", body, { Authorization: "Bearer user-jwt" }));
  assert.equal(r.status, 409, "one subscription, one account");

  held = [];
  current = { subscriptionState: "SUBSCRIPTION_STATE_EXPIRED", lineItems: [{ productId: "baget.pro.yearly", expiryTime: new Date(Date.now() - 1000).toISOString() }] };
  r = await handler(post("subscription", body, { Authorization: "Bearer user-jwt" }));
  out = await r.json();
  assert.equal(out.pro, false, "an expired Play subscription doesn't unlock Pro");
});

await test("push: Android phones get a data message through FCM", async () => {
  const kp = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
  const pem = "-----BEGIN PRIVATE KEY-----\n" + btoa(String.fromCharCode(...der)) + "\n-----END PRIVATE KEY-----\n";
  process.env.GOOGLE_SERVICE_ACCOUNT = JSON.stringify({ client_email: "push@baget.iam.gserviceaccount.com", private_key: pem, project_id: "baget-app" });
  const phone = "fcm_Token:APA91b" + "x".repeat(120);
  reset([
    [/GET .*rest\/v1\/notes\?select=\*/, () => ok([{ id: "55555555-0000-0000-0000-000000000000", user_id: jumpman.user_id, body: "Found one for you!", sender_name: "Jumpman Scout", kind: "available", find_id: null, held_for_morning: false, pushed_at: null }])],
    [/rest\/v1\/profiles\?select=settings/, () => ok([{ settings: { pushLevel: "all" } }])],
    [/rest\/v1\/device_tokens\?select/, () => ok([{ token: phone, environment: "production", platform: "android" }])],
    [/GET .*rest\/v1\/notes\?select=id/, () => ok([{ id: "x" }])],
    [/oauth2\.googleapis\.com\/token/, (_u, init) => { assert.match(String(init.body), /assertion=ey/); return ok({ access_token: "ya29.test", expires_in: 3600 }); }],
    [/fcm\.googleapis\.com\/v1\/projects\/baget-app\/messages:send/, (_u, init) => { assert.equal((init.headers as any).Authorization, "Bearer ya29.test"); return ok({ name: "projects/baget-app/messages/1" }); }],
    [/PATCH .*rest\/v1\/notes/, () => new Response(null, { status: 204 })],
  ]);
  const res = await push.handler(post("push", { note_id: "55555555-0000-0000-0000-000000000000" }, { "x-baget-secret": "s3cret-value" }));
  assert.deepEqual(await res.json(), { sent: 1 });
  const msg = calls.find((c) => c.url.includes("fcm.googleapis.com"))!.body.message;
  assert.equal(msg.token, phone);
  assert.equal(msg.data.title, "Jumpman Scout");
  assert.equal(msg.data.body, "Found one for you!");
  assert.equal(msg.android.priority, "HIGH");
  assert.ok(!calls.some((c) => c.url.includes("push.apple.com")), "Android tokens never go to Apple");
  delete process.env.GOOGLE_SERVICE_ACCOUNT;
});

await test("Free plan: scouts rest outside their 4-hour window", async () => {
  const at = (iso: string) => new Date(iso);
  const prof = (o: Record<string, unknown>) => reset([[/rest\/v1\/profiles/, () => ok([{ plan: "free", pro_until: null, tz: "America/New_York", settings: {}, ...o }])]]);
  prof({}); assert.equal(await sweep.restingMessage("u", at("2026-10-16T14:30:00Z")), null, "10:30am New York is inside 9am-1pm");
  prof({}); assert.match(String(await sweep.restingMessage("u", at("2026-10-16T19:00:00Z"))), /hunt 9am to 1pm/);
  prof({ settings: { huntStart: 20 } }); assert.equal(await sweep.restingMessage("u", at("2026-10-17T02:00:00Z")), null, "10pm inside 8pm-12am");
  prof({ plan: "pro", pro_until: new Date(Date.now() + 86400_000).toISOString() }); assert.equal(await sweep.restingMessage("u", at("2026-10-16T19:00:00Z")), null, "Pro never rests");
  prof({ plan: "comp" }); assert.equal(await sweep.restingMessage("u", at("2026-10-16T19:00:00Z")), null);
});

await test("deep hunts: more searches, page checks, three angles and rotating sources", async () => {
  const p = sweep.sweepPrompt(jumpman as never, "2026-10-18", undefined, sweep.anglesFor("a1", new Date()), [], "Larry",
    sweep.sourcesFor("sneakers", "a1", new Date()));
  assert.match(p, /leave no stone unturned/);
  assert.match(p, /at least 8 different searches/);
  assert.match(p, /web_fetch/);
  assert.equal(sweep.anglesFor("a1", new Date()).length, 3);
  const day = new Set<string>();
  for (let i = 0; i < 8; i++) for (const s of sweep.sourcesFor("sneakers", "a1", new Date(Date.UTC(2026, 9, 18) + i * 3 * 3600_000))) day.add(s);
  assert.equal(day.size, sweep.DEEP_SOURCES.sneakers.length, "a day of hunts covers every sneaker source");
  assert.ok(sweep.sourcesFor("vinyl", "a1", new Date()).length > 0, "unknown categories still get places to dig");
});

await test("hunt depth: Pro digs deep, Free searches less but still checks product pages", () => {
  const pro = sweep.depthFor(true), free = sweep.depthFor(false);
  assert.equal(pro.searches, 12); assert.equal(pro.fetches, 6); assert.equal(pro.angles, 3);
  assert.equal(free.searches, 6); assert.equal(free.fetches, 3); assert.equal(free.angles, 2);
  const fp = sweep.sweepPrompt(jumpman as never, "2026-10-18", undefined, ["a", "b"], [], "", [], free);
  assert.match(fp, /web_fetch/, "Free hunts open product pages to confirm price and stock");
  assert.doesNotMatch(fp, /leave no stone unturned/);
  assert.match(fp, /at least 4 different searches/);
  assert.match(sweep.sweepPrompt(jumpman as never, "2026-10-18", undefined, ["a", "b", "c"], [], "", [], pro), /leave no stone unturned/);
});

await test("hunts search through Serper when it works, and fall back to Claude's search when it doesn't", async () => {
  const search = await import("../functions/_shared/search.ts");
  process.env.SERPER_API_KEY = "serper-test";
  search.resetSerperHealth();
  let step = 0, serperCalls = 0;
  const claudeBodies: any[] = [];
  reset([
    [/google\.serper\.dev\/search/, () => { serperCalls++; return ok({ organic: [{ title: "Salehe 2002R - New Balance", link: "https://www.newbalance.com/pd/salehe-2002r/M2002R.html", snippet: "Earthy suede" }] }); }],
    [/api\.anthropic\.com/, (_u, _i, b) => {
      if (!b.tools) return claudeSays(null);
      claudeBodies.push(b);
      step++;
      if (step === 1) return ok({ stop_reason: "tool_use", content: [{ type: "tool_use", id: "t1", name: "search", input: { query: "salehe bembury 2002r" } }], usage: { input_tokens: 10, output_tokens: 10 } });
      return ok({ stop_reason: "end_turn", content: [{ type: "text", text: '```json\n{"listings":[]}\n```' }], usage: { input_tokens: 10, output_tokens: 10 } });
    }],
    [/rest\/v1\/finds/, () => ok([])],
    [/taste_photos/, () => ok([])],
    [/rpc\/record_finds/, () => ok(0)],
    [/sweep_runs/, () => ok({})],
    [/claude_usage/, () => ok({})],
  ]);
  const run = await sweep.sweepAgent({ ...jumpman, settings: {}, tz: "America/New_York", pro: true } as never, "manual", new Date());
  assert.equal(claudeBodies[0].tools[0].name, "search", "Baget's own search tool, not Claude's");
  assert.equal(claudeBodies[0].tools[1].name, "web_fetch");
  const toolResult = claudeBodies[1].messages.at(-1).content[0];
  assert.equal(toolResult.type, "tool_result");
  assert.match(toolResult.content, /newbalance\.com\/pd\/salehe-2002r/);
  assert.equal(run.searches, 1);
  assert.equal(serperCalls, 2, "one health check, one search");

  search.resetSerperHealth();
  claudeBodies.length = 0; step = 1;
  reset([
    [/google\.serper\.dev/, () => new Response(JSON.stringify({ message: "Not enough credits" }), { status: 400 })],
    [/rest\/v1\/(notes|app_admins)/, () => ok([])],
    [/api\.anthropic\.com/, (_u, _i, b) => { claudeBodies.push(b); return ok({ stop_reason: "end_turn", content: [{ type: "text", text: '{"listings":[]}' }], usage: {} }); }],
    [/rest\/v1\/finds/, () => ok([])], [/taste_photos/, () => ok([])], [/rpc\/record_finds/, () => ok(0)], [/sweep_runs/, () => ok({})], [/claude_usage/, () => ok({})],
  ]);
  await sweep.sweepAgent({ ...jumpman, settings: {}, tz: "America/New_York", pro: false } as never, "manual", new Date());
  assert.equal(claudeBodies[0].tools[0].type, "web_search_20250305", "out of Serper credits: Claude's search instead");
  assert.equal(claudeBodies[0].tools[1].name, "web_fetch", "Free hunts open product pages too");
  assert.equal(claudeBodies[0].tools[1].max_uses, 3, "up to 3 on Free");
  delete process.env.SERPER_API_KEY;
  search.resetSerperHealth();
});

await test("setup only makes as many scouts as the plan allows", async () => {
  const inserted: any[] = [];
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/api\.anthropic\.com/, () => ok({ stop_reason: "end_turn", content: [{ type: "text", text: JSON.stringify({ agents: [
      { name: "A", category: "sneakers" }, { name: "B", category: "fragrance" }, { name: "C", category: "watches" }, { name: "D", category: "cars" }] }) }] })],
    [/profiles\?select=plan/, () => ok([{ plan: "free", pro_until: null }])],
    [/GET .*rest\/v1\/agents/, () => ok([])],
    [/rest\/v1\/agents/, (_u, _i, b) => { inserted.push(b); return ok([{ id: `a${inserted.length}` }]); }],
    [/rest\/v1\/profiles/, () => ok([{ display_name: "" }])],
    [/rest\/v1\/notes/, () => new Response(null, { status: 201 })],
  ]);
  const res = await hunt.handler(post("hunt", { categories: ["sneakers", "fragrance", "watches", "cars"], text: "" }, { Authorization: "Bearer user-jwt" }));
  const body = await res.json();
  assert.equal(body.agents.length, 2, "Free: 2 scouts");
});

await test("easy for everyone: plain descriptions, and setup vibes and budget reach the scouts", async () => {
  const fr = { ...jumpman, mission_category: "fragrance", price_note: 120 };
  const prompt = sweep.sweepPrompt(fr as never, "2026-10-18");
  assert.match(prompt, /"about"/);
  assert.match(prompt, /what it smells like in everyday words/);
  assert.match(prompt, /up to \$120/);
  assert.doesNotMatch(sweep.sweepPrompt(jumpman as never, "2026-10-18"), /smells like/, "only fragrance gets scent wording");
  const [l] = sweep.cleanListings({ listings: [{ title: "Le Labo Santal 33", url: "https://www.lelabofragrances.com/santal-33.html",
    about: "  A creamy, woody scent:  sandalwood, cedar and a little leather. Easy to wear day or night.  " }] }, "fragrance");
  assert.equal(l.about, "A creamy, woody scent: sandalwood, cedar and a little leather. Easy to wear day or night.");
  assert.equal(sweep.cleanListings({ listings: [{ title: "X", url: "https://shop.com/p/x" }] }, "fragrance")[0].about, null);

  assert.deepEqual(hunt.cleanVibes({ fragrance: ["Fresh & clean", 3, ""], nope: ["x"], cars: "fast" }), { fragrance: ["fresh & clean"] });
  assert.equal(hunt.cleanBudget(150), 150);
  assert.equal(hunt.cleanBudget("150"), null);
  assert.equal(hunt.cleanBudget(0), null);

  const inserted: any[] = [];
  let sent = "";
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/api\.anthropic\.com/, (_u, _i, b) => { sent = JSON.stringify(b); return ok({ stop_reason: "end_turn", content: [{ type: "text", text: JSON.stringify({ agents: [
      { name: "Scent Scout", category: "fragrance", traits: ["citrus", "musk"] }] }) }] }); }],
    [/profiles\?select=plan/, () => ok([{ plan: "free", pro_until: null }])],
    [/GET .*rest\/v1\/agents/, () => ok([])],
    [/rest\/v1\/agents/, (_u, _i, b) => { inserted.push(b); return ok([{ id: "a1" }]); }],
    [/rest\/v1\/profiles/, () => ok([{ display_name: "" }])],
    [/rest\/v1\/notes/, () => new Response(null, { status: 201 })],
  ]);
  const res = await hunt.handler(post("hunt", { categories: ["fragrance"], text: "", vibes: { fragrance: ["fresh & clean", "date night"] }, budget: 120, brands: { fragrance: ["Le Labo"] } },
    { Authorization: "Bearer user-jwt" }));
  assert.equal(res.status, 200);
  assert.match(sent, /fresh & clean, date night/);
  assert.match(sent, /up to \$120/);
  assert.deepEqual(inserted[0].traits, ["fresh & clean", "date night", "citrus", "musk"], "their own words stay on the scout");
  assert.equal(inserted[0].price_note, 120);
  assert.match(sent, /Brands they picked: fragrance: Le Labo/);
  assert.deepEqual(inserted[0].makers, ["Le Labo"]);
});

await test("older finds get a plain description, and unsure stays empty", async () => {
  const updates: any[] = [];
  reset([
    [/GET .*rest\/v1\/listings/, () => ok([
      { id: "l1", title: "Le Labo Santal 33 50ml", brand: "Le Labo", category: "fragrance", traits: [], source: "Nordstrom" },
      { id: "l2", title: "Mystery Item 7", brand: "", category: "other", traits: [], source: "shop" }])],
    [/api\.anthropic\.com/, () => ok({ stop_reason: "end_turn", content: [{ type: "text", text:
      '{"items":[{"id":"p2","title":"Mystery Item 7","about":null},{"id":"p1","title":"Le Labo Santal 33 50ml","about":"A creamy, woody scent of sandalwood and cedar that works day or night."}]}' }] })],
    [/PATCH .*rest\/v1\/listings/, (u, _i, b) => { updates.push({ q: u.search, b }); return ok([]); }],
    [/rest\/v1\/claude_usage/, () => new Response(null, { status: 201 })],
  ]);
  const r = await sweep.backfillAbout(20);
  assert.deepEqual(r, { checked: 2, written: 1 });
  assert.equal(updates.find((x) => x.q.includes("l1")).b.about, "A creamy, woody scent of sandalwood and cedar that works day or night.");
  const l2 = updates.find((x) => x.q.includes("l2")).b;
  assert.equal(l2.about, null);
  assert.ok(l2.about_checked_at, "checked once, not retried every run");
});

await test("every brand gets a short blurb, written once and copied onto its listings", async () => {
  let saved: any[] = [];
  reset([
    [/rpc\/brands_needing_blurbs/, () => ok([{ name: "Le Labo" }, { name: "Nordstrom" }])],
    [/api\.anthropic\.com/, () => ok({ stop_reason: "end_turn", content: [{ type: "text", text:
      '{"items":[{"id":"b1","name":"Le Labo","blurb":"A New York perfume house known for small-batch, unisex scents. Around $200+ a bottle."},{"id":"b2","name":"Nordstrom","blurb":null}]}' }] })],
    [/rest\/v1\/brand_blurbs/, (_u, _i, b) => { saved = b; return new Response(null, { status: 201 }); }],
    [/rpc\/apply_brand_blurbs/, () => ok(3)],
    [/rest\/v1\/claude_usage/, () => new Response(null, { status: 201 })],
  ]);
  assert.deepEqual(await sweep.backfillBrands(15), { brands: 2, written: 1, applied: 3 });
  assert.equal(saved[0].key, "le labo");
  assert.match(saved[0].blurb, /New York perfume house/);
  assert.equal(saved[1].blurb, null, "unknown or a store: saved empty so it isn't asked again");
});

await test("batch answers can't land on the wrong brand", () => {
  const asked = [{ id: "b1", name: "Creed" }, { id: "b2", name: "The Row" }];
  // Skipped Creed and shifted The Row up into its slot: nothing for Creed.
  assert.deepEqual(sweep.keyed({ items: [{ id: "b1", name: "The Row", blurb: "Olsen twins label" }] }, "blurb", asked), [null, null]);
  assert.deepEqual(sweep.keyed({ items: [{ id: "b2", name: "the row", blurb: "Olsen twins label" }, { id: "b1", name: "CREED", blurb: "Paris perfume house" }] }, "blurb", asked),
    ["Paris perfume house", "Olsen twins label"], "order doesn't matter, the echoed name does");
  assert.deepEqual(sweep.keyed(null, "blurb", asked), [null, null]);
  const long = [{ id: "p1", name: "Creed Bois de Cedrat 75ml / 2.5 oz Vintage 2013 Batch 13Q01 RARE NEW" }, { id: "p2", name: "Creed Royal Princess Oud" }];
  assert.deepEqual(sweep.keyed({ items: [{ id: "p1", title: "Creed Bois de Cedrat 75ml 2.5 oz Vintage 2013 Batch 13Q01", about: "Citrus and cedar." },
    { id: "p2", title: "Creed Aventus 100ml", about: "Wrong one." }] }, "about", long), ["Citrus and cedar.", null],
    "a trimmed long title still matches; a different product doesn't");
});

await test("on-demand Claude features are limited per account", async () => {
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/rpc\/take_quota/, (_u, _i, b) => { assert.equal(b.p_fn, "hunt"); return ok("day"); }],
  ]);
  const res = await hunt.handler(post("hunt", { text: "jordans" }, { Authorization: "Bearer user-jwt" }));
  assert.equal(res.status, 429);
  assert.match((await res.json()).error, /limit for today/);
  assert.equal(calls.filter((c) => c.url.includes("anthropic")).length, 0, "Claude isn't called");
});

await test("setup: interests beyond the built-in categories become their own scouts", async () => {
  const inserted: any[] = [];
  let sent = "";
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/api\.anthropic\.com/, (_u, _i, b) => { sent = JSON.stringify(b); return ok({ stop_reason: "end_turn", content: [{ type: "text", text: JSON.stringify({ agents: [
      { name: "Gadget Scout", category: null, custom: "tech and gadgets" }] }) }] }); }],
    [/profiles\?select=plan/, () => ok([{ plan: "pro", pro_until: "2099-01-01T00:00:00Z" }])],
    [/GET .*rest\/v1\/agents/, () => ok([])],
    [/rest\/v1\/agents/, (_u, _i, b) => { inserted.push(b); return ok([{ id: `a${inserted.length}` }]); }],
    [/rest\/v1\/profiles/, () => ok([{ display_name: "" }])],
    [/rest\/v1\/notes/, () => new Response(null, { status: 201 })],
  ]);
  const res = await hunt.handler(post("hunt", { categories: [], interests: ["Tech & gadgets", "Vinyl & music"], text: "" }, { Authorization: "Bearer user-jwt" }));
  assert.equal(res.status, 200);
  assert.match(sent, /Tech & gadgets, Vinyl & music/);
  assert.deepEqual(inserted.map((a) => a.mission_custom), ["tech and gadgets", "vinyl & music"], "the one Claude skipped still gets a scout");
});

await test("watched sold-out finds: the store page is checked and watchers get a restock text", async () => {
  const I2 = await import("../functions/_shared/images.ts");
  assert.equal(I2.stockFromHtml('<script type="application/ld+json">{"offers":{"availability":"https://schema.org/InStock"}}</script>'), "in");
  assert.equal(I2.stockFromHtml('{"availability": "http://schema.org/OutOfStock"}'), "out");
  assert.equal(I2.stockFromHtml('<meta property="product:availability" content="out of stock">'), "out");
  assert.equal(I2.stockFromHtml("<p>Sold out</p>"), null, "a page that doesn't say isn't guessed at");
  const daily = await import("../functions/_shared/daily.ts");
  const notes: any[] = [], updates: any[] = [];
  reset([
    [/GET .*rest\/v1\/finds/, (u) => { assert.match(decodeURIComponent(u.search), /listing\.sold_out=eq\.true/); return ok([
      { id: "f1", user_id: "u1", agent_id: "a1", agent: { name: "Sneaker Scout" }, listing: { id: "l1", title: "Air Bakin High SP", source: "Slam Jam", url: "https://www.slamjam.com/p/air-bakin", sold_out: true, stock_checked_at: null } },
      { id: "f2", user_id: "u2", agent_id: "a2", agent: { name: "Kicks" }, listing: { id: "l1", title: "Air Bakin High SP", source: "Slam Jam", url: "https://www.slamjam.com/p/air-bakin", sold_out: true, stock_checked_at: null } },
      { id: "f3", user_id: "u3", agent_id: "a3", agent: null, listing: { id: "l2", title: "Checked recently", source: "X", url: "https://x.com/p", sold_out: true, stock_checked_at: new Date().toISOString() } }]); }],
    [/GET https:\/\/www\.slamjam\.com/, () => new Response('<script type="application/ld+json">{"availability":"https://schema.org/InStock"}</script>', { headers: { "content-type": "text/html" } })],
    [/PATCH .*rest\/v1\/listings/, (u, _i, b) => { updates.push({ q: u.search, b }); return ok([]); }],
    [/rest\/v1\/profiles/, () => ok([{ display_name: "Larry White" }])],
    [/POST .*rest\/v1\/notes/, (_u, _i, b) => { notes.push(b); return new Response(null, { status: 201 }); }],
  ]);
  assert.deepEqual(await daily.restockCheck(15, new Date(), fetch as never), { checked: 1, restocked: 1 }, "one page fetch per product; recently checked ones wait");
  assert.equal(updates[0].b.sold_out, false);
  assert.equal(notes.length, 2, "everyone watching it hears");
  assert.equal(notes[0].kind, "restock");
  assert.match(notes[0].body, /^Larry, the Air Bakin High SP is back in stock at Slam Jam/);
});

await test("store pages: product, US price, stock and photo are read from what the store publishes", async () => {
  const I3 = await import("../functions/_shared/images.ts");
  const page = `<head><meta property="og:site_name" content="Kith"><meta property="og:image" content="https://cdn.kith.com/p/990v6.jpg"></head>
    <script type="application/ld+json">{"@graph":[{"@type":"Product","name":"New Balance 990v6 Made in USA Grey","brand":{"@type":"Brand","name":"New Balance"},
    "image":"https://cdn.kith.com/p/990v6.jpg","offers":[{"@type":"Offer","price":"199.99","priceCurrency":"USD","availability":"https://schema.org/InStock"}]}]}</script>`;
  const p = I3.productFromHtml(page, "https://kith.com/products/990v6");
  assert.deepEqual(p, { name: "New Balance 990v6 Made in USA Grey", brand: "New Balance", price: 199.99, stock: "in", image: "https://cdn.kith.com/p/990v6.jpg", site: "Kith" });
  const eur = I3.productFromHtml('<script type="application/ld+json">{"@type":"Product","name":"X","offers":{"price":"150","priceCurrency":"EUR"}}</script>', "https://x.de/p");
  assert.equal(eur.price, null, "never shows a euro price as dollars");
});

await test("pulse: keeps only what the store's own page confirms and what fits the scout", async () => {
  process.env.SERPER_API_KEY = "serper-test";
  const pageFor = (name: string, avail: string, img = true) => new Response(`<meta property="og:site_name" content="Kith">${img ? '<meta property="og:image" content="https://cdn.kith.com/a.jpg">' : ""}
    <script type="application/ld+json">{"@type":"Product","name":"${name}","brand":"Jordan","offers":{"price":"150","priceCurrency":"USD","availability":"https://schema.org/${avail}"}}</script>`, { headers: { "content-type": "text/html" } });
  let saved: any[] = [];
  reset([
    [/google\.serper\.dev\/search/, () => ok({ organic: [
      { title: "Air Jordan 1 Low Travis Scott | Kith", link: "https://kith.com/products/aj1-low-ts", snippet: "" },
      { title: "Air Jordan 1 Low Mocha | Shop", link: "https://shop.com/products/aj1-mocha", snippet: "" },
      { title: "Air Jordan 1 Low Bred", link: "https://shop.com/products/aj1-bred", snippet: "" },
      { title: "Totally different headline", link: "https://blog.com/posts/jordan", snippet: "" },
      { title: "Search", link: "https://kith.com/search?q=jordan", snippet: "" }] })],
    [/kith\.com\/products\/aj1-low-ts/, () => pageFor("Air Jordan 1 Low Travis Scott", "InStock")],
    [/shop\.com\/products\/aj1-mocha/, () => pageFor("Air Jordan 1 Low Mocha", "OutOfStock")],
    [/shop\.com\/products\/aj1-bred/, () => pageFor("Air Jordan 1 Low Bred", "InStock", false)],
    [/blog\.com/, () => pageFor("Air Jordan 1 Low Fragment", "InStock")],
    [/rpc\/upsert_listings/, (_u, _i, b) => { saved = b.p_listings; return ok(b.p_listings.map((_: any, i: number) => ({ id: `l${i}`, fingerprint: "f", already_found: false }))); }],
    [/rest\/v1\/listing_seen/, () => new Response(null, { status: 201 })],
    [/GET .*rest\/v1\/listings/, () => ok([])],
  ]);
  const r = await sweep.pulseAgent({ ...jumpman, tz: "UTC", settings: {}, last_swept_at: "2026-10-19T00:00:00Z" } as never, new Date(), fetch as never);
  assert.equal(r.kept, 1, "sold out, no photo, a page that isn't the named product, and search pages are all dropped");
  assert.equal(saved[0].title, "Air Jordan 1 Low Travis Scott");
  assert.equal(saved[0].price, 150);
  assert.equal(saved[0].source, "Kith");
  assert.deepEqual(saved[0].tags, ["pulse"]);
  delete process.env.SERPER_API_KEY;
});

await test("refresh: open finds get the store's current price, sold out, or come off the list when the page is gone", async () => {
  const patches: any[] = [];
  reset([
    [/GET .*rest\/v1\/finds/, () => ok([
      { listing: { id: "l1", url: "https://kith.com/p/1", price: 200, sold_out: false, page_checked_at: null } },
      { listing: { id: "l2", url: "https://kith.com/p/2", price: 100, sold_out: false, page_checked_at: null } },
      { listing: { id: "l3", url: "https://kith.com/p/3", price: 100, sold_out: false, page_checked_at: new Date().toISOString() } }])],
    [/kith\.com\/p\/1/, () => new Response('<script type="application/ld+json">{"@type":"Product","name":"A","offers":{"price":"180","priceCurrency":"USD","availability":"https://schema.org/OutOfStock"}}</script>', { headers: { "content-type": "text/html" } })],
    [/kith\.com\/p\/2/, () => new Response("gone", { status: 404 })],
    [/PATCH .*rest\/v1\/(listings|finds)/, (u, _i, b) => { patches.push({ path: u.pathname + u.search, b }); return ok([]); }],
  ]);
  const r = await sweep.refreshFinds(40, new Date(), fetch as never);
  assert.deepEqual(r, { checked: 2, repriced: 1, sold_out: 1, gone: 1 });
  const l1 = patches.find((p) => p.path.includes("listings") && p.path.includes("l1")).b;
  assert.equal(l1.price, 180); assert.equal(l1.sold_out, true);
  assert.ok(patches.some((p) => p.path.includes("finds") && p.path.includes("l2") && p.b.status === "removed"));
});

await test("pulse: a famous brand at a fraction of its usual price, or a dupe, isn't kept", async () => {
  process.env.SERPER_API_KEY = "serper-test";
  const scent = { ...jumpman, name: "Scent Hunter", mission_category: "fragrance", keywords: ["amouage"], makers: ["Amouage"], traits: [], size: "", tz: "UTC", settings: {}, last_swept_at: "2026-10-19T00:00:00Z" };
  const page = (name: string, price: string) => new Response(`<meta property="og:image" content="https://cdn.x.com/a.jpg">
    <script type="application/ld+json">{"@type":"Product","name":"${name}","brand":"Amouage","offers":{"price":"${price}","priceCurrency":"USD","availability":"https://schema.org/InStock"}}</script>`, { headers: { "content-type": "text/html" } });
  let saved: any[] = [];
  reset([
    [/google\.serper\.dev\/search/, () => ok({ organic: [
      { title: "Amouage Oud Zuhal EDP", link: "https://venba.com/products/oud-zuhal", snippet: "" },
      { title: "Amouage Interlude Man inspired perfume", link: "https://dupes.com/products/interlude", snippet: "" },
      { title: "Amouage Reflection Man EDP 100ml", link: "https://luckyscent.com/products/reflection", snippet: "" }] })],
    [/venba\.com/, () => page("Amouage Oud Zuhal EDP", "29.99")],
    [/dupes\.com/, () => page("Amouage Interlude Man inspired perfume", "39")],
    [/luckyscent\.com/, () => page("Amouage Reflection Man EDP 100ml", "350")],
    [/GET .*rest\/v1\/listings/, () => ok([300, 320, 350, 365, 390, 410].map((price) => ({ price })))],
    [/rpc\/upsert_listings/, (_u, _i, b) => { saved = b.p_listings; return ok([{ id: "l1" }]); }],
    [/rest\/v1\/listing_seen/, () => new Response(null, { status: 201 })],
  ]);
  const r = await sweep.pulseAgent(scent as never, new Date(), fetch as never);
  assert.equal(r.kept, 1);
  assert.equal(saved[0].title, "Amouage Reflection Man EDP 100ml");
  delete process.env.SERPER_API_KEY;
});

await test("background writing goes through batches: sent once, applied when Anthropic finishes", async () => {
  let submitted: any = null, inserted: any = null, patched: any[] = [], blurbs: any[] = [], usage: any[] = [];
  const rows = [{ id: "l1", title: "Le Labo Santal 33 50ml", brand: "Le Labo", category: "fragrance", traits: [], source: "Nordstrom" }];
  // Round 1: nothing pending, so a batch is sent for each kind.
  reset([
    [/GET .*rest\/v1\/claude_batches/, () => ok([])],
    [/GET .*rest\/v1\/listings/, () => ok(rows)],
    [/rpc\/brands_needing_blurbs/, () => ok([{ name: "Le Labo" }])],
    [/rpc\/apply_brand_blurbs/, () => ok(0)],
    [/POST https:\/\/api\.anthropic\.com\/v1\/messages\/batches/, (_u, _i, b) => { submitted = submitted ?? []; submitted.push(b); return ok({ id: `msgbatch_${submitted.length}` }); }],
    [/POST .*rest\/v1\/claude_batches/, (_u, _i, b) => { inserted = inserted ?? []; inserted.push(b); return new Response(null, { status: 201 }); }],
  ]);
  const r1 = await sweep.batchBackfills();
  assert.equal(r1.about_sent, 1); assert.equal(r1.brands_sent, 1);
  assert.equal(submitted[0].requests[0].custom_id, "about-0");
  assert.equal(inserted[0].kind, "about");
  // Round 2: both still running, so nothing new is sent.
  submitted = null;
  reset([
    [/GET .*rest\/v1\/claude_batches\?select=id/, () => ok([{ id: "msgbatch_1", kind: "about", items: { "about-0": rows }, created_at: new Date().toISOString() }])],
    [/GET .*rest\/v1\/claude_batches\?select=kind/, () => ok([{ kind: "about" }, { kind: "brands" }])],
    [/GET https:\/\/api\.anthropic\.com\/v1\/messages\/batches\/msgbatch_1$/, () => ok({ processing_status: "in_progress", results_url: null })],
    [/rpc\/apply_brand_blurbs/, () => ok(0)],
  ]);
  await sweep.batchBackfills();
  assert.equal(submitted, null, "one batch of each kind at a time");
  // Round 3: done; results applied and the batch closed.
  reset([
    [/GET .*rest\/v1\/claude_batches\?select=id/, () => ok([
      { id: "msgbatch_1", kind: "about", items: { "about-0": rows }, created_at: new Date().toISOString() },
      { id: "msgbatch_2", kind: "brands", items: { "brands-0": ["Le Labo"] }, created_at: new Date().toISOString() }])],
    [/GET https:\/\/api\.anthropic\.com\/v1\/messages\/batches\/msgbatch_1$/, () => ok({ processing_status: "ended", results_url: "https://api.anthropic.com/v1/messages/batches/msgbatch_1/results" })],
    [/GET https:\/\/api\.anthropic\.com\/v1\/messages\/batches\/msgbatch_2$/, () => ok({ processing_status: "ended", results_url: "https://api.anthropic.com/v1/messages/batches/msgbatch_2/results" })],
    [/msgbatch_1\/results/, () => new Response(JSON.stringify({ custom_id: "about-0", result: { type: "succeeded", message: { model: "claude-haiku-5-5", usage: { input_tokens: 100, output_tokens: 50 },
      content: [{ type: "text", text: '{"items":[{"id":"p1","title":"Le Labo Santal 33 50ml","about":"A creamy, woody scent of sandalwood and cedar."}]}' }] } } }) + "\n")],
    [/msgbatch_2\/results/, () => new Response(JSON.stringify({ custom_id: "brands-0", result: { type: "succeeded", message: { model: "claude-sonnet-5-5", usage: { input_tokens: 80, output_tokens: 40 },
      content: [{ type: "text", text: '{"items":[{"id":"b1","name":"Le Labo","blurb":"A New York perfume house known for small-batch scents."}]}' }] } } }) + "\n")],
    [/PATCH .*rest\/v1\/(listings|claude_batches)/, (u, _i, b) => { patched.push({ path: u.pathname, b }); return ok([]); }],
    [/rest\/v1\/brand_blurbs/, (_u, _i, b) => { blurbs = b; return new Response(null, { status: 201 }); }],
    [/rest\/v1\/claude_usage/, (_u, _i, b) => { usage.push(b); return new Response(null, { status: 201 }); }],
    [/GET .*rest\/v1\/claude_batches\?select=kind/, () => ok([{ kind: "about" }, { kind: "brands" }])],
    [/rpc\/apply_brand_blurbs/, () => ok(3)],
  ]);
  const r3 = await sweep.batchBackfills();
  assert.equal(r3.applied, 2);
  assert.equal(patched.find((p) => p.path.endsWith("listings")).b.about, "A creamy, woody scent of sandalwood and cedar.");
  assert.equal(blurbs[0].blurb, "A New York perfume house known for small-batch scents.");
  assert.equal(patched.filter((p) => p.path.endsWith("claude_batches")).length, 2, "both batches closed");
  assert.match(usage[0].model, /\(batch\)$/, "logged at the batch price");
});

await test("photos: stored phone-sized when a smaller copy can be made, original otherwise", async () => {
  const I4 = await import("../functions/_shared/images.ts");
  const big = new Uint8Array(400_000);
  assert.equal((await I4.smaller(big, "image/jpeg")).bytes.length, 400_000, "no resizer (tests): unchanged");
  I4.setResizer(async (_b, t) => ({ bytes: new Uint8Array(90_000), type: t }));
  assert.equal((await I4.smaller(big, "image/jpeg")).bytes.length, 90_000);
  assert.equal((await I4.smaller(new Uint8Array(100_000), "image/jpeg")).bytes.length, 100_000, "small photos are left alone");
  I4.setResizer(async () => { throw new Error("bad image"); });
  assert.equal((await I4.smaller(big, "image/png")).bytes.length, 400_000, "a photo that can't be read is stored as is");
  I4.setResizer(async () => null);
});

await test("store map: non-store pages never become finds", async () => {
  const St = await import("../functions/_shared/stores.ts");
  const b = new Set(["supremecommunity.com", "fragrantica.com"]);
  assert.ok(St.notAProduct("https://supremecommunity.com/season/fall-winter2026/droplist/2026-10-23/", b));
  assert.ok(St.notAProduct("https://www.fragrantica.com/perfume/Creed/Aventus-9828.html", b));
  assert.ok(St.notAProduct("https://www.edmunds.com/used-porsche-911/", b), "a dealer search page");
  assert.ok(!St.notAProduct("https://www.edmunds.com/inventory/vin.html?vin=WP0AB2A9", b));
  assert.ok(St.notAProduct("https://www.kbb.com/porsche/911/", b));
  assert.ok(!St.notAProduct("https://www.kbb.com/cars-for-sale/vehicle/712345678", b));
  assert.ok(!St.notAProduct("https://kith.com/products/nb-990v6-grey", b));
});

await test("store map: a Shopify product becomes a listing in the right category, with sizes in stock", async () => {
  const St = await import("../functions/_shared/stores.ts");
  const shoe = { title: "New Balance 990v6 Grey", handle: "nb-990v6-grey", vendor: "New Balance", product_type: "Footwear", tags: ["Mens", "Made in USA"],
    images: [{ src: "https://cdn.shopify.com/a.jpg" }],
    variants: [{ option1: "9", price: "199.99", available: false }, { option1: "10", price: "199.99", available: true }, { option1: "10.5", price: "199.99", available: true }] };
  const l = St.shopifyListing(shoe, "kith.com", "Kith", ["sneakers", "apparel"])!;
  assert.equal(l.category, "sneakers");
  assert.equal(l.price, 199.99);
  assert.deepEqual(l.sizes_in_stock, ["10", "10.5"]);
  assert.equal(l.url, "https://kith.com/products/nb-990v6-grey");
  assert.ok(l.traits.includes("made in usa"));
  const hoodie = { ...shoe, title: "Kith Williams Hoodie", handle: "williams", product_type: "Hoodie", tags: [], vendor: "Kith" };
  assert.equal(St.shopifyListing(hoodie, "kith.com", "Kith", ["sneakers", "apparel"])!.category, "apparel");
  assert.equal(St.shopifyListing(hoodie, "kith.com", "Kith", ["sneakers"]), null, "not in the store's categories");
  assert.equal(St.shopifyListing({ ...shoe, variants: [{ option1: "9", price: "199.99", available: false }] }, "kith.com", "Kith", ["sneakers"]), null, "sold out");
  assert.equal(St.shopifyListing({ ...shoe, title: "Gift Card" }, "kith.com", "Kith", ["sneakers"]), null);
});

await test("store map: catalogs feed matching scouts' For You; non-Shopify stores are marked and skipped", async () => {
  const St = await import("../functions/_shared/stores.ts");
  const upserts: any[] = [], seen: any[] = [], patches: any[] = [];
  const scout = { id: "a1", user_id: "u1", name: "Jumpman", mission_category: "sneakers", mission_custom: null, keywords: ["990"], traits: [],
    makers: ["New Balance"], creators: [], size: "10", mode: "ask", voice: "chill", learned: {}, price_note: 0 };
  reset([
    [/rpc\/claim_feeds/, () => ok([{ domain: "kith.com", categories: ["sneakers"], shopify: null }, { domain: "nike.com", categories: ["sneakers"], shopify: null }])],
    [/rest\/v1\/stores\?select=domain,name/, () => ok([{ domain: "kith.com", name: "Kith" }, { domain: "nike.com", name: "Nike" }])],
    [/rpc\/feed_scouts/, () => ok([scout])],
    [/kith\.com\/cart\.js/, () => ok({ currency: "USD" })],
    [/kith\.com\/products\.json/, () => ok({ products: [
      { title: "New Balance 990v6 Grey", handle: "nb-990", vendor: "New Balance", product_type: "Footwear", tags: [], images: [{ src: "https://cdn.shopify.com/a.jpg" }],
        variants: [{ option1: "10", price: "199.99", available: true }] },
      { title: "Puma Speedcat", handle: "speedcat", vendor: "Puma", product_type: "Footwear", tags: [], images: [{ src: "https://cdn.shopify.com/b.jpg" }],
        variants: [{ option1: "10", price: "99.99", available: true }] }] })],
    [/nike\.com\/cart\.js/, () => new Response("<html>", { status: 404 })],
    [/PATCH .*rest\/v1\/stores/, (u, _i, b) => { patches.push({ q: u.search, b }); return ok([]); }],
    [/rpc\/upsert_listings/, (_u, _i, b) => { upserts.push(b); return ok(b.p_listings.map((_: unknown, i: number) => ({ id: `l${i}` }))); }],
    [/rest\/v1\/listing_seen/, (_u, _i, b) => { seen.push(...b); return ok([]); }],
  ]);
  const r = await St.storeFeeds(6);
  assert.deepEqual(r, { stores: 2, read: 1, kept: 1 });
  assert.equal(upserts[0].p_user, "u1");
  assert.deepEqual(upserts[0].p_listings.map((l: any) => l.title), ["New Balance 990v6 Grey"], "only what fits the scout");
  assert.equal(seen[0].user_id, "u1");
  assert.ok(patches.some((p) => p.q.includes("nike.com") && p.b.shopify === false), "nike isn't a Shopify catalog");
  assert.ok(patches.some((p) => p.q.includes("kith.com") && p.b.shopify === true));
});

await test("store map: each hunt searches its rotation of stores directly", async () => {
  const St = await import("../functions/_shared/stores.ts");
  process.env.SERPER_API_KEY = "serp";
  St.resetBlocks(new Set(["sneakernews.com"]));
  const qs: string[] = [];
  reset([
    [/rpc\/claim_stores/, (_u, _i, b) => { assert.equal(b.p_category, "sneakers"); assert.deepEqual(b.p_prefer, ["New Balance"]); return ok([{ domain: "newbalance.com", name: "New Balance" }, { domain: "kith.com", name: "Kith" }]); }],
    [/google\.serper\.dev/, (_u, _i, b) => { qs.push(b.q); return ok({ organic: b.q.includes("kith") ? [] : [
      { title: "990v6 Made in USA", link: "https://www.newbalance.com/pd/990v6/M990GL6.html", snippet: "$199.99" },
      { title: "elsewhere", link: "https://sneakernews.com/990", snippet: "" }] }); }],
  ]);
  const scout = { id: "a1", user_id: "u1", name: "Jumpman", mission_category: "sneakers", mission_custom: null, keywords: ["990"], traits: [],
    makers: ["New Balance"], creators: [], size: "10", mode: "ask", voice: "chill", learned: {}, price_note: 0 } as any;
  const r = await St.storeLeads(scout, 2, new Date("2026-10-21T12:00:00Z"));
  assert.equal(r.searches, 2);
  assert.ok(qs.every((q) => q.startsWith("site:")));
  assert.match(r.text, /newbalance\.com\/pd\/990v6/);
  assert.doesNotMatch(r.text, /sneakernews/);
  assert.match(r.text, /Kith \(kith\.com\): nothing matching/);
  St.resetBlocks();
  delete process.env.SERPER_API_KEY;
});

await test("intel: droplists and news are kept as intel, dealer results pages as search, products as products", async () => {
  const St = await import("../functions/_shared/stores.ts");
  const b = new Set(["supremecommunity.com", "fragrantica.com"]);
  assert.equal(St.pageKind("https://supremecommunity.com/season/fall-winter2026/droplist/2026-10-23/", b), "intel");
  assert.equal(St.pageKind("https://www.fragrantica.com/perfume/Creed/Aventus-9828.html", b), "intel");
  assert.equal(St.pageKind("https://www.edmunds.com/used-porsche-911/", b), "search");
  assert.equal(St.pageKind("https://kith.com/products/nb-990v6-grey", b), "product");
  const cl = sweep.cleanListings({ listings: [{ title: "Supreme Week 9 droplist", url: "https://supremecommunity.com/droplist/9", intel: true, price: null }] }, "apparel");
  assert.deepEqual(cl[0].tags, ["intel"]);
});

await test("store map: stores outside the US stay in, priced in dollars with their own price kept", async () => {
  const St = await import("../functions/_shared/stores.ts");
  St.resetRates();
  const shoe = { title: "Salomon XT-6", handle: "xt6", vendor: "Salomon", product_type: "Footwear", tags: [], images: [{ src: "https://cdn.shopify.com/a.jpg" }],
    variants: [{ option1: "42", price: "180.00", available: true }] };
  const l: any = St.shopifyListing(shoe, "slamjam.com", "Slam Jam", ["sneakers"], "EUR", 1.08);
  assert.equal(l.price, 194.4);
  assert.equal(l.orig_price, 180);
  assert.equal(l.orig_currency, "EUR");
  assert.ok(l.tags.includes("intl"));
  reset([
    [/rest\/v1\/fx_rates\?select/, () => ok([])],
    [/frankfurter/, () => ok({ rates: { USD: 1.08 } })],
    [/POST .*rest\/v1\/fx_rates/, () => ok([])],
  ]);
  assert.equal(await St.usdRate("EUR"), 1.08);
  assert.equal(await St.usdRate("USD"), 1);
  St.resetRates();
});

await test("typed-in missions: a color word alone doesn't make a match", async () => {
  assert.equal(M.missionCovers("Dior glasses black", "tudor black bay 58 39mm watches diver steel"), false);
  assert.equal(M.missionCovers("Dior glasses black", "dior blacktie s1i black glasses sunglasses"), true);
  assert.equal(M.missionCovers("Dior glasses black", "dior sauvage eau de parfum fragrance"), false, "Dior alone isn't Dior glasses");
  assert.equal(M.missionCovers("AR-platform pistols from licensed dealers", "ar platform pistol 10.5 inch"), true);
  assert.equal(M.missionCovers("vinyl records", "radiohead in rainbows vinyl record lp"), true);
  assert.equal(M.missionCovers("vinyl records", "carpet vinyl flooring"), false);
});

await test("tandem: grounded Gemini while the free allowance lasts, then Flash-Lite with Baget's own search", async () => {
  const G = await import("../functions/_shared/gemini.ts");
  assert.ok(sweep.sameProduct("Byredo Bal d'Afrique Eau de Parfum 50ml", "BYREDO Bal d'Afrique 50 ml"));
  assert.ok(!sweep.sameProduct("Byredo Bal d'Afrique", "Byredo Gypsy Water"));
  process.env.GEMINI_API_KEY = "g-key";
  process.env.SERPER_API_KEY = "serp";
  const json = '```json\n{"listings":[{"title":"Ataraxia Lumen","url":"https://ataraxiaperfumery.com/products/lumen","price":180}]}\n```';
  let used = 10;
  const logged: any[] = [], models: string[] = [];
  reset([
    [/rpc\/gemini_grounded_month/, () => ok(used)],
    [/generativelanguage\.googleapis\.com/, (u, init, b) => {
      assert.equal((init.headers as any)["x-goog-api-key"], "g-key");
      models.push(decodeURIComponent(u.pathname.split("/models/")[1]));
      if (b.tools[0].google_search) {
        assert.match(b.contents[0].parts[0].text, /second scout/);
        return ok({ candidates: [{ content: { parts: [{ text: json }] }, groundingMetadata: { webSearchQueries: ["a", "b"] } }], usageMetadata: { promptTokenCount: 1000, candidatesTokenCount: 500 } });
      }
      // Flash-Lite: first asks to search, then answers
      if (b.contents.length === 1) return ok({ candidates: [{ content: { role: "model", parts: [{ functionCall: { name: "search", args: { query: "niche oud" } } }] } }], usageMetadata: { promptTokenCount: 800, candidatesTokenCount: 20 } });
      assert.match(JSON.stringify(b.contents[2].parts[0].functionResponse), /ataraxia/);
      return ok({ candidates: [{ content: { parts: [{ text: json }] } }], usageMetadata: { promptTokenCount: 1500, candidatesTokenCount: 300 } });
    }],
    [/google\.serper\.dev/, () => ok({ organic: [{ title: "Lumen", link: "https://ataraxiaperfumery.com/products/lumen", snippet: "" }] })],
    [/rest\/v1\/claude_usage/, (_u, _i, b) => { logged.push(b); return ok([]); }],
  ]);
  G.resetGrounded();
  const r: any = await G.geminiHunt("Mission: niche fragrance");
  assert.equal(r.listings[0].title, "Ataraxia Lumen");
  assert.match(logged[0].model, /\(grounded\)$/);
  used = 4800;
  G.resetGrounded();
  const r2: any = await G.geminiHunt("Mission: niche fragrance", 4);
  assert.equal(r2.listings[0].title, "Ataraxia Lumen");
  assert.ok(models.every((m) => m.startsWith("gemini-3.1-flash-lite:")), "Gemini 3.1 Flash-Lite for both modes");
  assert.match(logged.at(-1).model, /lite.*\(serper\)$/);
  // a retired model is skipped
  reset([[/rpc\/gemini_grounded_month/, () => ok(0)],
    [/models\/gemini-3\.1-flash-lite/, () => new Response("gone", { status: 404 })],
    [/models\/gemini-3\.5-flash-lite/, () => ok({ candidates: [{ content: { parts: [{ text: json }] } }] })],
    [/rest\/v1\/claude_usage/, () => ok([])]]);
  G.resetGrounded();
  assert.equal(((await G.geminiHunt("x")) as any).listings[0].title, "Ataraxia Lumen", "falls through to the next model");
  assert.equal(logged.at(-1).searches, 1);
  delete process.env.GEMINI_API_KEY; delete process.env.SERPER_API_KEY;
  assert.equal(await G.geminiHunt("x"), null, "off without a key");
});

console.log(`\n${passed} passed${process.exitCode ? ", some FAILED" : ""}`);

await test("descriptions never show the model's notes to itself", async () => {
  const sw = await import("../functions/sweep/handler.ts");
  assert.equal(sw.cleanAbout("A retro adidas sneaker in black suede. Price and sizes not shown in the snippet I found."), "A retro adidas sneaker in black suede.");
  assert.equal(sw.cleanAbout("I couldn't confirm the notes."), null);
  assert.equal(sw.cleanAbout("Fresh and clean, like soap and citrus."), "Fresh and clean, like soap and citrus.");
});

await test("sizes tapped in setup land on the right scouts", async () => {
  const inserted: any[] = [];
  reset([
    [/auth\/v1\/user/, () => ok({ id: jumpman.user_id })],
    [/api\.anthropic\.com/, () => ok({ stop_reason: "end_turn", content: [{ type: "text", text: JSON.stringify({ agents: [
      { name: "Sole Scout", category: "sneakers", size: "10" }, { name: "Thread Scout", category: "apparel" }] }) }] })],
    [/profiles\?select=plan/, () => ok([{ plan: "free", pro_until: null }])],
    [/GET .*rest\/v1\/agents/, () => ok([])],
    [/rest\/v1\/agents/, (_u, _i, b) => { inserted.push(b); return ok([{ id: "a" + inserted.length }]); }],
    [/rest\/v1\/profiles/, () => ok([{ display_name: "" }])],
    [/rest\/v1\/notes/, () => new Response(null, { status: 201 })],
  ]);
  const res = await hunt.handler(post("hunt", { categories: ["sneakers", "apparel"], text: "", sizes: { sneakers: "10.5", apparel: "M", cars: "x" } },
    { Authorization: "Bearer user-jwt" }));
  assert.equal(res.status, 200);
  assert.equal(inserted.find((x) => x.mission_category === "sneakers").size, "10.5");
  assert.equal(inserted.find((x) => x.mission_category === "apparel").size, "M");
});

await test("scouts stick to the budget", () => {
  const vinyl = { ...jumpman, mission_category: null, mission_custom: "90s hip hop vinyl original pressings under $80", keywords: ["original pressing"], traits: [], makers: [], creators: [], size: "", price_note: 0 };
  const rec = { ...ts, title: "Public Enemy Fear Of A Black Planet original pressing", brand: "", category: "other", traits: [], tags: [], creator: null, sizes_in_stock: null };
  assert.equal(M.budgetOf(vinyl), 80);
  assert.equal(M.match(vinyl, { ...rec, price: 125 }, [], { own: true }), null, "well over budget is out");
  const near = M.match(vinyl, { ...rec, price: 95 }, [], { own: true })!;
  const under = M.match(vinyl, { ...rec, price: 40 }, [], { own: true })!;
  assert.ok(near.score < under.score && near.why.some((w) => w.includes("over your $80")), "a little over ranks lower and says so");
  assert.equal(M.budgetOf({ ...vinyl, mission_custom: "Datejust under $6k" }), 6000);
});

await test("women's sizes from setup are read right", () => {
  assert.equal(M.shoeUS("US W 8"), 6.5);
  assert.equal(M.topSize("M (womenswear)"), "M");
  assert.equal(M.topSize("S (womenswear)"), "S");
});

await test("a scout whose last 3 hunts found nothing rests for 3 days, then tries again", async () => {
  const sweep = await import("../functions/sweep/handler.ts");
  const now = new Date("2026-10-23T12:00:00Z");
  const runs = (finds: number[], hoursAgo: number) => finds.map((f, i) => ({ finds: f, created_at: new Date(now.getTime() - (hoursAgo + i * 24) * 3600_000).toISOString() }));
  reset([[/sweep_runs/, () => ok(runs([0, 0, 0], 20))]]);
  assert.equal(await sweep.restingAfterNothing("a1", now), true);
  reset([[/sweep_runs/, () => ok(runs([0, 0, 0], 80))]]);
  assert.equal(await sweep.restingAfterNothing("a1", now), false, "3 days on, it hunts again");
  reset([[/sweep_runs/, () => ok(runs([0, 2, 0], 20))]]);
  assert.equal(await sweep.restingAfterNothing("a1", now), false, "anything found recently keeps it hunting");
  reset([[/sweep_runs/, () => ok(runs([0, 0], 20))]]);
  assert.equal(await sweep.restingAfterNothing("a1", now), false, "new scouts get their first hunts");
});

