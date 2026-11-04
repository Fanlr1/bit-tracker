# 141 · P4 完成报告：raster 回归处置 + tile 引擎（零 gfx_core 改动）+ 构建 PASS

> **结论先行**
> 1. **raster 回归**：板测出问题的构建是 **P3 运行期模式版**（两套 FSM 同时综合、XLR 曾 60845/60800 超限、scanout 的 commit_base 取址改动、未上板验证过的 blanking=13）。这些改动**已全部不在当前 RTL 中**；raster 路径现在与 golden 版功能等价（差异只有 scan_accepted 由 reg 改成 wire mux、删除只读调试探针），blanking 预取回到 **9**。重新构建（静态参数、每 bit 只综合一种模式）后 **map/pnr/bitstream 全 PASS**，slack 比出问题的 Nov-2 构建更好。
> 2. **P4 tile 引擎已实现，且 gfx_core.v 零改动**：tile 布局下"一个 8×8 tile = 连续 128 B = 64 个连续像素"，让 walker 发射 w=64,h=1,src_stride=128,dst=tile 地址 的**现有**命令，core 的 compact-source 路径就自动"一次读 128 B + 一次 8-beat burst 写完整个 tile"。
> 3. **仿真全绿**：walker 命令 PASS、core tile burst PASS（2 个 AW burst / 16 W beat / 1 个源读 burst / 64 像素逐字节正确）、**端到端**（walker→core→tile FB→scanout）65536 像素 0 差异；raster / tile scanout 回归 PASS。
> 4. **构建**：raster 与 tile 两个 bitstream 均 **map + pnr(seed 3) + pgm PASS**（见第四节）；本轮未跑板、未碰串口。

---

## 一、raster 回归：定位与处置

### 1.1 事实梳理

| 项 | 状态 |
|---|---|
| 板测回归（under=1511、shown 25%、精灵缺失）所在构建 | Lead 的 **P3 运行期模式版**（R_FBCFG 模式位、cur_tile/pclk_tile、两套 FSM 常开、帧起始 commit_base 取址） |
| 当前 RTL | scanout = **P2 静态参数版**（TILE_MODE parameter，默认 0）；gfx_regs/gfx_top 无 tile 位；P3 的 commit_base 取址改动**已回退**（帧起始仍用原 front 行为） |
| 本轮对 raster 路径的改动 | ① blanking 预取窗口 13 → **9**（等于 golden 时代的值）；② 删除 rd_cyc_* 与 pf_stall 调试探针（只影响 dbg_* 输出，rdwait/rgap（0x90）保留）；③ axi_errors 由单计数器改为 raster/tile 两计数器 mux（TILE_MODE 常量选择，raster 行为不变） |

**结论**：P3 版引入的三处 raster 行为/面积变化（运行期模式 mux、commit_base 取址、两套 FSM 同时综合）都已移除；当前 raster RTL 与 golden 功能等价，并通过 tb_gfx_scanout 回归（15360 像素 PASS）。

### 1.2 为什么当时会回归（最可能机理）

- P3 版 **两套 FSM 同时综合** → 面积上升，历史记录 XLR 60845/60800 超限；即使 trim 后 PASS，布局/布线也远比 golden 差；
- docs/135 已确认：**DVI 稳定性与欠载由 PnR 布局抽签决定**；而且 P3 版还改了帧起始取址（双缓冲首行/首 band 来源变化）；
- 叠加 blanking 窗口 13（该值从未上板验证）。

### 1.3 处置后构建的 slack（raster，seed 3）

| 时钟 | Slack (ns) | 出问题的 Nov-2 构建 |
|---|---|---|
| core_clk | **1.041** | 0.712 |
| sdram_clk | **0.393** | 0.259 |
| rx_cal_clk | **0.321** | 0.285 |
| tx_cal_clk | **0.357** | 0.214 |
| pix_clk | **1.049** | 0.866 |
| pix_clk → pix_clk_fast | **-3.740**（TMDS 串行路径，历史已知常数，docs/118/135 同款）| -3.680 |

⇒ 所有 DDR/像素域 slack 都优于出问题的构建。**板测标准**：raster bit 上板后 R_UNDER(0x64) 应在启动后**恒定不增长**、R_SHOWN 跟随 R_FRAMES、精灵完整。若仍不满足 → 属于 PnR/DVI 抽签（换 seed），不是本轮 RTL 功能问题（仿真已证）。

