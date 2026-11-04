
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_assets_dark.py -- GFX-1408 SURVIVOR sprite generator, dark-cult 4bpp set.

What it replaces
----------------
The previous assets.h was a DawnLike-derived set (CC-BY 4.0) scaled from
16x16/32x32 sources; it had no dark-purple/blood family and the 16x16 mobs
were unreadable mush against this firmware's near-black night-graveyard
background. This generator hand-authors the whole sprite table for the
actual on-screen sizes the firmware uses:

    A64_PLAYER / A64_PLAYER_HURT    64x64  (drawn 1:1 on screen)
    A32_*                           32x32  (elite / big mobs)
    A16_*                           16x16  (mobs, gems, knives, orbs, FX)

and keeps the file contract game.h depends on byte-for-byte:
same array names, same array lengths, same #define names/order,
same 16-entry palette with index 0 = transparent key.

Run
---
    C:\\Users\\25437\\anaconda3\\python.exe work/gfx_demo/tools/gen_assets_dark.py
    C:\\Users\\25437\\anaconda3\\python.exe work/gfx_demo/tools/preview_assets.py   # render check
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

WS = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
OUT_H = os.path.join(WS, 'work', 'gfx_demo', 'src', 'assets.h')
PREV = os.path.join(WS, 'work', 'gfx_demo', 'assets-preview')
BG_PNG = os.path.join(PREV, 'bg-1920.png')

# ---------------------------------------------------------------------------
# Palette: 16 entries, index 0 = transparent key (never displayed).
# Every visible colour is chosen so the 8/8/8 -> 5/6/5 quantisation is exact,
# i.e. the preview renders literally what gfx_copy_key will put on screen.
# The family is the requested one: bone / blood / dark purple / toxic green /
# steel grey, plus one arcane cyan reserved for eyes and magic.
# ---------------------------------------------------------------------------
# nominal sRGB -> exact RGB565 word; the preview derives its 8-bit colours by
# expanding that word the same way the engine does, so what the preview shows is
# literally what asset_pal holds.
NOMINAL = [
    (255,   0, 255),   # 0  key (transparent)
    (  8,   8,  16),   # 1  void black     outline, hood interior
    ( 40,  28,  64),   # 2  purple shadow  robe shadow / bat body
    ( 72,  52, 104),   # 3  purple mid     robe cloth
    (120,  92, 160),   # 4  purple light   robe highlight / cloth edges
    (232, 224, 200),   # 5  bone white     skull, blade, specular
    (152, 140, 112),   # 6  bone shadow    old bone, leather, dark wood
    (136,  20,  32),   # 7  blood dark     dried blood, blood-wood staff
    (232,  48,  56),   # 8  blood bright   fresh blood, eyes, glow rim
    ( 56,  88,  40),   # 9  green shadow   rotting flesh
    (144, 196,  72),   # 10 green bright   poison glow, ghoul skin
    (200, 140,  56),   # 11 amber          wood, gold, ember
    (240, 208,  96),   # 12 gold bright    rune, spark, crown
    ( 88, 100, 120),   # 13 steel          blade, chains, armour
    (168, 180, 200),   # 14 steel light    moonlight rim light
    ( 88, 224, 248),   # 15 arcane cyan    eyes, soul fire, crystal
]


def rgb565(c):
    return ((c[0] >> 3) << 11) | ((c[1] >> 2) << 5) | (c[2] >> 3)


def expand565(v):
    return (((v >> 11) & 0x1F) * 255 // 31,
            ((v >> 5) & 0x3F) * 255 // 63,
            (v & 0x1F) * 255 // 31)


PAL565 = [rgb565(c) for c in NOMINAL]
PAL = [expand565(v) for v in PAL565]
KEY = PAL[0]

# ASCII art alphabet: '.' = transparent, one letter per palette index.
CH = {
    '.': 0, ' ': 0, '0': 0,
    'k': 1, 'p': 2, 'P': 3, 'q': 4,
    'W': 5, 'w': 6,
    'r': 7, 'R': 8,
    'g': 9, 'G': 10,
    'a': 11, 'A': 12,
    's': 13, 'S': 14,
    'c': 15,
}

# ---------------------------------------------------------------------------
# tiny raster helpers (integer only, size independent)
# ---------------------------------------------------------------------------
def blank(w, h, fill=0):
    return [[fill] * w for _ in range(h)]


def put(c, x, y, i):
    if 0 <= y < len(c) and 0 <= x < len(c[0]):
        c[y][x] = i


def get(c, x, y):
    if 0 <= y < len(c) and 0 <= x < len(c[0]):
        return c[y][x]
    return 0


def art(rows, size):
    out = blank(size, size)
    assert len(rows) == size, ('row count', len(rows), size)
    for y, row in enumerate(rows):
        assert len(row) == size, ('row %d width' % y, len(row), row)
        for x, ch in enumerate(row):
            assert ch in CH, ('bad art char', ch, y, x)
            out[y][x] = CH[ch]
    return out


def mirror_half(half):
    """32-wide half -> 64-wide symmetric sprite (right half is the mirror)."""
    h = len(half)
    w = len(half[0])
    out = blank(w * 2, h)
    for y in range(h):
        for x in range(w):
            out[y][x] = half[y][x]
            out[y][w * 2 - 1 - x] = half[y][x]
    return out


def disc(c, cx, cy, rx, ry, i):
    for y in range(len(c)):
        for x in range(len(c[0])):
            dx = (x - cx) / float(rx)
            dy = (y - cy) / float(ry)
            if dx * dx + dy * dy <= 1.0 + 1e-9:
                c[y][x] = i


def ring(c, cx, cy, rx, ry, r0, i):
    """annulus: normalised radius between r0 and 1.0"""
    for y in range(len(c)):
        for x in range(len(c[0])):
            dx = (x - cx) / float(rx)
            dy = (y - cy) / float(ry)
            d = dx * dx + dy * dy
            if r0 * r0 <= d <= 1.0 + 1e-9:
                c[y][x] = i


def poly(c, pts, i):
    """even-odd scanline polygon fill"""
    if not pts:
        return
    ys = [p[1] for p in pts]
    y0, y1 = int(min(ys)), int(max(ys))
    for y in range(y0, y1 + 1):
        xs = []
        n = len(pts)
        for k in range(n):
            ax, ay = pts[k]
            bx, by = pts[(k + 1) % n]
            if ay == by:
                continue
            if (ay <= y < by) or (by <= y < ay):
                xs.append(ax + (bx - ax) * (y - ay) / float(by - ay))
        xs.sort()
        for j in range(0, len(xs) - 1, 2):
            for x in range(int(round(xs[j])), int(round(xs[j + 1])) + 1):
                put(c, x, y, i)


def hline(c, x0, x1, y, i):
    for x in range(min(x0, x1), max(x0, x1) + 1):
        put(c, x, y, i)


def vline(c, x, y0, y1, i):
    for y in range(min(y0, y1), max(y0, y1) + 1):
        put(c, x, y, i)


def line(c, x0, y0, x1, y1, i):
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy
    while True:
        put(c, x0, y0, i)
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def bezier(p0, p1, p2, n=96):
    pts = []
    for i in range(n + 1):
        t = i / float(n)
        u = 1.0 - t
        pts.append((u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
                    u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]))
    return pts


