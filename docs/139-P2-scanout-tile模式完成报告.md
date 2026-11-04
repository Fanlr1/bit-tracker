# 139 · P2 完成报告：gfx_scanout tile 模式 + 对照 TB（2026-11-03 凌晨）

> **结论：P2 PASS。** tile 模式已在 `gfx_scanout.v` 中**新增**（`parameter TILE_MODE=0` 默认关闭），
> 对照 TB 证明 **raster 与 tile 两种模式输出的像素流逐字节一致**；原 raster 路径语义未变（旧 TB 回归 PASS）；
> 1080p tile 参数展开正确（band 30,720 B = 8×4 KB burst，135 band）。**未跑 Efinity、未碰板。**

---

## 一、完成度

| 项 | 状态 |
|---|---|
| `gfx_scanout.v` 新增 tile 模式（band 整读 + beat 转置写 16 bank）| ✅ 实现 |
| 原 raster 路径语义不变（`TILE_MODE=0`）| ✅ 回归 TB `RESULT: PASS (15360 pixels)` |
| band 读 = 1 请求/band（1080p：8 个 4 KB AXI burst，7×256 + 1×128 beat）| ✅ 参数化验证 |
| 显示侧 raddr / bank / epoch / 翻页逻辑复用 | ✅ 未改（只做模式 mux）|
| 对照 TB（同一帧内容，raster vs tile）| ✅ 65,535 像素检查 **0 差异**，暖机后 underruns 0 增长 |
| 24 bank 选项 | ⏸ 未做（见 §六），16 bank / 2 band 先跑 |
| 模式位接入 `R_FBCFG` | ⏸ 未做（按指示 P3 接线，当前是 parameter）|

**改动量**：`gfx_scanout.v` +271 行 / 改 24 行（其中 24 行是"把 rd 口/RAM 口/scan_accepted 等改成模式 mux"的机械改动）。
备份：`C:\fpga_work\gfx2\rtl\gfx\gfx_scanout.v.bak-20261103-p1tile`（P2 前版本）。

### 1080p 参数自检（`tb/tb_param_check.v`）
```
BAND_BEATS=1920  BAND_DATA=30720  BAND_STRIDE=32768  NBANDS=135  T_BURSTS=8  LAST_BEATS=128
```
（band 填充到 4 KB → 0x8000；135×0x8000 = 0x438000 = 现有 FB_B 偏移，地址常量不变。）

---

## 二、实现要点（对应代码位置）

| # | 位置 | 内容 |
|---|---|---|
| 1 | 端口/参数 | 新增 `parameter TILE_MODE=0, BAND_LINES=8`；局部常量 `BAND_BEATS/BAND_DATA/BAND_STRIDE/NBANDS/T_BURSTS/T_LAST_BEATS` |
| 2 | 读口（`rd_req/rd_addr/rd_beats`）| `TILE_MODE ? t_* : 原信号` 单行 mux（raster 路径行为不变）|
| 3 | bank RAM 端口 | `TILE_MODE ? t_bank_* : bank_*`（RAM 数量/组织不变：16 bank × 240 word × 128 bit = 48 RAM10）|
| 4 | pclk 域 | 新增 tile band 预取：一次 1 band，窗口 = 落后则丢弃、最多领先 1 band（只写下一条 band 的 bank 奇偶组）；消隐期预填 band 0/1；请求/完成 tag 用 toggle 跨时钟 |
| 5 | clk 域 | 新增 tile FSM：按 4 KB 边界发 8 个 burst（`t_cur_addr += 4096`），beat i → `bank={band[0], i[2:0]}`、`waddr=i/8`（tile 列号），完成后一次 ack |
| 6 | pclk bank 更新 | 一次 ack 发布 **8 条扫描行**：`bank_ok/row/epoch[(band&1)*8+r]`（raster 的 1~2 行更新路径保留在原分支）|
| 7 | 翻页/epoch | tile 分支独立维护 `t_front/t_commit_pend/t_scan_accepted`，在 band-0 请求时原子切换；`scan_accepted`、`front_now` 做模式 mux；display 的 `bank_row`/`bank_epoch`/`ready_row` 完全复用 |

