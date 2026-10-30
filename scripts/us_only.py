"""Makes Baget US-only in the App Store: the app and both Baget Pro plans are sold in the United States only, and not
added to new countries automatically. Safe to rerun. Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID."""
import json, os, sys, time
import jwt, requests

API = "https://api.appstoreconnect.apple.com/v1"
key = open(os.environ["ASC_KEY_PATH"]).read()
now = int(time.time())
TOKEN = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1150, "aud": "appstoreconnect-v1"},
                   key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
H = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def call(method, path, body=None, ok=(200, 201, 204)):
    url = path if path.startswith("http") else API + path
    for attempt in range(4):
        r = requests.request(method, url, headers=H, data=json.dumps(body) if body else None, timeout=60)
        if r.status_code == 429:
            time.sleep(20); continue
        break
    if r.status_code not in ok:
        errs = r.json().get("errors", []) if r.content else []
        msg = "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in errs) or r.text[:300]
        raise RuntimeError(f"{method} {url.replace(API, '').split('?')[0]} -> {r.status_code}: {msg}")
    return r.json() if r.content else {}


def pages(path):
    out, url = [], path
    while url:
        j = call("GET", url)
        out += j.get("data", [])
        url = j.get("links", {}).get("next")
    return out


def note(m): print(f"::notice::{m}")


app_id = call("GET", f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"][0]["id"]
API2 = "https://api.appstoreconnect.apple.com/v2"

# 1. The app: every territory off except the US.
try:
    av = call("GET", f"/apps/{app_id}/appAvailabilityV2")["data"]
    terr = pages(f"{API2}/appAvailabilities/{av['id']}/territoryAvailabilities?include=territory&limit=200")
    off = on = 0
    for t in terr:
        tid = t["relationships"]["territory"]["data"]["id"]
        want = tid == "USA"
        if t["attributes"].get("available") == want:
            on += want; continue
        try:
            call("PATCH", f"/territoryAvailabilities/{t['id']}", {"data": {"type": "territoryAvailabilities", "id": t["id"], "attributes": {"available": want}}})
            if want: on += 1
            else: off += 1
        except RuntimeError as e:
            print(f"::warning::{tid}: {str(e)[:160]}")
    note(f"App: US on ({on}), turned off in {off} other countries")
    if av["attributes"].get("availableInNewTerritories"):
        note("App: still set to join new countries automatically (turn off in App Store Connect > Pricing and Availability if wanted)")
except RuntimeError as e:
    print(f"::error::app availability: {str(e)[:300]}")

# 2. Baget Pro: US only.
groups = pages(f"/apps/{app_id}/subscriptionGroups")
for g in groups:
    for s in pages(f"/subscriptionGroups/{g['id']}/subscriptions"):
        pid = s["attributes"]["productId"]
        try:
            call("POST", "/subscriptionAvailabilities", {"data": {"type": "subscriptionAvailabilities", "attributes": {"availableInNewTerritories": False},
                "relationships": {"subscription": {"data": {"type": "subscriptions", "id": s["id"]}},
                                  "availableTerritories": {"data": [{"type": "territories", "id": "USA"}]}}}})
            note(f"{pid}: US only")
        except RuntimeError as e:
            print(f"::error::{pid}: {str(e)[:300]}")