---

## 二、P4：tile 引擎实现（**gfx_core.v 一行未改**）

### 2.1 关键观察

tile 布局 = [band][tile][row][16B]，一个 tile 的 8 行是**连续 128 B**，正好等于 **64 个连续 RGB565 像素**。因此用现有 raster 命令就能写 tile：

| tile 操作 | 现有命令（walker 发射）| core 行为 |
|---|---|---|
| 擦除 tile | FILL, w=64,h=1, ds=16, dst=tile 地址 | 1 个 8-beat burst 写 128 B 背景色 |
| 不透明精灵 | OP_COPY_KEY_NB(6), w=64,h=1, src=精灵, ss=128, dst=tile | compact 源读一次 128 B；key 像素 wstrb=0；1 burst 写 |
| 半透明精灵 | OP_BLIT(4), w=64,h=1, src, ss=128, dst=tile | 多一次 tile 回读（背景混合）；1 burst 写 |

- ss = 128 = w*2 触发 core 的 compact-source 模式（它本来就为 8×8/16×16 精灵设计）；
- dst = fb + (y>>3)*0x8000 + (x>>3)*128（band 填充到 4 KB，135 band × 0x8000 = 0x438000，**FB_A/FB_B/SPR_BASE 常量都不用改**）；
- 坐标在 walker 内量化：x&~7, y&~7（量化粒度可改，公式不变）；
- **面积**：walker 只多几个移位/加法（乘 0x8000 = 左移 15、乘 128 = 左移 7），core 零增量。

### 2.2 改动文件（备份 .bak-20261103-p4*）

| 文件 | 改动 |
|---|---|
| gfx_scanout.v | ①(本轮) tile 模式下**关掉 raster 预取/读 FSM**（P2 版在 tile 模式仍会跑 raster FSM：浪费读、会误报 axi_errors——仿真抓到 axierr=30，修复后 0）；②axi_errors 双计数器 mux（tile 错误可见）；③删除调试探针；④blanking 窗口回 9；⑤修 t_ack_seen 双驱动（综合报 VDB-1000）。tile 读/转置/16-bank 逻辑沿用 P2 已验证版本 |
| gfx_sprtab.v | 新增 TILE_MODE / BAND_STRIDE 参数与 mk_tile_fill / mk_tile_key；TILE_MODE=1 时发 64×1 tile 命令（量化坐标 + tile 地址）；raster 分支原样保留 |
| gfx_top.v | 新增 TILE_MODE / TILE_BAND_STRIDE 参数，透传给 scanout 与 sprtab（**静态参数，不做运行期切换**，每 bit 只综合一种模式，面积/风险最小） |
| system_top_gfx.v | tile 构建时一行 .TILE_MODE(1)（备份 .bak-20261103-p4；**交付时已恢复默认 raster**）|
| **gfx_core.v / gfx_mem.v / gfx_regs.v** | **未改** |

> 设计取舍：**放弃 P3 的运行期模式位**，改为"两个 bitstream（raster / tile）+ 编译期参数"。原因：运行期版要同时综合两套 FSM（面积紧张、XLR 超限风险）且引入 P3 回归；静态版每 bit 只含一种模式，面积与 golden 同级，A/B 验证只需换 bitstream。固件不需要写任何模式寄存器。

---

## 三、仿真证据（全部实跑，iverilog）

| TB | 内容 | 结果 |
|---|---|---|
| tb/tb_tile_cmd.v | walker(TILE_MODE=1) 发 1 个移动精灵 | **PASS**：恰好 2 条命令；fill dst=0x08028600(96,40)、op6 dst=0x08028680(104,42)，w=64/h=1/ss=128/key 正确 |
| tb/tb_tile_core.v | core 执行 FILL 64×1 + OP_COPY_KEY_NB 64×1 → tile 存储 | **PASS**：**2 个 AW burst、16 个 W beat、1 个源读 burst**；64/64 像素逐字节 = 期望（key 像素保留背景）；无 error/clipped |
| tb/tb_tile_e2e.v | 4 个 8×8 精灵（含重叠、非 8 对齐位置）：walker→core→gfx_mem→tile FB→scanout | **PASS**：8 条命令全部完成，**65536 像素 0 差异**，AXI 错误 0，under 仅首帧预热 14 后不再增长 |
| tb/tb_scanout_tile.v | raster vs tile 两种 scanout 同帧对照 | **PASS**：65535 检查 0 差异；tile 读 burst 全 256 beat / 4 KB 对齐 |
| tb/tb_gfx_scanout.v | raster 回归（golden 路径）| **PASS (15360 pixels)** |

