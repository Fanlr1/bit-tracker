# 99 - 真根因：帧缓冲越界判定只覆盖 front buffer，双缓冲的 back 绘制被静默丢弃

> 接 [docs/98](98-bisect结果.md)。本文记录 2026-10-25 发现的真正根因，
> 并说明为什么之前几次修复（`rd_row` 归零、`drain`、`o_blanking`）全都治错了地方。

## 一、板上直接证据

`work/logs/drain1.txt` 里的寄存器回读：

    DBG cfg fb=0x08000000 size=0x04380780 cfg=0x00011000 oob=0x00000000 st=0x00000000
    DBG cfg fb=0x08438000 size=0x04380780 cfg=0x00011000 oob=0x083e8db8 st=0x00000008

解码：`size=0x04380780` ⇒ height=1080、width=1920；`cfg=0x00011000` ⇒ enable=1、stride=4096。**全部正确。**

**但第二行 `oob=0x083e8db8` 非零** —— 有一笔 blit 被判越界。

`0x083e8db8 - 0x08000000 = 0x3E8DB8`，除以 stride 4096 = **第 1000 行**。
这是 **buf[0] 的第 1000 行**，一个完全合法的帧缓冲地址。

## 二、根因

`bitblt_top.v` 的越界范围（改前）：

    wire [31:0] fb_end_addr = reg_fb_base
                            + ({16'd0, reg_fb_height} * {16'd0, reg_fb_stride});
    .fb_start (reg_fb_base)

⇒ **范围只覆盖"当前正在扫描输出的那一块"**。

而双缓冲的绘制方式是：

    back  = buf[(f + 1) & 1];   // 画到这个
    front = buf[f & 1];         // 显示这个
    blt_set_fb(front, ...);     // fb_base = front
    blt_sprite_clipped(..., back, ...);   // 却画 back

**画 back、显示 front** ⇒ 画 back 的每一笔都落在 `[front, front+4.4MB)` 之外 ⇒
**全部被 `addr_gen` 的 oob 路径拒绝**，`addr_oob` 锁存，blit 什么也没做，
**而 CPU 依然认为画成功了**。

## 三、这解释了什么

| 现象 | 解释 |
|---|---|
| "上半屏旧图案 + 下半屏动画" | 被拒的行保留旧内容，落进窗口的行才是新内容 |
| 三帧画面完全一致 | 一旦 `fb_base` 定了，被拒/被接受的行集合就是固定的 |
| `copy-readback` 有时 0 错 | 它测的是单缓冲内的 copy，不跨 front/back |
| 之前的修复全无效 | 它们都在改"行号"和"FIFO"，而数据根本没写进去 |

## 四、修复

    localparam [31:0] FB_POOL_BASE = 32'h0800_0000;
    wire [31:0] frame_bytes   = {16'd0, reg_fb_height} * {16'd0, reg_fb_stride};
    wire [31:0] fb_start_addr = FB_POOL_BASE;
    wire [31:0] fb_end_addr   = FB_POOL_BASE + (frame_bytes << 1);

    .fb_start (fb_start_addr)

⇒ 边界覆盖**整个池**（buf[0] 与 buf[1] 两块连续 4.4 MB），画 back 不再被误判。

## 五、为什么之前几次修复都治错了地方

| 修复 | 当时以为的问题 | 实际 |
|---|---|---|
| `rd_row` / `px_in_line` 每帧归零 | 行号漂移 | 行号没问题，是**数据没写进去** |
| FIFO 消隐期排空（drain） | 管道残留旧像素 | 同上 |
| `o_blanking = ~v_active` | 翻页落在帧中间 | 这个是对的，但它不是这里的原因 |
| 10-24 全量 | —— | 引入了 959,128 的 copy-readback 回归（B/C 两处） |

**教训**：现象是"屏幕某几块是旧的"，直接推"行号错/管道残留"很自然，
但**真正该先查的是"那些绘制到底有没有发生"**——`addr_oob` 寄存器就在那里，
读一次就能看见。这个词在 monitor 和 status 里都有。

## 六、验证结果（2026-10-25 板上实测）

| 检查项 | 修复前 | 修复后 |
|---|---|---|
| `addr_oob` 寄存器回读 | `0x083e8db8` | **`0x00000000`** |
| 新增断言 `no-out-of-bounds` | —— | **PASS** |
| `copy-readback` | 0 错（单缓冲内测不出）| **0 错** |
| `DBG spr0` | `0x6000`（有画）| `0x6000` |

**新增断言**（`main.c`，紧跟在 `engine-fill-no-error` 之后）：

    test_result("no-out-of-bounds", blt_oob_addr() == 0u,
                "a blit was rejected as out of bounds (see oob_addr)");

**冷启动后的完整一轮记录（2026-10-25 18:2x）**：

    [TEST:PASS] no-out-of-bounds
      mismatching pixels : 0
    [TEST:SUMMARY] total=13 fail=0
    === demo complete ===

⇒ **13 项全 PASS，demo 完整跑完。**（比之前 12 项多出来的就是本次新增的 `no-out-of-bounds`。）

**该轮的寄存器回读**：`DBG cfg fb=0x08438000 ... oob=0x00000000`。

**比特流存档**：`work/bitstreams/bitblt_system-8192-oobfix-13of13-20261025.bit`（md5 `3b07a69513a6f84d850ea6b1e03433c4`）。

**注意**：同一轮的第二遍循环里仍会出现 `DBG wto st=00000001`——那是慢态（见第七节），与本次修复无关；
第一遍 13/13 已完整跑完。

**这个断言补上了一个存在两天的测试漏洞**：`blt_oob_addr()` 接口早就有，但没有任何测试读它，
所以"每一笔 back-buffer 绘制都被静默丢弃"这件事，在屏幕上表现为画面残缺，
而 11 项测试全程 PASS。现在若回退到旧范围，它会立刻 FAIL。

## 七、仍未解决

**慢态**（`walker` 卡 `S_RUN`、`STATUS` 的 bit0 不落、日志出现 `DBG wto st=00000001`）是**独立问题**，
见 [docs/92](92-慢态尝试与未确证.md)。它会让某一轮 demo 跑不完测试项，但不影响 OOB 修复的正确性。