def brush(c, pts, r, col):
    """round brush of radius r along a polyline"""
    for (fx, fy) in pts:
        cx, cy = int(round(fx)), int(round(fy))
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if dx * dx + dy * dy <= r * r + 0.4:
                    put(c, cx + dx, cy + dy, col)


def edge_rim(c, src, dst, dx, dy):
    """recolour every src pixel whose (dx,dy) neighbour is outside the silhouette."""
    h, w = len(c), len(c[0])
    out = [row[:] for row in c]
    for y in range(h):
        for x in range(w):
            if c[y][x] != src:
                continue
            nx, ny = x + dx, y + dy
            if not (0 <= nx < w and 0 <= ny < h) or c[ny][nx] == 0:
                out[y][x] = dst
    for y in range(h):
        c[y][:] = out[y][:]


def replace(c, src, dst, x0=0, y0=0, w=None, h=None):
    w = len(c[0]) if w is None else w
    h = len(c) if h is None else h
    for y in range(y0, min(y0 + h, len(c))):
        for x in range(x0, min(x0 + w, len(c[0]))):
            if c[y][x] == src:
                c[y][x] = dst


def outline(c, i=1, only_empty=True):
    """1px contour around the filled pixel set (4-neighbour)."""
    h, w = len(c), len(c[0])
    src = [row[:] for row in c]
    for y in range(h):
        for x in range(w):
            if (c[y][x] != 0) if only_empty else (c[y][x] == 0):
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and src[ny][nx] != 0:
                    c[y][x] = i
                    break


def upscale2(c):
    h, w = len(c), len(c[0])
    out = blank(w * 2, h * 2)
    for y in range(h):
        for x in range(w):
            v = c[y][x]
            out[y * 2][x * 2] = v
            out[y * 2][x * 2 + 1] = v
            out[y * 2 + 1][x * 2] = v
            out[y * 2 + 1][x * 2 + 1] = v
    return out


def bevel(c, light, dark):
    """Give 2x-upscaled art a lit/shadow edge per source block, so a 32x32
    enlargement of a 16x16 mob reads as the same creature with more depth."""
    h, w = len(c), len(c[0])
    src = [row[:] for row in c]
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            v = src[y][x]
            if v == 0:
                continue
            up = src[y - 1][x] if y > 0 else 0
            lf = src[y][x - 1] if x > 0 else 0
            if up == 0 or lf == 0:
                # silhouette top / left edge: moonlit rim
                c[y][x] = light if src[y][x] != light else src[y][x]
            dn = src[y + 1][x] if y + 1 < h else 0
            rt = src[y][x + 1] if x + 1 < w else 0
            if dn == 0 or rt == 0:
                c[y + 1][x + 1] = dark
    return c


# ---------------------------------------------------------------------------
# 16x16 items / FX (geometric, so they stay crisp at one screen pixel per texel)
# ---------------------------------------------------------------------------
def a16_gem():
    """Soul orb: a bright arcane-cyan sphere with a white-hot core and a dark
    purple rim.  The old cut-crystal silhouette read as mush against the dark
    purple map; a high-contrast orb is instantly recognisable at 1:1."""
    c = blank(16, 16)
    for y in range(16):
        for x in range(16):
            dx, dy = x - 7.5, y - 7.5
            d = (dx * dx + dy * dy) ** 0.5
            if d > 6.9:
                continue
            if d > 5.9:
                v = 3                       # dark purple rim
            elif d > 5.1:
                v = 15                      # bright arcane cyan edge
            elif d > 3.2:
                v = 4                       # mid purple-cyan blend
            elif d > 1.9:
                v = 15                      # bright cyan body
            else:
                v = 5                       # white-hot core
            put(c, x, y, v)
    # specular highlight (upper-left) so the orb reads as a lit sphere
    for x, y in ((5, 4), (6, 4), (5, 5), (4, 5), (6, 3)):
        put(c, x, y, 5)
    # a couple of dark pixels at the lower-right rim to seat it in the scene
    for x, y in ((11, 11), (10, 12)):
        put(c, x, y, 3)
    return c


