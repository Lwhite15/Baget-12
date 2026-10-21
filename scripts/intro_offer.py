"""Adds a free-trial introductory offer to both Baget Pro subscriptions (all territories). Safe to rerun: skips a
subscription that already has a free trial. Prints statuses only.
Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, TRIAL (ONE_WEEK by default)."""
import json, os, sys, time
import jwt, requests

API = "https://api.appstoreconnect.apple.com/v1"
now = int(time.time())
TOKEN = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1150, "aud": "appstoreconnect-v1"},
                   open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
H = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}
TRIAL = os.environ.get("TRIAL") or "ONE_WEEK"


def call(method, path, body=None, ok=(200, 201, 204)):
    r = requests.request(method, path if path.startswith("http") else API + path, headers=H, data=json.dumps(body) if body else None, timeout=60)
    if r.status_code not in ok:
        errs = r.json().get("errors", []) if r.content else []
        raise RuntimeError(f"{method} {path.split('?')[0]} -> {r.status_code}: " + "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in errs)[:900])
    return r.json() if r.content else {}

def note(m): print(f"::notice::{m}")

aid = call("GET", f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"][0]["id"]
failed = False
for g in call("GET", f"/apps/{aid}/subscriptionGroups")["data"]:
    for s in call("GET", f"/subscriptionGroups/{g['id']}/subscriptions")["data"]:
        name = s["attributes"]["name"]
        have = call("GET", f"/subscriptions/{s['id']}/introductoryOffers?limit=200")["data"]
        trials = [o for o in have if o["attributes"].get("offerMode") == "FREE_TRIAL"]
        if trials:
            note(f"{name}: already has a free trial ({trials[0]['attributes'].get('duration')}, {len(trials)} territories)"); continue
        body = {"data": {"type": "subscriptionIntroductoryOffers",
                         "attributes": {"duration": TRIAL, "offerMode": "FREE_TRIAL", "numberOfPeriods": 1},
                         "relationships": {"subscription": {"data": {"type": "subscriptions", "id": s["id"]}}}}}
        try:
            call("POST", "/subscriptionIntroductoryOffers", body)
            note(f"{name}: free trial added ({TRIAL}, all territories)")
            continue
        except Exception as e:
            note(f"{name}: all-territories offer not accepted ({e}); adding per territory")
        # Fall back: one offer per territory the subscription is sold in.
        prices = call("GET", f"/subscriptions/{s['id']}/prices?include=territory&limit=200")
        terrs = sorted({p["relationships"]["territory"]["data"]["id"] for p in prices["data"] if p.get("relationships", {}).get("territory", {}).get("data")})
        ok = 0
        for t in terrs:
            b = json.loads(json.dumps(body)); b["data"]["relationships"]["territory"] = {"data": {"type": "territories", "id": t}}
            try: call("POST", "/subscriptionIntroductoryOffers", b); ok += 1
            except Exception as e: print(f"::warning::{name} {t}: {e}")
        note(f"{name}: free trial added in {ok}/{len(terrs)} territories")
        failed = failed or ok == 0
sys.exit(1 if failed else 0)
