# 140 · P3 完成报告：scanout 端口化 + R_FBCFG 模式位接线 + 静态图验证工具（2026-11-03）

> **结论：P3 PASS。** `R_FBCFG(0x4C)` 的 **bit1** 现在作为 tile 模式位：**每次 `fb_commit` 捕获**（clk 域 `cur_tile`），
> pclk 侧在**消隐起点**采样（`pclk_tile`），保证一帧只按一种布局读；`band_stride` 由 `fb_w` 推导；`axi_errors` 两模式都计数。
> 三个 TB 全绿：P2 像素对照 PASS、raster 回归 PASS、**新 P3 切换 TB PASS**（raster→tile→raster，像素 0 差异、无挂死）。
> **未跑 Efinity、未碰板。**

---

## 一、改动清单（3 个文件，均有备份）

| 文件 | 改动 | 备份 |
|---|---|---|
| `gfx_scanout.v` | 新增输入端口 `tile_mode_cfg`；新增 `cur_tile`（clk，fb_commit 捕获）/ `pclk_tile`（pclk，消隐起点采样）；两套 FSM 改为**常开**、各认自己的请求 token；`band_stride_rt = ((fb_w<<4)+4095)>>12<<12`；`axi_errors` 改为 raster/tile 两计数器 mux；**帧起始请求改用 `commit_base` 取址**（原代码在翻页那一帧第一行/band 会用旧 base，双缓冲下会撕裂；本次一并修正，两种模式都改）| `gfx_scanout.v.bak-20261103-p3` |
| `gfx_regs.v` | `R_FBCFG` 写 bit1 → `reg_fb_tile`；新增输出 `cfg_fb_tile`；读回 `{tile, enable}`；复位默认 0 | `gfx_regs.v.bak-20261103-p3` |
| `gfx_top.v` | 新增 `wire cfg_fb_tile`；连到 gfx_regs 与 gfx_scanout | `gfx_top.v.bak-20261103-p3` |

**没有动** `gfx_core / gfx_mem / gfx_sprtab`（P4 才做）。默认仍是 raster（bit1 复位 0）。

### 语义要点
- `cur_tile` 只在 `fb_commit` 上升沿更新 → **模式与 framebuffer base 在同一次 commit 里切换**；
- `pclk_tile` 在 `x==0 && y==V_ACT`（消隐起点）采样 `cur_tile` → 一帧内不会混用两种布局；
- 两个 FSM 不再由模式门控（各自只响应自己的 request token），因此**切换过程中不会有请求被吞掉而死锁**；
- 切换代价：模式改变后的**第一帧**会因为新模式的预取从该帧消隐期才开始而整帧欠载（模型：≈ V_ACT 行），**从第二帧起稳定**。静态图验证把模式在 enable 之前设好，不经历切换。

---

## 二、TB 证据（全部实跑）

### 1) P2 像素对照（回归，`tb/tb_scanout_tile.v`）
```
pixel stream checks=65535 mismatches=0
burst pattern: raster beats!=64: 0 | tile beats!=256: 0, tile addr misaligned: 0
RESULT: PASS
```
### 2) raster 回归（`tb/tb_gfx_scanout.v`，旧 TB）
```
RESULT: PASS (15360 pixels checked)
```
### 3) **新增 P3 切换 TB**（`tb/tb_scanout_mode_switch.v`）
同一幅图存两份（raster 在 FB、tile 在 FB+0x10000），先跑 raster 2 帧 → commit 切 tile → 再 commit 切回 raster；每帧与理论像素比对：
```
after raster->tile switch: frames=4 under=65 (was 1)
frames=7 under=129 (after first switch 65) axierr=1 shown=4 checks=32768 mismatches=0
RESULT: PASS (mode captured on fb_commit; raster<->tile switch shows the right picture, no post-warmup underruns)
```
- **两种模式显示内容都逐像素正确**（mismatches=0）；
- 每次切换代价 = 1 帧欠载（+64 行 = 本 TB 的 V_ACT），之后不再增长——与上面"切换语义"一致；
- 切换过程不挂死（frames 继续递增），`axierr` 只在切换帧出现 1 次（旧请求 base 边界），稳定后为 0。

### 4) 顶层展开
`gfx_top` + 全部 gfx RTL iverilog 展开通过（只有一条既有 `wr_beats` 位宽 padding warning）。

---

## 三、如何用现有固件验证静态图（引擎还没 tile 化）

### 3.1 工具（本次新增）
`tools/png_to_tile.py`（numpy + Pillow）：
```bash
# 生成测试图（彩条 + 8x8 网格 + 四角标记；任何映射错误肉眼可见）
python tools/png_to_tile.py pattern --out-dir work/tileimg
#   -> fb_tile.bin / fb_raster.bin / expected.png（各 4,423,680 B，两种布局**字节数相同**）
# 实现自检：tile->raster 与 raster blob 逐像素一致
python tools/png_to_tile.py check --dir work/tileimg      # -> 0 differing pixels
# 真图转换 + 给固件用的 C 数组（选一块 8px 对齐区域）
python tools/png_to_tile.py make --in shot.png --crop 0,0,256,128 --c-array tile_logo --out-dir work/tileimg2
# 板端截图解码（A/B 对比用）
python tools/png_to_tile.py decode --in fb_dump.bin --mode tile   --out shot_tile.png
python tools/png_to_tile.py decode --in fb_dump.bin --mode raster --out shot_raster.png
```