def a16_orb():
    """Shadow orb: a lit purple sphere with a void heart and cyan rim fire."""
    c = blank(16, 16)
    for y in range(16):
        for x in range(16):
            dx, dy = x - 7.5, y - 7.5
            d = (dx * dx + dy * dy) ** 0.5
            if d > 6.4:
                continue
            n = (dx * 0.72 + dy * 0.92) / 6.4     # light from the upper left
            if d > 5.3:
                v = 15 if (-n) > 0.30 else 2
            elif n < -0.36:
                v = 4
            elif n < 0.24:
                v = 3
            else:
                v = 2
            c[y][x] = v
    disc(c, 7.5, 7.5, 2.7, 2.7, 1)
    for x, y in ((7, 6), (8, 8), (6, 8), (9, 6), (7, 9)):
        put(c, x, y, 15)
    put(c, 7, 7, 5); put(c, 8, 7, 5)
    for x, y in ((11, 2), (3, 12), (12, 10), (4, 1)):
        put(c, x, y, 15)
    return c


def a16_ebullet():
    """Shadow bolt: white-hot arcane core, blood shell, trailing shards."""
    c = blank(16, 16)
    disc(c, 7.5, 7.5, 5.4, 5.4, 7)
    disc(c, 7.5, 7.5, 4.2, 4.2, 8)
    disc(c, 7.5, 7.5, 2.3, 2.3, 1)
    disc(c, 7.5, 7.5, 1.2, 1.2, 15)
    put(c, 7, 7, 5); put(c, 8, 7, 5)
    for x, y in ((2, 12), (3, 13), (1, 11), (12, 3), (13, 2)):
        put(c, x, y, 7)
    return c


def a16_heart():
    """Blood heart: the two lobes are separated so the top notch reads."""
    c = blank(16, 16)
    disc(c, 4.2, 5.4, 3.3, 3.3, 8)
    disc(c, 11.8, 5.4, 3.3, 3.3, 8)
    poly(c, [(1.2, 6.4), (14.8, 6.4), (7.5, 14.6)], 8)
    for y in (5, 6, 7):
        for x in range(5, 11):
            if c[y][x] == 0:
                put(c, x, y, 8)
    for y in range(8, 15):
        for x in range(9, 16):
            if c[y][x] == 8:
                put(c, x, y, 7)
    for x, y in ((3, 3), (4, 3), (3, 4), (10, 4)):
        put(c, x, y, 5)
    return c


def a16_spark():
    """Hit burst / death shards: hot core, radial blood splash, flying shards."""
    c = blank(16, 16)
    disc(c, 7.5, 7.5, 3.4, 3.4, 8)
    disc(c, 7.5, 7.5, 1.8, 1.8, 5)
    for dx, dy, ln in ((1, 0, 5), (-1, 0, 4), (0, 1, 5), (0, -1, 4),
                       (1, 1, 4), (-1, 1, 3), (1, -1, 4), (-1, -1, 3)):
        for k in range(2, ln + 1):
            put(c, int(round(7.5 + dx * k)), int(round(7.5 + dy * k)),
                8 if k < ln else 7)
    for x, y in ((2, 2), (13, 3), (3, 13), (12, 12), (1, 8), (14, 7)):
        put(c, x, y, 7)
    put(c, 2, 3, 8); put(c, 13, 4, 8); put(c, 4, 12, 8)
    return c


def a16_blade():
    """Bone fang: the player's thrown blade.  Curved bone body, gold cutting
    edge along the outside, blood-wood grip at the lower left."""
    c = blank(16, 16)
    spine = bezier((4.0, 10.5), (7.0, 1.0), (15.0, 2.5), 160)
    brush(c, spine, 1, 5)
    edge_rim(c, 5, 6, 0, 1)
    edge_rim(c, 5, 12, 0, -1)
    edge_rim(c, 5, 12, 1, -1)
    brush(c, [(4.0, 10.0), (2.5, 12.5), (1.0, 15.0)], 1, 11)
    edge_rim(c, 11, 7, 1, 0)
    put(c, 3, 11, 12)
    put(c, 15, 2, 8); put(c, 14, 2, 8)
    return c


# ---------------------------------------------------------------------------
# 16x16 mobs.  Silhouette first: the skull is bone white, the bat a wide
# purple M with red eyes, the ghoul hunched toxic green.  At 16x16 a mob has
# to be identifiable from its outline alone.
# ---------------------------------------------------------------------------
A16_ENEMY_A = [
    '................',
    '.....WWWWWW.....',
    '....WWWWWWWW....',
    '...WWWWWWWWWW...',
    '...WkkWWWWkkW...',
    '...WkcWWWWckW...',
    '....WWWkkWWW....',
    '....WkWkWkWk....',
    '.....wWWWWw.....',
    '...WWWWWWWWWW...',
    '..WWkWkWkWkWW...',
    '..WWkWkWkWkWW...',
    '...wWWWWWWWWw...',
    '.....WW..WW.....',
    '.....WW..WW.....',
    '....WWW..WWW....',
]

