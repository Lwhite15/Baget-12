"""Gives the App Review demo account a new random password and puts it straight into App Store Connect's App Review
sign-in fields. The password is masked in logs and never printed, committed or stored anywhere else; you can see it in
App Store Connect under App Review Information. Doesn't submit anything.
Env: SUPABASE_ACCESS_TOKEN, PROJECT_REF, ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID."""
import json, os, secrets, string, sys, time
import bcrypt, jwt, requests

EMAIL = json.load(open("appstore/listing.json"))["demoAccountName"]
REF, TOKEN = os.environ["PROJECT_REF"], os.environ["SUPABASE_ACCESS_TOKEN"]
BASE = f"https://{REF}.supabase.co"

alphabet = string.ascii_letters + string.digits
pw = "Review-" + "".join(secrets.choice(alphabet) for _ in range(18))
print(f"::add-mask::{pw}")
hashed = bcrypt.hashpw(pw.encode(), bcrypt.gensalt(10)).decode()
print(f"::add-mask::{hashed}")

keys = requests.get(f"https://api.supabase.com/v1/projects/{REF}/api-keys?reveal=true",
                    headers={"Authorization": f"Bearer {TOKEN}"}, timeout=30).json()
service = next((k["api_key"] for k in keys if k.get("name") == "service_role"), None)
anon = next((k["api_key"] for k in keys if k.get("name") == "anon"), None)
if not service or not anon:
    sys.exit("::error::No keys from the Supabase management API")
print(f"::add-mask::{service}"); print(f"::add-mask::{anon}")

r = requests.post(f"{BASE}/rest/v1/rpc/set_demo_password", timeout=30,
                  headers={"apikey": service, "Authorization": f"Bearer {service}", "Content-Type": "application/json"},
                  data=json.dumps({"p_hash": hashed}))
if r.status_code != 200 or r.json() is not True:
    sys.exit(f"::error::Couldn't set the demo password (HTTP {r.status_code})")
print("::notice::OK   Demo account has a new password")

# Make sure it actually signs in before handing it to Apple.
r = requests.post(f"{BASE}/auth/v1/token?grant_type=password", timeout=30, headers={"apikey": anon, "Content-Type": "application/json"},
                  data=json.dumps({"email": EMAIL, "password": pw}))
if r.status_code != 200:
    sys.exit(f"::error::The demo account didn't sign in with the new password (HTTP {r.status_code})")
print(f"::notice::OK   Signed in as {EMAIL}")

API = "https://api.appstoreconnect.apple.com/v1"
now = int(time.time())
tok = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1150, "aud": "appstoreconnect-v1"},
                 open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
H = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
def call(method, path, body=None):
    r = requests.request(method, API + path, headers=H, data=json.dumps(body) if body else None, timeout=60)
    if r.status_code not in (200, 201, 204):
        errs = r.json().get("errors", []) if r.content else []
        sys.exit(f"::error::{method} {path.split('?')[0]} -> {r.status_code}: " + "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in errs)[:400].replace(pw, "***"))
    return r.json() if r.content else {}

aid = call("GET", f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"][0]["id"]
vid = call("GET", f"/apps/{aid}/appStoreVersions?filter[platform]=IOS&limit=1")["data"][0]["id"]
attrs = {"demoAccountName": EMAIL, "demoAccountPassword": pw, "demoAccountRequired": True}
cur = call("GET", f"/appStoreVersions/{vid}/appStoreReviewDetail").get("data")
if cur:
    call("PATCH", f"/appStoreReviewDetails/{cur['id']}", {"data": {"type": "appStoreReviewDetails", "id": cur["id"], "attributes": attrs}})
else:
    call("POST", "/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
          "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
print("::notice::OK   App Store Connect App Review sign-in updated (see App Review Information to view it)")
