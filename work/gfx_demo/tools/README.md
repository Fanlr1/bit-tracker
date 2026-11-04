# gfx_demo 精灵生成工具（assets.h 流水线）

> 作者：art-spr（2026-11-01）。目标：**assets.h 只由生成器产出，不手改**。

## 三件套

| 文件 | 作用 | 何时跑 |
|---|---|---|
| `gen_assets_dark.py` | **唯一美术源**：16 色暗黑邪典调色板 + 全部 16 张精灵的绘制代码；写入 `src/assets.h`，并出预览图 | 改美术时 |
| `preview_assets.py` | **从 assets.h 反向解码**渲染（按引擎的真实 RGB565 调色板、4bpp 半字节顺序），用来确认“板上看到的”= “画出来的” | 生成后必跑 |
| `verify_assets.py` | **完整性闸门**：数组名/维度/数量、调色板 16 色且 index0=0xF81F、每张精灵非空、64×64 填充率不足 25% 直接 FAIL | 生成后 / 提交前 |

## 常用命令

```bash
cd work/gfx_demo/tools
C:/Users/25437/anaconda3/python.exe gen_assets_dark.py      # 生成 assets.h + 预览
C:/Users/25437/anaconda3/python.exe verify_assets.py        # 必须 ASSET-VERIFY OK
C:/Users/25437/anaconda3/python.exe preview_assets.py       # 反向解码，确认不是空图
cd ../../game-board && pwsh -NoProfile -File build-fw.ps1   # 必须 BUILD-FW OK
```

## 不变量（改了会被 game.h 打断）

- `asset_pal[16]`，**index 0 = 透明键 0xF81F**（`G_TRANS`）
- `asset16_idx[9][128]` / `asset32_idx[5][512]` / `asset64_idx[2][2048]`
- `#define ASSET16_N 9 / ASSET32_N 5 / ASSET64_N 2` 与 `A16_*/A32_*/A64_*` 名字、索引不变
- 4bpp 打包：**高半字节=偶像素（左）**，低半字节=奇像素，逐行、无行填充
- 精灵在屏上是 1:1 原生尺寸：玩家 64×64、精英 32×32、杂兵/道具 16×16

## 调色板（16 色，除 0 外 RGB565 精确可表示）

| # | 用途 | # | 用途 |
|---|---|---|---|
| 0 | 透明键 0xF81F | 8 | 血红（亮）|
| 1 | 虚空黑（描边/兜帽内）| 9 | 墨绿（暗）|
| 2 | 暗紫（阴影）| 10 | 毒绿（亮）|
| 3 | 紫（袍主体）| 11 | 琥珀（木/金）|
| 4 | 亮紫（高光）| 12 | 金（符文/皇冠）|
| 5 | 骨白 | 13 | 钢灰 |
| 6 | 骨暗（旧骨/皮革）| 14 | 月光边缘光 |
| 7 | 血暗 | 15 | 秘法青（眼/魔法）|

## 预览产物（`work/gfx_demo/assets-preview/`）

| 文件 | 内容 |
|---|---|
| `preview-16/32/64.png` | 按尺寸分组的放大预览 |
| `preview-dark-all.png` | 全 16 张总览（黑底棋盘=透明）|
| `preview-game.png` | **1920×1080 实景合成帧**：真实背景 + 玩家/杂兵/精英/宝石/刀/球，用于判断“远看能不能分辨”|
| `preview-current.png` | 由 `preview_assets.py` 从 assets.h 反解出来的核对图 |
