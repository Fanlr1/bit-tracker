
import re
p = r'C:\Users\25437\Desktop\竞赛\嵌入式设计竞赛FPGA设计项目\2D图形加速引擎\work\gfx_demo\src\font_cn.h'
s = open(p, encoding='utf-8').read()
m = re.search(r'CN_CP\[CN_N\] = \{(.*?)\};', s, re.S)
cps = [int(x,16) for x in re.findall(r'0x[0-9A-Fa-f]+', m.group(1))]
m2 = re.search(r'CN_BITS\[CN_N\]\[32\] = \{(.*?)\n\};', s, re.S)
rows = re.findall(r'\{\s*([0-9x, A-Fa-f]+)\s*\}', m2.group(1))
print('glyphs:', len(cps), 'bitmaps:', len(rows))
def art(cp):
    if cp not in cps:
        print('MISSING', hex(cp), chr(cp)); return
    i = cps.index(cp)
    vals = [int(x,16) for x in re.findall(r'0x[0-9A-Fa-f]{2}', rows[i])]
    print('glyph', chr(cp), 'rows', len(vals))
    for r in range(16):
        w = (vals[2*r]<<8) | vals[2*r+1]
        print(''.join('#' if w & (1<<(15-c)) else '.' for c in range(16)))
for ch in '升级上难度':
    art(ord(ch)); print()