A16_ENEMY_B = [
    '................',
    '................',
    '................',
    '.....qq..qq.....',
    '.....qqPqqq.....',
    '.P...qqPqqq...P.',
    '.PP..qRPRPq..PP.',
    '.qqq.qqPqqq.qqq.',
    '.qqqq.qWWq.qqqq.',
    '.qqqqqqqqqqqqqq.',
    '.qqqqPqqqqPqqqq.',
    '..qqq.qPPq.qqq..',
    '..q...q..q...q..',
    '................',
    '................',
    '................',
]

A16_ENEMY_C = [
    '................',
    '......GGGG......',
    '.....GGGGGG.....',
    '.....GRGGRG.....',
    '.....GGGGGG.....',
    '......GrWr......',
    '....gGGGGGGg....',
    '..GGgPPPPPPgGG..',
    '..GGGGPPPPGGGG..',
    '..GGgPPPPPPgGG..',
    '...GG.PPPP.GG...',
    '....G.PPPP.G....',
    '......PPPP......',
    '.....GG..GG.....',
    '.....GG..GG.....',
    '....GGG..GGG....',
]

A16_KNIFE = None   # filled procedurally in main()
# ---------------------------------------------------------------------------
# 64x64 player: hooded death-cult necromancer.  The vestment is drawn as a
# 32-wide half and mirrored; the arms and the bone staff are stamped on top
# afterwards so the pose stays asymmetric (left hand casting, right hand on
# the staff) instead of reading like a symmetric chess piece.
# ---------------------------------------------------------------------------
# 32x32 elites.  These are the two 32x32 sprites the game actually draws
# (game.h: A32_ENEMY_BIG / A32_ENEMY_ELITE), so they are hand-built from
# primitives instead of being an upscaled mob.
# ---------------------------------------------------------------------------
LIGHT = {2: 4, 3: 4, 5: 5, 6: 5, 7: 8, 8: 5, 9: 10, 10: 10, 15: 5}
DARK = {4: 3, 5: 6, 8: 7, 10: 9, 15: 4}


def volume(c):
    """Rim-light the upper/left edge and darken the lower/right edge so the
    primitive-built monsters get the same top-left key light as the rest."""
    h, w = len(c), len(c[0])
    src = [row[:] for row in c]
    for y in range(h):
        for x in range(w):
            v = src[y][x]
            if v == 0:
                continue
            up = src[y - 1][x] if y > 0 else 0
            lf = src[y][x - 1] if x > 0 else 0
            dn = src[y + 1][x] if y + 1 < h else 0
            rt = src[y][x + 1] if x + 1 < w else 0
            if (up == 0 or lf == 0) and v in LIGHT:
                c[y][x] = LIGHT[v]
            elif (dn == 0 or rt == 0) and v in DARK:
                c[y][x] = DARK[v]


def a32_flesh_golem():
    """BIG: stitched flesh golem.  Red muscle, bone spikes and claws, one
    bloodshot eye -- the bulk is what must read at a glance."""
    c = blank(32, 32)
    # legs + feet
    brush(c, [(11.0, 31.0), (11.0, 26.0)], 3, 7)
    brush(c, [(21.0, 31.0), (21.0, 26.0)], 3, 7)
    for x in range(6, 13):
        put(c, x, 30, 6)
        put(c, x, 31, 6)
    for x in range(19, 27):
        put(c, x, 30, 6)
        put(c, x, 31, 6)
    # torso
    disc(c, 16.0, 20.0, 9.5, 8.5, 8)
    # arms + shoulders
    disc(c, 5.5, 14.0, 5.0, 5.0, 8)
    disc(c, 26.5, 14.0, 5.0, 5.0, 8)
    brush(c, bezier((4.0, 15.0), (1.0, 21.0), (3.0, 27.0), 60), 2, 8)
    brush(c, bezier((28.0, 15.0), (31.0, 21.0), (29.0, 27.0), 60), 2, 8)
    # head
    disc(c, 16.0, 7.5, 5.6, 5.2, 8)
    # exposed muscle: darker fibre bands down the torso
    for x in (11, 14, 17, 20):
        for y in range(13, 28):
            if c[y][x] == 8 and (y % 3) != 0:
                put(c, x, y, 7)
    # rib slats
    for y in (16, 19, 22):
        for x in range(12, 21):
            if c[y][x] in (7, 8):
                put(c, x, y, 6)
    # bone spikes on the pauldrons
    for x, y in ((2, 10), (3, 9), (4, 8), (5, 9), (28, 8), (29, 9), (30, 10)):
        put(c, x, y, 5)
    for x, y in ((3, 10), (4, 9), (29, 10), (28, 9)):
        put(c, x, y, 6)
    # claws
    for x, y in ((1, 27), (2, 28), (3, 28), (4, 29), (30, 27), (29, 28),
                 (28, 28), (27, 29)):
        put(c, x, y, 5)
    # one big bloodshot eye: bone sclera, black slit, arcane glint
    for x in range(12, 20):
        put(c, x, 5, 1)
        put(c, x, 9, 1)
    for y in range(6, 9):
        put(c, 12, y, 1)
        put(c, 19, y, 1)
    for y in range(6, 9):
        for x in range(13, 19):
            put(c, x, y, 5)
    for y in range(6, 9):
        put(c, 15, y, 1)
        put(c, 16, y, 1)
    put(c, 13, 6, 15)
    put(c, 18, 8, 6)
    # stitched mouth
    for x in range(13, 20):
        put(c, x, 12, 1)
    for x in (14, 16, 18):
        put(c, x, 12, 6)
    volume(c)
    return c


