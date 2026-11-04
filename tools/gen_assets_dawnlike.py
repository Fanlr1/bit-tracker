
# gen_assets_dawnlike.py -- build assets.h from DawnLike (CC-BY 4.0, credit DawnBringer)
# plus a few hand-drawn 8x8 icons in the same palette.
import os
from PIL import Image, ImageDraw

WS = r'C:\Users\25437\Desktop\竞赛\嵌入式设计竞赛FPGA设计项目\2D图形加速引擎'
T = os.path.join(WS, 'work', 'ref', 'tiles')
OUT_H = os.path.join(WS, 'work', 'gfx_demo', 'src', 'assets.h')
PREV = os.path.join(WS, 'work', 'gfx_demo', 'assets-preview')
os.makedirs(PREV, exist_ok=True)
TRANS = (255, 0, 255)

def rgb565(c):
    r, g, b = c
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

def load16(name):
    im = Image.open(os.path.join(T, name.replace(' ', '_') + '.png')).convert('RGBA')
    return im.resize((16, 16), Image.NEAREST)

def to_sprite(im, size):
    """RGBA -> RGB565 list; alpha < 128 becomes the key colour."""
    out = []
    for y in range(size):
        for x in range(size):
            p = im.getpixel((x, y))
            out.append(0xF81F if p[3] < 128 else rgb565((p[0], p[1], p[2])))
    return out

# ---------------- 8x8 hand-drawn icons (DawnLike palette family) ----------------
def c8():
    im = Image.new('RGBA', (8, 8), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)

def a8_gem():
    im, d = c8()
    d.polygon([(4,0),(7,3),(4,7),(1,3)], fill=(90, 200, 255, 255))
    d.polygon([(4,1),(6,3),(4,4),(2,3)], fill=(180, 240, 255, 255))
    d.point((4,2), fill=(255,255,255,255))
    return im
def a8_knife():
    im, d = c8()
    d.polygon([(4,0),(5,2),(5,6),(4,7),(3,6),(3,2)], fill=(210, 215, 230, 255))
    d.line([(4,1),(4,5)], fill=(255,255,255,255))
    d.rectangle([3,5,4,7], fill=(120, 80, 40, 255))
    return im
def a8_orb():
    im, d = c8()
    d.ellipse([1,1,6,6], fill=(70, 140, 255, 255))
    d.ellipse([2,2,5,5], fill=(150, 220, 255, 255))
    d.point((3,3), fill=(255,255,255,255))
    return im
def a8_ebullet():
    im, d = c8()
    d.ellipse([1,1,6,6], fill=(220, 60, 100, 255))
    d.ellipse([2,2,5,5], fill=(255, 170, 200, 255))
    return im
def a8_heart():
    im, d = c8()
    d.polygon([(3,1),(4,2),(5,1),(7,3),(4,7),(1,3)], fill=(230, 40, 70, 255))
    d.point((3,2), fill=(255, 220, 220, 255))
    return im
def a8_spark():
    im, d = c8()
    d.rectangle([3,0,4,7], fill=(255, 230, 120, 255))
    d.rectangle([0,3,7,4], fill=(255, 230, 120, 255))
    d.rectangle([2,2,5,5], fill=(255, 255, 220, 255))
    return im
def a8_enemy_a():
    im = load16('blue slime_0').resize((8,8), Image.NEAREST); return im
def a8_enemy_b():
    im = load16('spark bug_0').resize((8,8), Image.NEAREST); return im
def a8_enemy_c():
    im = load16('goblin_0').resize((8,8), Image.NEAREST); return im
def a16_enemy_a(): return load16('baby bat_0')
def a16_enemy_b(): return load16('ghost_0')
def a16_enemy_c(): return load16('goblin_0')
def a16_enemy_big(): return load16('ogre_0')
def a16_enemy_elite(): return load16('minotaur_0')

