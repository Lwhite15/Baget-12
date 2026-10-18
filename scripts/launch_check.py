"""Read-only App Store launch check: prints what's ready and what's missing for releasing Baget on the App Store.
Never changes anything. Prints statuses and counts only (no secrets, no tester data).
Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID."""
import builtins, os, time
import jwt, requests

LINES: list[str] = []
_print = builtins.print
def print(*a, **k):  # noqa: A001 - collect lines for one combined notice at the end
    LINES.append(" ".join(str(x) for x in a)); _print(*a, **k)

API = "https://api.appstoreconnect.apple.com/v1"
now = int(time.time())
TOKEN = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1150, "aud": "appstoreconnect-v1"},
                   open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
H = {"Authorization": f"Bearer {TOKEN}"}
ok_count, todo = 0, []


def get(path):
    r = requests.get(path if path.startswith("http") else API + path, headers=H, timeout=60)
    if r.status_code >= 400:
        return {"_error": f"{r.status_code}: " + "; ".join(e.get("detail", "") for e in r.json().get("errors", []))[:200]}
    return r.json()


def good(m):
    global ok_count
    ok_count += 1
    print(f"OK    {m}")


def need(m):
    todo.append(m)
    print(f"TODO  {m}")


apps = get(f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"]
app = apps[0]
aid = app["id"]
print(f"App: {app['attributes']['name']} (primary locale {app['attributes'].get('primaryLocale')})")

# App info: categories, age rating, privacy policy
infos = get(f"/apps/{aid}/appInfos?include=primaryCategory,ageRatingDeclaration")
for info in infos.get("data", [])[:1]:
    a = info["attributes"]
    print(f"App info state: {a.get('appStoreState') or a.get('state')}")
    rel = info.get("relationships", {})
    (good if rel.get("primaryCategory", {}).get("data") else need)("Primary category" + ("" if rel.get("primaryCategory", {}).get("data") else " not set"))
    age = get(f"/appInfos/{info['id']}/ageRatingDeclaration")
    filled = [k for k, v in age.get("data", {}).get("attributes", {}).items() if v not in (None, "")]
    (good if len(filled) > 5 else need)(f"Age rating questionnaire ({len(filled)} answers)")
    locs = get(f"/appInfos/{info['id']}/appInfoLocalizations").get("data", [])
    for l in locs:
        la = l["attributes"]
        (good if la.get("privacyPolicyUrl") else need)(f"Privacy policy URL [{la['locale']}]" + ("" if la.get("privacyPolicyUrl") else " missing"))
        if la.get("subtitle"): good(f"Subtitle [{la['locale']}]")
        else: need(f"Subtitle [{la['locale']}] (optional but recommended)")

# App Store version
vers = get(f"/apps/{aid}/appStoreVersions?filter[platform]=IOS&limit=5").get("data", [])
if not vers:
    need("No App Store version created yet (create 1.0 in App Store Connect → Distribution)")
for v in vers[:1]:
    va = v["attributes"]
    print(f"Version {va['versionString']}: {va.get('appStoreState') or va.get('appVersionState')}, release type {va.get('releaseType')}")
    b = get(f"/appStoreVersions/{v['id']}/build").get("data")
    (good if b else need)("Build attached to the version" if b else "No build attached to the version")
    for loc in get(f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations").get("data", []):
        la = loc["attributes"]
        for field in ("description", "keywords", "supportUrl"):
            (good if la.get(field) else need)(f"{field} [{la['locale']}]" + ("" if la.get(field) else " missing"))
        if not la.get("promotionalText"): print(f"      (optional) promotional text [{la['locale']}] empty")
        sets = get(f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets").get("data", [])
        types = {s["attributes"]["screenshotDisplayType"]: s["id"] for s in sets}
        shots = {t: len(get(f"/appScreenshotSets/{sid}/appScreenshots").get("data", [])) for t, sid in types.items()}
        print(f"      screenshots [{la['locale']}]: {shots or 'none'}")
        if not any(t.startswith("APP_IPHONE_67") or t.startswith("APP_IPHONE_69") or t.startswith("APP_IPHONE_65") for t in shots if shots[t]):
            need(f"iPhone screenshots (6.9\" or 6.5\") [{la['locale']}]")
        else:
            good(f"iPhone screenshots [{la['locale']}]")
    rd = get(f"/appStoreVersions/{v['id']}/appStoreReviewDetail").get("data")
    if rd:
        ra = rd["attributes"]
        (good if ra.get("demoAccountName") else need)("Review: demo account" + ("" if ra.get("demoAccountName") else " missing"))
        (good if ra.get("contactEmail") and ra.get("contactPhone") else need)("Review: contact name, email and phone")
    else:
        need("App Review information (contact + demo account) not filled on the version")

# Subscriptions
groups = get(f"/apps/{aid}/subscriptionGroups").get("data", [])
for g in groups:
    for s in get(f"/subscriptionGroups/{g['id']}/subscriptions").get("data", []):
        st = s["attributes"].get("state")
        (good if st in ("READY_TO_SUBMIT", "WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED") else need)(f"Subscription {s['attributes']['productId']}: {st}")
    gl = get(f"/subscriptionGroups/{g['id']}/subscriptionGroupLocalizations").get("data", [])
    (good if gl else need)("Subscription group display name" + ("" if gl else " missing"))

# Builds
blds = get(f"/builds?filter[app]={aid}&sort=-uploadedDate&limit=1&include=buildBetaDetail").get("data", [])
for b in blds:
    ba = b["attributes"]
    print(f"Latest build {ba['version']}: {ba.get('processingState')}, expires {ba.get('expirationDate', '')[:10]}")
    sub = get(f"/builds/{b['id']}/betaAppReviewSubmission").get("data")
    print(f"      beta review: {sub['attributes'].get('betaReviewState') if sub else 'not submitted'}")

print(f"\n{ok_count} ready, {len(todo)} to do")
_print("::notice title=Launch check::" + "%0A".join(l.replace("%", "%25").replace("\n", " ") for l in LINES))
