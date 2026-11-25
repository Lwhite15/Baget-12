from PIL import Image, ImageDraw, ImageFont, ImageFilter
import sys, os
W, H = 1320, 2868
D = "/home/claude/panels"
F = "/usr/share/fonts/opentype/inter/"
head = ImageFont.truetype(F + "InterDisplay-ExtraBold.otf", 118)
sub = ImageFont.truetype(F + "Inter-Medium.otf", 50)
NAVY, BLUE, CYAN, WHITE, MUTED = (7, 14, 25), (43, 60, 245), (56, 211, 232), (242, 246, 251), (168, 184, 206)

panels = [
    ("1-today",  ["Your personal", "shopping curator"], 1, "AI scouts hunt the web for what you love"),
    ("2-finds",  ["Finds what you", "didn't know you'd love"], 1, "Real stores, real prices, checked in stock"),
    ("3-swipe",  ["Swipe to teach", "your taste"], 1, "Every like and pass makes your scouts sharper"),
    ("4-texts",  ["Texts you when it", "finds something"], 1, "Only the finds worth your time"),
    ("5-squad",  ["Your own team", "of AI scouts"], 1, "Fragrance, sneakers, watches, home, anything"),
]

def background(seed):
    bg = Image.new("RGB", (W, H), NAVY)
    glow = Image.new("RGB", (W, H), NAVY)
    g = ImageDraw.Draw(glow)
    cx = [0.2, 0.8, 0.3, 0.75, 0.5][seed] * W
    g.ellipse((cx - 900, -700, cx + 900, 1300), fill=BLUE)
    g.ellipse((W - cx - 700, H - 900, W - cx + 700, H + 700), fill=(20, 90, 140))
    glow = glow.filter(ImageFilter.GaussianBlur(260))
    return Image.blend(bg, glow, 0.85)

def rounded(im, r):
    m = Image.new("L", im.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, im.size[0], im.size[1]), r, fill=255)
    out = Image.new("RGBA", im.size); out.paste(im, (0, 0), m); return out

def make(i, name, lines, accent, tagline):
    bg = background(i).convert("RGBA")
    d = ImageDraw.Draw(bg)
    y = 190
    size = 118
    while max(d.textlength(l, font=ImageFont.truetype(F + "InterDisplay-ExtraBold.otf", size)) for l in lines) > W - 180: size -= 2
    hf = ImageFont.truetype(F + "InterDisplay-ExtraBold.otf", size)
    for k, line in enumerate(lines):
        tw = d.textlength(line, font=hf)
        d.text(((W - tw) / 2, y), line, font=hf, fill=CYAN if k == accent else WHITE)
        y += int(size * 1.17)
    ss = 50
    while d.textlength(tagline, font=ImageFont.truetype(F + "Inter-Medium.otf", ss)) > W - 200: ss -= 1
    sf = ImageFont.truetype(F + "Inter-Medium.otf", ss)
    tw = d.textlength(tagline, font=sf)
    d.text(((W - tw) / 2, y + 26), tagline, font=sf, fill=MUTED)
    # Phone: the real screen, framed, bleeding off the bottom.
    shot = Image.open(f"{D}/shots/store/{name}.png").convert("RGB")
    pw = int(W * 0.80)
    ph = int(shot.size[1] * pw / shot.size[0])
    shot = shot.resize((pw, ph), Image.LANCZOS)
    bez = 22
    r = int(pw * 0.13)
    frame = Image.new("RGB", (pw + 2 * bez, ph + 2 * bez), (24, 30, 44))
    frame = rounded(frame, r + bez)
    screen = rounded(shot, r)
    frame.alpha_composite(screen, (bez, bez))
    ImageDraw.Draw(frame).rounded_rectangle((1, 1, frame.size[0] - 2, frame.size[1] - 2), r + bez, outline=(70, 82, 110), width=3)
    top = y + 150
    x = (W - frame.size[0]) // 2
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x + 10, top + 40, x + frame.size[0] - 10, top + frame.size[1]), r, fill=(0, 0, 0, 170))
    shadow = shadow.filter(ImageFilter.GaussianBlur(50))
    bg.alpha_composite(shadow)
    bg.alpha_composite(frame, (x, top))
    os.makedirs(f"{D}/out", exist_ok=True)
    bg.convert("RGB").save(f"{D}/out/{name}.png")

for i, p in enumerate(panels): make(i, *p)
ims = [Image.open(f"{D}/out/{p[0]}.png").resize((440, 956)) for p in panels]
sheet = Image.new("RGB", (440 * 5 + 80, 956), (0, 0, 0))
for i, im in enumerate(ims): sheet.paste(im, (i * 460, 0))
sheet.save(f"{D}/out/all-panels.png")
