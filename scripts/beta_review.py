"""Submits a TestFlight build for Beta App Review through the App Store Connect API.

Sets "What to Test", adds the build to every external tester group and to the app's individual external testers,
then submits it for review. Prints statuses only, never keys.
Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, BUILD (number or "latest"), WHAT_TO_TEST.
"""
import json, os, sys, time
import jwt, requests

API = "https://api.appstoreconnect.apple.com/v1"


def token():
    key = open(os.environ["ASC_KEY_PATH"]).read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


H = {"Authorization": f"Bearer {token()}", "Content-Type": "application/json"}


def call(method, path, body=None, ok=(200, 201, 204)):
    r = requests.request(method, API + path, headers=H, data=json.dumps(body) if body else None, timeout=60)
    if r.status_code not in ok:
        errs = r.json().get("errors", []) if r.content else []
        msg = "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in errs) or r.text[:300]
        raise RuntimeError(f"{method} {path.split('?')[0]} -> {r.status_code}: {msg}")
    return r.json() if r.content else {}


def note(msg): print(f"::notice::{msg}")


app = call("GET", f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"]
if not app: sys.exit("::error::No app with that bundle ID")
app_id = app[0]["id"]

want = os.environ.get("BUILD", "latest").strip() or "latest"
q = f"/builds?filter[app]={app_id}&sort=-uploadedDate&limit=1" if want == "latest" else f"/builds?filter[app]={app_id}&filter[version]={want}"
builds = call("GET", q)["data"]
if not builds: sys.exit(f"::error::Build {want} not found (still processing?)")
b = builds[0]
bid, num, state = b["id"], b["attributes"]["version"], b["attributes"]["processingState"]
note(f"Build {num}: processing {state}, expired={b['attributes'].get('expired')}")
for _ in range(20):
    if state == "VALID": break
    time.sleep(30)
    state = call("GET", f"/builds/{bid}")["data"]["attributes"]["processingState"]
if state != "VALID": sys.exit(f"::error::Build {num} is {state}; try again once it finishes processing")

# Export compliance (the app uses only standard encryption).
if b["attributes"].get("usesNonExemptEncryption") is None:
    try:
        call("PATCH", f"/builds/{bid}", {"data": {"type": "builds", "id": bid, "attributes": {"usesNonExemptEncryption": False}}})
    except RuntimeError as e:
        note(f"Export compliance already set ({str(e)[:80]})")

# What to Test.
text = os.environ.get("WHAT_TO_TEST", "").strip()
if text:
    locs = call("GET", f"/builds/{bid}/betaBuildLocalizations")["data"]
    if locs:
        call("PATCH", f"/betaBuildLocalizations/{locs[0]['id']}", {"data": {"type": "betaBuildLocalizations", "id": locs[0]["id"], "attributes": {"whatsNew": text}}})
    else:
        call("POST", "/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": text},
                                                          "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
    note("What to Test set")

# External testers: every external group, plus individual testers.
groups = [g for g in call("GET", f"/apps/{app_id}/betaGroups?limit=50")["data"] if not g["attributes"].get("isInternalGroup")]
for g in groups:
    call("POST", f"/betaGroups/{g['id']}/relationships/builds", {"data": [{"type": "builds", "id": bid}]}, ok=(200, 201, 204, 409))
note(f"Added to {len(groups)} external group(s)")
testers = call("GET", f"/betaTesters?filter[apps]={app_id}&limit=200")["data"]
internal_ids = set()
for g in call("GET", f"/apps/{app_id}/betaGroups?limit=50")["data"]:
    if g["attributes"].get("isInternalGroup"):
        internal_ids |= {t["id"] for t in call("GET", f"/betaGroups/{g['id']}/betaTesters?limit=200")["data"]}
external = [t for t in testers if t["id"] not in internal_ids]
if external:
    call("POST", f"/builds/{bid}/relationships/individualTesters", {"data": [{"type": "betaTesters", "id": t["id"]} for t in external]}, ok=(200, 201, 204, 409))
note(f"Shared with {len(external)} individual external tester(s)")

# Submit.
subs = call("GET", f"/betaAppReviewSubmissions?filter[build]={bid}")["data"]
if subs:
    note(f"Already submitted: {subs[0]['attributes'].get('betaReviewState')}")
else:
    try:
        s = call("POST", "/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
        note(f"Submitted build {num} for Beta App Review: {s['data']['attributes'].get('betaReviewState')}")
    except RuntimeError as e:
        print(f"::error::Submit failed: {e}")
        sys.exit(1)
detail = call("GET", f"/builds/{bid}/buildBetaDetail")["data"]["attributes"]
note(f"External state: {detail.get('externalBuildState')}, internal: {detail.get('internalBuildState')}")
