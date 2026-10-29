"""Fills Baget/Localizable.xcstrings with Spanish, French and Korean for every string the app shows.

Reads the strings Xcode extracted (xcodebuild -exportLocalizations → <lang>.xcloc), translates the ones the catalog
doesn't have yet with Claude, checks that placeholders (%@, %lld, %1$@ …) survive, and writes the catalog back.
Env: ANTHROPIC_API_KEY, ANTHROPIC_MODEL (optional), LOC_DIR (the export folder). Usage: python3 scripts/translate_strings.py
"""
import concurrent.futures, glob, json, os, re, sys, threading, time
import xml.etree.ElementTree as ET
import requests

LANGS = {
    "es": "Spanish (United States, neutral Latin American)", "fr": "French (France)", "ko": "Korean (polite 해요체)",
    "vi": "Vietnamese", "zh-Hans": "Simplified Chinese (Mainland China)", "zh-Hant": "Traditional Chinese (Taiwan)",
    "ja": "Japanese (polite です/ます)", "th": "Thai", "id": "Indonesian", "hi": "Hindi (Devanagari, everyday conversational)",
    "fil": "Filipino (Tagalog, natural Taglish where English shopping words are normal)",
}
CATALOG = "Baget/Localizable.xcstrings"
MODEL = os.environ.get("ANTHROPIC_MODEL") or "claude-sonnet-5-5"
KEY = os.environ["ANTHROPIC_API_KEY"]
PH = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f|\.\d+f|%)")

def extracted():
    """Source strings from the exported xliff (any language's file has the same sources)."""
    out = {}
    for path in glob.glob(os.path.join(os.environ.get("LOC_DIR", "loc"), "*.xcloc", "Localized Contents", "*.xliff")):
        ns = {"x": "urn:oasis:names:tc:xliff:document:1.2"}
        for f in ET.parse(path).getroot().findall("x:file", ns):
            if not f.get("original", "").endswith("Localizable.xcstrings"):
                continue
            for tu in f.iter("{urn:oasis:names:tc:xliff:document:1.2}trans-unit"):
                src = tu.find("x:source", ns)
                note = tu.find("x:note", ns)
                if src is not None and tu.get("id"):
                    out[tu.get("id")] = (src.text or "", (note.text or "") if note is not None else "")
        break
    return out

def ask(lang_name, items):
    prompt = f"""Translate these strings from Baget, an iPhone shopping app, into {lang_name}.
Baget gives people personal "scouts" (AI shopping agents) that hunt the web for sneakers, clothing, fragrance, watches and more.
Rules:
- Natural, short, friendly app copy, the way a native speaker would write a button, label or message. Match the length of the English.
- Keep every placeholder exactly as written (%@, %lld, %1$@, %%, and so on), in an order that reads naturally.
- Keep brand and product names, "Baget", "Pro", "Today's Drop" style proper names, and emoji as they are.
- "scout" is the app's word for an AI shopping agent: translate it consistently (Spanish "explorador", French "éclaireur", Korean "스카우트",
  Japanese "スカウト"; for other languages pick one natural word and use it every time).
- A "find" is a product a scout found (Spanish "hallazgo", French "trouvaille", Korean "발견"); translate it consistently too.
Reply with only JSON: an object mapping each id to its translation.

{json.dumps({str(i): s for i, (s, _) in enumerate(items)}, ensure_ascii=False, indent=0)}"""
    for attempt in range(4):
        r = requests.post("https://api.anthropic.com/v1/messages", timeout=300, headers={
            "x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"},
            json={"model": MODEL, "max_tokens": 16000, "messages": [{"role": "user", "content": prompt}]})
        if r.status_code in (429, 500, 502, 503, 529):
            time.sleep(10 * (attempt + 1)); continue
        if not r.ok:
            # Shown in the run's summary; the strings are retried on the next run.
            print(f"::warning::{lang_name}: translation request failed ({r.status_code}): {r.text[:200]}")
            return {}
        text = "".join(b.get("text", "") for b in r.json()["content"] if b.get("type") == "text")
        m = re.search(r"\{.*\}", text, re.S)
        try:
            return json.loads(m.group(0)) if m else {}
        except json.JSONDecodeError as e:
            print(f"::warning::{lang_name}: couldn't read the translations ({e}); retrying next run")
            return {}
    return {}

def main():
    src = extracted()
    if not src:
        sys.exit("::error::No strings found in the export")
    cat = json.load(open(CATALOG)) if os.path.exists(CATALOG) else {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    strings = cat.setdefault("strings", {})
    for key in src:
        strings.setdefault(key, {})
    added = {l: 0 for l in LANGS}
    lock = threading.Lock()

    def one_language(lang, name):
        # Languages run side by side; each one's batches go in order.
        todo = [k for k in src if src[k][0].strip() and lang not in strings[k].get("localizations", {})]
        for i in range(0, len(todo), 100):
            batch = todo[i:i + 100]
            got = ask(name, [src[k] for k in batch])
            with lock:
                for j, k in enumerate(batch):
                    t = got.get(str(j))
                    if not isinstance(t, str) or not t.strip():
                        continue
                    if sorted(PH.findall(t)) != sorted(PH.findall(src[k][0])):
                        print(f"::warning::{lang}: placeholders changed, skipped: {src[k][0][:60]}")
                        continue
                    strings[k].setdefault("localizations", {})[lang] = {"stringUnit": {"state": "translated", "value": t}}
                    added[lang] += 1
                print(f"{lang}: {min(i + 100, len(todo))}/{len(todo)}", flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for f in [pool.submit(one_language, l, n) for l, n in LANGS.items()]:
            f.result()
    cat["strings"] = dict(sorted(strings.items()))
    with open(CATALOG, "w") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"::notice::{len(src)} strings; added " + ", ".join(f"{l} {n}" for l, n in added.items()))

main()
