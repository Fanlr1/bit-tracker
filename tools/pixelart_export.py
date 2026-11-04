#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Export the sprite document to the C header and PNG previews.

    tools/assets.json  ->  work/gfx_demo/src/assets.h
                       ->  work/gfx_demo/assets-preview/preview-{8,16,32}.png

The document format is 16-colour indexed pixel art (see tools/gen_assets.py):
    palette : 16 x "#rrggbb"
    sprites : {id, name, size, pixels}; pixels = size*size chars,
              '.' = transparent, 0-9a-f = palette index

Output pixels are RGB565, row-major, tightly packed, and transparent pixels are
written as the colour key 0xF81F, so each array can be memcpy'd to DDR as-is.

Usage
    python tools/pixelart_export.py
    python tools/pixelart_export.py --json tools/assets.json --no-preview
"""
import argparse
import json
import os
import sys

KEY = 0xF81F
DDR_BASE = 0x08870000
SIZES = (8, 16, 32)
TILE_BYTES = {8: 128, 16: 512, 32: 2048}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_JSON = os.path.join(ROOT, "tools", "assets.json")
DEFAULT_HEADER = os.path.join(ROOT, "work", "gfx_demo", "src", "assets.h")
DEFAULT_PREVIEW_DIR = os.path.join(ROOT, "work", "gfx_demo", "assets-preview")

ID_RE = None


def hex_rgb(h):
    n = int(h[1:], 16)
    return (n >> 16) & 255, (n >> 8) & 255, n & 255


def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def rgb_from_565(v):
    r = (v >> 11) & 0x1F
    g = (v >> 5) & 0x3F
    b = v & 0x1F
    return (r * 255 // 31, g * 255 // 63, b * 255 // 31)


def fail(msg):
    print("[export] ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def load_doc(path):
    if not os.path.exists(path):
        fail("sprite document not found: " + path)
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)

    pal = doc.get("palette")
    if not isinstance(pal, list) or len(pal) != 16:
        fail("palette must be a list of 16 '#rrggbb' colours")
    for c in pal:
        if not isinstance(c, str) or len(c) != 7 or c[0] != "#":
            fail("bad palette colour: %r" % (c,))
        try:
            hex_rgb(c)
        except ValueError:
            fail("bad palette colour: %r" % (c,))

    sprites = doc.get("sprites")
    if not isinstance(sprites, list) or not sprites:
        fail("document has no sprites")

    ids = set()
    for s in sprites:
        sid = s.get("id", "")
        if not isinstance(sid, str) or not _is_ident(sid):
            fail("bad sprite id: %r" % (sid,))
        if sid in ids:
            fail("duplicate sprite id: " + sid)
        ids.add(sid)
        size = s.get("size")
        if size not in SIZES:
            fail("sprite %s: unsupported size %r" % (sid, size))
        pix = s.get("pixels")
        if not isinstance(pix, str) or len(pix) != size * size:
            fail("sprite %s: expected %d pixel chars, got %d"
                 % (sid, size * size, len(pix) if isinstance(pix, str) else -1))
        for ch in pix:
            if ch != "." and ch not in "0123456789abcdef":
                fail("sprite %s: bad pixel char %r" % (sid, ch))
        if "name" not in s:
            s["name"] = sid

    for size in SIZES:
        if not any(s["size"] == size for s in sprites):
            fail("no %dx%d sprites in the document" % (size, size))
    return doc


def _is_ident(s):
    if not s or not (s[0].isalpha() or s[0] == "_"):
        return False
    return all(ch.isalnum() or ch == "_" for ch in s)


def pal565(doc):
    """Palette as RGB565; refuses colours that collide with the colour key."""
    out = []
    for i, h in enumerate(doc["palette"]):
        v = rgb565(*hex_rgb(h))
        if v == KEY:
            fail("palette index %d (%s) collides with colour key 0xF81F" % (i, h))
        out.append(v)
    return out


def groups(doc):
    """[(size, macro_prefix, sprites)] in 8 -> 16 -> 32 order."""
    out = []
    for size in SIZES:
        sprites = [s for s in doc["sprites"] if s["size"] == size]
        out.append((size, "A%d" % size, sprites))
    return out


def sprite_values(sprite, pal):
    return [KEY if ch == "." else pal[int(ch, 16)] for ch in sprite["pixels"]]


def write_header(doc, out_path):
    pal = pal565(doc)
    grp = groups(doc)
    counts = {size: len(ss) for (size, _p, ss) in grp}
    blocks = {size: counts[size] * TILE_BYTES[size] for size in SIZES}
    offs = {}
    acc = 0
    for size in SIZES:
        offs[size] = acc
        acc += blocks[size]
    total = acc

    L = []
    a = L.append
    a("/* assets.h -- sprite sheets for the GFX-1408 survivor-style game demo.")
    a(" *")
    a(" * GENERATED FILE -- produced by tools/pixelart_export.py from")
    a(" * tools/assets.json (edit that document in tools/sprite-editor.html).")
    a(" * Do not edit this header by hand: it will be overwritten.")
    a(" *")
    a(" * Pixel format: RGB565, little-endian uint16_t, row-major, rows tightly")
    a(" * packed (no padding).  Transparent colour key = 0xF81F")
    a(" * (pass ASSET_KEY to gfx_copy_key()/gfx_blit() or write it to G_KEY).")
    a(" *")
    a(" * DDR layout (assets_upload() copies the three arrays in this order):")
    for size in SIZES:
        a(" *   0x%08X + 0x%04X .. + 0x%04X  asset%-2d_data  %d x %dx%-2d  (%d B)"
          % (DDR_BASE, offs[size], offs[size] + blocks[size] - 1, size,
             counts[size], size, size, blocks[size]))
    a(" *   total %d bytes (0x%X)" % (total, total))
    a(" *")
    a(" * palette index -> RGB565 (for reference / effects):")
    for i in range(16):
        a(" *   %2d  %s  -> 0x%04X" % (i, doc["palette"][i], pal[i]))
    a(" *")
    a(" * tile lists (macro value = array subscript)")
    for size, prefix, ss in grp:
        for i, s in enumerate(ss):
            a(" *   %-2d %s  (%dx%d)" % (i, s["id"], size, size))
        a(" *")
    a(" * Example (colour-keyed copy of one tile at even screen coordinates):")
    a(" *   gfx_copy_key(A8_GEM_ADDR,")
    a(" *                FB_A + (y & ~1u) * FB_STRIDE + (x & ~1u) * 2u,")
    a(" *                ASSET8_W, ASSET8_H, ASSET8_STRIDE, FB_STRIDE, ASSET_KEY);")
    a(" */")
    a("#ifndef ASSETS_H")
    a("#define ASSETS_H")
    a("")
    a("#include <stdint.h>")
    a("")
    for size in SIZES:
        a("#define ASSET%d_N        %d" % (size, counts[size]))
    a("")
    for size in SIZES:
        a("#define ASSET%d_W        %d" % (size, size))
        a("#define ASSET%d_H        %d" % (size, size))
    a("")
    a("#define ASSET_KEY       0xF81Fu")
    a("")
    for size in SIZES:
        a("#define ASSET%d_BYTES    (ASSET%d_N * %d)      /* %d */"
          % (size, size, TILE_BYTES[size], blocks[size]))
    a("#define ASSET_TOTAL_BYTES (ASSET8_BYTES + ASSET16_BYTES + ASSET32_BYTES)  /* %d */" % total)
    a("")
    a("#define ASSET_DDR_BASE      0x%08Xu" % DDR_BASE)
    a("#define ASSET8_DDR_BASE     (ASSET_DDR_BASE)")
    a("#define ASSET16_DDR_BASE    (ASSET8_DDR_BASE + ASSET8_BYTES)")
    a("#define ASSET32_DDR_BASE    (ASSET16_DDR_BASE + ASSET16_BYTES)")
    a("")
    a("/* source strides in bytes for gfx_copy_key() (rows are tightly packed) */")
    for size in SIZES:
        a("#define ASSET%d_STRIDE   (ASSET%d_W * 2)" % (size, size))
    a("")
    a("/* index macros (values are the array subscripts) */")
    for size, prefix, ss in grp:
        for i, s in enumerate(ss):
            a("#define %-20s %d" % (s["id"], i))
    a("")
    a("/* absolute DDR address of every tile */")
    for size, prefix, ss in grp:
        for i, s in enumerate(ss):
            a("#define %-20s (ASSET%d_DDR_BASE + 0x%04Xu)"
              % (s["id"] + "_ADDR", size, i * TILE_BYTES[size]))
    a("")
    a("/* generic address helpers, e.g. A8_ADDR(A8_GEM) */")
    for size, prefix, ss in grp:
        a("#define A%d_ADDR(i)       (ASSET%d_DDR_BASE + (uint32_t)(i) * %du)"
          % (size, size, TILE_BYTES[size]))
    a("")

    def emit_array(size, macro_prefix):
        a("static const uint16_t asset%d_data[ASSET%d_N][%d] = {"
          % (size, size, size * size))
        ss = [s for s in doc["sprites"] if s["size"] == size]
        for i, s in enumerate(ss):
            vals = sprite_values(s, pal)
            a("    {   /* %d: %s -- %s */" % (i, s["id"], s["name"]))
            n = size
            for r in range(n):
                chunk = vals[r * n:(r + 1) * n]
                a("        " + ", ".join("0x%04X" % v for v in chunk) + ",")
            a("    },")
        a("};")
        a("")

    for size in SIZES:
        emit_array(size, "A%d" % size)

    a("#endif /* ASSETS_H */")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    return counts, blocks, offs, total


# ---------------------------------------------------------------- previews --
CHK_A = (11, 14, 20)
CHK_B = (19, 24, 33)
PANEL = (16, 18, 26)
FRAME = (84, 94, 118)
C_TITLE = (220, 235, 255)
C_LABEL = (205, 240, 170)
C_SUB = (140, 152, 176)
FONT_PATHS = [
    r"C:\Windows\Fonts\consola.ttf",
    r"C:\Windows\Fonts\Consola.ttf",
    r"C:\Windows\Fonts\arial.ttf",
]


def _font(size):
    from PIL import ImageFont
    for p in FONT_PATHS:
        try:
            if os.path.exists(p):
                return ImageFont.truetype(p, size)
        except Exception:
            pass
    return ImageFont.load_default()


def _sprite_image(s, pal):
    from PIL import Image
    n = s["size"]
    img = Image.new("RGB", (n, n))
    px = img.load()
    for y in range(n):
        for x in range(n):
            ch = s["pixels"][y * n + x]
            if ch == ".":
                px[x, y] = CHK_A if ((x + y) & 1) else CHK_B
            else:
                px[x, y] = rgb_from_565(pal[int(ch, 16)])
    return img


def write_preview(doc, pal, size, sprites, out_dir):
    from PIL import Image, ImageDraw
    scale = 10
    sp = size * scale
    n = len(sprites)
    cols = n if n <= 5 else 5
    cell_w = max(sp + 44, 150)
    pad = 26
    title_h = 62
    label_h = 46
    strip_h = 52
    rows_n = (n + cols - 1) // cols
    W = pad * 2 + cols * cell_w
    H = title_h + rows_n * (sp + label_h) + strip_h
    img = Image.new("RGB", (W, H), PANEL)
    dr = ImageDraw.Draw(img)
    f_title = _font(19)
    f_label = _font(13)
    f_sub = _font(11)
    dr.text((pad, 16),
            "GFX-1408 survivor demo -- %dx%d sprites (x%d, checker = transparent 0xF81F)"
            % (size, size, scale), font=f_title, fill=C_TITLE)
    for i, s in enumerate(sprites):
        r, c = i // cols, i % cols
        x = pad + c * cell_w
        y = title_h + r * (sp + label_h)
        big = _sprite_image(s, pal).resize((sp, sp), Image.NEAREST)
        img.paste(big, (x, y))
        dr.rectangle([x - 1, y - 1, x + sp, y + sp], outline=FRAME)
        dr.text((x, y + sp + 5), "%s  idx %d" % (s["id"], i), font=f_label, fill=C_LABEL)
        dr.text((x, y + sp + 23), s["name"], font=f_sub, fill=C_SUB)
    sy = H - strip_h + 12
    dr.text((pad, sy + 2), "1x actual size:", font=f_sub, fill=C_SUB)
    x = pad + 118
    for s in sprites:
        img.paste(_sprite_image(s, pal), (x, sy))
        dr.rectangle([x - 1, sy - 1, x + size, sy + size], outline=(60, 68, 84))
        x += size + 24
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "preview-%d.png" % size)
    img.save(path)
    return path


def main(argv):
    ap = argparse.ArgumentParser(description="assets.json -> assets.h + preview PNGs")
    ap.add_argument("--json", default=DEFAULT_JSON, help="sprite document (default tools/assets.json)")
    ap.add_argument("--header", default=DEFAULT_HEADER, help="output C header")
    ap.add_argument("--preview-dir", default=DEFAULT_PREVIEW_DIR, help="preview PNG directory")
    ap.add_argument("--no-preview", action="store_true", help="skip PNG previews")
    args = ap.parse_args(argv)

    doc = load_doc(args.json)
    pal = pal565(doc)
    counts, blocks, offs, total = write_header(doc, args.header)

    print("[export] header: %s" % args.header)
    for size in SIZES:
        print("  %5d  %2d sprites x %4d B = %5d B   DDR 0x%08X"
              % (size, counts[size], TILE_BYTES[size], blocks[size], DDR_BASE + offs[size]))
    print("  total %d B (0x%X) at DDR 0x%08X" % (total, total, DDR_BASE))

    if not args.no_preview:
        try:
            for size in SIZES:
                sprites = [s for s in doc["sprites"] if s["size"] == size]
                path = write_preview(doc, pal, size, sprites, args.preview_dir)
                print("[export] preview: %s" % path)
        except ImportError:
            print("[export] WARN: Pillow not available, previews skipped", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
