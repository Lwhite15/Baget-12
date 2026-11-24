"""Releases an App Store version that Apple approved and is waiting for a manual release (Pending Developer Release).
Run only when Larry says to release. Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, VERSION (optional)."""
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
want = os.environ.get("VERSION", "").strip()
versions = call("GET", f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=20")["data"]
v = next((x for x in versions if x["attributes"]["appStoreState"] == "PENDING_DEVELOPER_RELEASE"
          and (not want or x["attributes"]["versionString"] == want)), None)
if not v:
    states = ", ".join(f"{x['attributes']['versionString']}: {x['attributes']['appStoreState']}" for x in versions[:5])
    print(f"::error::No approved version waiting for release ({states})"); sys.exit(1)
vs = v["attributes"]["versionString"]
call("POST", "/appStoreVersionReleaseRequests",
     {"data": {"type": "appStoreVersionReleaseRequests",
               "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
note(f"Released version {vs}")
for _ in range(6):
    time.sleep(10)
    st = call("GET", f"/appStoreVersions/{v['id']}")["data"]["attributes"]["appStoreState"]
    if st != "PENDING_DEVELOPER_RELEASE": break
note(f"Version {vs} is now {st}")
