"""Cuts a demo recording into a captioned 1080x1920 Reel.

It finds each moment by reading the screen (OCR on frames), not by clock, because the simulator's recording skips
time when the screen is still. Usage: cut.py demo.mp4 prompt.json out.mp4 out.txt
Needs ffmpeg, tesseract, Pillow and the Inter font (fonts-inter)."""
import json, os, re, subprocess, sys, tempfile, glob
from PIL import Image, ImageDraw, ImageFont, ImageFilter

src, prompt_path, out_mp4, out_txt = sys.argv[1:5]
P = json.load(open(prompt_path))
work = tempfile.mkdtemp()
W, H = 1080, 1920
NAVY, BLUE, CYAN, WHITE, MUTED = (7, 14, 25), (43, 60, 245), (56, 211, 232), (242, 246, 251), (168, 184, 206)
VW, VH, VX, VY = 700, 1522, (1080 - 700) // 2, 380
FPS_SCAN = 2

def font(face, size):
    for d in ["/usr/share/fonts/opentype/inter/", "/usr/share/fonts/truetype/inter/"]:
        if os.path.exists(d + face): return ImageFont.truetype(d + face, size)
    return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", size)

# 1. Read the top of the screen twice a second (the whole screen for chat, where the typed ask sits above the keyboard).
subprocess.run(["ffmpeg", "-v", "error", "-i", src, "-vf", f"fps={FPS_SCAN},crop=iw:ih*{1.0 if P.get('mode') == 'chat' else 0.42}:0:0,scale=700:-1,format=gray", f"{work}/f%05d.png"], check=True)
frames = sorted(glob.glob(f"{work}/f*.png"))
from concurrent.futures import ThreadPoolExecutor
def ocr(f):
    # One thread per tesseract: it otherwise spawns a thread per core in every process and crawls on CI.
    r = subprocess.run(["tesseract", f, "-", "--psm", "6"], capture_output=True, text=True, env={**os.environ, "OMP_THREAD_LIMIT": "1"})
    return re.sub(r"\s+", " ", r.stdout.lower())
with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex: texts = list(ex.map(ocr, frames))
T = lambda i: i / FPS_SCAN
duration = T(len(frames))
# What the screen said every 3 seconds, so a cut that misses can be fixed from the log alone.
for i in range(0, len(texts), 3 * FPS_SCAN): print(f"ocr {T(i):6.1f}s  {texts[i][:140]}")

def first(pred, after=0.0, before=1e9):
    for i, t in enumerate(texts):
        if after <= T(i) < before and pred(t): return T(i)
    return None
def last(pred, after=0.0):
    hit = None
    for i, t in enumerate(texts):
        if T(i) >= after and pred(t): hit = T(i)
    return hit
has = lambda *ws: (lambda t: any(w in t for w in ws))

segs = []  # (start, end, speed, line1, line2)
def add(a, length, speed, l1, l2):
    if a is None: return
    a += 0.6  # skip the transition into the screen
    b = min(a + length * speed, duration)
    if b - a > 1: segs.append((a, b, speed, l1, l2))

if P.get("mode") == "longterm":
    # The long-running demo account: weeks of hunting, shown in order.
    today = first(has("good morning", "good afternoon", "good evening"))
    scouts = first(has("your scouts"), after=today or 0)
    inbox = first(has("mark all read", "background and alerts"), after=scouts or 0)
    finds = first(lambda t: "finds" in t and ("sort" in t or "saved" in t), after=inbox or scouts or 0)
    detail = first(lambda t: "match" in t and not any(w in t for w in ("finds", "sort", "saved", "scout hunting", "good m", "good a", "good e")), after=(finds or 0) + 6)
    print("timeline", dict(today=today, scouts=scouts, inbox=inbox, finds=finds, detail=detail, duration=duration))
    if today is None or finds is None: sys.exit("Couldn't find the screens in the recording.")
    days, count = P.get("days"), P.get("finds")
    add(today, 5, 1.2, "Set it up once.", "Your scouts never stop hunting")
    add(scouts, 6.5, 1.4, f"{days} days in," if days else "Weeks later,", "every scout still learning your taste")
    add(inbox, 8, 1.5, "Still texting you", "new finds, restocks, price drops")
    add(finds, 7, 1.5, f"{count:,} finds and counting" if count else "Hundreds of finds", "most you'd never find yourself")
    if detail is None and P.get("detail_at"): detail = float(P["detail_at"]) - 0.6
    # The detail screen often gets only a second or two of the recording: hold it rather than skip it.
    if detail is not None:
        span = float(P.get("detail_len") or max(1.2, min(duration, detail + 0.6 + 7.8) - (detail + 0.6)))
        add(detail, 4.5, min(1.3, span / 4.5), "Every find checked:", "in stock, real price")
    hook = "a team of AI scouts that never stops hunting"
