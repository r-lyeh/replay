#!/usr/bin/env python3
# make_tiles.py - draws plugins/tilemap/tiles.png: 256 x 256, 16 x 16 tiles
# (16 x 16 of them), pixel art made here from noise and patterns, and the
# names (tiles.lua). Ours, CC0 (public domain): see LICENSE-tiles.txt.
#   python3 make_tiles.py   (needs Pillow; writes beside this folder)
import os, random
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..')
T = 16
img = Image.new('RGBA', (256, 256), (0, 0, 0, 0))
names = {}

def hexc(h, a=255):
    h = h.lstrip('#')
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)
def shade(c, k):
    return tuple(max(0, min(255, int(v * k))) for v in c[:3]) + (c[3],)

class Tile:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.p = [[(0, 0, 0, 0)] * T for _ in range(T)]
    def set(self, x, y, c):
        if 0 <= x < T and 0 <= y < T: self.p[y][x] = c
    def fill(self, cols, weights=None):
        for y in range(T):
            for x in range(T): self.p[y][x] = self.r.choices(cols, weights)[0]
    def speckle(self, c, n):
        for _ in range(n): self.set(self.r.randrange(T), self.r.randrange(T), c)
    def blob(self, c, cx, cy, r):
        for y in range(T):
            for x in range(T):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r + self.r.random() * 1.5: self.set(x, y, c)
    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1): self.set(x, y, c)
    def frame(self, c):
        for i in range(T): self.set(i, 0, c); self.set(i, T - 1, c); self.set(0, i, c); self.set(T - 1, i, c)

