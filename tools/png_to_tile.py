#!/usr/bin/env python3
# ============================================================================
# png_to_tile.py -- host-side helper for the tiled framebuffer (P3, 2026-11-03)
#
# Tile layout (8x8 RGB565 tiles, band = 8 scan lines, band stride 0x8000):
#   addr(x,y) = FB + (y>>3)*0x8000 + (x>>3)*128 + (y&7)*16 + (x&7)*2
# Raster layout (today): addr(x,y) = FB + y*4096 + x*2
#
# Modes
#   pattern : build a test picture (color bars + tile grid) -> tile + raster blobs
#   make    : PNG -> tile + raster blobs, optional C array for a crop
#   decode  : framebuffer dump (tile or raster) -> PNG (for screenshots)
#   check   : verify tile blob decodes to exactly the raster blob
# ============================================================================
import argparse, os, sys
import numpy as np

W, H = 1920, 1080
RASTER_STRIDE = 4096
BAND_STRIDE   = 0x8000
BANDS         = H // 8
FB_TILE_BYTES = BANDS * BAND_STRIDE
FB_RAST_BYTES = H * RASTER_STRIDE

def rgb_to_565(rgb):
    r = (rgb[..., 0] >> 3).astype(np.uint16)
    g = (rgb[..., 1] >> 2).astype(np.uint16)
    b = (rgb[..., 2] >> 3).astype(np.uint16)
    return (r << 11) | (g << 5) | b

def px565_to_rgb(p):
    r = ((p >> 11) & 0x1F) << 3
    g = ((p >> 5) & 0x3F) << 2
    b = (p & 0x1F) << 3
    return np.stack([r, g, b], axis=-1).astype(np.uint8)

