"""Fills the App Store listing for version 1.0 from appstore/listing.json, appstore/description.txt and the latest
store screenshots on the "shots" branch. Doesn't submit anything for review. Prints statuses only.
Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, SHOTS_DIR."""
import hashlib, json, os, sys, time
import jwt, requests

API = "https://api.appstoreconnect.apple.com/v1"
now = int(time.time())
TOKEN = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1150, "aud": "appstoreconnect-v1"},
                   open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
H = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}
L = json.load(open("appstore/listing.json"))
DESC = open("appstore/description.txt").read().strip()


def call(method, path, body=None, ok=(200, 201, 204)):
    r = requests.request(method, path if path.startswith("http") else API + path, headers=H, data=json.dumps(body) if body else None, timeout=60)
    if r.status_code not in ok:
        errs = r.json().get("errors", []) if r.content else []
        raise RuntimeError(f"{method} {path.split('?')[0]} -> {r.status_code}: " + "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in errs)[:400])
    return r.json() if r.content else {}


def note(m): print(f"::notice::{m}")
def step(name, fn):
    try:
        fn(); note(f"OK   {name}")
    except Exception as e:
        print(f"::warning::FAIL {name}: {e}")


app = call("GET", f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")["data"][0]
aid = app["id"]
info = call("GET", f"/apps/{aid}/appInfos")["data"][0]
ver = call("GET", f"/apps/{aid}/appStoreVersions?filter[platform]=IOS&limit=1")["data"][0]
vid = ver["id"]

def categories():
    call("PATCH", f"/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": L["primaryCategory"]}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": L["secondaryCategory"]}}}}})
step("Category: Shopping, then Lifestyle", categories)

def info_loc():
    loc = [x for x in call("GET", f"/appInfos/{info['id']}/appInfoLocalizations")["data"] if x["attributes"]["locale"] == "en-US"][0]
    call("PATCH", f"/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": {
        "subtitle": L["subtitle"], "privacyPolicyUrl": L["privacyPolicyUrl"]}}})
step("Subtitle and privacy policy link", info_loc)

def version_attrs():
    call("PATCH", f"/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid, "attributes": {
        "copyright": L["copyright"], "releaseType": L["releaseType"]}}})
step("Copyright and manual release", version_attrs)

vloc = [x for x in call("GET", f"/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"] if x["attributes"]["locale"] == "en-US"][0]
def version_loc():
    call("PATCH", f"/appStoreVersionLocalizations/{vloc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": vloc["id"], "attributes": {
        "description": DESC, "keywords": L["keywords"], "supportUrl": L["supportUrl"], "promotionalText": L["promotionalText"]}}})
step("Description, keywords, support link, promotional text", version_loc)

def build():
    b = call("GET", f"/builds?filter[app]={aid}&filter[version]={L['build']}")["data"][0]
    call("PATCH", f"/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": b["id"]}})
step(f"Build {L['build']} attached", build)

def review():
    attrs = {"notes": L["reviewNotes"], "demoAccountName": L["demoAccountName"], "demoAccountRequired": True}
    cur = call("GET", f"/appStoreVersions/{vid}/appStoreReviewDetail").get("data")
    if cur:
        call("PATCH", f"/appStoreReviewDetails/{cur['id']}", {"data": {"type": "appStoreReviewDetails", "id": cur["id"], "attributes": attrs}})
    else:
        call("POST", "/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
             "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
step("App Review notes and demo account name", review)

def screenshots():
    d = os.environ["SHOTS_DIR"]
    files = sorted(f for f in os.listdir(d) if f[0].isdigit() and f.endswith(".png"))
    if not files: raise RuntimeError("no screenshots found")
    sets = call("GET", f"/appStoreVersionLocalizations/{vloc['id']}/appScreenshotSets")["data"]
    s = next((x for x in sets if x["attributes"]["screenshotDisplayType"] == "APP_IPHONE_67"), None)
    if s:
        for old in call("GET", f"/appScreenshotSets/{s['id']}/appScreenshots")["data"]:
            call("DELETE", f"/appScreenshots/{old['id']}")
    else:
        s = call("POST", "/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
                 "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": vloc["id"]}}}}})["data"]
    for f in files:
        data = open(os.path.join(d, f), "rb").read()
        shot = call("POST", "/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {"fileName": f, "fileSize": len(data)},
                    "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": s["id"]}}}}})["data"]
        for op in shot["attributes"]["uploadOperations"]:
            part = data[op["offset"]: op["offset"] + op["length"]]
            r = requests.request(op["method"], op["url"], data=part, headers={h["name"]: h["value"] for h in op.get("requestHeaders", [])}, timeout=120)
            r.raise_for_status()
        call("PATCH", f"/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
             "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    note(f"{len(files)} screenshots uploaded: {', '.join(files)}")
step("iPhone 6.9-inch screenshots", screenshots)
