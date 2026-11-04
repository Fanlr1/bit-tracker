
# gen_assets_quick.py -- fast placeholder sprite set for the GFX survivor game.
# Draws everything procedurally with PIL, converts to RGB565, writes assets.h
# and a magnified preview PNG.  The HTML sprite editor can replace this later.
import os
from PIL import Image, ImageDraw, ImageFont

WS = r'C:\Users\25437\Desktop\竞赛\嵌入式设计竞赛FPGA设计项目\2D图形加速引擎'
OUT_H = os.path.join(WS, 'work', 'gfx_demo', 'src', 'assets.h')
OUT_P = os.path.join(WS, 'work', 'gfx_demo', 'assets-preview')
os.makedirs(OUT_P, exist_ok=True)

TRANS = (255, 0, 255)      # key colour -> 0xF81F

def rgb565(c):
    r, g, b = c
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

def canvas(w, h):
    im = Image.new('RGB', (w, h), TRANS)
    return im, ImageDraw.Draw(im)

def out(d, xy, fill, outline=None):
    if outline: d.rectangle(xy, fill=fill, outline=outline)
    else: d.rectangle(xy, fill=fill)

# ---------------- 8x8 sprites ----------------
def s_gem():
    im, d = canvas(8, 8)
    d.polygon([(4,0),(7,3),(4,7),(1,3)], fill=(40,255,120))
    d.polygon([(4,1),(6,3),(4,5),(2,3)], fill=(160,255,200))
    return im
def s_knife():
    im, d = canvas(8, 8)
    d.polygon([(4,0),(5,2),(5,6),(4,7),(3,6),(3,2)], fill=(235,240,255))
    d.rectangle([3,5,4,7], fill=(150,120,80))
    return im
def s_orb():
    im, d = canvas(8, 8)
    d.ellipse([0,0,7,7], fill=(30,160,255))
    d.ellipse([1,1,6,6], fill=(120,230,255))
    d.ellipse([2,2,4,4], fill=(240,255,255))
    return im
def s_enemy_a():
    im, d = canvas(8, 8)
    d.ellipse([0,1,7,7], fill=(200,30,60), outline=(90,10,25))
    d.point((2,3), fill=(255,220,120)); d.point((5,3), fill=(255,220,120))
    return im
def s_enemy_b():
    im, d = canvas(8, 8)
    d.polygon([(4,0),(7,3),(6,7),(2,7),(1,3)], fill=(30,200,210), outline=(10,90,100))
    d.point((3,4), fill=(255,255,200)); d.point((5,4), fill=(255,255,200))
    return im
def s_enemy_c():
    im, d = canvas(8, 8)
    d.ellipse([0,0,7,7], fill=(150,60,210), outline=(70,20,110))
    d.ellipse([2,2,5,5], fill=(240,180,255))
    return im
def s_ebullet():
    im, d = canvas(8, 8)
    d.ellipse([1,1,6,6], fill=(255,80,160), outline=(140,20,70))
    d.ellipse([2,2,4,4], fill=(255,220,240))
    return im
def s_heart():
    im, d = canvas(8, 8)
    d.ellipse([0,1,4,4], fill=(255,50,80)); d.ellipse([3,1,7,4], fill=(255,50,80))
    d.polygon([(1,3),(6,3),(4,7),(3,7)], fill=(255,50,80))
    return im
def s_spark():
    im, d = canvas(8, 8)
    d.ellipse([1,1,6,6], fill=(255,240,140))
    d.ellipse([2,2,4,4], fill=(255,255,240))
    return im

# ---------------- 16x16 sprites ----------------
def s_big():
    im, d = canvas(16, 16)
    d.ellipse([0,0,15,15], fill=(170,50,110), outline=(80,15,50))
    d.ellipse([2,2,13,13], fill=(210,80,150))
    d.ellipse([4,5,7,8], fill=(255,230,140)); d.ellipse([8,5,11,8], fill=(255,230,140))
    d.arc([3,8,12,13], 0, 180, fill=(90,15,45))
    return im
def s_elite():
    im, d = canvas(16, 16)
    d.polygon([(8,0),(15,5),(13,13),(8,15),(3,13),(1,5)], fill=(240,160,30), outline=(110,60,5))
    d.polygon([(8,2),(13,6),(11,12),(8,13),(5,12),(3,6)], fill=(255,200,70))
    d.ellipse([5,5,7,7], fill=(255,60,60)); d.ellipse([9,5,11,7], fill=(255,60,60))
    d.rectangle([7,10,9,12], fill=(140,70,10))
    return im
def s_enemy_a16():
    im, d = canvas(16, 16)
    d.ellipse([1,1,14,14], fill=(200,30,60), outline=(90,10,25))
    d.ellipse([4,5,6,8], fill=(255,220,120)); d.ellipse([9,5,11,8], fill=(255,220,120))
    return im

# ---------------- 32x32 player ----------------
def s_player():
    im, d = canvas(32, 32)
    # gun barrel pointing up
    d.rectangle([14,2,17,14], fill=(220,230,255), outline=(90,110,150))
    d.rectangle([15,0,16,3], fill=(255,255,255))
    # torso
    d.ellipse([8,12,23,28], fill=(40,120,180), outline=(10,50,90))
    # head
    d.ellipse([10,7,21,18], fill=(70,200,230), outline=(15,90,110))
    # visor
    d.rectangle([12,11,19,14], fill=(200,255,255))
    d.rectangle([13,12,18,13], fill=(255,255,255))
    # shoulders
    d.ellipse([2,14,9,22], fill=(50,150,210), outline=(10,60,100))
    d.ellipse([22,14,29,22], fill=(50,150,210), outline=(10,60,100))
    # legs
    d.rectangle([11,26,14,31], fill=(30,90,140))
    d.rectangle([17,26,20,31], fill=(30,90,140))
    return im
