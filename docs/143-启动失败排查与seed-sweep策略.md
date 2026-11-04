# 143 · 启动失败排查：证据链、vstripes 归类、seed sweep 策略（2026-11-03）

## 一、结论

| 项 | 结论 |
|---|---|
| P4 RTL 是否上电死锁 | **否**。同一份 P4 RTL 有能启动的实例：seed3 RASTER（Lead 实测 under=13709、串口有数据）、seed3 TILE（8 列图 = 固件在跑） |
| build flow 是否可疑 | **否**。用 compile 全流程重建 seed7，slack、bit 大小与 pnr+pgm-only 版逐项相同，md5 仅差位流头元数据（7ef79dbc vs 14a147ba）；两流程产同一布局 |
| 失败 seed 的共同点 | **tx_cal_clk 余量薄**：失败 seed11 0.143 / seed7 0.197 / seed17 0.245；能启动 seed3 raster 0.342 / seed3 tile 0.303 |
| 无串口的含义 | 固件 main 第一句就是 printf（bsp_init + "=== GFX v2 engine ==="），所以挂在 **bootloader / DDR 初始化阶段**，与 DDR 校准余量薄的机理一致 |
| 处置 | **seed sweep**：按 tx_cal/rx_cal 余量挑 seed 出 RASTER bit，上板测启动（固件已在 flash，只需烧 design bit，约 40 s/个） |

## 二、vstripes 照片（work/logs/board-vstripes.jpg）归类

**低确定性证据，不作为 P4 RTL 证据。** 照片来源 Lead 时间线推断最可能是 seed17（14:11 烧、串口 0 输出但有显示）或 golden bit + 8x8 固件时的异常帧。

机理上要注意：
- 当前 raster scanout 在 enable=0（上电默认）时**不发起 DDR 读**：raster FSM 收到预取 token 后 if (!enable) 直接 fault 并 ack（gfx_scanout.v st=0 -> st=3），bank_ok 复位为 0、bank 数据复位为 0 ⇒ 纯"固件没跑"的 raster bit 上电理论上应显示黑屏。
- 因此条纹更可能来自"能启动但取数失败"的位（行取不到时回退上一行/残存 bank 内容 + AXI 读出垃圾），或 tile 位 + 非 tile 帧存的另一种花法，或 DVI 链路比特错误。
- 无法用模型精确复现（需要未知的 DDR 残留内容）；不据此推翻 tx_cal 假设。

## 三、seed sweep 策略

1. 用 efx_run_pnr_sweep.bat（注意：--nJobs 等全局参数必须写在子命令之前）扫 seed 12-31（20 个，3 并行）。
2. 从 timing summary 提取每个 seed 的 core/sdram/rx_cal/tx_cal/pix slack，按 **tx_cal 与 rx_cal 的较小值**排序。
3. 取前 4-6 个，逐个 pnr seed + pgm 出 RASTER bit，命名 work/backup/p4-20261103/gfx2_system.RASTER-seedN.bit，附 md5 + slack 表。
4. Lead 上板：只烧 design bit（固件在 flash），看串口是否输出 + under 是否恒定。

## 四、若高 tx_cal seed 也起不来的后备方案（先不做）

1. raster 预取/读 FSM 加 en_s2 门控（上电完全不发 AXI 请求）；
2. 用 P2 备份 RTL（.bak-20261103-p4*）出最小 diff 位做 A/B。
两者都会改变布线抽签，收益不确定，等 sweep 结果再说。

---

## 五、Seed sweep 结果（2026-11-03 14:47，seed 12-31，3 并行）

PnR 配方：每 seed `--opt seed=N max_threads=10 detailed_place route`；TT 报告用 timing.sum.rpt；slack = target_period - 最大周期。

| seed | min(rx,tx) | rx_cal | tx_cal | sdram | core | 备注 |
|---|---|---|---|---|---|---|
| 25 | **0.342** | 0.368 | 0.342 | 0.253 | 0.932 | 候选#1 |
| 22 | 0.321 | 0.378 | 0.321 | 0.230 | 0.992 | 候选#4 |
| 21 | 0.314 | 0.397 | 0.314 | 0.324 | 0.912 | 候选#3，sdram 最好 |
| 28 | 0.312 | 0.312 | 0.443 | 0.303 | 0.976 | 候选#2，tx 最好 |
| 30 | 0.305 | 0.305 | 0.351 | 0.240 | 0.976 | 候选#5 |
| 12 | 0.305 | 0.305 | 0.326 | 0.251 | 0.971 | 候选#6 |
| 13 | 0.281 | 0.289 | 0.281 | 0.158 | 0.761 | |
| 26 | 0.280 | 0.280 | 0.383 | 0.387 | 0.905 | sdram 最好 |
| 18 | 0.280 | 0.280 | 0.293 | 0.353 | 0.757 | |
| 15 | 0.274 | 0.274 | 0.291 | 0.303 | 0.971 | |
| 20 | 0.255 | 0.255 | 0.328 | 0.237 | 0.832 | |
| 19 | 0.252 | 0.252 | 0.434 | 0.230 | 1.035 | |
| 27 | 0.251 | 0.251 | 0.270 | 0.305 | 0.927 | |
| 17 | 0.245 | 0.280 | 0.245 | 0.204 | 0.761 | 失败（已上板） |
| 24 | 0.221 | 0.425 | 0.221 | 0.309 | 0.624 | |
| 23 | 0.214 | 0.255 | 0.214 | 0.391 | 0.911 | |
| 14 | 0.210 | 0.210 | 0.319 | 0.318 | 0.905 | |
| 31 | 0.188 | 0.188 | 0.341 | 0.378 | 1.049 | |
| 29 | 0.167 | 0.167 | 0.267 | 0.322 | 0.884 | |
| 16 | 0.165 | 0.220 | 0.165 | 0.287 | 0.893 | |

候选位已提取到 `work/backup/p4-20261103/gfx2_system.RASTER-sweep-seedN.bit`（同名 .hex）；完整 per-seed 结果在 `C:/fpga_work/gfx2/run_sweep_7893ca4b786e/seed_N/outflow/`。

对照：能启动的 seed3 raster min(rx,tx)=0.283；已上板失败的 seed7/11/17 分别为 0.197/0.143/0.245 —— 候选 6 个全部高于能启动阈值。
