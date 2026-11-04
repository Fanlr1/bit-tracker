# 145 · 最终位清单：TILE 演示位 + RASTER 候选（2026-11-03 16:45）

## 一、TILE 位（TILE_MODE=1，tile 帧存布局）

| 文件（work/backup/p4-20261103/）| md5 | 配置 | slack 摘要 | 用途 |
|---|---|---|---|---|
| gfx2_system.TILE-p4-currentmem-seed28.bit | 61f697e87a1586fa237d52d5b400b060 | P4 tile scanout + 当前 mem | core 1.221 / sdram 0.278 / rx 0.235 / tx 0.271 / pix 0.998 | 首选：与 seed28 raster 同源，改动最小 |
| gfx2_system.TILE-p4-oldmem-seed26.bit | 548bf0b27ee07dabd18fef32ab18a16a | P4 tile scanout + 旧 mem（pre-mem-pipeline）| core 1.054 / sdram 0.412 / rx 0.339 / tx 0.421 / pix 0.864 | "上一个回退版本 + tile"，启动余量最大 |

共同点：map+pnr+pgm PASS；都是 tile 帧存布局。固件必须 CPU 直写 tile 布局（tools/png_to_tile.py 生成 fb_tile.bin，地址 = fb + (y>>3)*0x8000 + (x>>3)*128 + (y&7)*16，每行 4×32bit），或只跑 walker 的 tile 精灵命令；不能在同帧再发 raster 引擎命令画背景/HUD。

## 二、RASTER 候选（游戏正常画面用）

| 文件 | md5 | slack 摘要 | 已知上板 |
|---|---|---|---|
| gfx2_system.RASTER-p4win13-seed22.bit | 4cb54578e18d21dcae963ced37f3fd27 | core 0.907 / sdram 0.312 / rx 0.317 / tx 0.272 / pix 0.628 | 新，未测 |
| gfx2_system.RASTER-win13-seed28.bit | 83859fa7cdf4739b3e0672cb93140ff9 | core 0.926 / sdram 0.259 / rx 0.276 / tx 0.201 / pix 0.964 | 已测：启动 OK，idle 0.9 行/帧 |
| gfx2_system.RASTER-win13-seed25.bit | 5c6e71efcea74d8001a31b75ffffb6f1 | core 0.794 / sdram 0.405 / rx 0.199 / tx 0.201 / pix 0.716 | 未测 |

注意：gfx2_system.RASTER-p4win13-oldmem-seed28.bit（组合位，win13+旧 mem）上板 idle 11 行/帧，不要用于交付。

## 三、结论与建议

- raster 欠载残余（0.9-4.5 行/帧）来自 11-02 的 mem-pipeline 改动（主因）+ 窗口/布线抽签，不属于单点 RTL bug；golden 位仍是 raster 交付的稳妥选择。
- TILE 位用于演示 tile 能力：先静态图（CPU 直写 tile 布局）验证 scanout，再跑 walker tile 精灵。
- RTL 磁盘状态（构建后已恢复）：system_top = raster 默认（无 TILE_MODE 行），gfx_mem = 当前版，gfx_scanout = P4 win13 版（tile 逻辑在内）。
- 构建脚本（工作区 work/）：_build_final_bits.sh（本轮）、_build_tile_and_raster.sh、_build_revert_ab.sh、_build_mem_revert.sh、_build_comboc.sh。运行 EFinity 前确保无其它 efx 进程；被 kill 的构建会留下锁，重跑一次 _efx.sh map 即可恢复。