elif P.get("mode") == "friends":
    # A friend's profile (sample data): taste match, shared taste DNA, grails, twin finds, gift radar, Taste Cards.
    profile = first(has("taste dna", "hetty"))
    both = first(has("you both love", "both love"), after=(profile or 0) + 1)
    grails = first(has("grails"), after=(both or profile) + 1)
    gift = first(has("gift radar", "picked for hetty"), after=(grails or both or profile) + 3)
    card = first(has("taste card", "oud collector", "cards swap"), after=(gift or grails or profile) + 1)
    mine = first(has("oud collector"), after=card or 0)
    friends = first(lambda t: "friends" in t and "taste dna" not in t, after=(mine or card or profile or 0) + 2)
    print("timeline", dict(profile=profile, both=both, grails=grails, gift=gift, card=card, mine=mine, friends=friends, duration=duration))
    if profile is None: sys.exit("Couldn't find the friend profile in the recording.")
    add(profile, 3.5, 1, "Add your friends.", "See how your taste lines up")
    add(both, 3, 1.2, "The taste you share", "and where you differ")
    add(grails, 3, 1.2, "Their grails,", "and finds you both love")
    add(gift, 3.5, 1.2, "Birthday coming up?", "Gift ideas that fit their taste")
    add(card, 3, 1, "Swap Taste Cards", "with your crew")
    add(mine, 2.5, 1, "Yours updates", "as your taste changes")
    hook = "the friends feature"
elif P.get("mode") == "chat":
    # Ask a scout for something in plain words; it replies and goes hunting.
    key = (P.get("key") or "under").lower()
    scouts = first(has("your scouts"))
    chat = first(has("tell me what you've", "hey, i'm"), after=scouts or 0)
    typed = first(has(key), after=chat or 0)          # the ask, fully typed
    # The reply pushes the scout's greeting off the top of the chat.
    home = ("fitness", "reminders", "utilities", "contacts")   # the simulator's home screen: the app went away
    reply = first(lambda t: "tell me what you" not in t and "your scouts" not in t and "finds" not in t and "done" in t.replace("bone", "done")
                  and not any(w in t for w in home), after=(typed or 0) + 1)
    finds = first(lambda t: "finds" in t and ("best match" in t or "scouts hunting" in t), after=(reply or chat or 0) + 3)
    print("timeline", dict(scouts=scouts, chat=chat, typed=typed, reply=reply, finds=finds, duration=duration))
    if chat is None or typed is None: sys.exit("Couldn't find the chat in the recording.")
    if reply is None: sys.exit("The scout's reply never showed on screen (the app may have closed): no chat reel from this recording.")
    add(scouts, 2.5, 1.2, "Your scouts work for you.", "Talk to them like a friend")
    add(max(chat, typed - 9), 4, 2.5, "Ask in plain words:", P.get("hook", ""))
    if reply is not None:
        add(reply - 0.6, 3.5, 1, "It answers in seconds", "with real picks")
        add(reply + 4, 3.5, 1.6, "then keeps hunting", "while you get on with your day")
    add(finds, 3, 1, "New finds land", "in your feed")
    hook = "talking to my AI scouts"
