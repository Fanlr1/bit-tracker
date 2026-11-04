# -*- coding: utf-8 -*-
"""Contract check: the video timing the top level actually instantiates must be
self-consistent, and must agree with the pixel clock the PLL supplies.

WHY THIS EXISTS
  system_top.v instantiates bitblt_video_out overriding only H_ACT and V_ACT:

      bitblt_video_out #(.H_ACT(640), .V_ACT(480), .FIFO_AW(11), .AXI_ID(...))

  The module's other six timing parameters keep their defaults, which are the
  1920x1080 values. So H_TOTAL becomes 640+88+44+148 = 920 rather than 800, and
  with the 148.5 MHz pixel clock the refresh rate works out at 307 Hz.

  The testbench for that module already warns about exactly this trap -- "a
  testbench that overrode only H_ACT/V_ACT would silently inherit full-HD
  blanking" -- and passes all eight parameters explicitly to avoid it. The top
  level does not.

WHAT THIS CHECKS
  1. every timing parameter the module declares is either overridden at the top
     level or matches the active-region values
  2. the implied refresh rate = pix_clk / (H_TOTAL * V_TOTAL) is plausible
  3. the active region implied by H_ACT/V_ACT agrees with the framebuffer
     geometry the driver programs, which is what fb_width must equal

Reads the RTL and the PLL definition; no simulation required, so it can run as
part of the regression.
"""

import io, os, re, sys

WS = r'C:\Users\25437\Desktop\竞赛\嵌入式设计竞赛FPGA设计项目\2D图形加速引擎'
SYS = os.path.join(WS, 'rtl', 'system_top.v')
VID = os.path.join(WS, 'rtl', 'bitblt_video_out.v')
PERI = os.path.join(WS, 'fpga', 'bitblt_system.peri.xml')
MAIN = os.path.join(WS, 'work', 'bitblt_demo', 'src', 'main.c')

fails = []
warns = []


def read(p):
    return io.open(p, encoding='utf-8', errors='replace').read()


# ---------- 1. module defaults ----------
v = read(VID)
m = re.search(r'module\s+bitblt_video_out\s*#\s*\((.*?)\)\s*\(', v, re.S)
if not m:
    print('  FATAL: cannot parse bitblt_video_out parameter list'); sys.exit(2)
defaults = {}
for pm in re.finditer(r'\bparameter\s+(\w+)\s*=\s*(\d+)', m.group(1)):
    defaults[pm.group(1)] = int(pm.group(2))
print('  模块默认参数（共 %d 个）:' % len(defaults))
for k in sorted(defaults):
    print('    %-10s = %d' % (k, defaults[k]))

TIMING = ['H_ACT', 'H_FP', 'H_SYNC', 'H_BP', 'V_ACT', 'V_FP', 'V_SYNC', 'V_BP']

# ---------- 2. what the top level overrides ----------
s = read(SYS)
mi = re.search(r'bitblt_video_out\s*#\s*\((.*?)\)\s*u_video_out', s, re.S)
if not mi:
    print('  FATAL: cannot find the bitblt_video_out instance in system_top.v'); sys.exit(2)
inst = mi.group(1)
overrides = {}
for pm in re.finditer(r'\.(\w+)\s*\(\s*(\d+)\s*\)', inst):
    overrides[pm.group(1)] = int(pm.group(2))
print()
print('  顶层覆盖的参数（共 %d 个）:' % len(overrides))
for k in sorted(overrides):
    print('    %-10s = %d' % (k, overrides[k]))

eff = {}
for k in TIMING:
    eff[k] = overrides.get(k, defaults.get(k))
# Whether each came from the top level is shown in the table below and is not
# warned about per parameter: overriding none of them is legitimate (the
# defaults are one complete mode). Only a partial override is a fault, and
# that is reported once, under the verdict.

# A partial override is the hazard, not an absent one. Overriding all eight is
# coherent; overriding none is coherent (the defaults are one complete mode);
# overriding some is how the 640/480 instance produced 920x525 timing.
ov_timing = [k for k in TIMING if k in overrides]
if 0 < len(ov_timing) < len(TIMING):
    mixed = [k for k in TIMING if k not in overrides]
    fails.append('顶层只覆盖了 %d/%d 个时序参数（%s），其余继承默认（%s）'
                 '—— 两套模式的参数混在一起，正是 640x480 实例踩过的坑'
                 % (len(ov_timing), len(TIMING),
                    ', '.join(ov_timing), ', '.join(mixed)))
    warns = [w for w in warns if '未在顶层覆盖' not in w]