def s_player_hurt():
    im = s_player()
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            if px[x, y] != TRANS:
                r, g, b = px[x, y]
                px[x, y] = (min(255, r + 90), min(255, g // 3 + 30), min(255, b // 3 + 30))
    return im

A8 = [('A8_GEM', s_gem), ('A8_KNIFE', s_knife), ('A8_ORB', s_orb),
      ('A8_ENEMY_A', s_enemy_a), ('A8_ENEMY_B', s_enemy_b), ('A8_ENEMY_C', s_enemy_c),
      ('A8_EBULLET', s_ebullet), ('A8_HEART', s_heart), ('A8_SPARK', s_spark)]
A16 = [('A16_ENEMY_A', s_enemy_a16), ('A16_ENEMY_BIG', s_big), ('A16_ENEMY_ELITE', s_elite)]
A32 = [('A32_PLAYER', s_player), ('A32_PLAYER_HURT', s_player_hurt)]

def arr(name, sprites, size):
    vals = []
    for nm, fn in sprites:
        im = fn()
        assert im.size == (size, size), (nm, im.size)
        px = im.load()
        for y in range(size):
            for x in range(size):
                vals.append(rgb565(px[x, y]))
    lines = []
    lines.append('static const uint16_t %s[%s_N][%d] = {' % (name, 'ASSET' + str(size if size != 16 else 16), size*size))
    idx = 0
    for nm, fn in sprites:
        row = []
        for k in range(size*size):
            row.append('0x%04X' % vals[idx]); idx += 1
        lines.append('    { ' + ', '.join(row) + ' },   // ' + nm)
    lines.append('};')
    return '\n'.join(lines)

hdr = []
hdr.append('// assets.h -- sprite bitmaps for GFX-1408 SURVIVOR (RGB565, key 0xF81F).')
hdr.append('// Generated by tools/gen_assets_quick.py. Replace via the HTML sprite editor later.')
hdr.append('// Layout: all 8x8 tiles (128 B each), then 16x16 (512 B), then 32x32 (2048 B);')
hdr.append('// every tile is contiguous with stride = w*2 and starts 16 B aligned, which is')
hdr.append('// what the engine compact-source path needs.')
hdr.append('#ifndef ASSETS_H')
hdr.append('#define ASSETS_H')
hdr.append('#include <stdint.h>')
hdr.append('')
hdr.append('#define ASSET8_N  %d' % len(A8))
hdr.append('#define ASSET16_N %d' % len(A16))
hdr.append('#define ASSET32_N %d' % len(A32))
hdr.append('')
for i, (nm, _) in enumerate(A8):  hdr.append('#define %-14s %du' % (nm, i))
for i, (nm, _) in enumerate(A16): hdr.append('#define %-14s %du' % (nm, i))
for i, (nm, _) in enumerate(A32): hdr.append('#define %-14s %du' % (nm, i))
hdr.append('')
hdr.append(arr('asset8_data', A8, 8))
hdr.append('')
hdr.append(arr('asset16_data', A16, 16))
hdr.append('')
hdr.append(arr('asset32_data', A32, 32))
hdr.append('')
hdr.append('#endif // ASSETS_H')
hdr.append('')
open(OUT_H, 'w', encoding='utf-8', newline='\n').write('\n'.join(hdr))
print('wrote', OUT_H)

# ---------------- preview ----------------
SCALE = 12
PAD = 8
groups = [(A8, 8, 'preview-8.png'), (A16, 16, 'preview-16.png'), (A32, 32, 'preview-32.png')]
for grp, sz, fn in groups:
    cols = min(5, len(grp))
    rows = (len(grp) + cols - 1) // cols
    cell = sz * SCALE + PAD * 2
    im = Image.new('RGB', (cols * cell, rows * cell + 20), (18, 22, 34))
    d = ImageDraw.Draw(im)
    for i, (nm, f) in enumerate(grp):
        cx = (i % cols) * cell + PAD
        cy = (i // cols) * cell + PAD
        sp = f().resize((sz * SCALE, sz * SCALE), Image.NEAREST)
        # checkerboard behind so transparency is visible
        for yy in range(0, sz * SCALE, 6):
            for xx in range(0, sz * SCALE, 6):
                if ((xx // 6) + (yy // 6)) & 1:
                    d.rectangle([cx + xx, cy + yy, cx + xx + 5, cy + yy + 5], fill=(45, 50, 65))
        im.paste(sp, (cx, cy), None)
        # draw transparency as checker: paste with mask
        dot = sp.load()
        for yy in range(sz * SCALE):
            for xx in range(sz * SCALE):
                if dot[xx, yy] == TRANS:
                    im.putpixel((cx + xx, cy + yy), (255, 0, 255))
        d.text((cx, cy + sz * SCALE + 2), nm, fill=(230, 230, 230))
    im.save(os.path.join(OUT_P, fn))
    print('wrote', os.path.join(OUT_P, fn))
