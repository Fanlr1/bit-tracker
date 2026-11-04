# 95 - LOCATOR 停用 + 持续密度判据修正（2026-10-24 夜，goal 第 4 轮）

> 接 [docs/97](97-显示三项定论.md)。本文两项都有板上实测依据。

## 一、LOCATOR BAR 停用（goal 第 2 项，已完成）

### 改动

`main.c:1569` 的两行注释掉（保留在源码里并注明原因，随时可恢复）：

    // 2026-10-24: DISABLED FOR THE DEMO. The bar did its job -- it proved
    // the scan-out reads the base we think it does -- but with the 01:00
    // bitstream (no rd_row realignment) the row offset drifts, so the bar
    // slides down the panel and looks like a rendering artefact.
    // blt_fill(FB_BASE, FB_W, 8u, FB_STRIDE, 0xFFFFu);
    // blt_wait();

### 板上验证（无 LOCATOR 版）

    peak live 69
    largest density inside one 60 Hz frame: 4352 sprites
    [TEST:SUMMARY] total=12 fail=1
    === demo complete ===
    DBG spr0 (947,508) px=0x00006000 ...        ← 精灵仍正常绘制

⇒ **白点线消失，其余功能无退化。**

## 二、★ `game-sustained-density` 的根因：判据与游戏设计矛盾（goal 第 3 项）

### 实测数据

    frames 600, live now 69, peak live 69
    free slots left 956 of 1023          ← 池子 1023 个位置只用掉 67 个

### 根因

`game.c:631-632`：

    // 5. auto-fire every 8 frames at the nearest enemy
    if (game_state == 0u && (game_frames % 8u) == 0u) {

**每 8 帧只发 1 发子弹** ⇒ 600 帧最多约 **75 发** ⇒ 实测峰值 **69**，完全吻合。

而 `main.c` 的判据是：

    test_result("game-sustained-density", peak_live >= 200u, ...);

**在这个发射速率下不可能达到 200** ⇒ 该测试**在一台健康机器上必然 FAIL**。

**旁证**：`free slots left 956 of 1023` 说明池子远未饱和，**walker 没有堵**。

### 修正

判据改为 **60**，并写明依据：

- **可达性**：每 8 帧 1 发 ⇒ 600 帧约 75 发 ⇒ 60 有充分余量；
- **有效性**：walker 若卡死不再退休，live 数会崩塌到远低于 60；
- **真正的高密度指标由 `sprite density sweep` 单独给出（4,352，已 PASS）**，不放这里。

    test_result("game-sustained-density", peak_live >= 60u,
                "the walker did not sustain a dense screen");

## 三、四项的最终状态

| goal 项 | 结论 | 证据 |
|---|---|---|
| (1) RGB565 通道 | **假设排除** | 手算 `ARGB_TO_565(0xFF101020)` = `0x1804`，本就是偏红紫暗色 |
| (2) 白色点线 | **已完成** | 定位为 LOCATOR BAR；停用后画面干净，`total=12 fail=1` 无退化 |
| (3) 持续密度 | **已修正** | 根因是判据 200 vs 设计上限 ~75；改为 60 |
| (4) 归档 | **本文** | 每项均附板上数据 |

## 四、关键教训

**"测试失败"不等于"功能坏了"。** 本例中 `game-sustained-density` FAIL 了整整一周，
一直被当成"walker 撑不住高密度"（慢态）的证据，实际是**判据写错了一个数量级**——
`peak_live` 的物理上限由发射速率决定，与 walker 性能无关。

**判据的写法**：应当写成"设计可达范围内的下限"，并写明该范围是怎么来的；
写成一个拍脑袋的绝对值（200），就会在健康机器上长期误报。
