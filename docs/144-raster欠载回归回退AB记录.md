# 144 · raster 欠载回归：回退 A/B 记录（2026-11-03 下午）

## 一、结论（截至本记录）

| 配置（idle scan 实验，同固件 游戏压测版）| under / 60 帧 | rows/frame | first | 说明 |
|---|---|---|---|---|
| **golden bit**（11-01 构建）| +0 | 0.0 | 2047 | 基准 |
| V-cdc（golden 时代 scanout 文件 + 当前其它 RTL）| +1308 | 21.8 | 136 | 排除 scanout 文件本身 |
| seed28 P4 位（P4 win13 scanout + 当前 mem）| +58 | 0.9 | 128 | win13 明显改善 |
| V-cdc + 旧 mem（pre-mem-pipeline）| under 1102->3054 / 447 帧 | ~4.5 | - | mem-pipeline 贡献约 79% |
| **P4 win13 scanout + 旧 mem**（组合位，seed28）| 待测 | - | - | 两个最优组合 |

关键事实：
1. golden bit = **11-01 的构建**（md5 0fecc762…，在 final-20261101 / golden-20261031 / final1500-20261102 中同一文件）；11-02 之后 RTL 改了大量内容。
2. gfx_scanout.v 的 golden 时代文件 = gfx_scanout.v.bak-cdc，且与工作区 git 10-30 提交内容**逐字节相同**（md5 35e49fac…）⇒ 用它做的 V-cdc 确实代表 golden scanout。
3. 11-02 的 **gfx_mem mem-pipeline** 是主要贡献者（回退后 21.8 -> 4.5 行/帧）。
4. 窗口 9->13（blanking 预取加深）能让 21.8 -> 0.9 行/帧，是第二因素。
5. 残余 1-4 行/帧更像 PnR/布线时序差异（sdram slack 当前 0.22-0.45，golden 时代官方同设计 0.53），不再是单点 RTL 问题。

## 二、作过的对照位（都在 work/backup/p4-20261103/）

| 文件 | md5 | 内容 | 结果 |
|---|---|---|---|
| gfx2_system.RASTER-sweep-seed28.bit | b1029ea4… | 当前 P4 RTL（窗口9）+ seed28 | idle 0.9 行/帧；boot OK |
| gfx2_system.RASTER-revert-cdc-seed28.bit | 783d1e84… | gfx_scanout=.bak-cdc | idle 21.8 行/帧 |
| gfx2_system.RASTER-revert-cdc-mem-seed28.bit | 0219d0e5… | .bak-cdc + 旧 mem | ~4.5 行/帧 |
| gfx2_system.RASTER-revert-p1tile-seed28.bit | 31594ec4… | pre-P2 scanout（窗口13）| 备用 |
| gfx2_system.RASTER-p4win13-oldmem-seed28.bit | 33054851… | P4 win13 + 旧 mem | 待测（最优组合）|
| gfx2_system.RASTER-win13-seed{22,25,28}.bit | 9e9cf560 / 5c6e71ef / 83859fa7 | 当前 RTL 窗口13 | 窗口对照 |

## 三、全套 11-01 模块回退：map 失败（放弃）

原因：老的 gfx_top / gfx_sprtab / gfx_core 是成对演进的，跨版本接口不一致：
- tab_n / tab_fb / tab_spr / tab_key 未声明（老 top 期望新 spr_tab 端口）；
- 老 core 无 dbg_tag 端口（当前 top 连接）；
- 新老混搭时出现 t_ack_seen 双驱动等。
修接口成本高且引入新错误风险，不划算；改用"单模块回退 + 组合"策略。

## 四、当前 RTL 状态

- gfx_scanout.v：P4 版（tile 逻辑 + **窗口 13**，即本轮修复后的版本；备份 .bak-20261103-p4c / p4e）
- gfx_mem.v：**当前 P4 版**（构建组合位时临时换旧 mem，脚本已恢复）
- 构建位时的临时替换都由脚本自动恢复；磁盘上的 RTL 不会被留在中间状态。
