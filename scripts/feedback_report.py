"""Collects tester feedback into one report: TestFlight screenshot feedback and crash reports (App Store Connect API)
plus feedback sent inside the app (database). Writes out/report.md and out/shots/*. The workflow encrypts the folder
before it leaves the runner, because the repo is public. Prints counts only.
Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, SUPABASE_ACCESS_TOKEN, PROJECT_REF, DAYS."""
import json, os, time, datetime
import jwt, requests

OUT = "out"
os.makedirs(f"{OUT}/shots", exist_ok=True)
days = int(os.environ.get("DAYS", "14"))
since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
lines = [f"# Baget tester feedback (last {days} days)", f"_Generated {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC_", ""]

# ── TestFlight (App Store Connect) ──
key = open(os.environ["ASC_KEY_PATH"]).read()
now = int(time.time())
tok = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                 key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
H = {"Authorization": f"Bearer {tok}"}
API = "https://api.appstoreconnect.apple.com/v1"


def get(path):
    r = requests.get(path if path.startswith("http") else API + path, headers=H, timeout=60)
    return r.status_code, (r.json() if r.content else {})


def recent(items):
    out = []
    for it in items:
        d = it.get("attributes", {}).get("createdDate")
        try:
            if d and datetime.datetime.fromisoformat(d.replace("Z", "+00:00")) < since: continue
        except ValueError:
            pass
        out.append(it)
    return out


counts = {}
st, apps = get(f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")
app_id = apps["data"][0]["id"]
builds = {}
st, bl = get(f"/builds?filter[app]={app_id}&limit=50&sort=-uploadedDate")
for b in bl.get("data", []): builds[b["id"]] = b["attributes"].get("version")

lines.append("## TestFlight screenshot feedback")
st, j = get(f"/apps/{app_id}/betaFeedbackScreenshotSubmissions?limit=100&include=build")
if st != 200:
    lines.append(f"_Not available from the API ({st})._")
else:
    items = recent(j.get("data", []))
    counts["testflight_feedback"] = len(items)
    for n, it in enumerate(items, 1):
        a = it["attributes"]
        bid = it.get("relationships", {}).get("build", {}).get("data", {}) or {}
        lines.append(f"### {n}. {a.get('createdDate', '')[:16].replace('T', ' ')} · build {builds.get(bid.get('id'), '?')} · {a.get('deviceModel', '')} iOS {a.get('osVersion', '')}")
        lines.append(a.get("comment") or "_(no comment)_")
        for k, s in enumerate(a.get("screenshots") or []):
            try:
                img = requests.get(s["url"], timeout=60).content
                name = f"tf-{n}-{k}.jpg"
                open(f"{OUT}/shots/{name}", "wb").write(img)
                lines.append(f"Screenshot: shots/{name}")
            except Exception:
                pass
        lines.append("")
    if not items: lines.append("_None._")

lines.append("\n## TestFlight crashes")
st, j = get(f"/apps/{app_id}/betaFeedbackCrashSubmissions?limit=50&include=build")
if st != 200:
    lines.append(f"_Not available from the API ({st})._")
else:
    items = recent(j.get("data", []))
    counts["testflight_crashes"] = len(items)
    for n, it in enumerate(items, 1):
        a = it["attributes"]
        bid = it.get("relationships", {}).get("build", {}).get("data", {}) or {}
        lines.append(f"### Crash {n}. {a.get('createdDate', '')[:16].replace('T', ' ')} · build {builds.get(bid.get('id'), '?')} · {a.get('deviceModel', '')} iOS {a.get('osVersion', '')}")
        if a.get("comment"): lines.append(a["comment"])
        st2, log = get(f"/betaFeedbackCrashSubmissions/{it['id']}/crashLog")
        text = (log.get("data", {}) or {}).get("attributes", {}).get("logText", "") if st2 == 200 else ""
        if text:
            lines.append("```\n" + "\n".join(text.splitlines()[:80]) + "\n```")
        lines.append("")
    if not items: lines.append("_None._")

# ── In the app ──
lines.append("\n## Sent from inside Baget")
q = f"""select f.created_at, f.kind, f.body, f.app_version, f.device, f.screen, f.status, f.photo_path,
       coalesce(nullif(p.display_name, ''), '@' || p.handle) as who
  from public.feedback f join public.profiles p on p.id = f.user_id
 where f.created_at > now() - interval '{days} days' order by f.created_at desc limit 200"""
r = requests.post(f"https://api.supabase.com/v1/projects/{os.environ['PROJECT_REF']}/database/query",
                  headers={"Authorization": f"Bearer {os.environ['SUPABASE_ACCESS_TOKEN']}", "Content-Type": "application/json"},
                  data=json.dumps({"query": q}), timeout=60)
rows = r.json() if r.status_code < 300 and isinstance(r.json(), list) else []
counts["in_app"] = len(rows)
for n, f in enumerate(rows, 1):
    emoji = {"bug": "🐞", "idea": "💡", "love": "❤️"}.get(f["kind"], "💬")
    lines.append(f"### {emoji} {n}. {str(f['created_at'])[:16].replace('T', ' ')} · {f['who']} · {f['app_version']} · {f['device']} · on {f['screen']} · {f['status']}")
    lines.append(f["body"])
    if f.get("photo_path"): lines.append(f"(has a screenshot in the app's Stats → Tester feedback)")
    lines.append("")
if not rows: lines.append("_None._")

open(f"{OUT}/report.md", "w").write("\n".join(lines))
print(f"::notice::feedback counts: {json.dumps(counts)}")