## 三、对照 TB（`tb/tb_scanout_tile.v`）

- 几何：512×64（band=8 行=8,192 B=2×4 KB burst，8 band），同一帧内容按两种布局写入两个独立 DDR/AXI 模型。
- 两个 `gfx_scanout`（`TILE_MODE=0` / `=1`）+ 两个 `gfx_mem` 同时运行，逐像素比对输出 rgb/de/hs/vs。

```
PIX MISMATCH ...                 (无输出)
frames raster=3 tile=3  under raster=1 tile=15 (after warmup 1/15)
read bursts raster=191 tile=45 | read beats raster=12161 tile=11265
pixel stream checks=65535 mismatches=0
burst pattern: raster beats!=64: 0 | tile beats!=256: 0, tile addr misaligned: 0
RESULT: PASS (raster and tile pixel streams are byte-identical, no post-warmup underruns)
```

- **像素流 65,535 检查 0 mismatch**（覆盖 2 帧多）；暖机后 underruns 不再增长（raster 1/tile 15 都是首帧储能不足，见下）。
- tile 侧读 burst 全部 256 beat 且 **4 KB 对齐**（0 违规）；读 beat 总数与 raster 相同（每帧 4,096 = 64 行 × 64 beat）。
- 测试几何下 burst 数 raster 64/帧、tile 16/帧（tile 每 band 2 个 4 KB burst）；1080p 下两者都是 1080 burst/帧、259,200 beat/帧（P1 已算）。

**暖机说明**：tile 模式首帧只预填 0/1 band（消隐期才开始按 band 预取），所以首帧会 underrun 约 1 band；板端 enable 后同样会有一帧不完整（之后稳定），静态图验证时先跑几帧再截图。

## 四、P2 中暴露并修掉的 2 个实现 bug（P2 的价值）

1. **多 burst 时 beat 计数被重置**：原想在每个 burst 开始时清 `widx`，导致第 2 个 burst 覆写前半个 band（表现为输出像素整帧错位）。→ 现在 `widx` 只在 band 请求时清零，跨 burst 连续。
2. **fault 判据按 burst 判**：被判成"burst 末 beat 数不足"→ 所有 band 被标 fault → `bank_ok` 永远为 0（整帧 underrun）。→ 改为只在**最后一个 burst**校验 beat 数。

这两个都是"多 burst / 8 行一次发布"特有的坑，正好是 P2 要提前暴露的风险；其余（翻页/epoch/转置）一次做对。

---

## 五、P3 需要接线/补齐的清单

| # | 项 | 说明 |
|---|---|---|
| 1 | `R_FBCFG(0x4C)` 模式位 → `gfx_scanout` 的 `tile_mode` **输入端口** | 当前是 parameter；P3 改成端口后 gfx_top 直连。模式位必须**随 `fb_commit` 捕获**，与 framebuffer base 一起生效（同一个 commit 事件）|
| 2 | band stride 来源 | tile 模式下 `fb_stride` 不再使用；band_stride 由 `fb_w` 直接推导（`fb_w×8×2` 上取整到 4 KB）。gfx_regs 无需新增寄存器（用现有 `fb_w`）|
| 3 | `axi_errors` 计数 | 当前 tile 模式不计 AXI 响应错误（raster 分支才计）；P3 需 mux 一个 tile 错误计数器（便于抓帧存读错）|
| 4 | `fetch_row_dbg` | 仍是 raster 的 `cur_row`；P3 可改为 band/burst 调试值（非功能）|
| 5 | 引擎 tile 写路径 | 不在 P2 范围：core 新增 TILE_FILL / TILE_COPY_KEY_NB / TILE_BLIT（8×8 单 burst）；`gfx_mem` 不改 |
| 6 | 固件 | 按场景选模式 + tile 地址映射（截图/自检解码）；FB_B/SPR_BASE 不变 |
| 7 | 24 bank 可选 | 未实现：显示侧 bank 索引是 `y[3:0]`（16 的幂次），24 bank 需要 `y mod 24` 的非幂次取模/加法器，且 P2 只需 16 bank 验证。若 P4 判余量不够再加 |