def a32_wraith_king():
    """ELITE: wraith king.  Floating, crowned, hollow cyan eyes; the lower
    body dissolves into wisps so it never reads as a walker."""
    c = blank(32, 32)
    # robe: widening cone that stops short of the ground
    for y in range(14, 28):
        hw = 3 + (y - 14) * 8 // 14
        for x in range(16 - hw, 16 + hw):
            put(c, x, y, 4)
    for x in (11, 15, 20):
        for y in range(18, 28):
            hw = 3 + (y - 14) * 8 // 14
            if 16 - hw <= x < 16 + hw:
                put(c, x, y, 3)
    # wisps below the robe
    for x, y in ((13, 27), (15, 28), (18, 28), (12, 29), (16, 29), (20, 29),
                 (14, 30), (18, 31), (11, 31), (21, 30)):
        put(c, x, y, 3)
    for x, y in ((10, 26), (22, 26), (9, 28), (23, 28), (17, 30), (13, 31)):
        put(c, x, y, 2)
    # shoulders / arms outstretched
    disc(c, 16.0, 16.0, 7.0, 3.2, 3)
    brush(c, bezier((11.0, 16.0), (7.0, 15.0), (3.0, 13.0), 40), 2, 3)
    brush(c, bezier((21.0, 16.0), (25.0, 15.0), (29.0, 13.0), 40), 2, 3)
    # claws
    for x, y in ((0, 11), (1, 12), (1, 14), (2, 15), (0, 16),
                 (31, 11), (30, 12), (30, 14), (29, 15), (31, 16)):
        put(c, x, y, 5)
    for x, y in ((1, 11), (2, 13), (30, 11), (29, 13)):
        put(c, x, y, 6)
    # hood + hollow face
    disc(c, 16.0, 9.0, 6.4, 6.0, 3)
    disc(c, 16.0, 10.0, 4.2, 4.4, 1)
    # glowing eyes
    for x in (13, 14):
        put(c, x, 9, 15)
        put(c, x, 10, 15)
    for x in (17, 18):
        put(c, x, 9, 15)
        put(c, x, 10, 15)
    # crown
    for x in range(11, 22):
        put(c, x, 3, 12)
        put(c, x, 4, 11)
    for x in (11, 14, 17, 20):
        put(c, x, 2, 12)
        put(c, x, 1, 12)
    put(c, 12, 2, 11); put(c, 15, 2, 11); put(c, 18, 2, 11); put(c, 21, 2, 11)
    # arcane collar
    for x in range(11, 22):
        if c[13][x] == 3:
            c[13][x] = 4
    # soul fire inside the robe
    for x, y in ((16, 18), (15, 20), (17, 21), (16, 23), (14, 24), (18, 25)):
        if c[y][x] == 3:
            put(c, x, y, 15)
    # wisp glow
    for x, y in ((10, 28), (22, 28), (8, 27), (24, 27), (6, 16), (26, 16)):
        put(c, x, y, 15)
    volume(c)
    # the void face must stay void after volume()
    disc(c, 16.0, 10.0, 3.4, 3.6, 1)
    for x in (13, 14, 17, 18):
        put(c, x, 9, 15)
        put(c, x, 10, 15)
    return c


# ---------------------------------------------------------------------------
# y -> half width of the silhouette (hood tip -> shoulder -> hem)
PLAYER_SIL = [
    (4, 1), (5, 2), (6, 3), (7, 4), (8, 5), (9, 6), (10, 7), (11, 8),
    (12, 8), (13, 9), (14, 9), (15, 10), (16, 10), (17, 10), (18, 10),
    (19, 10), (20, 10), (21, 10), (22, 10), (23, 10), (24, 10), (25, 10),
    (26, 9), (27, 9), (28, 10), (29, 12), (30, 13), (31, 14), (32, 15),
    (33, 15), (34, 15), (35, 15), (36, 15), (37, 16), (38, 16), (39, 16),
    (40, 16), (41, 17), (42, 17), (43, 17), (44, 17), (45, 17), (46, 18),
    (47, 18), (48, 18), (49, 18), (50, 18), (51, 19), (52, 19), (53, 19),
    (54, 19), (55, 19), (56, 19), (57, 19),
]
# y -> half width of the hood opening (the void the face lives in)
PLAYER_VOID = [
    (16, 2), (17, 4), (18, 5), (19, 6), (20, 6), (21, 6), (22, 6), (23, 6),
    (24, 6), (25, 5), (26, 4), (27, 3), (28, 1),
]
PLAYER_HW = dict(PLAYER_SIL)


