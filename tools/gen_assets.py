#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Seed tools/assets.json with the initial pixel-art sprite set and embed the
same document into tools/sprite-editor.html as its DEFAULT_DOC.

Pipeline
    python tools/gen_assets.py          # (re)write tools/assets.json + seed the editor
    python tools/pixelart_export.py     # assets.json -> assets.h + preview PNGs

After this seeding step the editor is the canonical authoring tool: open
tools/sprite-editor.html, edit, press "download assets.json", overwrite
tools/assets.json, then run tools/pixelart_export.py again.

The JSON format is 16-colour indexed pixel art:
    palette : 16 x "#rrggbb" strings
    sprites : {id, name, size, pixels}
    pixels  : size*size chars, '.' = transparent, 0-9a-f = palette index
Rows are row-major and tightly packed.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
JSON_PATH = os.path.join(HERE, "assets.json")
HTML_PATH = os.path.join(HERE, "sprite-editor.html")

# 16-colour controlled palette (neon / laser-lab flavoured, all RGB565-safe)
PALETTE = [
    "#14101f",  # 0  outline (deep purple-black)
    "#2b2440",  # 1  dark shade
    "#5b5478",  # 2  mid grey-purple (steel dark)
    "#9b95b8",  # 3  light grey-purple (steel light)
    "#ffffff",  # 4  white
    "#aef4ff",  # 5  light cyan
    "#3cc8f0",  # 6  cyan
    "#5affc8",  # 7  mint
    "#b9ffe4",  # 8  light mint
    "#ffdf4a",  # 9  gold / yellow
    "#ff9a20",  # 10 orange
    "#ff5aa0",  # 11 pink
    "#ffc0e0",  # 12 light pink
    "#e32c40",  # 13 red
    "#8a6bd0",  # 14 purple
    "#c9a6ff",  # 15 light purple
]

CHAR2IDX = {
    "O": 0, "q": 0, "e": 0, "K": 0,   # outlines
    "s": 2, "S": 3,                   # steel
    "W": 4,                           # white
    "C": 6, "L": 5,                   # cyan / light cyan
    "M": 7, "g": 8,                   # mint / light mint
    "Y": 9, "y": 9, "X": 9,           # gold
    "o": 10,                          # orange
    "D": 11, "d": 12,                 # purple-red body / highlight
    "p": 11, "P": 12,                 # pink bullet
    "R": 13, "U": 12,                 # red / light pink highlight
    "V": 14, "v": 15,                 # purple / light purple
}

PLAYER_HURT_MAP = {
    "O": 0, "W": 4, "S": 12, "s": 13, "C": 13, "L": 12, "Y": 9,
}


def mirror(rows):
    """Mirror even-width rows about their vertical axis (left half -> full)."""
    out = []
    for r in rows:
        out.append(r + r[::-1])
    return out


def outline(rows, ch="q"):
    """Add a 1-pixel outline around the opaque silhouette (4-neighbour)."""
    h = len(rows)
    w = len(rows[0])
    src = [list(r) for r in rows]
    out = [r[:] for r in src]
    for y in range(h):
        for x in range(w):
            if src[y][x] == ".":
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if nx < 0 or ny < 0 or nx >= w or ny >= h or src[ny][nx] == ".":
                    out[y][x] = ch
                    break
    return ["".join(r) for r in out]


