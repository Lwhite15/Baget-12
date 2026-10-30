"""Creates Baget Pro in App Store Connect: a subscription group with monthly and yearly plans, names, prices in every
territory (from the US price), availability, and the server notification URL. Safe to re-run: existing pieces are kept.
Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, MONTHLY, YEARLY (US prices like 7.99), NOTIFY_URL."""
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

groups = pages(f"/apps/{app_id}/subscriptionGroups")
group = next((g for g in groups if g["attributes"]["referenceName"] == "Baget Pro"), None)
if not group:
    group = call("POST", "/subscriptionGroups", {"data": {"type": "subscriptionGroups", "attributes": {"referenceName": "Baget Pro"},
                                                      "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
    note("Created subscription group Baget Pro")
gid = group["id"]
if not pages(f"/subscriptionGroups/{gid}/subscriptionGroupLocalizations"):
    call("POST", "/subscriptionGroupLocalizations", {"data": {"type": "subscriptionGroupLocalizations", "attributes": {"name": "Baget Pro", "locale": "en-US"},
                                                           "relationships": {"subscriptionGroup": {"data": {"type": "subscriptionGroups", "id": gid}}}}})

# US only (Baget launches in the US; scripts/us_only.py keeps it that way).
territories = ["USA"]
plans = [
    ("baget.pro.monthly", "Pro Monthly", "ONE_MONTH", os.environ.get("MONTHLY", "7.99"), 1),
    ("baget.pro.yearly", "Pro Yearly", "ONE_YEAR", os.environ.get("YEARLY", "59.99"), 1),
]
existing = {s["attributes"]["productId"]: s for s in pages(f"/subscriptionGroups/{gid}/subscriptions")}
for pid, name, period, usd, level in plans:
    sub = existing.get(pid)
    if not sub:
        sub = call("POST", "/subscriptions", {"data": {"type": "subscriptions",
            "attributes": {"name": name, "productId": pid, "subscriptionPeriod": period, "groupLevel": level, "familySharable": False,
                           "reviewNote": "Unlocks around-the-clock hunting. Free accounts hunt 4 hours a day."},
            "relationships": {"group": {"data": {"type": "subscriptionGroups", "id": gid}}}}})["data"]
        note(f"Created {pid}")
    sid = sub["id"]
    if not pages(f"/subscriptions/{sid}/subscriptionLocalizations"):
        call("POST", "/subscriptionLocalizations", {"data": {"type": "subscriptionLocalizations",
            "attributes": {"locale": "en-US", "name": "Baget Pro", "description": "Your scouts hunt around the clock."},
            "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sid}}}}})
    # Availability: everywhere, including new territories.
    try:
        call("POST", "/subscriptionAvailabilities", {"data": {"type": "subscriptionAvailabilities", "attributes": {"availableInNewTerritories": False},
            "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sid}},
                              "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]}}}})
    except RuntimeError as e:
        note(f"{pid} availability: {str(e)[:160]}")
    # Prices: the US price point, then its equivalents in every other territory.
    # REPRICE=1 changes existing prices (from tomorrow if Apple won't change today's).
    reprice = os.environ.get("REPRICE") == "1"
    if pages(f"/subscriptions/{sid}/prices?limit=200") and not reprice:
        note(f"{pid}: prices already set")
        continue
    us = next((p for p in pages(f"/subscriptions/{sid}/pricePoints?filter[territory]=USA&limit=200")
               if p["attributes"]["customerPrice"] in (usd, usd.rstrip("0").rstrip("."))), None)
    if not us:
        print(f"::error::{pid}: no US price point for ${usd}"); continue
    points = [us] + pages(f"/subscriptionPricePoints/{us['id']}/equalizations?limit=200")
    done = 0
    start = None
    import datetime
    for p in points:
        for attempt in (start, (datetime.date.today() + datetime.timedelta(days=1)).isoformat()):
            try:
                attrs = {"preserveCurrentPrice": False, **({"startDate": attempt} if attempt else {})}
                call("POST", "/subscriptionPrices", {"data": {"type": "subscriptionPrices", "attributes": attrs,
                    "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sid}},
                                      "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": p["id"]}}}}})
                done += 1
                start = attempt
                break
            except RuntimeError as e:
                if done == 0 and attempt: print(f"::warning::{pid} price: {str(e)[:200]}")
    note(f"{pid}: ${usd} set in {done} territories" + (f" (from {start})" if start else ""))
    final = call("GET", f"/subscriptions/{sid}")["data"]["attributes"]["state"]
    note(f"{pid} state: {final}")

url = os.environ.get("NOTIFY_URL", "")
if url:
    try:
        call("PATCH", f"/apps/{app_id}", {"data": {"type": "apps", "id": app_id, "attributes": {
            "subscriptionStatusUrl": url, "subscriptionStatusUrlVersion": "V2",
            "subscriptionStatusUrlForSandbox": url, "subscriptionStatusUrlVersionForSandbox": "V2"}}})
        note("App Store Server Notifications point at Baget")
    except RuntimeError as e:
        note(f"Notification URL not set ({str(e)[:160]}); renewals still sync from the app")
# App Review screenshot of the paywall (taken by the iOS build in the simulator).
shot = os.environ.get("SHOT", "")
if shot and os.path.exists(shot):
    import hashlib
    data = open(shot, "rb").read()
    for s in pages(f"/subscriptionGroups/{gid}/subscriptions"):
        sid = s["id"]
        try:
            have = call("GET", f"/subscriptions/{sid}/appStoreReviewScreenshot").get("data")
        except RuntimeError:
            have = None
        if have and os.environ.get("RESHOT") == "1":
            call("DELETE", f"/subscriptionAppStoreReviewScreenshots/{have['id']}")
            have = None
        if have:
            continue
        res = call("POST", "/subscriptionAppStoreReviewScreenshots", {"data": {"type": "subscriptionAppStoreReviewScreenshots",
            "attributes": {"fileName": "paywall.png", "fileSize": len(data)},
            "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sid}}}}})["data"]
        for op in res["attributes"]["uploadOperations"]:
            hdrs = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
            chunk = data[op["offset"]: op["offset"] + op["length"]]
            r = requests.request(op["method"], op["url"], headers=hdrs, data=chunk, timeout=120)
            if r.status_code >= 300: raise RuntimeError(f"screenshot upload {r.status_code}")
        call("PATCH", f"/subscriptionAppStoreReviewScreenshots/{res['id']}", {"data": {"type": "subscriptionAppStoreReviewScreenshots", "id": res["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
        note(f"{s['attributes']['productId']}: review screenshot uploaded")
else:
    note("No paywall screenshot yet (run an iOS build first)")
time.sleep(5)
for s in pages(f"/subscriptionGroups/{gid}/subscriptions"):
    note(f"{s['attributes']['productId']}: {s['attributes']['state']}")