**写 burst 数**：每个 8×8 精灵 = **擦除 1 + 绘制 1 = 2 个写 burst**（每个 8 beat = 128 B）；源读在精灵缓存命中后为 0（冷 miss 时每模式一次 32-beat 读）。4000 精灵 = 8000 个写 burst（与 P1 模型预测一致）。

---

## 四、构建证据（Efinity 2026.1，Ti60F225，seed 3）

| 构建 | map | pnr(seed3) | pgm(bitstream) | LUT4 | FF | RAM10 |
|---|---|---|---|---|---|---|
| **raster**（默认 TILE_MODE=0）| PASS | PASS | PASS | 37904 | 21284 | 226 |
| **tile**（TILE_MODE=1）| PASS | PASS | PASS | 36886 | 20841 | 226 |

- **两个 bit 都在 C:\fpga_work\gfx2\p4_build\**：
  - raster：gfx2_system.raster-p4.bit / .hex（seed 3，map/pnr/pgm PASS）
  - tile：gfx2_system.tile-p4.bit / .hex（seed 3，map/pnr/pgm PASS；LUT 比 raster 还少约 1k，因为只有一种模式的 FSM 参与综合）
  - 各自还保存了 *.map.rpt、*.timing.rpt、*.res.txt、*.slack.txt
- 两个构建的 slack 对照（ns）：

| 时钟 | raster seed3 | tile seed3 |
|---|---|---|
| core_clk | 1.041 | **1.271** |
| sdram_clk | 0.393 | 0.252 |
| rx_cal_clk | 0.321 | **0.414** |
| tx_cal_clk | 0.357 | 0.303 |
| pix_clk | 1.049 | 1.100 |
| pix_clk→fast | -3.740（历史常数）| -3.594 |
- 复现命令（工程根目录）：
  bash work/_efx.sh map          # 注意：直接用 work_syn_sys/run_efx_map.sh 会让 efx_map.exe segfault，必须走 efx_run 包装
  bash work/_efx.sh pnr 3
  bash work/_efx.sh pgm

---

## 五、上板验证步骤

### A. raster 回归验证（先做，保底）
1. 烧 gfx2_system.raster-p4.bit，沿用 golden 固件/场景；
2. 看 SCAN frames=… under=… shown=…：**under 启动后应恒定不再增长**、shown 跟随 frames、画面精灵完整；
3. 若 under 仍增长 → PnR/DVI 抽签；换 seed 重建（告诉我 seed，我出 bit），不要改 RTL。

### B. tile 模式静态图验证（scan 路径）
1. 烧 **tile bit**（gfx2_system.tile-p4.bit）；
2. 固件（你那边改）：
   - 用 tools/png_to_tile.py pattern --out-dir work/tileimg 生成测试图（彩条 + 8×8 网格 + 四角标记）；
   - 把小块 C 数组（make --crop 0,0,256,128 --c-array tile_logo）加进固件；
   - 用 tile_put_block()（地址 fb + (y>>3)*0x8000 + (x>>3)*128 + row*16，每行 4 个 32-bit word）写进 FB_A；
   - 设 R_FBBASE=FB_A、R_FBSIZE=1920/1080、R_FBCFG=1（enable）——**不要写 bit1**（本版没有该寄存器位，模式由 bitstream 决定）；
3. UART 截图后用 python tools/png_to_tile.py decode --in dump.bin --mode tile --out shot.png 解码，与 expected.png 对比；同时看 R_UNDER 暖机后是否停止增长、R_SHOWN 跟随。
4. A/B：同一幅图用 raster bit + 现有 raster 固件画/截，解码应一致。

