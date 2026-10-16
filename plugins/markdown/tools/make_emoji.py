# make_emoji.py - draws plugins/markdown/emoji/*.png (64 x 64, supersampled 4x): the
# markdown viewer's built-in emoji. python3 make_emoji.py ../emoji ../../../editor/3rd/lite/data/fonts/font_bold.ttf
import sys, math
from PIL import Image, ImageDraw
S = 4; N = 64 * S
def canvas(): im = Image.new("RGBA", (N, N), (0,0,0,0)); return im, ImageDraw.Draw(im)
def save(im, name, out): im.resize((64, 64), Image.LANCZOS).save(f"{out}/{name}.png", optimize=True)
def P(x): return int(x * S)
out = sys.argv[1]

# 🎮 gamepad
im, d = canvas()
body = (112, 118, 134, 255); dark = (48, 50, 60, 255)
d.rounded_rectangle((P(4), P(18), P(60), P(46)), radius=P(13), fill=body)
d.ellipse((P(4), P(28), P(26), P(56)), fill=body); d.ellipse((P(38), P(28), P(60), P(56)), fill=body)
d.rectangle((P(13), P(26), P(19), P(42)), fill=dark); d.rectangle((P(8), P(31), P(24), P(37)), fill=dark)
for (x, y, c) in ((46, 27, (235, 87, 87, 255)), (52, 33, (90, 190, 110, 255)), (40, 33, (80, 150, 235, 255)), (46, 39, (240, 200, 70, 255))):
    d.ellipse((P(x - 3.4), P(y - 3.4), P(x + 3.4), P(y + 3.4)), fill=c)
d.rounded_rectangle((P(27), P(25), P(31), P(28)), radius=P(1), fill=dark); d.rounded_rectangle((P(33), P(25), P(37), P(28)), radius=P(1), fill=dark)
save(im, "gamepad", out)

# ✔️ heavy check mark
im, d = canvas()
d.line([(P(10), P(34)), (P(25), P(49)), (P(54), P(14))], fill=(70, 185, 95, 255), width=P(10), joint="curve")
for (x, y) in ((10, 34), (25, 49), (54, 14)): d.ellipse((P(x - 5), P(y - 5), P(x + 5), P(y + 5)), fill=(70, 185, 95, 255))
save(im, "check", out)

# 🧪 test tube (tilted)
im, d = canvas()
tube = Image.new("RGBA", (N, N), (0,0,0,0)); t = ImageDraw.Draw(tube)
x0, x1, top, bot = 24, 40, 6, 58
t.rounded_rectangle((P(x0), P(top + 4), P(x1), P(bot)), radius=P(8), fill=(215, 230, 240, 200), outline=(150, 170, 190, 255), width=P(2.5))
t.rounded_rectangle((P(x0 + 2.5), P(32), P(x1 - 2.5), P(bot - 2.5)), radius=P(6), fill=(110, 205, 120, 255))
t.rectangle((P(x0 + 2.5), P(32), P(x1 - 2.5), P(36)), fill=(150, 225, 150, 255))
t.rounded_rectangle((P(x0 - 4), P(top), P(x1 + 4), P(top + 6)), radius=P(2), fill=(150, 170, 190, 255))
t.ellipse((P(29), P(40), P(33), P(44)), fill=(200, 245, 200, 255)); t.ellipse((P(33), P(48), P(36), P(51)), fill=(200, 245, 200, 255))
tube = tube.rotate(-35, resample=Image.BICUBIC, center=(N / 2, N / 2))
save(tube, "test", out)

# 💤 zzz
im, d = canvas()
def Z(x, y, s, c):
    w = P(s * 0.22)
    d.line([(P(x), P(y)), (P(x + s), P(y)), (P(x), P(y + s)), (P(x + s), P(y + s))], fill=c, width=w, joint="curve")
Z(6, 30, 26, (90, 160, 240, 255)); Z(34, 14, 18, (110, 175, 245, 255)); Z(50, 4, 11, (130, 190, 250, 255))
save(im, "sleep", out)

# 🔜 soon (an arrow over SOON)
im, d = canvas()
c = (60, 140, 220, 255)
d.line([(P(8), P(20)), (P(50), P(20))], fill=c, width=P(5))
d.polygon([(P(58), P(20)), (P(46), P(11)), (P(46), P(29))], fill=c)
from PIL import ImageFont
f = ImageFont.truetype(sys.argv[2], P(19))
tw = d.textlength("SOON", font=f)
d.text(((N - tw) / 2, P(31)), "SOON", font=f, fill=c)
save(im, "soon", out)

# 💡 light bulb
im, d = canvas()
d.ellipse((P(14), P(4), P(50), P(40)), fill=(255, 214, 70, 255))
d.polygon([(P(20), P(32)), (P(44), P(32)), (P(40), P(44)), (P(24), P(44))], fill=(255, 214, 70, 255))
d.ellipse((P(21), P(10), P(30), P(19)), fill=(255, 245, 190, 255))
for i, y in enumerate((45, 50, 55)):
    d.rounded_rectangle((P(23 + i * 0.6), P(y), P(41 - i * 0.6), P(y + 4)), radius=P(2), fill=(150, 155, 165, 255))
d.ellipse((P(28), P(57), P(36), P(62)), fill=(110, 115, 125, 255))
save(im, "idea", out)