def raster_blob(img565):
    buf = np.zeros((H, RASTER_STRIDE // 2), dtype=np.uint16)
    buf[:, :W] = img565
    return buf.tobytes()

def raster_from_blob(blob):
    words = np.frombuffer(blob, dtype=np.uint16).reshape(H, RASTER_STRIDE // 2)
    return words[:, :W]

def tile_blob(img565):
    buf = np.zeros((BANDS, BAND_STRIDE), dtype=np.uint8)
    for band in range(BANDS):
        rows = img565[band*8:(band+1)*8].reshape(8, W // 8, 8)
        t = rows.transpose(1, 0, 2).reshape((W // 8) * 8, 8)
        b = np.empty((t.shape[0], 8, 2), dtype=np.uint8)
        b[..., 0] = t & 0xFF
        b[..., 1] = (t >> 8) & 0xFF
        buf[band, :(W // 8) * 8 * 16] = b.reshape(-1)
    return buf.tobytes()

def tile_to_raster(blob):
    b = np.frombuffer(blob, dtype=np.uint8).reshape(BANDS, BAND_STRIDE)
    out = np.zeros((H, W), dtype=np.uint16)
    for band in range(BANDS):
        d = b[band, :(W // 8) * 8 * 16].reshape(W // 8, 8, 8, 2)
        v = d[..., 0].astype(np.uint16) | (d[..., 1].astype(np.uint16) << 8)
        out[band*8:(band+1)*8] = v.transpose(1, 0, 2).reshape(8, W)
    return out

def pattern_image():
    img = np.zeros((H, W, 3), dtype=np.uint8)
    bars = [(255,0,0),(0,255,0),(0,0,255),(255,255,0),(0,255,255),(255,0,255),(255,255,255),(128,128,128)]
    for i, c in enumerate(bars):
        img[:, i*W//len(bars):(i+1)*W//len(bars)] = c
    for y in range(0, H, 8):
        img[y, :, :] = 255 - img[y, :, :]
    for x in range(0, W, 8):
        img[:, x, :] = 255 - img[:, x, :]
    img[0:8, 0:8] = (255,255,255)
    img[0:8, W-8:W] = (255,0,0)
    img[H-8:H, 0:8] = (0,255,0)
    img[H-8:H, W-8:W] = (0,0,255)
    return img

def load_png(path):
    from PIL import Image
    im = Image.open(path).convert("RGB").resize((W, H), Image.NEAREST)
    return np.asarray(im, dtype=np.uint8)

def write_c_array(path, name, img565, x0, y0, w, h):
    nl = chr(10)
    with open(path, "w") as f:
        f.write("/* tile-layout block %dx%d at (%d,%d), RGB565, 32-bit words */%s" % (w, h, x0, y0, nl))
        f.write("#define %s_W %d%s#define %s_H %d%s" % (name.upper(), w, nl, name.upper(), h, nl))
        nwords = (w // 8) * (h // 8) * 8 * 4
        f.write("static const unsigned int %s[%d] = {%s" % (name, nwords, nl))
        for ty in range(0, h, 8):
            for tx in range(0, w, 8):
                for row in range(8):
                    px = img565[y0+ty+row, x0+tx:x0+tx+8]
                    for j in range(4):
                        v = int(px[2*j]) | (int(px[2*j+1]) << 16)
                        f.write("0x%08xu," % v)
                    f.write(nl)
        f.write("};" + nl)

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    pat = sub.add_parser("pattern"); pat.add_argument("--out-dir", default="work/tileimg")
    mk = sub.add_parser("make")
    mk.add_argument("--in", dest="inp", required=True)
    mk.add_argument("--out-dir", default="work/tileimg")
    mk.add_argument("--crop", default="")
    mk.add_argument("--c-array", default="")
    dec = sub.add_parser("decode")
    dec.add_argument("--in", dest="inp", required=True)
    dec.add_argument("--mode", choices=["tile", "raster"], required=True)
    dec.add_argument("--out", required=True)
    chk = sub.add_parser("check"); chk.add_argument("--dir", default="work/tileimg")
    a = ap.parse_args()

    if a.cmd == "pattern":
        img = pattern_image(); os.makedirs(a.out_dir, exist_ok=True)
        img565 = rgb_to_565(img)
        open(os.path.join(a.out_dir, "fb_tile.bin"), "wb").write(tile_blob(img565))
        open(os.path.join(a.out_dir, "fb_raster.bin"), "wb").write(raster_blob(img565))
        from PIL import Image
        Image.fromarray(img).save(os.path.join(a.out_dir, "expected.png"))
        print("pattern: %s/fb_tile.bin (%d B) fb_raster.bin (%d B) expected.png" %
              (a.out_dir, FB_TILE_BYTES, FB_RAST_BYTES))
        return 0
    if a.cmd == "make":
        img = load_png(a.inp); img565 = rgb_to_565(img); os.makedirs(a.out_dir, exist_ok=True)
        open(os.path.join(a.out_dir, "fb_tile.bin"), "wb").write(tile_blob(img565))
        open(os.path.join(a.out_dir, "fb_raster.bin"), "wb").write(raster_blob(img565))
        print("make: %s/fb_tile.bin + fb_raster.bin" % a.out_dir)
        if a.crop:
            x0, y0, w, h = [int(v) for v in a.crop.split(",")]
            name = a.c_array or "tile_img"
            out = (a.c_array + ".h") if a.c_array else os.path.join(a.out_dir, "tile_img.h")
            write_c_array(out, name, img565, x0, y0, w, h)
            print("C array: %s (%dx%d at %d,%d)" % (out, w, h, x0, y0))
        return 0
    if a.cmd == "decode":
        blob = open(a.inp, "rb").read()
        img565 = tile_to_raster(blob) if a.mode == "tile" else raster_from_blob(blob)
        from PIL import Image
        Image.fromarray(px565_to_rgb(img565)).save(a.out)
        print("decode: %s -> %s (%s)" % (a.inp, a.out, a.mode))
        return 0
    if a.cmd == "check":
        t = open(os.path.join(a.dir, "fb_tile.bin"), "rb").read()
        r = open(os.path.join(a.dir, "fb_raster.bin"), "rb").read()
        bad = int(np.count_nonzero(tile_to_raster(t) != raster_from_blob(r)))
        print("check: tile->raster vs raster: %d differing pixels of %d" % (bad, W*H))
        return 0 if bad == 0 else 1
    return 1

if __name__ == "__main__":
    sys.exit(main())
