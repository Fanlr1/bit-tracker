# 142 · P4 后续：RASTER 多 seed bit + 烧录/资产建议（2026-11-03）

## 一、RASTER 多 seed bitstream（同一 RTL、同一 netlist，只差 PnR seed）

| seed | 文件（work/backup/p4-20261103/）| md5 | 大小 | core | sdram | rx_cal | tx_cal | pix | pix_fast |
|---|---|---|---|---|---|---|---|---|---|
| 3  | gfx2_system.RASTER-seed3.bit  | be1a3f60a5929c92a4adc6029c162209 | 2,861,649 | 0.877 | 0.371 | 0.283 | 0.342 | 0.619 | -3.967 |
| **7**  | **gfx2_system.RASTER-seed7.bit**  | **14a147ba9fabd20d1782204a432c520f** | 2,844,801 | 0.855 | 0.306 | **0.382** | 0.197 | 0.639 | -3.803 |
| **11** | **gfx2_system.RASTER-seed11.bit** | **3d9e3bd33a481714a2d67f91c6240fdf** | 2,859,093 | 0.820 | **0.337** | 0.331 | 0.143 | 0.687 | -3.784 |
| 17 | gfx2_system.RASTER-seed17.bit | 91697bc6f75e32294eaa7d001f80f018 | 2,860,674 | 0.761 | 0.204 | 0.280 | 0.245 | 0.813 | -3.770 |

- 每个都有同名 .hex 和 raster-p4-seedN.slack / timing.rpt；map/pnr/pgm 全部 PASS。
- 上板建议顺序：**seed 7 → seed 11 → seed 17 → seed 3**（rx_cal/sdram 综合看，7 最优，17 最差）。
- pix_clk_fast 在 -3.77~-3.97，是历史已知常数（docs/118/135），与上板 under 无强相关，不用据此筛。
- 都是同一份 RTL/netlist，只是 PnR 抽签不同；哪个种子稳定就把它的 bit 留作新黄金 fallback。

## 二、flash 烧写不稳定：根因与稳定流程

现象根因：
- Unsupported JTAG Bridge version: 0.0 = **FPGA 里没有 JTAG bridge bitstream**。烧完 design bit 或断电后 bridge 就没了，所以**每次刷 flash 都必须先烧 bridge**。
- 旧脚本只在第 3 次尝试前才烧 bridge ⇒ 前两次必然失败（不是运气问题）。
- Command timeout (1 cycles) 是 FT4232H/JTAG-bridge 的偶发超时；降低 JTAG 频率、减小 burst、重烧 bridge 可解决。

**固定顺序（不要倒）**：
1. 关闭串口监视器（COM10）与任何 Efinity GUI / 其它 FTDI 使用者；
2. 用 -m jtag 烧 JTAG bridge：C:/Efinity/2026.1/pgm/fli/titanium/u10660A79.bit，等 finished with JTAG programming，sleep 3；
3. 用 -m jtag_bridge --jtag_bridge_mode erase_and_write --address 0x380000 --jtag_clock_freq 3000000 --burst_size 1 <firmware.hex>；失败（Command timeout）就重烧 bridge 后重试（最多 3 次）；
4. 用 -m jtag 烧 design bit（会再次清掉 bridge，正常）；
5. 本次会话结束；下次刷 flash 从第 2 步开始。

现成脚本：work/_flash_stable.sh（按上面顺序写好、bash -n 通过，可传 design bit 与 hex 两个参数）。注意：它不做第 0 步的串口关闭，需要人工确保。

## 三、A16_KNIFE 改 8×8 的注意事项（对照当前 game.h）

现状（工作区已改）：knife8.h + KNIFE8_ADDR = GAME_ASSET_BASE + 0x8000 + 上传 64 个 uint16；绘制 g_spr(..., g_kn[i].x + 4, g_kn[i].y + 4, 8u)。

**1）绘制偏移是错的，应去掉 +4**：
- knife_fire() 里出生点 kf->x = (cx-4)&~1（cx=玩家中心）⇒ **x,y 已经是 8×8 左上角**；
- knife_hit() 用 k->x + 4 当子弹中心 ⇒ 也按 8×8 左上角约定；
- 出界判断用 GX_HI-8 / GY_HI-8 ⇒ 同上；
- 所以绘制应为 g_spr(..., g_kn[i].x, g_kn[i].y, 8u)；现在的 +4 会让**画面比碰撞中心偏右下 4px**（8px 子弹上很明显）。

**2）资产槽位安全**：
- 16×16：9×512 = 0x1200；32×32：5×2048 = 0x2800；64×64：2×8192 = 0x4000 ⇒ 资产总占用到 GAME_ASSET_BASE + 0x7A00；
- KNIFE8_ADDR = +0x8000 有 0x600 空隙，**不重叠**，且 16B 对齐（compact 源读要求）；
- SPRTAB_BASE = 0xE1008000（SoC 外设空间）、BG_BASE = 0x0B400000 都不在这段 DDR，无冲突。

**3）保持 A16_KNIFE 资产不删**：删掉会改 ASSET16_N，把所有 32×32/64×64 资产地址整体前移 ⇒ 需要同步改 A32ADDR/A64ADDR 的使用者（玩家/精英敌人都依赖）。512 B 残留不值得冒险。

**4）可选的性能增益**：gfx_copy_key() 用的是 OP_COPY_KEY(5) = 读背景的 RMW（key 像素写回背景），每颗子弹 = 源读 + 背景读 + 写 = 3 个 burst。RTL 已有 OP_COPY_KEY_NB(6)（key 像素不写、不读背景，walker 精灵路径在用）；在 gfx.h 加一个 gfx_copy_key_nb() 即可让子弹降到 2 个 burst（约 33% DDR 流量）。前提：旧位置擦除已经发生（g_rb 擦除逻辑已有），所以 key 像素保留旧内容没问题。
