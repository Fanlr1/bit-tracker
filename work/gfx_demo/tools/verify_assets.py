# verify_assets.py -- integrity gate for work/gfx_demo/src/assets.h
# Checks the contract game.h depends on and reports how much of each sprite is
# actually filled (a blank 64x64 player would break the game silently).
import os, re, sys

WS = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
H = os.path.join(WS, 'work', 'gfx_demo', 'src', 'assets.h')
src = open(H, encoding='utf-8').read()

EXPECT = {
    'ASSET_PAL_N': 16, 'ASSET16_N': 9, 'ASSET32_N': 5, 'ASSET64_N': 2,
}
NAMES = [
    'A16_GEM', 'A16_KNIFE', 'A16_ORB', 'A16_ENEMY_A', 'A16_ENEMY_B',
    'A16_ENEMY_C', 'A16_EBULLET', 'A16_HEART', 'A16_SPARK',
    'A32_ENEMY_A', 'A32_ENEMY_B', 'A32_ENEMY_C', 'A32_ENEMY_BIG',
    'A32_ENEMY_ELITE', 'A64_PLAYER', 'A64_PLAYER_HURT',
]

fail = []
for k, v in EXPECT.items():
    m = re.search(r'#define\s+%s\s+(\d+)u?' % k, src)
    if not m or int(m.group(1)) != v:
        fail.append('%s != %d' % (k, v))
for i, nm in enumerate(NAMES):
    if not re.search(r'#define\s+%s\s+\d+u' % nm, src):
        fail.append('missing #define ' + nm)

m = re.search(r'asset_pal\[\s*16\s*\]\s*=\s*\{([^}]*)\}', src)
pal = [int(v, 16) for v in re.findall(r'0x([0-9A-Fa-f]{4})', m.group(1))]
if len(pal) != 16:
    fail.append('palette len %d' % len(pal))
if pal[0] != 0xF81F:
    fail.append('palette[0] must stay the 0xF81F key')

def grab(name, exp_n, exp_s):
    m = re.search(r'static const uint8_t\s+' + name + r'\s*\[\s*(\d+)\s*\]\s*\[\s*(\d+)\s*\]\s*=\s*\{(.*?)\n\};', src, re.S)
    if not m:
        fail.append('array missing: ' + name)
        return [], 0, 0
    n, s = int(m.group(1)), int(m.group(2))
    if n != exp_n or s != exp_s:
        fail.append('%s dims %dx%d != %dx%d' % (name, n, s, exp_n, exp_s))
    rows = re.findall(r'\{([^{}]*)\}', m.group(3))
    out = []
    for r in rows:
        vals = [int(v, 16) for v in re.findall(r'0x([0-9A-Fa-f]{2})', r)]
        if len(vals) != s:
            fail.append('%s row len %d != %d' % (name, len(vals), s))
        out.append(vals)
    if len(out) != n:
        fail.append('%s rows %d != %d' % (name, len(out), n))
    return out, s, n

groups = [
    ('asset16_idx', 9, 128, 16, 'A16'),
    ('asset32_idx', 5, 512, 32, 'A32'),
    ('asset64_idx', 2, 2048, 64, 'A64'),
]
print('%-18s %6s %8s  %s' % ('sprite', 'size', 'filled', 'share'))
for arrname, n, stride, size, prefix in groups:
    arr, s, nn = grab(arrname, n, stride)
    for i, data in enumerate(arr):
        pix = 0
        for k in range(size * size):
            b = data[k >> 1]
            ix = (b & 0x0F) if (k & 1) else (b >> 4)
            if ix:
                pix += 1
        share = pix * 100.0 / (size * size)
        nm = '%s_%d' % (prefix, i)
        mm = re.search(r'#define\s+(A%s_\w+)\s+%du' % (prefix[1:], i), src)
        if mm:
            nm = mm.group(1)
        print('%-18s %4dx%-3d %8d  %5.1f%%' % (nm, size, size, pix, share))
        if pix == 0:
            fail.append('BLANK sprite ' + nm)
        if size == 64 and share < 25.0:
            fail.append('%s only %.1f%% filled - player art missing?' % (nm, share))
        if size == 16 and share < 8.0:
            fail.append('%s only %.1f%% filled - suspiciously empty' % (nm, share))

print()
if fail:
    print('ASSET-VERIFY FAIL')
    for f in fail:
        print('  ! ' + f)
    sys.exit(1)
print('ASSET-VERIFY OK  (%d sprites, palette %d entries)' % (sum(x[1] for x in groups), len(pal)))