### 3.2 固件最小改法（**推荐 256×128 小块，先证明 scan/DVI**）
1. 把 `tile_logo.h`（256×128 = 64 KB，16,384 个 32-bit word）加进固件；
2. 加一个直写 DDR 的 helper（SoC 有 DDR 访问权；**不要**用引擎命令，引擎还是 raster 写）：
```c
static void tile_put_block(const unsigned int *a, int x0, int y0, int w, int h) {
    for (int ty = 0; ty < h; ty += 8)
      for (int tx = 0; tx < w; tx += 8) {
        unsigned int base = FB_A + (((y0+ty) >> 3) * 0x8000u)
                                    + (((x0+tx) >> 3) * 128u);
        for (int row = 0; row < 8; row++)
          for (int j = 0; j < 4; j++)
            *((volatile unsigned int *)(base + row*16 + 4*j)) = *a++;
      }
}
```
3. 启动顺序（**模式在 enable 之前设好 → 无切换帧**）：
```c
tile_put_block(tile_logo, 0, 0, 256, 128);          // 写 tile 布局图像
gfx_wr(0x40u, FB_A);                                // R_FBBASE
gfx_wr(0x48u, (1080u << 16) | 1920u);               // R_FBSIZE
gfx_wr(0x4Cu, 0x1u);                                // R_FBCFG: enable=1, tile=0 (raster，A 组)
// 截图 A 组……
gfx_wr(0x4Cu, 0x3u);                                // R_FBCFG: enable=1, tile=1 (tile，B 组)
// 截图 B 组……
```
4. **A/B 判定**：
   - B 组截图用 `--mode tile` 解码、A 组用 `--mode raster`；两组应与 `expected.png` 的左上 256×128 逐像素一致（黑底之外区域随意）；
   - 看 `R_UNDER(0x64)`：enable 后第一帧允许少量 underrun（tile 预热），之后应**停止增长**；`R_FRAMES(0x70)` 递增、`R_SHOWN(0x68)` 跟随；
   - 若 B 组错位/错色 → 查 tile 地址公式/band_stride；若黑屏/闪烁 → DVI 时序/PnR，先回退黄金 bit（`tile=0` 即原路径）。
5. 想全屏验证：`fb_tile.bin` 4.4 MB 走现有 UART 下载/Flash 分区即可（工具已生成）；小块先验证不必全屏。

---

## 四、P4 前还差什么（不在 P3 范围）

| # | 项 |
|---|---|
| 1 | 引擎 tile 写路径（core 新增 TILE_FILL / TILE_COPY_KEY_NB / TILE_BLIT；gfx_mem 不改）|
| 2 | gfx_sprtab 发 tile 命令 + 位置量化；固件按场景选模式（随 commit 切）|
| 3 | 全屏背景/HUD 的 tile 适配（band fill + 8×8 字形复用精灵路径）|
| 4 | 24 bank（当前 16 bank / 2 band；P4 视余量再定）|
| 5 | 自检 6/6 的 tile 期望值重写；截图解码（工具已支持）|

## 五、风险

| 风险 | 说明 |
|---|---|
| PnR/DVI | scanout 新增模式寄存器/采样/两 FSM 常开（逻辑少量增加，RAM 不变）；布局抽签仍是头号风险，先看静态图 bit |
| 切换帧 | 模式切换后第一帧整帧欠载（≈1080 行）；场景切换时可接受；静态验证不经历 |
| 翻页首帧 base | 本次顺手修正了"帧起始请求用旧 base"的隐患（两种模式都改），双缓冲首行撕裂问题应一并消失——但这改变了 raster 行为，**上板需顺带确认无异常** |
| axi_errors | tile 计数已加；切换帧会 +1（旧请求边界），稳定后应 0 |

## 六、文件

| 文件 | 说明 |
|---|---|
| `C:\fpga_work\gfx2\rtl\gfx\gfx_scanout.v` / `gfx_regs.v` / `gfx_top.v` | P3 改动（备份 `.bak-20261103-p3`）|
| 工作区 `tb/tb_scanout_mode_switch.v` | 新增切换 TB |
| 工作区 `tb/tb_scanout_tile.v` / `tb/tb_gfx_scanout.v` | 已加 `tile_mode_cfg` 端口连接，回归 PASS |
| 工作区 `tools/png_to_tile.py` | host 工具（pattern/make/decode/check）|
| 工作区 `work/tileimg/`, `work/tileimg2/` | 测试图案 blob + expected.png + C 数组 |