def a32_player():
    im = Image.new('RGBA', (32, 32), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    # cloak
    d.polygon([(16, 6), (25, 14), (23, 29), (9, 29), (7, 14)], fill=(38, 52, 96, 255))
    d.polygon([(16, 6), (21, 14), (19, 28), (13, 28), (11, 14)], fill=(52, 70, 124, 255))
    # hood
    d.polygon([(16, 3), (24, 12), (8, 12)], fill=(64, 88, 150, 255))
    d.polygon([(16, 5), (21, 12), (11, 12)], fill=(84, 112, 180, 255))
    # face
    d.ellipse([13, 9, 19, 16], fill=(236, 198, 158, 255))
    d.point((15, 12), fill=(24, 26, 40, 255))
    d.point((18, 12), fill=(24, 26, 40, 255))
    d.line([(15, 14), (18, 14)], fill=(150, 90, 80, 255))
    # belt
    d.rectangle([12, 22, 20, 24], fill=(96, 70, 40, 255))
    d.rectangle([15, 22, 17, 24], fill=(220, 190, 90, 255))
    # feet
    d.rectangle([11, 28, 14, 31], fill=(50, 40, 34, 255))
    d.rectangle([18, 28, 21, 31], fill=(50, 40, 34, 255))
    # staff with a glowing crystal
    d.line([(25, 9), (27, 28)], fill=(120, 88, 52, 255), width=2)
    d.ellipse([23, 3, 30, 10], fill=(96, 216, 255, 255))
    d.ellipse([25, 5, 28, 8], fill=(210, 244, 255, 255))
    return im
def a32_player_hurt():
    im = a32_player().copy()
    px = im.load()
    for y in range(32):
        for x in range(32):
            p = px[x, y]
            if p[3] >= 128:
                px[x, y] = (min(255, p[0] + 90), max(0, p[1] // 2), max(0, p[2] // 2), 255)
    return im

A8 = [('A8_GEM', a8_gem), ('A8_KNIFE', a8_knife), ('A8_ORB', a8_orb),
      ('A8_ENEMY_A', a8_enemy_a), ('A8_ENEMY_B', a8_enemy_b), ('A8_ENEMY_C', a8_enemy_c),
      ('A8_EBULLET', a8_ebullet), ('A8_HEART', a8_heart), ('A8_SPARK', a8_spark)]
A16 = [('A16_ENEMY_A', a16_enemy_a), ('A16_ENEMY_B', a16_enemy_b), ('A16_ENEMY_C', a16_enemy_c),
       ('A16_ENEMY_BIG', a16_enemy_big), ('A16_ENEMY_ELITE', a16_enemy_elite)]
A32 = [('A32_PLAYER', a32_player), ('A32_PLAYER_HURT', a32_player_hurt)]
def emit(name, sprites, size):
    lines = ['static const uint16_t %s[%d][%d] = {' % (name, len(sprites), size*size)]
    for nm, fn in sprites:
        vals = to_sprite(fn(), size)
        lines.append('    { ' + ', '.join('0x%04X' % v for v in vals) + ' },  // ' + nm)
    lines.append('};')
    return '\n'.join(lines)

hdr = []
hdr.append('// assets.h -- GFX-1408 SURVIVOR sprites (RGB565, transparent key 0xF81F).')
hdr.append('//')
hdr.append('// Monsters/player are DawnLike tiles by DragonDePlatino and DawnBringer,')
hdr.append('// licensed CC-BY 4.0 (https://opengameart.org/content/dawnlike-16x16-universal-rogue-like-tileset-v181).')
hdr.append('// Credit: DawnBringer. 8x8 icons are hand-drawn in the same palette.')
hdr.append('// Generated by tools/gen_assets_dawnlike.py -- re-run it to regenerate.')
hdr.append('//')
hdr.append('// Layout: all 8x8 (128 B each), then 16x16 (512 B), then 32x32 (2048 B),')
hdr.append('// every tile contiguous with stride = w*2 and 16 B aligned.')
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
hdr.append(emit('asset8_data', A8, 8)); hdr.append('')
hdr.append(emit('asset16_data', A16, 16)); hdr.append('')
hdr.append(emit('asset32_data', A32, 32)); hdr.append('')
hdr.append('#endif // ASSETS_H')
hdr.append('')
open(OUT_H, 'w', encoding='utf-8', newline='\n').write('\n'.join(hdr))
print('wrote', OUT_H)

# ---------------- previews ----------------
for grp, sz, fn in [(A8, 8, 'preview-8.png'), (A16, 16, 'preview-16.png'), (A32, 32, 'preview-32.png')]:
    SC = 10 if sz <= 16 else 6
    cols = min(6, len(grp))
    rows = (len(grp)+cols-1)//cols
    cw = sz*SC+10; chh = sz*SC+22
    im = Image.new('RGB', (cols*cw, rows*chh+4), (24,27,38))
    d = ImageDraw.Draw(im)
    for i,(nm,fn2) in enumerate(grp):
        ox=(i%cols)*cw+5; oy=(i//cols)*chh+5
        for yy in range(0,sz*SC,10):
            for xx in range(0,sz*SC,10):
                if ((xx//10)+(yy//10))&1: d.rectangle([ox+xx,oy+yy,ox+xx+9,oy+yy+9], fill=(40,44,58))
        s = fn2().convert('RGBA').resize((sz*SC, sz*SC), Image.NEAREST)
        px = s.load()
        for y in range(sz*SC):
            for x in range(sz*SC):
                p = px[x,y]
                if p[3] >= 128: im.putpixel((ox+x, oy+y), (p[0],p[1],p[2]))
        d.text((ox, oy+sz*SC+4), nm, fill=(230,230,230))
    im.save(os.path.join(PREV, fn))
    print('wrote', fn, im.size)
