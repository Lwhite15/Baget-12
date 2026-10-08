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
await test("match: no size means no hunting for sneakers", () => {
  assert.equal(M.match({ ...jumpman, size: "" }, ts), null);
});
await test("sizes convert across systems", () => {
  assert.equal(M.shoeUS("EU 44.5"), 10.5);
  assert.equal(M.shoeUS("UK 9.5"), 10.5);
  assert.equal(M.shoeUS("US W 12"), 10.5);
  assert.equal(M.topSize("l · 32x32"), "L");
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
const listingJSON = '```json\n{"listings":[{"title":"Travis Scott x Air Jordan 1 Low OG","brand":"Jordan","category":"sneakers","price":150,"market":610,"source":"Nike SNKRS","url":"https://www.nike.com/launch/t/ts-aj1","drop_at":"2026-10-11T14:00:00Z","sold_out":false,"creator":"Travis Scott","traits":["suede","low top"],"sizes_in_stock":["10.5","11"],"sku":"DM7866-140"},{"title":"Jordan 4 Bred","brand":"Jordan","category":"sneakers","price":215,"source":"Kith","url":"https://kith.com/aj4","traits":["leather"],"sizes_in_stock":["8","9"]}]}\n```';

await test("scheduled sweep: web search, continue a paused turn, score, notify", async () => {
  let claudeCalls = 0;
  reset([
    [/rpc\/sweep_candidates/, () => ok([{ ...jumpman, tz: "America/New_York", settings: { quietHours: false }, last_swept_at: null }])],
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
  const res = await sweep.handler(post("sweep", { mode: "scheduled" }, { "x-baget-secret": "s3cret-value" }));
  const out = await res.json();
  assert.equal(res.status, 200, JSON.stringify(out));
  assert.deepEqual(out, { swept: 1, found: 1, searches: 3 });
  const claudeReq = calls.filter((c) => c.url.includes("anthropic"));
  assert.equal(claudeReq[0].headers["x-api-key"], "sk-test");
  assert.equal(claudeReq[0].body.tools[0].type, "web_search_20250305");
  assert.equal(claudeReq[1].body.messages.length, 2, "paused turn continued");
  const rec = calls.find((c) => c.url.includes("record_finds"))!.body;
  assert.equal(rec.p_finds.length, 1, "the AJ4 isn't in his size, so only one find");
  assert.match(rec.p_finds[0].note.body, /^Yo! The Travis Scott x Air Jordan 1 Low OG drops/);
  assert.ok(rec.p_finds[0].why.includes("Like your taste photos: suede"));
  const runLog = calls.find((c) => c.url.includes("sweep_runs"))!.body;
  assert.equal(runLog.searches, 3);
  assert.equal(runLog.input_tokens, 2900);
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
  reset([
    [/auth\/v1\/user$/, () => ok({ id: jumpman.user_id })],
    [/object\/list\/taste-photos/, (_u, _i, b) => b.prefix === `${jumpman.user_id}/`
      ? ok([{ name: "p1.jpg", id: "f1" }, { name: "avatars", id: null }])
      : (assert.equal(b.prefix, `${jumpman.user_id}/avatars/`), ok([{ name: "me.jpg", id: "f2" }]))],
    [/DELETE .*object\/taste-photos/, (_u, _i, b) => { assert.deepEqual(b.prefixes, [`${jumpman.user_id}/p1.jpg`, `${jumpman.user_id}/avatars/me.jpg`]); return ok([]); }],
    [/DELETE .*admin\/users/, (u) => { assert.ok(u.pathname.endsWith(jumpman.user_id)); return ok({}); }],
  ]);
  const res = await del.handler(post("delete-account", {}, { Authorization: "Bearer user-jwt" }));
  assert.deepEqual(await res.json(), { deleted: true });
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
    [/api\.anthropic\.com/, (_u, _i, b) => /haiku/.test(b.model)
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
  assert.equal(a1.length, 2);
  assert.notEqual(a1[0], a1[1]);
  assert.notDeepEqual(a1, a2, "the next run uses different angles");
  const seen = new Set<string>();
  for (let i = 0; i < 8; i++) seen.add(sweep.anglesFor("agent-1", new Date(t0.getTime() + i * 3 * 3600_000))[0]);
  assert.equal(seen.size, sweep.ANGLES.length, "a day of runs covers every angle");
});
await test("discovery picks keep the agent's own pitch and text you about it", async () => {
  const disc = '```json\n{"listings":[{"title":"Salehe Bembury x New Balance 2002R","brand":"New Balance","category":"sneakers","price":160,"source":"New Balance","url":"https://www.newbalance.com/pd/salehe-2002r/M2002R.html","traits":["suede"],"sizes_in_stock":["10.5"],"discovery":true,"pitch":"Same earthy suede you liked on the Mocha 1s, from a designer you have not tried yet."}]}\n```';
  let recorded: any[] = [];
  reset([
    [/api\.anthropic\.com/, (_u, _i, b) => /haiku/.test(b.model) ? claudeSays(null)
      : ok({ content: [{ type: "text", text: disc }], stop_reason: "end_turn", usage: { input_tokens: 10, output_tokens: 10 } })],
    [/rest\/v1\/finds/, () => ok([])],
    [/rpc\/upsert_listings/, (_u, _i, b) => ok(b.p_listings.map((l: any) => ({ fingerprint: l.fingerprint, id: "l1", already_found: false })))],
    [/taste_photos/, () => ok([])],
    [/rpc\/record_finds/, (_u, _i, b) => { recorded = b.p_finds; return ok(recorded.length); }],
    [/sweep_runs/, () => ok({})],
    [/newbalance\.com/, () => html("<head></head>")],
  ]);
  await sweep.sweepAgent({ ...jumpman, settings: {}, tz: "America/New_York" } as never, "manual", new Date("2026-10-08T15:00:00Z"));
  assert.equal(recorded.length, 1);
  assert.match(recorded[0].why[0], /earthy suede/);
  assert.match(recorded[0].why[1], /^Discovery/);
  assert.match(recorded[0].note.body, /didn't ask for but I think you'll love: Salehe Bembury/);
  const asked = calls.find((c) => /anthropic/.test(c.url) && !/haiku/.test(c.body.model));
  assert.equal(asked!.body.tools[0].max_uses, 6);
});

console.log(`\n${passed} passed${process.exitCode ? ", some FAILED" : ""}`);
