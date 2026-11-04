
# preview_assets.py -- parse work/gfx_demo/src/assets.h and render what the
# engine will actually put on screen (16-colour RGB565 palette, 4bpp indices).
# Also prints the palette so the art can be designed against real colours.
import os, re, sys
from PIL import Image, ImageDraw

WS   = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
H    = os.path.join(WS, 'work', 'gfx_demo', 'src', 'assets.h')
PREV = os.path.join(WS, 'work', 'gfx_demo', 'assets-preview')
os.makedirs(PREV, exist_ok=True)

src = open(H, encoding='utf-8').read()

def grab_array(name):
    m = re.search(r'static const uint8_t\s+' + name + r'\s*\[\s*(\d+)\s*\]\s*\[\s*(\d+)\s*\]\s*=\s*\{(.*?)\n\};', src, re.S)
    if not m:
        raise SystemExit('array not found: ' + name)
    n, stride = int(m.group(1)), int(m.group(2))
    rows = re.findall(r'\{([^{}]*)\}', m.group(3))
    out = []
    for r in rows:
        vals = [int(v, 16) for v in re.findall(r'0x([0-9A-Fa-f]{2})', r)]
        assert len(vals) == stride, (name, len(vals), stride)
        out.append(vals)
    assert len(out) == n, (name, len(out), n)
    return out

def grab_pal():
    m = re.search(r'asset_pal\[\s*(\d+)\s*\]\s*=\s*\{([^}]*)\}', src)
    n = int(m.group(1))
    vals = [int(v, 16) for v in re.findall(r'0x([0-9A-Fa-f]{4})', m.group(2))]
    assert len(vals) == n, (len(vals), n)
    return vals

def rgb565(c):
    r = (c >> 11) & 0x1F; g = (c >> 5) & 0x3F; b = c & 0x1F
    return (r * 255 // 31, g * 255 // 63, b * 255 // 31)

PAL = grab_pal()
print('palette (%d):' % len(PAL))
for i, c in enumerate(PAL):
    print('  [%2d] 0x%04X  rgb%s%s' % (i, c, rgb565(c), '  <- transparent' if i == 0 else ''))

def names(prefix, n):
    out = []
    for i in range(n):
        m = re.search(r'#define\s+(' + prefix + r'\w*)\s+%du' % i, src)
        out.append(m.group(1) if m else '%s%d' % (prefix, i))
    return out

def decode(data, size):
    """4bpp packed -> PIL RGB image, index 0 drawn as checkerboard (transparent)."""
    im = Image.new('RGB', (size, size))
    px = im.load()
    for k in range(size * size):
        b = data[k >> 1]
        ix = (b & 0x0F) if (k & 1) else (b >> 4)
        x, y = k % size, k // size
        if ix == 0:
            px[x, y] = (24, 24, 30) if ((x // 4 + y // 4) & 1) == 0 else (34, 34, 42)
        else:
            px[x, y] = rgb565(PAL[ix])
    return im

def sheet(groups, fname, scale=4):
    cells = []
    for arrname, size, n, prefix in groups:
        arr = grab_array(arrname)
        nm = names(prefix, n)
        for i in range(n):
            cells.append((nm[i], decode(arr[i], size), size))
    cols = 6
    rows = (len(cells) + cols - 1) // cols
    cw = 64 * scale + 16
    ch = 64 * scale + 28
    out = Image.new('RGB', (cols * cw, rows * ch), (18, 18, 22))
    d = ImageDraw.Draw(out)
    for j, (nm, im, size) in enumerate(cells):
        big = im.resize((size * scale, size * scale), Image.NEAREST)
        x = (j % cols) * cw + 8; y = (j // cols) * ch + 6
        out.paste(big, (x, y))
        d.rectangle([x - 1, y - 1, x + size * scale, y + size * scale], outline=(70, 70, 80))
        d.text((x, y + size * scale + 6), '%s %dx%d' % (nm, size, size), fill=(210, 210, 220))
    out.save(os.path.join(PREV, fname))
    print('wrote', fname, out.size)

G = [('asset16_idx', 16, 9, 'A16_'), ('asset32_idx', 32, 5, 'A32_'), ('asset64_idx', 64, 2, 'A64_')]
sheet(G, 'preview-current.png', scale=4)

print('done')
