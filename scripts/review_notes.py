"""Puts docs/review-notes.txt (with the video link filled in) into App Store version 1.0's App Review notes.
Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, VIDEO_LINK."""
import json, os, sys, time
import jwt, requests

API = "https://api.appstoreconnect.apple.com/v1"
now = int(time.time())
TOKEN = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1150, "aud": "appstoreconnect-v1"},
                   open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
H = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}

def call(method, path, body=None):
    r = requests.request(method, API + path, headers=H, data=json.dumps(body) if body else None, timeout=60)
    if r.status_code not in (200, 201, 204):
        sys.exit(f"::error::{method} {path.split('?')[0]} -> {r.status_code}: {r.text[:500]}")
    return r.json() if r.content else {}

link = os.environ.get("VIDEO_LINK", "").strip()
if not link.startswith("https://"):
    sys.exit("::error::VIDEO_LINK must be an https link")
notes = open("docs/review-notes.txt").read().replace("{VIDEO_LINK}", link).strip()
if len(notes) > 4000:
    sys.exit(f"::error::Notes are {len(notes)} characters; Apple allows 4000")
aid = call("GET", f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"][0]["id"]
vid = call("GET", f"/apps/{aid}/appStoreVersions?filter[platform]=IOS&limit=1")["data"][0]["id"]
d = call("GET", f"/appStoreVersions/{vid}/appStoreReviewDetail").get("data")
if not d:
    sys.exit("::error::No App Review details on the version")
call("PATCH", f"/appStoreReviewDetails/{d['id']}", {"data": {"type": "appStoreReviewDetails", "id": d["id"], "attributes": {"notes": notes}}})
print(f"::notice::Review notes set ({len(notes)} characters), demo sign-in required: {d['attributes'].get('demoAccountRequired')}")