# ---------------------------------------------------------------- 8x8 art --
GEM = [
    "........",
    "...MM...",
    "..MggM..",
    ".MgWWgM.",
    ".MgWWgM.",
    "..MggM..",
    "...MM...",
    "........",
]
KNIFE = [
    "........",
    "...WW...",
    "..WWWW..",
    "..WWWW..",
    "..SWWS..",
    ".SSSSSS.",
    "...ss...",
    "...ss...",
]
ORB = [
    "........",
    "..CCCC..",
    ".CLLLLC.",
    ".CLWWLC.",
    ".CLWWLC.",
    ".CLLLLC.",
    "..CCCC..",
    "........",
]
ENEMY_A8_LEFT = [
    "..e.",
    "..e.",
    ".eUU",
    "eURR",
    "eRWR",
    "eRRe",
    ".eRR",
    "..ee",
]
ENEMY_B8 = [
    "........",
    "..C..C..",
    "...CC...",
    ".CCCCCC.",
    "CCLWWLCC",
    "CCLWWLCC",
    ".CCCCCC.",
    "...CC...",
]
ENEMY_C8_LEFT = [
    "....",
    ".qqq",
    "qVVV",
    "qWWv",
    "qVVv",
    "qVvq",
    ".qqq",
    "....",
]
EBULLET = [
    "........",
    "..pppp..",
    ".pPPPPp.",
    ".pPWWPp.",
    ".pPWWPp.",
    ".pPPPPp.",
    "..pppp..",
    "........",
]
HEART_LEFT = [
    "....",
    ".RR.",
    "RUUR",
    "RURR",
    "RRRR",
    ".RRR",
    "..RR",
    "...R",
]
SPARK = [
    "........",
    "...YY...",
    "...yW...",
    "YYyWWyYY",
    "YYyWWyYY",
    "...yW...",
    "...YY...",
    "........",
]

# --------------------------------------------------------------- 16x16 art --
ENEMY_A16_LEFT = [
    "....e...",
    "....ee..",
    "....eRR.",
    "....eRR.",
    "....eUUR",
    "...eURRR",
    "..eURRRR",
    ".eRRRRRR",
    ".eRRWWRR",
    ".eRRWWRR",
    ".eRRRRRR",
    ".eRRRRRR",
    "..eRRReW",
    "...eRRRR",
    "....eRRR",
    ".....eRR",
]
ENEMY_B16 = [
    "................",
    ".......CC.......",
    "......CCCC......",
    "..CC..CCCC..CC..",
    "..CCC.CCCC.CCC..",
    "...CCCCCCCCCC...",
    "..CCCWWCCWWCCC..",
    ".CCCCWqCCqWCCCC.",
    ".CCCCCCCCCCCCCC.",
    "..CCCCCCCCCCCC..",
    "...CCCCCCCCCC...",
    "..CCC.CCCC.CCC..",
    "..CC..CCCC..CC..",
    "......CCCC......",
    ".......CC.......",
    "................",
]
ENEMY_C16_LEFT = [
    "........",
    ".....qqq",
    "....qVVV",
    "...qvvVV",
    "..qvvVVV",
    ".qvvVVVV",
    ".qVVWWVV",
    ".qVVWqVV",
    ".qVVVVVV",
    ".qVVVVVV",
    ".qVVVVqq",
    ".qVVVVVV",
    "..qVVVVV",
    "...qVVVV",
    "....qVVV",
    ".....qqq",
]
BIG_LEFT = [
    "........",
    "......qq",
    ".....qDD",
    "....qdDD",
    "...qddDD",
    "..qddDDD",
    ".qDDDDDD",
    ".qDDWWDD",
    ".qDDWqDD",
    ".qDDDDDD",
    ".qDDDDqq",
    "..qDDDDD",
    "...qDDDD",
    "....qDDD",
    ".....qDD",
    "......qq",
]
ELITE_LEFT = [
    "....Y..Y",
    "....YY.Y",
    "...YYYYY",
    "...KKKKK",
    "..KYoooo",
    ".KYooooo",
    ".KXooooo",
    ".KoWWooo",
    ".KoWRooo",
    ".Koooooo",
    "..Kooooo",
    "..Kooooo",
    "...Koooo",
    "....Kooo",
    ".....Koo",
    "......KK",
]

# --------------------------------------------------------------- 32x32 art --
PLAYER32_LEFT = [
    "...............W",
    "..............sW",
    "..............sW",
    "..............sW",
    "..............sW",
    "..............sW",
    "..............sW",
    ".............ssW",
    "...........OYYYY",
    "...............s",
    "...............s",
    "............OCCY",
    "...........OLCCC",
    "..........OCCWWW",
    "..........OCCWWW",
    "..........OCCCCC",
    "..........OCCCCC",
    "..........OCCCCC",
    "..........OCCCCC",
    "..........OOOOOO",
    "......OLLCOCCCCC",
    "......OLLCOCCCCC",
    "......OLLCOCCCCC",
    ".......OLCCCCCCC",
    "........OLCCCCCC",
    ".........OCCCCCC",
    ".........OCCCCCC",
    "..........OCCCCC",
    "..........OCCCCC",
    "..........OCCCYY",
    "...........OCCC.",
    "...........OCCC.",
]