elif P.get("mode") == "drops":
    # Never miss a drop: the texts (restocks, price drops, new drops), then a find up close with its price check.
    inbox = first(has("mark all read", "background and alerts"))
    inbox_end = last(has("mark all read", "background and alerts"), after=inbox or 0)
    detail = first(lambda t: "match" in t and not any(w in t for w in ("finds", "sort", "saved", "mark all", "scouts hunting")), after=(inbox_end or 0) + 1)
    print("timeline", dict(inbox=inbox, inbox_end=inbox_end, detail=detail, duration=duration))
    if inbox is None: sys.exit("Couldn't find the texts in the recording.")
    span = max(6, (inbox_end or inbox + 12) - inbox)
    add(inbox, 4, max(1.2, span * 0.4 / 4), "Your scouts text you", "the moment something drops")
    add(inbox + span * 0.45, 4.5, max(1.2, span * 0.5 / 4.5), "Restocks in your size,", "price drops, new releases")
    if detail is not None:
        add(detail, 3.5, 1, "Every find checked:", "in stock, real price")
        add(detail + 4.5, 3.5, 1.2, "and where it's", "cheaper elsewhere")
    hook = "never missing a drop"
else:
    words = [w for w in re.findall(r"[a-z]{5,}", P["prompt"].lower())][:4]
    welcome = first(has("never miss what", "continue with apple"))
    ask = first(has("what are you into"))
    quiz = first(has("quick taste check"), after=ask or 0)
    typing = first(lambda t: sum(w in t for w in words) >= 2, after=ask or 0, before=quiz or 1e9)
    taste = first(has("tap the brands", "the vibe you"), after=ask or 0, before=quiz or 1e9)
    quiz_end = last(has("quick taste check"), after=quiz or 0)
    found = first(has("first finds are in", "finds are in"), after=quiz or 0)
    finds = first(lambda t: "finds" in t and ("sort" in t or "saved" in t or "hunting" in t), after=found or 0)
    detail = first(lambda t: "match" in t and not any(w in t for w in ("finds", "sort", "saved", "scout hunting")), after=finds or 0)
    chat = first(has("ask me to", "tell me what you're into, or"), after=detail or finds or 0)
    print("timeline", dict(welcome=welcome, ask=ask, typing=typing, taste=taste, quiz=quiz, quiz_end=quiz_end, found=found, finds=finds, detail=detail, chat=chat, duration=duration))
    if found is None or finds is None:
        sys.exit("The hunt never showed finds: no reel today.")

    # Open on the payoff (real finds for this ask), then a quick run through how it got there.
    hook = P.get("hook", "")
    add(finds + 1.0, 3, 1, "I asked Baget for", hook)
    if typing is not None:
        end = taste if taste and taste > typing else typing + 10
        add(typing - 1, 3, max(1.6, (end - typing) / 3), "Say it in", "your own words")
    else:
        add(ask, 2.5, 1.5, "Tell it what", "you're into")
    if quiz is not None:
        span = max(4, (quiz_end or quiz + 20) - quiz)
        add(quiz, 3, max(2, span / 3), "A few quick swipes", "teach it your taste")
    add(found, 2.5, 1.5, "Minutes later:", "your scouts are hunting")
    add(finds + 4.0, 4, 1.2, "Real stores, real prices,", "picked for you")
    add(detail, 4.5, 1.3, "Every find checked:", "in stock, real price")
    add(chat, 6, 2, "Ask for more", "and it digs deeper")

def bg():
    b = Image.new("RGB", (W, H), NAVY); g = Image.new("RGB", (W, H), NAVY); d = ImageDraw.Draw(g)
    d.ellipse((-500, -600, 1100, 900), fill=BLUE); d.ellipse((300, 1300, 1600, 2500), fill=(20, 90, 140))
    return Image.blend(b, g.filter(ImageFilter.GaussianBlur(220)), 0.85)
bg().save(f"{work}/bg.png")
m = Image.new("L", (VW, VH), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, VW, VH), 70, fill=255); m.save(f"{work}/mask.png")

def lines_for(d, text, face, size, minsize=50):
    while size > minsize and d.textlength(text, font=font(face, size)) > W - 120: size -= 2
    f = font(face, size)
    if d.textlength(text, font=f) <= W - 120: return [text], f
    ws, out, cur = text.split(), [], ""
    for w in ws:
        if d.textlength((cur + " " + w).strip(), font=f) > W - 120: out.append(cur); cur = w
        else: cur = (cur + " " + w).strip()
    return out + [cur], f

