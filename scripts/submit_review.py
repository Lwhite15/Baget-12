"""Submits App Store version 1.0 (with its attached build) for App Review, with the Pro subscriptions alongside it.
Checks the build first and prints Apple's states and reasons only. Run only when Larry asks to submit.
Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, EXPECT_BUILD."""
import json, os, sys, time
import jwt, requests

API = "https://api.appstoreconnect.apple.com/v1"
now = int(time.time())
TOKEN = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1150, "aud": "appstoreconnect-v1"},
                   open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
H = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def call(method, path, body=None, ok=(200, 201, 204)):
    r = requests.request(method, path if path.startswith("http") else API + path, headers=H, data=json.dumps(body) if body else None, timeout=60)
    if r.status_code not in ok:
        errs = r.json().get("errors", []) if r.content else []
        raise RuntimeError(f"{method} {path.split('?')[0]} -> {r.status_code}: " + "; ".join(
            f"{e.get('title')}: {e.get('detail')}" + (f" [{json.dumps(e.get('meta', {}).get('associatedErrors'))[:600]}]" if e.get("meta") else "") for e in errs)[:1500])
    return r.json() if r.content else {}

def note(m): print(f"::notice::{m}")
def warn(m): print(f"::warning::{m}")

aid = call("GET", f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"][0]["id"]
ver = call("GET", f"/apps/{aid}/appStoreVersions?filter[platform]=IOS&limit=1")["data"][0]
vid, vs = ver["id"], ver["attributes"]
note(f"Version {vs['versionString']}: {vs.get('appStoreState') or vs.get('appVersionState')}")
b = call("GET", f"/appStoreVersions/{vid}/build").get("data")
if not b:
    sys.exit("::error::No build attached to the version")
if b["attributes"]["version"] != os.environ.get("EXPECT_BUILD", b["attributes"]["version"]):
    sys.exit(f"::error::Attached build is {b['attributes']['version']}, expected {os.environ['EXPECT_BUILD']}")
note(f"Build {b['attributes']['version']} attached ({b['attributes'].get('processingState')})")

# Subscriptions ride along with the version (first-time subscriptions must go with an app version).
for g in call("GET", f"/apps/{aid}/subscriptionGroups")["data"]:
    for s in call("GET", f"/subscriptionGroups/{g['id']}/subscriptions")["data"]:
        name, state = s["attributes"]["name"], s["attributes"]["state"]
        if state == "READY_TO_SUBMIT":
            try:
                call("POST", "/subscriptionSubmissions", {"data": {"type": "subscriptionSubmissions",
                     "relationships": {"subscription": {"data": {"type": "subscriptions", "id": s["id"]}}}}})
                note(f"Subscription '{name}' added to the submission")
            except Exception as e:
                warn(f"Subscription '{name}': {e}")
        else:
            note(f"Subscription '{name}': {state}")

# One review submission for iOS: reuse an open one, otherwise make it.
open_states = ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES")
subs = call("GET", f"/reviewSubmissions?filter[app]={aid}&filter[platform]=IOS&limit=20")["data"]
for s in subs:
    if s["attributes"]["state"] in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
        note(f"Already submitted: {s['attributes']['state']}"); sys.exit(0)
rs = next((s for s in subs if s["attributes"]["state"] in open_states), None)
if not rs:
    rs = call("POST", "/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
              "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}})["data"]
rid = rs["id"]
items = call("GET", f"/reviewSubmissions/{rid}/items?include=appStoreVersion")["data"]
has_version = any((i.get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id") == vid for i in items)
note(f"Review submission has {len(items)} item(s); version included: {has_version}")
if not has_version:
    try:
        call("POST", "/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
             "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": rid}},
             "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
        note("Version added to the review submission")
    except Exception as e:
        sys.exit(f"::error::Couldn't add the version: {e}")

try:
    r = call("PATCH", f"/reviewSubmissions/{rid}", {"data": {"type": "reviewSubmissions", "id": rid, "attributes": {"submitted": True}}})
    note(f"SUBMITTED for App Review: {r['data']['attributes']['state']}")
except Exception as e:
    sys.exit(f"::error::Submit failed: {e}")
