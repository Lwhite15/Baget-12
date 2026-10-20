"""Shrinks stored product photos to phone size (longest side 1000 px) and writes them back at the same address.
Runs on GitHub's machines (no compute limit there). Prints counts only, never keys.
Env: SUPABASE_ACCESS_TOKEN, PROJECT_REF, LIMIT."""
import io, json, os, sys
import requests
from PIL import Image

REF, TOKEN = os.environ["PROJECT_REF"], os.environ["SUPABASE_ACCESS_TOKEN"]
BASE = f"https://{REF}.supabase.co"

keys = requests.get(f"https://api.supabase.com/v1/projects/{REF}/api-keys?reveal=true",
                    headers={"Authorization": f"Bearer {TOKEN}"}, timeout=30).json()
service = next((k["api_key"] for k in keys if k.get("name") == "service_role"), None)
if not service:
    sys.exit("::error::No service key from the management API")
print(f"::add-mask::{service}")
H = {"apikey": service, "Authorization": f"Bearer {service}"}

rows = requests.post(f"{BASE}/rest/v1/rpc/large_photos", headers={**H, "Content-Type": "application/json"},
                     data=json.dumps({"p_limit": int(os.environ.get("LIMIT", "50"))}), timeout=60).json()
if not isinstance(rows, list):
    sys.exit(f"::error::large_photos failed: {str(rows)[:200]}")

shrunk = saved = failed = 0
for r in rows:
    name, mime = r["name"], r["mimetype"]
    try:
        got = requests.get(f"{BASE}/storage/v1/object/public/product-photos/{name}", timeout=60)
        got.raise_for_status()
        img = Image.open(io.BytesIO(got.content))
        img.thumbnail((1000, 1000), Image.LANCZOS)
        out = io.BytesIO()
        if mime == "image/png":
            img.save(out, "PNG", optimize=True)
        else:
            img.convert("RGB").save(out, "JPEG", quality=80, optimize=True, progressive=True)
        data = out.getvalue()
        if len(data) < len(got.content):
            up = requests.put(f"{BASE}/storage/v1/object/product-photos/{name}", data=data, timeout=60,
                              headers={**H, "Content-Type": mime, "x-upsert": "true", "cache-control": "max-age=31536000"})
            if up.ok:
                shrunk += 1
                saved += len(got.content) - len(data)
            else:
                failed += 1
    except Exception:
        failed += 1
    requests.post(f"{BASE}/rest/v1/photo_shrink_done", headers={**H, "Content-Type": "application/json", "Prefer": "resolution=ignore-duplicates"},
                  data=json.dumps({"name": name}), timeout=30)

print(f"::notice::photos checked {len(rows)}, shrunk {shrunk}, saved {saved // 1024} KB, failed {failed}")