H_TOTAL = eff['H_ACT'] + eff['H_FP'] + eff['H_SYNC'] + eff['H_BP']
V_TOTAL = eff['V_ACT'] + eff['V_FP'] + eff['V_SYNC'] + eff['V_BP']
print()
print('  实际生效的时序:')
for k in TIMING:
    src = '顶层' if k in overrides else '★ 默认'
    print('    %-8s = %-6d  (%s)' % (k, eff[k], src))
print('    H_TOTAL  = %d' % H_TOTAL)
print('    V_TOTAL  = %d' % V_TOTAL)

# ---------- 3. pixel clock from the PLL definition ----------
p = read(PERI)
clk = None
mp = re.search(r'<efxpt:pll name="HDMI_PLL".*?</efxpt:pll>', p, re.S)
if mp:
    blk = mp.group(0)
    ref = re.search(r'ref_clock_freq="([\d.]+)"', blk)
    ref = float(ref.group(1)) if ref else None
    fb = re.search(r'comp_output_clock name="pll_fb"\s+number="\d+"\s+out_divider="(\d+)"', blk)
    px = re.search(r'comp_output_clock name="pix_clk"\s+number="\d+"\s+out_divider="(\d+)"', blk)
    if ref and fb and px:
        vco = ref * int(fb.group(1))
        clk = vco / int(px.group(1))
        print()
        print('  PLL: ref=%g  pll_fb_div=%s  pix_clk_div=%s' % (ref, fb.group(1), px.group(1)))
        print('       VCO = %g MHz,  pix_clk = %g MHz' % (vco, clk))
if clk is None:
    print('  WARNING: 无法从 peri.xml 推出 pix_clk，跳过刷新率检查')
else:
    refresh = clk * 1e6 / (H_TOTAL * V_TOTAL)
    print('  推出刷新率 = %.1f Hz' % refresh)
    if not (50.0 <= refresh <= 75.0):
        fails.append('刷新率 %.1f Hz 不在 50~75 Hz 之内 —— 显示器极可能锁不上'
                     % refresh)

# ---------- 4. active region vs the framebuffer the driver programs ----------
mc = read(MAIN)
fw = re.search(r'#define\s+FB_W\s+(\d+)u', mc)
fh = re.search(r'#define\s+FB_H\s+(\d+)u', mc)
if fw and fh:
    drv_w, drv_h = int(fw.group(1)), int(fh.group(1))
    print()
    print('  驱动写的帧缓冲: %d x %d' % (drv_w, drv_h))
    print('  顶层例化的有效区: %d x %d' % (eff['H_ACT'], eff['V_ACT']))
    if (drv_w, drv_h) != (eff['H_ACT'], eff['V_ACT']):
        fails.append('有效区不一致：驱动 fb_width=%d 而顶层 H_ACT=%d ⇒ '
                     '扫描输出每行取 %d 像素、只显示 %d'
                     % (drv_w, eff['H_ACT'], drv_w, eff['H_ACT']))

# ---------- 5. the register reset value the scan-out starts with ----------
#
# A third opinion about what the geometry is. The driver overwrites FB_SIZE_H
# before enabling scan-out, so this is milder than the instantiation fault -- but
# it is the same mistake: a constant describing the old resolution left where the
# new one belongs. It was 32'h01E0_0280 (height 480, width 640) with a comment
# saying so.
SLAVE = os.path.join(WS, 'rtl', 'bitblt_axi_slave.v')
sl = read(SLAVE)
mr = re.search(r"r_fb_size_h\s*<=\s*32'h([0-9A-Fa-f_]+)\s*;\s*(//[^\n]*)?", sl)
if mr:
    raw = mr.group(1).replace('_', '')
    val = int(raw, 16)
    rst_w = val & 0xFFFF
    rst_h = (val >> 16) & 0xFFFF
    print()
    print('  FB_SIZE_H 复位值 = 32\'h%s  ->  width %d, height %d'
          % (raw, rst_w, rst_h))
    if (rst_w, rst_h) != (eff['H_ACT'], eff['V_ACT']):
        fails.append('FB_SIZE_H 复位值是 %dx%d，而扫描输出的有效区是 %dx%d'
                     '—— 驱动写它之前，扫描输出按旧分辨率取像素'
                     % (rst_w, rst_h, eff['H_ACT'], eff['V_ACT']))
else:
    print()
    print('  WARNING: 找不到 r_fb_size_h 的复位赋值，跳过该项')

# ---------- verdict ----------
print()
print('  ================ verdict ================')
for w in warns:
    print('  WARN  ' + w)
if fails:
    for f in fails:
        print('  FAIL  ' + f)
    sys.exit(1)
print('  PASS  视频时序自洽')
sys.exit(0)
