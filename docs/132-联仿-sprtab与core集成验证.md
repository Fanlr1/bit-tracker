# 132 · 联仿：gfx_sprtab(TRANSP flag) → gfx_core(OP_COPY_KEY_NB) 集成验证

> **结论先行**：`tb_tab_core2.v` 联仿 **PASS**。命令序列 `FILL,FILL,op6,op4` 两帧共 8 条全部正确；
> **op=6 精灵 rd2（背景读）= 0、写事务 = 8**；op=4 精灵 rd2 = 8、写 = 8；
> 像素级（按 wr_strb 逐字节落盘）op=6 的 10 个 key 像素全部保持背景 0x1082、54 个非 key 像素写入精灵色；
> op=4 的 54 个半透明像素 = 理论 mix565(f, 0x1082, 200)；done_cnt 到 4/8，error=0、clipped=0。
> **未发现 walker↔core 约定不一致**；`tb_tab_core2.v` 是新增文件，两块 RTL 我一行未改。

---

## 一、联仿组成与运行

| 项 | 内容 |
|---|---|
| 组成 | `gfx_sprtab` + `gfx_core` + `simple_dual_port_ram` + DDR 行为模型（65536×128 bit，地址 [19:4] 索引） |
| tb | `C:\fpga_work\gfx2\rtl-sim\tb_tab_core2.v`（工作区副本 `work/rtl-sim/tb_tab_core2.v`，日志 `work/rtl-sim/tc2_sim_log.txt`） |
| 配置 | n=2、fb=0x0800_0000、spr=0x0887_0000、key=0xF81F、fill_col=0x1082、alp=200 |
| 表项 | entry0：flag=0，新 (x=100,y=50)，旧 (40,60)；entry1：flag=1，新 (x=300,y=200)，旧 (310,210) |
| BRAM 预载 | `u_tab.tab_lo0[0]=(60<<16)|40`、`[1]=(210<<16)|310`（BRAM 无上电值，裸 initial 0 只会让擦除打在 (0,0)） |
| 帧数 | 2 帧。帧 1 = 冷缓存（首次绘制要读精灵源）；帧 2 = 稳态（源已在 BRAM 缓存，擦除落在帧 1 的绘制位置） |

```bash
cd /c/fpga_work/gfx2
/c/Users/25437/iverilog/bin/iverilog -o /tmp/tc2.vvp -I rtl/gfx \
  rtl/gfx/gfx_sprtab.v rtl/gfx/gfx_core.v rtl/simple_dual_port_ram.v rtl-sim/tb_tab_core2.v
/c/Users/25437/iverilog/bin/vvp /tmp/tc2.vvp
```

## 二、命令序列（断言通过）

| # | 帧 | op | dst | alpha | key | 说明 |
|---|---|---|---|---|---|---|
| cmd0 | 1 | 0 FILL | 0x0803_C050 | – | – | 擦 entry0 旧位置 (40,60) |
| cmd1 | 1 | 0 FILL | 0x080D_226C | – | – | 擦 entry1 旧位置 (310,210) |
| cmd2 | 1 | **6 COPY_KEY_NB** | 0x0803_20C8 | 0 | F81F | entry0 flag=0 → 不读背景、key 掩码 |
| cmd3 | 1 | **4 BLIT** | 0x080C_8258 | 200 | F81F | entry1 flag=1 → key+alpha 混合 |
| cmd4 | 2 | 0 FILL | 0x0803_20C8 | – | – | 擦帧1绘制位置（tab_lo0 回写生效） |
| cmd5 | 2 | 0 FILL | 0x080C_8258 | – | – | 同上 |
| cmd6 | 2 | **6 COPY_KEY_NB** | 0x0803_20C8 | 0 | F81F | 稳态 |
| cmd7 | 2 | **4 BLIT** | 0x080C_8258 | 200 | F81F | 稳态 |

测试还断言：alpha 字段 op6=0 / op4=200、两条绘制命令 key=0xF81F、擦除命令 dst 来自 tab_lo0、绘制命令 dst 来自表项高字；
`tab_lo0[0]` 回写为 `0x0032_0064`、`tab_lo0[1]` 回写为 `0x80C8_012C`（bit31 flag 保留）。

## 三、事务计数（每命令，DDR 模型统计）

| 命令 | op | rd1（源读）事务 | rd2（背景读）事务 | 写事务 | 写 beat |
|---|---|---|---|---|---|
| cmd0 擦 entry0 | 0 | 0 | 0 | 8 | 8（x 对齐，1 beat/行）|
| cmd1 擦 entry1 | 0 | 0 | 0 | 8 | 16（x=310 非 8 像素对齐，2 beat/行）|
| cmd2 绘 entry0 | **6** | **1**（冷缓存）| **0** ✅ | **8** | 16（x=100 同）|
| cmd3 绘 entry1 | 4 | 0（缓存命中）| **8** | 8 | 16 |
| cmd4/5 帧2 擦 | 0 | 0 | 0 | 8+8 | 16+16 |
| cmd6 帧2 绘 entry0 | **6** | **0**（缓存命中）| **0** ✅ | **8** | 16 |
| cmd7 帧2 绘 entry1 | 4 | 0（缓存命中）| **8** | 8 | 16 |