---

## 六、上板验证要点（静态图，先不跑引擎）

1. **场景**：用固件写一帧静态测试图（渐变 + 若干 8×8 色块）到 **tile 布局** FB_A，然后 `fb_base=FB_A`、`tile_mode=1`、`enable=1`；另一路跑 `tile_mode=0` 的 raster 图作 A/B。
2. **看**：① 颜色/位置正确（tile→raster 映射无错位）；② 无闪烁/黑屏（DVI 稳定）；③ 读 `R_UNDER(0x64)`：暖机一帧后应稳定不再增长；④ `R_FRAMES` 递增、`R_SHOWN` 跟随。
3. **DVI 风险**：tile 逻辑会在 scanout 里新增组合/时序路径（尤其 `bank` 写索引与 8 行 ack 的 for 循环展开），可能改变 PnR 布局抽签结果 → 先出 bit 用 seed 对比；若黑屏先退回黄金 bit（raster 模式仍可用）。
4. **raster 回退**：同一 bit 里 `tile_mode=0` 就是原路径（本次已回归 PASS），无需单独保留旧 RTL。

## 七、文件与复现

| 文件 | 说明 |
|---|---|
| `C:\fpga_work\gfx2\rtl\gfx\gfx_scanout.v` | P2 改动（md5 `84407bc0…`，+271/−24 行）|
| `gfx_scanout.v.bak-20261103-p1tile` | P2 前备份 |
| 工作区 `tb/tb_scanout_tile.v` | raster vs tile 对照 TB |
| 工作区 `tb/tb_param_check.v` | 1080p tile 参数自检 |
| 工作区 `work/dbg_patch.py`, `work/dbg2*.py`, `work/fix*_scanout_tile.py` | 本轮调试/修补脚本（可删）|

```bash
# 对照 TB（在工程根目录 C:\Users\...\2D图形加速引擎）
/c/Users/25437/iverilog/bin/iverilog -g2012 -o /tmp/tb_scan_tile.vvp \
  tb/tb_scanout_tile.v /c/fpga_work/gfx2/rtl/gfx/gfx_scanout.v \
  /c/fpga_work/gfx2/rtl/gfx/gfx_mem.v /c/fpga_work/gfx2/rtl/simple_dual_port_ram.v
/c/Users/25437/iverilog/bin/vvp /tmp/tb_scan_tile.vvp
# raster 回归
/c/Users/25437/iverilog/bin/iverilog -g2012 -o /tmp/tb_reg.vvp tb/tb_gfx_scanout.v \
  /c/fpga_work/gfx2/rtl/gfx/gfx_scanout.v /c/fpga_work/gfx2/rtl/gfx/gfx_mem.v \
  /c/fpga_work/gfx2/rtl/simple_dual_port_ram.v && /c/Users/25437/iverilog/bin/vvp /tmp/tb_reg.vvp
```

## 八、遗留风险

| 风险 | 说明 |
|---|---|
| 首帧 underrun | tile 模式首帧约 1 band 未就绪（之后稳定），截图前先跑 2 帧 |
| PnR/DVI | 新增逻辑可能改变布局抽签；需 1~2 轮 seed 对比，失败即回退黄金 bit |
| LUT 增量 | 未综合，估计 +1~2%（两个 always/for 展开/模式 mux）；RAM10 不变（48）|
| 24 bank | 未做（见 §五 #7），P4 再定 |
| tile 模式 axi_errors | 暂不计数（见 §五 #3）|