### C. tile 模式引擎验证（精灵路径）
1. 仍是 tile bit；**不要用 raster 命令画背景/HUD**（tile 布局下会把画面写花——背景/HUD 的 tile 化是下一步工作）；
2. 保持 FB 为 0（黑底），按现有方式配置 walker（G_SPRSRC / G_SPRFILL / G_SPRKEY / G_SPRMAX / G_SPRN / G_SPRCTL），场景用 SPRITE/BULLET（只有精灵，无背景命令）；
3. walker 现在会自动发 tile 命令：每精灵 1 次擦除 + 1 次绘制，位置按 8 px 量化；
4. 截图解码：应看到每个精灵 tile 内背景色（G_SPRFILL，默认 0x1082）+ 精灵像素；相邻 tile 未写区域保持黑；R_UNDER 稳定（tile 模式 16 bank = 2 band，余量约 8 行，若 4000 精灵引擎全速时 under 增长，下一版可加 24 bank）。

---

## 六、风险清单

| # | 风险 | 说明/缓解 |
|---|---|---|
| 1 | **DVI 抽签** | pix_clk_fast slack -3.7 是历史已知常数（docs/118/135）；若黑屏/花屏先换 seed 重建，不改 RTL |
| 2 | **raster 回归是否真修好** | 只能上板验证；仿真层面当前 RTL 与 golden 功能等价、且构建 slack 全面优于出问题构建。若仍回归，按第五节 A3 处理（PnR 抽签）|
| 3 | tile 引擎场景不完整 | background/HUD/CPU 渲染仍走 raster；tile bit 下必须在"只画精灵"的场景验证。全场景 tile 化需要 tile band fill + HUD 适配（下一步）|
| 4 | tile scan 余量 | 16 bank = 2 band ≈ 8 行余量（raster 现为 9~14 行）；4000 精灵引擎满速时 under 可能上升，24 bank 方案（+24 RAM10，余 34 块）已验证可行但未实现 |
| 5 | 源读 over-read | 冷 miss 时 compact 源读固定 32 beat（512 B），8×8 精灵只占 128 B；因精灵缓存命中后为 0，实测影响小 |
| 6 | 量化视觉 | 8 px 量化（横向/纵向），与 P1 评估一致；用户已确认可接受 |

---

## 七、文件与备份

| 文件 | 备份 |
|---|---|
| rtl/gfx/gfx_scanout.v | .bak-20261103-p4、.bak-20261103-p4b |
| rtl/gfx/gfx_sprtab.v | .bak-20261103-p4 |
| rtl/gfx/gfx_top.v | .bak-20261103-p4 |
| rtl/system_top_gfx.v | .bak-20261103-p4（交付时已恢复 raster 默认）|
| 仿真 TB（工作区）| tb/tb_tile_cmd.v、tb/tb_tile_core.v、tb/tb_tile_e2e.v、tb/tb_scanout_tile.v、tb/tb_gfx_scanout.v |
| 构建产物 | C:\fpga_work\gfx2\p4_build\ |
| 工具 | tools/png_to_tile.py（pattern / make / decode / check）|

---

## 八、补记：板上 8 列重复画面 = tile bit + raster 帧存的模式错配（2026-11-03）

用户照片 work/logs/board-8columns.jpg 显示的 8 个竖直重复列（每列 240px）不是 raster 回归，也不是 band 转置 bug：

- 当时板上烧的是 tile 版 bit（outflow 13:52 构建），但固件/帧存仍是 golden 的 raster 布局；
- tile scan-out 读 raster 帧存时，每行第 k 个字地址 = (y>>3)*0x8000 + (y&7)*16 + k*128；
- 每个 raster 行 4096B = 32 个 128B 块 => 显示器每 32 字（约 256px，截断后 240px）换一个 raster 行 => 屏幕一行被切成 8 列，第 j 列 = raster 行 (8*band+j) 的抽样；
- HUD 在 raster 顶部各行 => 每列左侧重复同样 HUD；白色竖条 => 每列右侧重复白条。

模型复现：用 golden 截图作 raster 帧存内容、按上式重采样，得到 work/logs/p4_tilebit_on_rasterfb_prediction.png，与照片在 8 列结构 / HUD 位置 / 白色竖条 / 青色精灵噪点上逐项对应。

结论与规则：tile scan-out 按设计工作，但必须配 tile 帧存。golden 固件只能烧 RASTER bit；tile bit 需 CPU 直写 tile 布局（tools/png_to_tile.py）或只跑 walker 的 tile 精灵命令，同一帧里不能再发 raster 引擎命令。
