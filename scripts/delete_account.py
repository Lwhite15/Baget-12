"""Permanently deletes one Baget account by handle: its photos in storage, then the login (everything else goes with it).
Prints counts only. Env: SUPABASE_ACCESS_TOKEN, PROJECT_REF, HANDLE, CONFIRM (must equal HANDLE)."""
import json, os, sys
import requests

REF, TOKEN = os.environ["PROJECT_REF"], os.environ["SUPABASE_ACCESS_TOKEN"]
handle = os.environ["HANDLE"].strip().lstrip("@").lower()
if not handle or os.environ.get("CONFIRM", "").strip().lstrip("@").lower() != handle:
    sys.exit("::error::Type the handle again in 'confirm' to delete it")
BASE = f"https://{REF}.supabase.co"
keys = requests.get(f"https://api.supabase.com/v1/projects/{REF}/api-keys?reveal=true", headers={"Authorization": f"Bearer {TOKEN}"}, timeout=30).json()
service = next((k["api_key"] for k in keys if k.get("name") == "service_role"), None)
if not service:
    sys.exit("::error::No service key")
print(f"::add-mask::{service}")
H = {"apikey": service, "Authorization": f"Bearer {service}"}

rows = requests.get(f"{BASE}/rest/v1/profiles", params={"select": "id,plan", "handle": f"eq.{handle}"}, headers=H, timeout=30).json()
if not isinstance(rows, list) or len(rows) != 1:
    sys.exit(f"::error::No single account with that handle (found {len(rows) if isinstance(rows, list) else 'error'})")
uid = rows[0]["id"]
if uid.startswith("0a99e1e0-5eed-4d3e-8a00-"):
    sys.exit("::error::That's one of Baget's own accounts")

removed = 0
for bucket, prefixes in (("taste-photos", [f"{uid}/", f"{uid}/avatars/"]), ("feedback", [f"{uid}/"])):
    for prefix in prefixes:
        files = requests.post(f"{BASE}/storage/v1/object/list/{bucket}", headers={**H, "Content-Type": "application/json"},
                              data=json.dumps({"prefix": prefix, "limit": 1000, "offset": 0}), timeout=30).json()
        paths = [f"{prefix}{f['name']}" for f in (files if isinstance(files, list) else []) if f.get("id")]
        if paths:
            requests.delete(f"{BASE}/storage/v1/object/{bucket}", headers={**H, "Content-Type": "application/json"},
                            data=json.dumps({"prefixes": paths}), timeout=30)
            removed += len(paths)

r = requests.delete(f"{BASE}/auth/v1/admin/users/{uid}", headers=H, timeout=30)
if not r.ok:
    sys.exit(f"::error::Couldn't delete the login ({r.status_code})")
left = requests.get(f"{BASE}/rest/v1/profiles", params={"select": "id", "id": f"eq.{uid}"}, headers=H, timeout=30).json()
print(f"::notice::Deleted @{handle}: {removed} photos removed, login deleted, profile gone: {left == []}")