SPRITES = [
    # --- 8x8 ---
    ("A8_GEM", "经验宝石", GEM, None),
    ("A8_KNIFE", "飞刀", KNIFE, None),
    ("A8_ORB", "环绕光球", ORB, None),
    ("A8_ENEMY_A", "红色小怪", mirror(ENEMY_A8_LEFT), None),
    ("A8_ENEMY_B", "青色尖刺怪", ENEMY_B8, None),
    ("A8_ENEMY_C", "紫色圆怪", mirror(ENEMY_C8_LEFT), None),
    ("A8_EBULLET", "敌方子弹", EBULLET, None),
    ("A8_HEART", "回血爱心", mirror(HEART_LEFT), None),
    ("A8_SPARK", "火花粒子", SPARK, None),
    # --- 16x16 ---
    ("A16_ENEMY_A", "红色恶魔", mirror(ENEMY_A16_LEFT), None),
    ("A16_ENEMY_B", "青色尖刺怪", outline(ENEMY_B16, "q"), None),
    ("A16_ENEMY_C", "紫色圆怪", mirror(ENEMY_C16_LEFT), None),
    ("A16_ENEMY_BIG", "紫红胖子", mirror(BIG_LEFT), None),
    ("A16_ENEMY_ELITE", "金冠精英", mirror(ELITE_LEFT), None),
    # --- 32x32 ---
    ("A32_PLAYER", "玩家（俯视·持武）", mirror(PLAYER32_LEFT), None),
    ("A32_PLAYER_HURT", "玩家受击帧", mirror(PLAYER32_LEFT), PLAYER_HURT_MAP),
]


def to_sprite(sid, name, rows, mapping):
    mapping = mapping or CHAR2IDX
    h = len(rows)
    w = len(rows[0])
    if w != h:
        raise SystemExit("sprite %s is not square (%dx%d)" % (sid, w, h))
    if w not in (8, 16, 32):
        raise SystemExit("sprite %s has unsupported size %d" % (sid, w))
    pix = []
    for r in rows:
        if len(r) != w:
            raise SystemExit("sprite %s row %r is %d wide, expected %d" % (sid, r, len(r), w))
        for ch in r:
            if ch == ".":
                pix.append(".")
            else:
                if ch not in mapping:
                    raise SystemExit("sprite %s uses unmapped char %r" % (sid, ch))
                pix.append("%x" % mapping[ch])
    return {"id": sid, "name": name, "size": w, "pixels": "".join(pix)}


def main():
    sprites = [to_sprite(sid, name, rows, mp) for (sid, name, rows, mp) in SPRITES]

    ids = set()
    for s in sprites:
        if s["id"] in ids:
            raise SystemExit("duplicate sprite id %s" % s["id"])
        ids.add(s["id"])

    doc = {
        "version": 1,
        "title": "GFX-1408 survivor demo sprites",
        "key": "0xF81F",
        "palette": PALETTE,
        "sprites": sprites,
    }

    with open(JSON_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")

    # embed the document in the editor so it works from file:// without fetch
    with open(HTML_PATH, encoding="utf-8") as f:
        html = f.read()
    pattern = re.compile(r"const DEFAULT_DOC = /\*__DEFAULT_DOC__\*/.*?/\*__END_DEFAULT_DOC__\*/", re.S)
    if not pattern.search(html):
        raise SystemExit("editor placeholder not found in %s" % HTML_PATH)
    inline = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
    html = pattern.sub(lambda m: "const DEFAULT_DOC = /*__DEFAULT_DOC__*/" + inline +
                       "; /*__END_DEFAULT_DOC__*/", html, count=1)
    with open(HTML_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(html)

    counts = {}
    for s in sprites:
        counts[s["size"]] = counts.get(s["size"], 0) + 1
    print("wrote %s (%d sprites: %s)" % (JSON_PATH, len(sprites),
          ", ".join("%dx%d x%d" % (k, k, counts[k]) for k in sorted(counts))))
    print("seeded %s (%d bytes, DEFAULT_DOC inlined)" % (HTML_PATH, os.path.getsize(HTML_PATH)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