slot = [0]
def put(name, t, at=None):
    i = slot[0] if at is None else at
    for y in range(T):
        for x in range(T): img.putpixel(((i % 16) * T + x, (i // 16) * T + y), t.p[y][x])
    names[i] = name
    slot[0] = i + 1

def noisy(name, base, spread=0.12, extra=None):
    t = Tile(name)
    c = hexc(base)
    t.fill([shade(c, 1 - spread), c, shade(c, 1 + spread * 0.7)], [3, 5, 2])
    if extra: extra(t)
    put(name, t)
    return t

def bricks(name, brick, mortar, bw=8, bh=4):
    t = Tile(name)
    b, m = hexc(brick), hexc(mortar)
    for y in range(T):
        row = y // bh
        for x in range(T):
            off = (bw // 2) * (row % 2)
            edge = y % bh == bh - 1 or (x + off) % bw == bw - 1
            t.set(x, y, m if edge else t.r.choice([shade(b, 0.9), b, b, shade(b, 1.08)]))
    put(name, t)

def planks(name, wood):
    t = Tile(name)
    w = hexc(wood)
    for y in range(T):
        for x in range(T):
            edge = y % 4 == 3 or (x == (5 if (y // 4) % 2 else 12) and True)
            grain = shade(w, 0.93) if (x * 7 + y // 4 * 3) % 5 == 0 else w
            t.set(x, y, shade(w, 0.7) if edge else t.r.choice([grain, w, shade(w, 1.05)]))
    put(name, t)

# row 0: ground
noisy('grass', '#5fa04a', 0.14, lambda t: t.speckle(hexc('#7cc35c'), 14))
noisy('dirt', '#8a5a36', 0.15, lambda t: t.speckle(hexc('#6b4226'), 10))
noisy('stone', '#7d7d7d', 0.1, lambda t: t.speckle(hexc('#666666'), 18))
def cobble(t):
    for _ in range(9): t.blob(t.r.choice([hexc('#8a8a8a'), hexc('#6e6e6e'), hexc('#999999')]), t.r.randrange(T), t.r.randrange(T), 2.2)
    for _ in range(20): t.set(t.r.randrange(T), t.r.randrange(T), hexc('#4a4a4a'))
noisy('cobblestone', '#777777', 0.1, cobble)
noisy('sand', '#dccf8c', 0.06, lambda t: t.speckle(hexc('#c9b874'), 12))
def gravel(t):
    for _ in range(14): t.blob(t.r.choice([hexc('#8f8680'), hexc('#6d6560'), hexc('#a59d97')]), t.r.randrange(T), t.r.randrange(T), 1.2)
noisy('gravel', '#857c76', 0.12, gravel)
noisy('snow', '#f1f5f8', 0.03, lambda t: t.speckle(hexc('#dbe5ee'), 10))
def ice(t):
    for i in range(0, T, 5):
        for k in range(6): t.set((i + k) % T, (k * 2 + i) % T, hexc('#e6f4ff'))
noisy('ice', '#9cc8ee', 0.05, ice)
def waves(t, light):
    for y in range(2, T, 5):
        for x in range(T):
            if (x + y) % 6 < 3: t.set(x, y + (x // 3) % 2, light)
noisy('water', '#2f6fd0', 0.06, lambda t: waves(t, hexc('#5e95e6')))
noisy('deep water', '#1c4a96', 0.06, lambda t: waves(t, hexc('#2b5fb4')))
def lava(t):
    for _ in range(6): t.blob(hexc('#ffd040'), t.r.randrange(T), t.r.randrange(T), 1.6)
noisy('lava', '#e8541c', 0.12, lava)
noisy('mud', '#5b4532', 0.1, lambda t: t.speckle(hexc('#3f3022'), 16))
noisy('clay', '#a2a6b4', 0.05)
def moss(t):
    for _ in range(8): t.blob(hexc('#4f7f3a'), t.r.randrange(T), t.r.randrange(T), 1.8)
noisy('mossy stone', '#7a7a7a', 0.1, moss)
noisy('bedrock', '#3c3c3c', 0.35, lambda t: t.speckle(hexc('#1c1c1c'), 30))
def path(t):
    for y in range(T):
        for x in (0, 1, 14, 15): t.set(x, y, t.r.choice([hexc('#5fa04a'), hexc('#7cc35c')]))
noisy('path', '#a5875a', 0.08, path)

# row 1: built
planks('planks', '#b08a52')
def logside(t):
    for y in range(T):
        for x in range(T):
            t.set(x, y, shade(hexc('#6b4a2b'), 0.8 if x % 4 == 0 else (1.05 if (x + y // 3) % 7 == 0 else 1)))
t = Tile('log'); logside(t); put('log', t)
t = Tile('log top')
for y in range(T):
    for x in range(T):
        d = ((x - 7.5) ** 2 + (y - 7.5) ** 2) ** 0.5
        t.set(x, y, hexc('#6b4a2b') if d > 7 else shade(hexc('#c09a62'), 0.85 if int(d) % 3 == 0 else 1))
put('log top', t)
t = Tile('leaves')
for y in range(T):
    for x in range(T):
        v = t.r.random()
        t.set(x, y, (0, 0, 0, 0) if v < 0.12 else t.r.choice([hexc('#3d7a2a'), hexc('#4c9334'), hexc('#2f6221')]))
put('leaves', t)
bricks('bricks', '#a3483a', '#c9bfb4')
bricks('stone bricks', '#7c7c7c', '#555555', 8, 8)
t = Tile('floor tiles')
for y in range(T):
    for x in range(T):
        light = ((x // 8) + (y // 8)) % 2 == 0
        t.set(x, y, hexc('#555555') if x % 8 == 7 or y % 8 == 7 else (hexc('#d8d4cc') if light else hexc('#b6b1a8')))
put('floor tiles', t)
t = Tile('glass')
t.frame(hexc('#c8e6f0'))
for k in range(3, 7): t.set(k, 9 - k, hexc('#ffffff', 220)); t.set(k + 5, 12 - k, hexc('#ffffff', 200))
for y in range(1, T - 1):
    for x in range(1, T - 1):
        if t.p[y][x][3] == 0: t.set(x, y, hexc('#bfe3f2', 40))
put('glass', t)
for nm, c in [('wool white', '#ececec'), ('wool red', '#b8322f'), ('wool blue', '#3048a8'), ('wool green', '#4f7d2a'), ('wool yellow', '#e3c13c')]:
    noisy(nm, c, 0.06)
def metal(t):
    t.frame(shade(hexc('#c4c8cc'), 0.75))
    for p in [(2, 2), (13, 2), (2, 13), (13, 13)]: t.set(*p, hexc('#888c90'))
noisy('metal', '#c4c8cc', 0.03, metal)
def gold(t):
    t.frame(hexc('#b8901c'))
    t.speckle(hexc('#fff3a8'), 8)
noisy('gold', '#f0c434', 0.05, gold)
def crystal(t):
    for _ in range(4): t.blob(hexc('#c6f6ff'), t.r.randrange(T), t.r.randrange(T), 1.4)
noisy('crystal', '#4fd0e0', 0.1, crystal)

# row 2: ores, furniture, plants
def ore(c):
    def f(t):
        t.speckle(hexc('#666666'), 18)
        for _ in range(4): t.blob(hexc(c), t.r.randrange(2, T - 2), t.r.randrange(2, T - 2), 1.1)
    return f
for nm, c in [('coal ore', '#202020'), ('iron ore', '#d6a98a'), ('gold ore', '#f2d24a'), ('gem ore', '#45d6c8'), ('copper ore', '#d07a4a'), ('ruby ore', '#d8323c')]:
    noisy(nm, '#7d7d7d', 0.1, ore(c))
t = Tile('bookshelf')
planks_c = hexc('#b08a52')
for y in range(T):
    for x in range(T):
        if y in (0, 7, 8, 15): t.set(x, y, shade(planks_c, 0.8))
        else: t.set(x, y, t.r.choice([hexc('#a33a32'), hexc('#3a5aa3'), hexc('#3f8a3a'), hexc('#d4b23a'), hexc('#6a3a8a')]) if x % 2 == 0 or x % 3 == 0 else shade(planks_c, 0.6))
put('bookshelf', t)
t = Tile('crate')
for y in range(T):
    for x in range(T):
        edge = x in (0, 15) or y in (0, 15) or x == y or x == 15 - y
        t.set(x, y, hexc('#6b4a2b') if edge else t.r.choice([hexc('#b08a52'), hexc('#a07c48')]))
put('crate', t)
t = Tile('barrel')
for y in range(T):
    for x in range(T):
        d = ((x - 7.5) ** 2 + (y - 7.5) ** 2) ** 0.5
        t.set(x, y, (0, 0, 0, 0) if d > 7.6 else (hexc('#555555') if d > 6.4 or abs(d - 3.5) < 0.5 else hexc('#9a7040')))
put('barrel', t)
t = Tile('door')
for y in range(T):
    for x in range(2, 14): t.set(x, y, hexc('#7a5530') if x in (2, 13) or y in (0, 15) else hexc('#a87a48'))
t.set(11, 8, hexc('#e0c050')); t.set(11, 9, hexc('#e0c050'))
put('door', t)
t = Tile('ladder')
for y in range(T):
    t.set(3, y, hexc('#7a5530')); t.set(12, y, hexc('#7a5530'))
    if y % 4 == 1:
        for x in range(3, 13): t.set(x, y, hexc('#a87a48'))
put('ladder', t)
t = Tile('fence')
for y in range(2, T): t.set(3, y, hexc('#a87a48')); t.set(4, y, hexc('#8a6238')); t.set(11, y, hexc('#a87a48')); t.set(12, y, hexc('#8a6238'))
for x in range(T): t.set(x, 5, hexc('#a87a48')); t.set(x, 10, hexc('#a87a48'))
put('fence', t)
def flower(nm, petal):
    t = Tile(nm)
    for y in range(8, T): t.set(7, y, hexc('#3d7a2a'))
    t.set(6, 11, hexc('#4c9334')); t.set(8, 12, hexc('#4c9334'))
    for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (1, -1), (-1, 1)]: t.set(7 + dx, 6 + dy, hexc(petal))
    t.set(7, 6, hexc('#f0d040'))
    put(nm, t)
flower('red flower', '#d8323c')
flower('yellow flower', '#f2d24a')
t = Tile('mushroom')
for y in range(9, 14): t.set(7, y, hexc('#e8e0d0')); t.set(8, y, hexc('#d0c8b8'))
for x in range(4, 12):
    for y in range(5, 9):
        if (x - 7.5) ** 2 / 16 + (y - 8.5) ** 2 / 12 <= 1: t.set(x, y, hexc('#c8322c'))
t.set(6, 6, hexc('#ffffff')); t.set(9, 7, hexc('#ffffff'))
put('mushroom', t)
t = Tile('tall grass')
for k in range(7):
    x = 2 + k * 2
    h = t.r.randrange(5, 12)
    for y in range(T - h, T): t.set(x + (1 if y < T - h + 2 and k % 2 else 0), y, t.r.choice([hexc('#4c9334'), hexc('#5fa04a')]))
put('tall grass', t)

# row 3: more
t = Tile('cactus')
for y in range(T):
    for x in range(3, 13): t.set(x, y, hexc('#2f7a2a') if x in (3, 12) else t.r.choice([hexc('#4c9a34'), hexc('#3f8a2c')]))
    if y % 4 == 1: t.set(3, y, hexc('#e8e0a0')); t.set(12, y + 2 if y + 2 < T else y, hexc('#e8e0a0'))
put('cactus', t)
t = Tile('reeds')
for k in range(4):
    x = 3 + k * 3
    for y in range(t.r.randrange(1, 5), T): t.set(x, y, hexc('#8ac46a') if y % 5 else hexc('#5e9a40'))
put('reeds', t)
t = Tile('torch')
for y in range(6, T): t.set(7, y, hexc('#7a5530')); t.set(8, y, hexc('#6b4a2b'))
t.rect(7, 3, 8, 5, hexc('#ffd040')); t.set(7, 2, hexc('#ff9a30')); t.set(8, 4, hexc('#fff3a8'))
put('torch', t)
t = Tile('rock')
for y in range(T):
    for x in range(T):
        if (x - 7.5) ** 2 / 40 + (y - 10) ** 2 / 22 <= 1: t.set(x, y, t.r.choice([hexc('#8a8a8a'), hexc('#7a7a7a'), hexc('#6a6a6a')]))
put('rock', t)
t = Tile('bush')
for y in range(T):
    for x in range(T):
        if (x - 7.5) ** 2 / 50 + (y - 9.5) ** 2 / 36 <= 1 and t.r.random() > 0.06: t.set(x, y, t.r.choice([hexc('#3d7a2a'), hexc('#4c9334'), hexc('#2f6221')]))
put('bush', t)
t = Tile('sign')
for y in range(9, T): t.set(7, y, hexc('#6b4a2b')); t.set(8, y, hexc('#6b4a2b'))
t.rect(2, 2, 13, 9, hexc('#b08a52'))
for x in range(4, 12, 2): t.set(x, 4, hexc('#3a2a1a')); t.set(x + 1, 6, hexc('#3a2a1a'))
put('sign', t)
t = Tile('window')
t.rect(0, 0, 15, 15, hexc('#7a5530'))
t.rect(2, 2, 13, 13, hexc('#9fd0ee'))
t.rect(7, 2, 8, 13, hexc('#7a5530')); t.rect(2, 7, 13, 8, hexc('#7a5530'))
t.set(4, 4, hexc('#ffffff')); t.set(10, 4, hexc('#ffffff'))
put('window', t)
def roof(nm, c):
    t = Tile(nm)
    for y in range(T):
        for x in range(T):
            t.set(x, y, shade(hexc(c), 0.7) if y % 4 == 3 else (shade(hexc(c), 0.85) if (x + (y // 4) * 2) % 4 == 0 else hexc(c)))
    put(nm, t)
roof('red roof', '#a83a2a')
roof('blue roof', '#2a4a8a')
def thatch(t):
    for x in range(0, T, 2):
        for y in range(T): 
            if (y + x) % 5 == 0: t.set(x, y, hexc('#a88a40'))
noisy('thatch', '#d4b45a', 0.08, thatch)
noisy('hay', '#e2c75a', 0.1, lambda t: [t.set(x, y, hexc('#c4a640')) for y in (4, 11) for x in range(T)])
noisy('carpet', '#8a2a4a', 0.04, lambda t: t.frame(hexc('#e2c75a')))
noisy('coal block', '#1e1e1e', 0.25)
noisy('obsidian', '#1a1028', 0.25, lambda t: t.speckle(hexc('#5a3a8a'), 10))

# from index 64: auto-tiles, 47 a kind ("blob" sets: the 8 neighbours). mask =
# N 1, NE 2, E 4, SE 8, S 16, SW 32, W 64, NW 128 for each neighbour of the
# same kind, a corner counting only when both its sides do; the 47 masks that
# leaves, in ascending order, are the kind's tiles: first + their place.
# plugins/tilemap/map.lua M.autotile does the same sum.
def blob_masks():
    out = set()
    for m in range(256):
        r = m & (1 | 4 | 16 | 64)
        for c, a, b in ((2, 1, 4), (8, 4, 16), (32, 16, 64), (128, 64, 1)):
            if m & c and m & a and m & b: r |= c
        out.add(r)
    return sorted(out)
BLOB = blob_masks()
assert len(BLOB) == 47
AUTO = {}

def edge_dist(m, x, y):
    # how far (px) the pixel is from where the kind ends: an open side, or an
    # open corner between two closed sides (inner corners); 99: nowhere near
    d = 99
    if not m & 1: d = min(d, y)
    if not m & 4: d = min(d, T - 1 - x)
    if not m & 16: d = min(d, T - 1 - y)
    if not m & 64: d = min(d, x)
    for c, a, b, cx, cy in ((2, 1, 4, T - 1, 0), (8, 4, 16, T - 1, T - 1), (32, 16, 64, 0, T - 1), (128, 64, 1, 0, 0)):
        if m & a and m & b and not m & c: d = min(d, max(abs(x - cx), abs(y - cy)))
    return d

def blobset(key, label, first, base_tile, edge):
    for i, m in enumerate(BLOB):
        t = Tile('%s %d' % (key, m))
        for y in range(T):
            for x in range(T): t.p[y][x] = base_tile.p[y][x]
            for x in range(T):
                d = edge_dist(m, x, y)
                if d < 99: edge(t, x, y, d)
        put('%s (auto %d)' % (label, i), t, first + i)
    AUTO[key] = (first, label)

def copy_of(i):
    t = Tile('copy %d' % i)
    for y in range(T):
        for x in range(T): t.p[y][x] = img.getpixel(((i % 16) * T + x, (i // 16) * T + y))
    return t

def shore(t, x, y, d):                              # water: sand where land is, wet sand, a foam line
    sand, wet, foam = hexc('#d9c48a'), hexc('#bfae78'), hexc('#d8eef8')
    if d <= 1: t.set(x, y, t.r.choice([sand, sand, shade(sand, 1.06)]))
    elif d == 2: t.set(x, y, wet)
    elif d == 3: t.set(x, y, foam if (x + y) % 3 else shade(foam, 0.92))

def wall_edge(t, x, y, d):                          # stone wall: a dark outline, a lighter bevel inside it
    if d == 0: t.set(x, y, hexc('#26262c'))
    elif d == 1: t.set(x, y, hexc('#b4b4bc'))
    elif d == 2: t.set(x, y, shade(t.p[y][x], 0.8))

def lava_edge(t, x, y, d):                          # lava: a cooled black crust, a bright rim inside
    if d <= 1: t.set(x, y, t.r.choice([hexc('#2a1c18'), hexc('#3a2620'), hexc('#2a1c18')]))
    elif d == 2: t.set(x, y, hexc('#ffd040'))
    elif d == 3: t.set(x, y, hexc('#ff9020'))

def grass_edge(t, x, y, d):                         # grass: ragged where it meets other ground, dirt between the tufts
    dirt = hexc('#7a5530')
    if d == 0: t.set(x, y, dirt if t.r.random() < 0.7 else hexc('#4a8a3a'))
    elif d == 1: t.set(x, y, hexc('#3f7a33') if t.r.random() < 0.6 else dirt)
    elif d == 2 and t.r.random() < 0.4: t.set(x, y, hexc('#3f7a33'))

first = 64
for key, label, base, fn in (('shore', 'water', 8, shore), ('wall', 'stone wall', 21, wall_edge),
                             ('lava', 'lava', 10, lava_edge), ('grass', 'grass', 0, grass_edge)):
    blobset(key, label, first, copy_of(base), fn)
    first += 47

img.save(os.path.join(OUT, 'tiles.png'))
with open(os.path.join(OUT, 'tiles.lua'), 'w') as f:
    f.write('-- tiles.lua: the names of tiles.png\'s tiles (16 x 16 px, 16 a row; index 0 at the top left)\n')
    f.write('-- made by tools/make_tiles.py: ours, CC0 (LICENSE-tiles.txt)\nreturn {\n  size = 16,\n  names = {\n')
    for i in sorted(names): f.write('    [%d] = "%s",\n' % (i, names[i]))
    f.write('  },\n')
    f.write('  -- auto-tiles: 47 a kind ("blob" sets: first + the place of the mask among the 47, map.lua M.autotile)\n  auto = {\n')
    for k in sorted(AUTO): f.write('    %s = { first = %d, n = 47, name = "%s" },\n' % (k, AUTO[k][0], AUTO[k][1]))
    f.write('  },\n}\n')
print(len(names), 'tiles')