def _player_half():
    h = blank(32, 64)

    # ---- cloth: moonlit rim on both shoulders, bright centre seam
    for y, hw in PLAYER_SIL:
        xl = 32 - hw
        for x in range(xl, 32):
            if y >= 52:
                v = 2                       # hem in shadow
            elif 29 <= y <= 34:
                v = 2 if x < 29 else 3      # shoulder mantle reads darker
            elif x == xl:
                v = 3
            elif x == xl + 1:
                v = 4                       # rim light
            elif x == 31:
                v = 4                       # centre seam
            else:
                v = 3
            h[y][x] = v

    # ---- vertical folds
    for fx in (18, 23, 27):
        for y in range(35, 57):
            hw = PLAYER_HW.get(y, 0)
            if hw and fx >= 32 - hw:
                h[y][fx] = 2

    # ---- hood: carve the void, then a dark lining with a lit upper lip
    for y, vw in PLAYER_VOID:
        for x in range(32 - vw, 32):
            h[y][x] = 1
    rim = [row[:] for row in h]
    for y, vw in PLAYER_VOID:
        for x in range(32 - vw, 32):
            if rim[y][x] != 1:
                continue
            for dx, dy in ((0, -1), (-1, 0), (0, 1), (1, 0)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < 32 and 0 <= ny < 64 and rim[ny][nx] != 1:
                    h[ny][nx] = 2
                    break
    for x in range(26, 32):
        if h[15][x] == 2:
            h[15][x] = 4

    # ---- glowing eyes (3x2 embers, white-hot core)
    for x in range(27, 30):
        h[21][x] = 15
    h[22][27] = 15
    h[22][28] = 5
    h[22][29] = 15
    h[20][28] = 4

    # ---- bone skull amulet on the chest
    for x in range(28, 32):
        h[33][x] = 6
    for x in range(27, 32):
        h[34][x] = 5
        h[35][x] = 5
    h[34][28] = 1
    h[35][29] = 1
    for x in range(28, 32):
        h[36][x] = 5
    h[33][31] = 5

    # ---- blood sash + small gold buckle
    for x in range(13, 32):
        h[45][x] = 8
        h[46][x] = 7
    for x in (30, 31):
        h[43][x] = 12
        h[44][x] = 12
        h[45][x] = 12

    # ---- arcane runes stitched into the robe
    for x, y in ((17, 39), (17, 40), (24, 38), (20, 47)):
        h[y][x] = 12
    for x, y in ((19, 38), (17, 47)):
        h[y][x] = 11

    # ---- bony hands hanging at the sides
    for x, y in ((13, 43), (14, 43), (15, 43), (13, 44), (14, 44), (15, 44),
                 (14, 45), (15, 45)):
        h[y][x] = 6
    for x, y in ((14, 43), (14, 44), (15, 45)):
        h[y][x] = 5

    # ---- blood hem line + tattered tips
    for x in range(13, 32):
        h[52][x] = 8
        h[53][x] = 7
    for x in range(13, 32):
        d = 32 - x
        depth = ((d * 5 + 2) % 5) + 1
        for y in range(54, min(64, 54 + depth)):
            h[y][x] = 7 if (y % 2 == 0) else 2
    return h


def a64_player():
    c = mirror_half(_player_half())

    # ---- left arm: sleeve flung out, open bony hand, spell fire in the palm
    brush(c, bezier((17.0, 33.0), (12.0, 37.0), (8.0, 44.0), 90), 2, 3)
    edge_rim(c, 3, 4, -1, -1)
    edge_rim(c, 3, 2, 1, 1)
    for x, y in ((4, 44), (5, 45), (6, 46), (7, 47), (8, 47), (9, 46),
                 (3, 45), (5, 47), (7, 48)):
        c[y][x] = 6
    for x, y in ((4, 45), (5, 46), (6, 47), (8, 46)):
        c[y][x] = 5
    for x, y in ((3, 41), (4, 40), (2, 43), (5, 39), (1, 46), (10, 44),
                 (3, 47), (8, 42), (2, 40)):
        if get(c, x, y) == 0:
            put(c, x, y, 15)
    for x, y in ((4, 42), (2, 46), (9, 44), (3, 38)):
        if get(c, x, y) == 0:
            put(c, x, y, 5)

    # ---- right arm: narrow sleeve down to the hand on the staff
    brush(c, bezier((48.0, 34.0), (52.0, 38.0), (55.0, 44.0), 80), 2, 3)
    edge_rim(c, 3, 4, 1, -1)
    edge_rim(c, 3, 2, -1, 1)

    # ---- bone staff, set outside the robe so the silhouette stays clean
    shaft = bezier((61.0, 63.0), (58.0, 40.0), (56.0, 17.0), 160)
    brush(c, shaft, 2, 1)
    brush(c, shaft, 1, 5)
    edge_rim(c, 5, 6, 1, 1)
    for y in range(42, 48):
        for x in range(53, 64):
            if c[y][x] == 5 and (y % 2 == 0):
                c[y][x] = 7
    for x, y in ((54, 43), (55, 43), (56, 44), (55, 44), (56, 43), (57, 44),
                 (54, 45), (55, 45)):
        c[y][x] = 5 if (x + y) % 2 == 0 else 6

    # ---- staff head: bone claws around a soul crystal (no gap: the claws
    # sit on the top of the shaft and cup the crystal)
    for x, y in ((52, 15), (51, 14), (51, 13), (52, 12),
                 (60, 15), (61, 14), (61, 13), (60, 12)):
        put(c, x, y, 5)
    for x, y in ((51, 13), (61, 13)):
        put(c, x, y, 6)
    crystal = [(6, 2), (7, 4), (8, 6), (9, 8), (10, 8), (11, 8), (12, 6),
               (13, 4), (14, 2)]
    for y, w in crystal:
        xl = 56 - w // 2
        for x in range(xl, xl + w):
            c[y][x] = 15
    for y in (9, 10, 11, 12):
        c[y][56] = 5
    c[8][56] = 4
    c[13][56] = 4
    for x, y in ((53, 8), (59, 8), (53, 13), (59, 13)):
        c[y][x] = 4
    for x, y in ((49, 10), (63, 10), (56, 3), (52, 6), (60, 6), (56, 17),
                 (48, 16), (64 - 1, 16)):
        if get(c, x, y) == 0:
            put(c, x, y, 15)
    for x, y in ((50, 8), (62, 8), (56, 2), (49, 18)):
        if get(c, x, y) == 0:
            put(c, x, y, 4)

    # ---- drifting embers
    for x, y, v in ((38, 1, 15), (41, 0, 12), (63 - 1, 29, 15), (4, 34, 12),
                    (33, 60, 7)):
        if get(c, x, y) == 0:
            put(c, x, y, v)
    return c


# palette remap for the damage blink: cloth turns blood, arcane glow goes
# white-hot, silhouette unchanged so the 50% alpha BLIT stays aligned.
HURT_MAP = {0: 0, 1: 1, 2: 7, 3: 8, 4: 6, 5: 5, 6: 6, 7: 8, 8: 5,
            9: 9, 10: 10, 11: 7, 12: 5, 13: 6, 14: 5, 15: 5}


def a64_player_hurt():
    return [[HURT_MAP[v] for v in row] for row in a64_player()]


def upscale2_detail(src):
    """32x32 version of a 16x16 mob: exact silhouette, plus a lit rim on the
    silhouette edges so the enlargement does not look like flat blocks."""
    c = upscale2(src)
    h, w = len(c), len(c[0])
    # moonlit rim on the outer silhouette (upper-left), shadow on lower-right
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            v = c[y][x]
            if v == 0:
                continue
            up, lf = c[y - 1][x], c[y][x - 1]
            dn, rt = c[y + 1][x], c[y][x + 1]
            if (up == 0 or lf == 0) and v in (2, 3, 7, 9):
                c[y][x] = {2: 4, 3: 4, 7: 8, 9: 10}[v]
            elif (dn == 0 or rt == 0) and v in (4, 5, 8, 10):
                c[y][x] = {4: 3, 5: 6, 8: 7, 10: 9}[v]
    return c


def main():
    a16 = [
        ('A16_GEM', a16_gem()),
        ('A16_KNIFE', a16_blade()),
        ('A16_ORB', a16_orb()),
        ('A16_ENEMY_A', art(A16_ENEMY_A, 16)),
        ('A16_ENEMY_B', art(A16_ENEMY_B, 16)),
        ('A16_ENEMY_C', art(A16_ENEMY_C, 16)),
        ('A16_EBULLET', a16_ebullet()),
        ('A16_HEART', a16_heart()),
        ('A16_SPARK', a16_spark()),
    ]
    a32 = [
        ('A32_ENEMY_A', upscale2_detail(art(A16_ENEMY_A, 16))),
        ('A32_ENEMY_B', upscale2_detail(art(A16_ENEMY_B, 16))),
        ('A32_ENEMY_C', upscale2_detail(art(A16_ENEMY_C, 16))),
        ('A32_ENEMY_BIG', a32_flesh_golem()),
        ('A32_ENEMY_ELITE', a32_wraith_king()),
    ]
    a64 = [
        ('A64_PLAYER', a64_player()),
        ('A64_PLAYER_HURT', a64_player_hurt()),
    ]
    for name, img in a16 + a32 + a64:
        size = 16 if name.startswith('A16') else 32 if name.startswith('A32') else 64
        assert len(img) == size and len(img[0]) == size, (name, len(img), len(img[0]))
        for row in img:
            for v in row:
                assert 0 <= v < 16, (name, v)

    # ------------------------------------------------------------------ emit
    hdr = []
    hdr.append('// assets.h -- GFX-1408 SURVIVOR sprites, 4bpp palette-packed.')
    hdr.append('//')
    hdr.append('// Dark-cult set authored for the sizes the firmware actually draws:')
    hdr.append('// player 64x64, elites 32x32, mobs/items 16x16.  Every colour is one')
    hdr.append('// of the 16 palette entries below, so a sprite is 1/4 the RAM of RGB565')
    hdr.append('// and the uploader expands it straight into DDR at boot.')
    hdr.append('// Layout: 16x16 group (128 B each), then 32x32 (512 B), then 64x64 (2048 B).')
    hdr.append('// Generated by tools/gen_assets_dark.py -- edit the art there, not here.')
    hdr.append('// (Earlier revisions used DawnLike tiles, CC-BY 4.0 credit DawnBringer;')
    hdr.append('//  this set is original art and carries no third-party licence.)')
    hdr.append('')
    hdr.append('#ifndef ASSETS_H')
    hdr.append('#define ASSETS_H')
    hdr.append('#include <stdint.h>')
    hdr.append('')
    hdr.append('// palette index 0 = transparent')
    hdr.append('#define ASSET_PAL_N %d' % len(PAL))
    hdr.append('static const uint16_t asset_pal[%d] = {' % len(PAL))
    hdr.append('    ' + ', '.join('0x%04X' % v for v in PAL565))
    hdr.append('};')
    hdr.append('')
    hdr.append('#define ASSET16_N %d' % len(a16))
    hdr.append('#define ASSET32_N %d' % len(a32))
    hdr.append('#define ASSET64_N %d' % len(a64))
    hdr.append('')
    for i, (nm, _) in enumerate(a16):
        hdr.append('#define %-16s %du' % (nm, i))
    for i, (nm, _) in enumerate(a32):
        hdr.append('#define %-16s %du' % (nm, i))
    for i, (nm, _) in enumerate(a64):
        hdr.append('#define %-16s %du' % (nm, i))
    hdr.append('')

    def pack4(img):
        size = len(img)
        out = []
        for y in range(size):
            for x in range(0, size, 2):
                out.append(((img[y][x] & 15) << 4) | (img[y][x + 1] & 15))
        return out

    def emit(name, group, size):
        lines = ['static const uint8_t %s[%d][%d] = {' % (name, len(group), size * size // 2)]
        for nm, img in group:
            data = pack4(img)
            lines.append('    { ' + ', '.join('0x%02X' % b for b in data) + ' },  // ' + nm)
        lines.append('};')
        return '\n'.join(lines)

    hdr.append(emit('asset16_idx', a16, 16)); hdr.append('')
    hdr.append(emit('asset32_idx', a32, 32)); hdr.append('')
    hdr.append(emit('asset64_idx', a64, 64)); hdr.append('')
    hdr.append('#endif // ASSETS_H')
    txt = '\n'.join(hdr) + '\n'
    open(OUT_H, 'w', encoding='utf-8', newline='\n').write(txt)
    print('wrote', OUT_H, len(txt), 'bytes')

    # --------------------------------------------------------------- preview
    os.makedirs(PREV, exist_ok=True)

    def to_rgb(img, bg=None):
        size = len(img)
        out = Image.new('RGB', (size, size))
        px = out.load()
        for y in range(size):
            for x in range(size):
                v = img[y][x]
                if v == 0:
                    if bg is None:
                        px[x, y] = (24, 24, 30) if ((x // 4 + y // 4) & 1) == 0 else (34, 34, 42)
                    else:
                        px[x, y] = bg
                else:
                    px[x, y] = PAL[v]
        return out

    def font(sz):
        try:
            return ImageFont.truetype('arial.ttf', sz)
        except Exception:
            return ImageFont.load_default()

    def sheet(groups, fname, scale, cols=3, maxsize=16):
        cells = []
        for group in groups:
            for nm, img in group:
                cells.append((nm, to_rgb(img), len(img)))
        rows = (len(cells) + cols - 1) // cols
        cw = maxsize * scale + 18
        ch = maxsize * scale + 34
        out = Image.new('RGB', (cols * cw, rows * ch), (14, 12, 22))
        d = ImageDraw.Draw(out)
        f = font(max(12, scale))
        for j, (nm, im, size) in enumerate(cells):
            big = im.resize((size * scale, size * scale), Image.NEAREST)
            x = (j % cols) * cw + 8
            y = (j // cols) * ch + 6
            out.paste(big, (x, y))
            d.rectangle([x - 1, y - 1, x + size * scale, y + size * scale], outline=(60, 50, 80))
            d.text((x, y + size * scale + 8), '%s %dx%d' % (nm, size, size), fill=(200, 190, 215), font=f)
        out.save(os.path.join(PREV, fname))
        print('wrote', fname, out.size)

    sheet([a16], 'preview-16.png', 14, cols=3, maxsize=16)
    sheet([a32], 'preview-32.png', 7, cols=3, maxsize=32)
    sheet([a64], 'preview-64.png', 4, cols=2, maxsize=64)
    sheet([a16, a32, a64], 'preview-dark-all.png', 4, cols=6, maxsize=64)

    # ------------------------------------------------ in-context mockup frame
    if os.path.exists(BG_PNG):
        import random
        frame = Image.open(BG_PNG).convert('RGB')
        canvas = frame.load()
        layers = {}
        for nm, img in a16 + a32 + a64:
            size = len(img)
            rgbs = [[PAL[v] if v else None for v in row] for row in img]
            layers[nm] = (size, rgbs)

        def blit(nm, x, y):
            size, rgbs = layers[nm]
            for yy in range(size):
                py = y + yy
                if py < 0 or py >= 1080:
                    continue
                row = rgbs[yy]
                for xx in range(size):
                    c = row[xx]
                    if c is None:
                        continue
                    pxx = x + xx
                    if pxx < 0 or pxx >= 1920:
                        continue
                    canvas[pxx, py] = c

        rnd = random.Random(0xC0FFEE)
        mobs = ['A16_ENEMY_A', 'A16_ENEMY_B', 'A16_ENEMY_C']
        for i in range(70):
            x = rnd.randrange(8, 1900)
            y = rnd.randrange(150, 1056)
            dx, dy = x - 928, y - 604
            if dx * dx + dy * dy < 150 * 150:
                continue
            blit(mobs[i % 3], x, y)
        for i in range(12):
            blit('A32_ENEMY_BIG' if i % 2 else 'A32_ENEMY_ELITE',
                 rnd.randrange(8, 1880), rnd.randrange(150, 1040))
        for i in range(14):
            blit('A16_GEM', rnd.randrange(8, 1900), rnd.randrange(150, 1060))
        for i in range(10):
            blit('A16_KNIFE', rnd.randrange(8, 1900), rnd.randrange(150, 1060))
        for i in range(6):
            blit('A16_ORB', rnd.randrange(8, 1900), rnd.randrange(150, 1060))
        blit('A64_PLAYER', 928, 604)
        frame.save(os.path.join(PREV, 'preview-game.png'))
        frame.resize((1280, 720), Image.LANCZOS).save(os.path.join(PREV, 'preview-game-1280.png'))
        print('wrote preview-game.png (1920x1080 mockup frame)')
    print('done')


if __name__ == '__main__':
    main()
