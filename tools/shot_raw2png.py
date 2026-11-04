
# shot_raw2png.py -- raw RGB565 dump from shot.ps1 -> PNG (10x nearest for readability)
import sys, struct
from PIL import Image
raw = sys.argv[1] if len(sys.argv) > 1 else r'work/logs/shot.raw'
out = sys.argv[2] if len(sys.argv) > 2 else raw.replace('.raw', '.png')
w, h = (int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else (480, 270)
d = open(raw, 'rb').read()
n = min(len(d) // 2, w * h)
im = Image.new('RGB', (w, h))
px = im.load()
for i in range(n):
    v = d[2*i] | (d[2*i+1] << 8)
    r = ((v >> 11) & 0x1F) * 255 // 31
    g = ((v >> 5) & 0x3F) * 255 // 63
    b = (v & 0x1F) * 255 // 31
    px[i % w, i // w] = (r, g, b)
im = im.resize((w * 3, h * 3), Image.NEAREST)
im.save(out)
print('wrote', out, im.size, 'from', n, 'pixels')
