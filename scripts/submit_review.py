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
            f"{e.get('title')}: {e.get('detail')}" + (f" [{json.dumps(e.get('meta', {}).get('associatedErrors'))[:4000]}]" if e.get("meta") else "") for e in errs)[:6000])
    return r.json() if r.content else {}

def note(m): print(f"::notice::{m}")
def warn(m): print(f"::warning::{m}")

aid = call("GET", f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"][0]["id"]
ver = call("GET", f"/apps/{aid}/appStoreVersions?filter[platform]=IOS&limit=1")["data"][0]
vid, vs = ver["id"], ver["attributes"]
note(f"Version {vs['versionString']}: {vs.get('appStoreState') or vs.get('appVersionState')}")
if os.environ.get("CANCEL_FIRST") == "1":
    subs = call("GET", f"/reviewSubmissions?filter[app]={aid}&filter[platform]=IOS&limit=20")["data"]
    # Pull a waiting submission back (e.g. to add the subscriptions), then build it again below.
    for s in subs:
        if s["attributes"]["state"] == "WAITING_FOR_REVIEW":
            call("PATCH", f"/reviewSubmissions/{s['id']}", {"data": {"type": "reviewSubmissions", "id": s["id"], "attributes": {"canceled": True}}})
            note("Pulled the waiting submission back from review")
            for _ in range(30):
                time.sleep(10)
                st = call("GET", f"/reviewSubmissions/{s['id']}")["data"]["attributes"]["state"]
                if st not in ("CANCELING", "WAITING_FOR_REVIEW"): break
            note(f"Previous submission now: {st}")
# Swap in a different build (by number) when asked.
want = os.environ.get("ATTACH_BUILD", "")
if want:
    bs = call("GET", f"/builds?filter[app]={aid}&filter[version]={want}&filter[preReleaseVersion.platform]=IOS&limit=5")["data"]
    if not bs: sys.exit(f"::error::Build {want} not found")
    call("PATCH", f"/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": bs[0]["id"]}})
    note(f"Build {want} attached to version {vs['versionString']}")
b = call("GET", f"/appStoreVersions/{vid}/build").get("data")
if not b:
    sys.exit("::error::No build attached to the version")
if b["attributes"]["version"] != os.environ.get("EXPECT_BUILD", b["attributes"]["version"]):
    sys.exit(f"::error::Attached build is {b['attributes']['version']}, expected {os.environ['EXPECT_BUILD']}")
note(f"Build {b['attributes']['version']} attached ({b['attributes'].get('processingState')})")

# Content rights: Larry answered "contains third-party content, and I have the rights" (Oct 20). Apply it if it didn't stick.
app = call("GET", f"/apps/{aid}")["data"]
cr = app["attributes"].get("contentRightsDeclaration")
note(f"Content rights: {cr}")
if not cr:
    call("PATCH", f"/apps/{aid}", {"data": {"type": "apps", "id": aid, "attributes": {"contentRightsDeclaration": "USES_THIRD_PARTY_CONTENT"}}})
    note("Content rights set: uses third-party content, with rights")

# Screenshots: Apple won't take the version while any are still processing.
loc = [x for x in call("GET", f"/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"] if x["attributes"]["locale"] == "en-US"][0]
for st in call("GET", f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]:
    shots = call("GET", f"/appScreenshotSets/{st['id']}/appScreenshots")["data"]
    states = [(x["attributes"].get("fileName"), (x["attributes"].get("assetDeliveryState") or {}).get("state")) for x in shots]
    note(f"Screenshots {st['attributes']['screenshotDisplayType']}: " + ", ".join(f"{n}={s}" for n, s in states))

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
        msg = str(e)
        for k in range(0, len(msg), 900): print(f"::error::Couldn't add the version ({k // 900 + 1}): {msg[k:k + 900]}")
        sys.exit(1)

# Subscriptions ride along with the version (first-time subscriptions must go with an app version, so this runs after
# the version is in the review submission). If they can't be added, stop before submitting.
missing = []
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
                missing.append(name)
        else:
            note(f"Subscription '{name}': {state}")

# The subscription group goes with its subscriptions: reset a rejected group name, then add the group itself.
for g in call("GET", f"/apps/{aid}/subscriptionGroups")["data"]:
    for gl in call("GET", f"/subscriptionGroups/{g['id']}/subscriptionGroupLocalizations")["data"]:
        st = gl["attributes"].get("state")
        note(f"Group '{g['attributes']['referenceName']}' {gl['attributes'].get('locale')}: {st}")
        if st and st not in ("APPROVED", "WAITING_FOR_REVIEW", "PREPARE_FOR_SUBMISSION"):
            try:
                call("PATCH", f"/subscriptionGroupLocalizations/{gl['id']}", {"data": {"type": "subscriptionGroupLocalizations", "id": gl["id"],
                     "attributes": {"name": gl["attributes"]["name"], "customAppName": gl["attributes"].get("customAppName")}}})
                note("Group name re-saved")
            except Exception as e:
                warn(f"Group name: {e}")
    try:
        call("POST", "/subscriptionGroupSubmissions", {"data": {"type": "subscriptionGroupSubmissions",
             "relationships": {"subscriptionGroup": {"data": {"type": "subscriptionGroups", "id": g["id"]}}}}})
        note(f"Group '{g['attributes']['referenceName']}' added to the submission")
    except Exception as e:
        warn(f"Group submission: {e}")

if missing and os.environ.get("REQUIRE_SUBS") == "1":
    sys.exit(f"::error::Not submitted: couldn't add {', '.join(missing)}. Add them on the version page (In-App Purchases and Subscriptions), then submit.")

try:
    r = call("PATCH", f"/reviewSubmissions/{rid}", {"data": {"type": "reviewSubmissions", "id": rid, "attributes": {"submitted": True}}})
    note(f"SUBMITTED for App Review: {r['data']['attributes']['state']}")
except Exception as e:
    sys.exit(f"::error::Submit failed: {e}")