def caption(path, l1, l2):
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    y = 120
    for text, col in [(l1, WHITE), (l2, CYAN)]:
        ls, f = lines_for(d, text, "InterDisplay-ExtraBold.otf", 78)
        for l in ls:
            d.text(((W - d.textlength(l, font=f)) / 2, y), l, font=f, fill=col); y += int(f.size * 1.15)
    im.save(path)

files = []
for i, (a, b, sp, l1, l2) in enumerate(segs):
    cap = f"{work}/c{i}.png"; caption(cap, l1, l2)
    out = f"{work}/s{i}.mp4"; dur = (b - a) / sp
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-loop", "1", "-i", f"{work}/bg.png", "-loop", "1", "-i", f"{work}/mask.png", "-loop", "1", "-i", cap,
        "-filter_complex", f"[0:v]fps=30,trim=start={a:.2f}:end={b:.2f},setpts=(PTS-STARTPTS)/{sp},scale={VW}:{VH},format=rgba[v];[2:v]format=gray[m];[v][m]alphamerge[vr];[1:v][vr]overlay={VX}:{VY}:shortest=1[o1];[o1][3:v]overlay=0:0,format=yuv420p[o]",
        "-map", "[o]", "-t", f"{dur:.2f}", "-r", "30", "-c:v", "libx264", "-preset", "medium", "-crf", "19", "-an", out], check=True)
    files.append(out)

e = bg().convert("RGBA"); d = ImageDraw.Draw(e)
logo = Image.new("RGBA", (300, 300)); ld = ImageDraw.Draw(logo); ld.rounded_rectangle((0, 0, 300, 300), 70, fill=BLUE)
lf = font("InterDisplay-Black.otf", 230); ld.text(((300 - ld.textlength("b", font=lf)) / 2, 0), "b", font=lf, fill=WHITE)
e.alpha_composite(logo, ((W - 300) // 2, 560))
for txt, face, size, col, y in [("Baget", "InterDisplay-ExtraBold.otf", 120, WHITE, 920), ("Your personal shopping curator", "InterDisplay-Bold.otf", 60, CYAN, 1080), ("Free on the App Store", "Inter-Medium.otf", 52, MUTED, 1190)]:
    ls, f = lines_for(d, txt, face, size); d.text(((W - d.textlength(ls[0], font=f)) / 2, y), ls[0], font=f, fill=col)
e.convert("RGB").save(f"{work}/end.png")
subprocess.run(["ffmpeg", "-v", "error", "-y", "-loop", "1", "-i", f"{work}/end.png", "-t", "3", "-r", "30", "-vf", "format=yuv420p", "-c:v", "libx264", "-crf", "19", f"{work}/end.mp4"], check=True)
files.append(f"{work}/end.mp4")
open(f"{work}/list.txt", "w").write("".join(f"file '{f}'\n" for f in files))
subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", f"{work}/list.txt", "-c", "copy", "-movflags", "+faststart", out_mp4], check=True)

tag = re.sub(r"[^a-z]", "", P.get("pill", "shopping").lower())
mode = P.get("mode", "ask")
first_line = {
    "longterm": (f"{P['days']} days ago" if P.get("days") else "A few weeks ago") + " I set up my AI scouts. They're still finding things for me every day 👀",
    "friends": "My friends and I swap Taste Cards now. Baget shows how our taste lines up and what to get them for their birthday 🎁",
    "chat": "I just text my AI scouts what I want, in plain words, and they go find it 👀",
    "drops": "I haven't missed a drop since. My AI scouts text me restocks, price drops and what's coming soon 🔔",
}.get(mode, f"I asked my AI personal shopper for {hook}. Here's what it found 👀")
tags = {"friends": "#friends #gifts", "chat": "#aiassistant", "drops": "#restock #drops"}.get(mode, f"#{tag}")
open(out_txt, "w").write(
    f"{first_line}\n\n"
    f"Baget sends your own AI scouts across the web, checks the price and stock, and tells you when they find something worth it.\n\n"
    f"Free on the App Store (US).\n\n#baget #personalshopper #aishopping {tags} #shoppingfinds #founditonbaget\n")
print("segments", [(round(a, 1), round(b, 1), sp, l1) for a, b, sp, l1, _ in segs])