**每精灵合计（含擦除 8）**

| 精灵 | 帧 1（冷缓存） | 稳态（源缓存命中）| 与 Lead 期望 |
|---|---|---|---|
| flag=0 / op6（不透明）| 8 + 9 = **17** | 8 + 8 = **16** ✅ | 16 |
| flag=1 / op4（半透明）| 8 + 16 = **24** ✅ | 8 + 16 = **24** ✅ | 24 |

> ★ 两个偏差都要解释清楚（不是 bug）：
> 1. **冷缓存帧多 1 个源读事务**：第一次绘制要读精灵位图（32 beat 一拍突发，1 个事务）；之后 4000 个精灵共用同一 `spr` 地址 → 缓存命中，稳态是 0 源读。Lead 说的「16（不透明）」就是稳态。
> 2. **wr_beats=16 而不是 8**：Lead 给的 x=100 / x=300 不是 8 像素对齐（x%8=4），dst 字节偏移 = x*2 → 每行要写 32 B = 2 beat；**但仍是 1 个写事务/行（wr_txn=8 达标）**。我上一轮的 `tb_core_nb.v` 测试 A 已用对齐 dst 验证过每行 1 beat（8 事务/8 beat）。若业务要降到 1 beat/行，固件侧把 px 量化到 8 的倍数即可（8×8 精灵视觉无差别）。

## 四、像素正确性（DDR 模型按 wr_strb 逐字节落盘 + 参考内存逐字比对）

| 检查 | 结果 |
|---|---|
| op=6 矩形（0x0803_20C8）64 像素 | **64/64 正确**：10 个 key 像素 = 背景 0x1082（**未被写**）、54 个非 key 像素 = 精灵色 |
| op=4 矩形（0x080C_8258）64 像素 | **64/64 正确**：10 个 key 像素 = 背景 0x1082、54 个半透明像素 = 理论 `mix565(f, 0x1082, 200)`（tb 内用规格公式独立计算）|
| 擦除矩形 ER0 / ER1 | 64/64 = 0x1082（预置成 0xBEEF 脏数据后跑到 0x1082，证明擦除真的写了）|
| 4 个矩形覆盖的全部 DDR 字（1~2 word/行 × 8 行）| 与参考内存 **逐字相等**（矩形外字节保持原值 ⇒ 边界掩码正确）|
| 显式断言 | `op6 key pixels not written: 10/10 keep 1082 ; sprite pixels written: 54/54` |

参考内存只按**命令语义**（op/dst/w/h/stride/key/alpha）更新，不读 DUT 内部状态。

## 五、walker ↔ core 约定核对（重点）

| 约定 | 结论 |
|---|---|
| op 字段 | walker 写 `cmd_data[351:320]=6/4/0`；core 取 `[322:320]`（低 3 位）→ **一致**，4/6 均在 3 位内 |
| dst 字段 | walker `fb + y*4096 + x*2` 直接给 core，core 只做 FB pool 边界检查 → 一致，两条绘制均未触发 clipped |
| key 字段 | `[79:64]=0xF81F` → core 的 key 比较一致（op6 掩码命中 10/10 像素）|
| alpha 字段 | op4 写 `[103:96]=200`，op6 写 0；core 对 op6 不使用 alpha → 一致 |
| src 紧凑源 | `ss=16=w*2`、src 16B 对齐 → core 走 spx 紧凑路径，首绘 1 次读、之后 BRAM 缓存命中 → 一致（缓存命中已实测）|
| 表项位段 | walker 只解 `[31]=TRANSP`、`[26:16]=y`、`[15:0]=x`；tb 用 `(y<<16)|x` 写入（y<2048 时 bit31 与 bit30:27 均为 0，不干扰 flag）→ 一致 |
| 擦除历史 | walker 擦除用 tab_lo0（旧位置）、绘制后用 rec 回写 tab_lo0（含 flag）→ 实测第二帧擦除落在第一帧绘制位置，flag 保留 ✅ |

**未发现真 bug，RTL 一行未改。**

## 六、文件

| 文件 | 位置 |
|---|---|
| 集成 tb | `C:\fpga_work\gfx2\rtl-sim\tb_tab_core2.v`（工作区副本 `work/rtl-sim/tb_tab_core2.v`）|
| 联仿日志 | `work/rtl-sim/tc2_sim_log.txt` |
| 相关 RTL | `gfx_sprtab.v`（他人改，flag/op 分派）、`gfx_core.v`（我改，op6 掩码/不读背景）——本次均未改动 |

未跑 Efinity / map / pnr，未碰 COM10 / FTDI。
