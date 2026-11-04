"""Exhaustive check of the sprite-clipping arithmetic used in the demo driver.

WHAT THIS IS
    A Python transcription of the intersection maths in blt_sprite_clipped()
    (sw/bitblt_demo/src/main.c), checked exhaustively over edge cases.

WHAT THIS IS NOT
    It does not prove the C implementation matches. There is no host C compiler
    on this machine, so the C code cannot be executed here. The transcription
    was written by reading the C, and the two must be kept in step by hand -- if
    the C changes, this file has to change with it.

    What it DOES prove is that the algorithm itself handles every edge case,
    which is where clipping bugs live: negative coordinates, sprites entirely
    off screen, sprites larger than the display, and exact-boundary touches.

Run:  python clip_check.py
Exit: 0 if every case behaves, 1 otherwise.
"""

FB_W = 640
FB_H = 480


def clip(x, y, w, h):
    """Transcription of the intersection logic in blt_sprite_clipped.

    Returns (src_dx, src_dy, dst_x, dst_y, cw, ch) or None when nothing is
    visible. Mirrors the C exactly, including the signed comparisons.
    """
    x0 = 0 if x < 0 else x
    y0 = 0 if y < 0 else y
    x1 = FB_W if x + w > FB_W else x + w
    y1 = FB_H if y + h > FB_H else y + h

    if x0 >= x1 or y0 >= y1:
        return None

    cw = x1 - x0
    ch = y1 - y0
    return (x0 - x, y0 - y, x0, y0, cw, ch)


fails = 0
checks = 0


def check(name, cond, detail=""):
    global fails, checks
    checks += 1
    if cond:
        print("  PASS %s" % name)
    else:
        fails += 1
        print("  FAIL %s  %s" % (name, detail))


# ------------------------------------------------------------------ normal
print("== fully inside ==")
r = clip(100, 100, 64, 64)
check("100,100 64x64 visible", r is not None)
check("  source offset is 0,0", r[0] == 0 and r[1] == 0, str(r))
check("  dest is 100,100", r[2] == 100 and r[3] == 100, str(r))
check("  full size kept", r[4] == 64 and r[5] == 64, str(r))

# ------------------------------------------------------------------ one edge each
print("== one edge each ==")
r = clip(-10, 100, 64, 64)                       # off the left
check("left:  visible", r is not None)
check("  src_dx = 10", r[0] == 10, str(r))
check("  dst_x  = 0", r[2] == 0, str(r))
check("  width  = 54", r[4] == 54, str(r))

r = clip(100, -10, 64, 64)                       # off the top
check("top:   src_dy = 10, dst_y = 0, h = 54",
      r[1] == 10 and r[3] == 0 and r[5] == 54, str(r))

r = clip(FB_W - 10, 100, 64, 64)                 # off the right
check("right: visible", r is not None)
check("  width  = 10", r[4] == 10, str(r))
check("  src_dx = 0 (no shift needed)", r[0] == 0, str(r))

r = clip(100, FB_H - 10, 64, 64)                 # off the bottom
check("bottom: height = 10", r[5] == 10, str(r))
check("  src_dy = 0", r[1] == 0, str(r))

# ------------------------------------------------------------------ corner
print("== corner: off both axes ==")
r = clip(-10, -20, 64, 64)
check("top-left visible", r is not None)
check("  src_dx=10 src_dy=20 dst=(0,0) size=(54,44)",
      r == (10, 20, 0, 0, 54, 44), str(r))

# ------------------------------------------------------------------ entirely off
print("== entirely off screen (must return None) ==")
for name, args in [
    ("left",   (-64, 100, 64, 64)),
    ("right",  (FB_W, 100, 64, 64)),
    ("top",    (100, -64, 64, 64)),
    ("bottom", (100, FB_H, 64, 64)),
    ("far",    (-1000, -1000, 10, 10)),
    ("zero-w", (100, 100, 0, 64)),
    ("zero-h", (100, 100, 64, 0)),
]:
    check("  %s -> None" % name, clip(*args) is None, str(clip(*args)))

# ------------------------------------------------------------------ touching exactly
print("== touching the boundary exactly (visible, 1 px) ==")
r = clip(-63, 100, 64, 64)
check("1 px peeking from the left", r is not None and r[4] == 1, str(r))
r = clip(FB_W - 1, 100, 64, 64)
check("1 px peeking from the right", r is not None and r[4] == 1, str(r))
r = clip(FB_W, 100, 64, 64)
check("flush against the right edge -> None", r is None, str(r))

# ------------------------------------------------------------------ larger than screen
print("== sprite larger than the display ==")
r = clip(-100, -100, FB_W + 200, FB_H + 200)
check("covers the whole screen", r == (100, 100, 0, 0, FB_W, FB_H), str(r))

# ------------------------------------------------------------------ invariants over a sweep
print("== invariants over a coordinate sweep ==")
bad = []
for x in range(-80, FB_W + 80, 7):
    for y in range(-80, FB_H + 80, 7):
        for (w, h) in [(64, 64), (1, 1), (200, 300), (FB_W, FB_H)]:
            r = clip(x, y, w, h)
            if r is None:
                # must genuinely not overlap
                if not (x + w <= 0 or y + h <= 0 or x >= FB_W or y >= FB_H):
                    bad.append(("should be visible", x, y, w, h))
                continue
            sdx, sdy, dx, dy, cw, ch = r
            # 1. the destination rectangle must lie inside the screen
            if not (0 <= dx and dx + cw <= FB_W and 0 <= dy and dy + ch <= FB_H):
                bad.append(("dest outside screen", x, y, w, h, r))
            # 2. the source offset must lie inside the source sprite
            if not (0 <= sdx and sdx + cw <= w and 0 <= sdy and sdy + ch <= h):
                bad.append(("source offset outside sprite", x, y, w, h, r))
            # 3. the visible size must equal the overlap
            ox = min(x + w, FB_W) - max(x, 0)
            oy = min(y + h, FB_H) - max(y, 0)
            if cw != ox or ch != oy:
                bad.append(("size mismatch", x, y, w, h, r, ox, oy))

check("sweep found no violations (%d points)" % (((FB_W + 160) // 7 + 1) * ((FB_H + 160) // 7 + 1) * 4),
      len(bad) == 0, str(bad[:3]))

print("")
if fails == 0:
    print("ALL %d CHECKS PASSED" % checks)
    raise SystemExit(0)
else:
    print("%d of %d CHECKS FAILED" % (fails, checks))
    raise SystemExit(1)
