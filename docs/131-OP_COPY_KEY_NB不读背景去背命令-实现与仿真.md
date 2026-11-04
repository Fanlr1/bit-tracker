# 131 · OP_COPY_KEY_NB（不读背景的 key 去背）引擎实现与仿真

> **结论先行**：`gfx_core.v` 已加入 `OP_COPY_KEY_NB = 3'd6`：key 像素**不写**（wr_strb=0）、**不读背景**（rd2_req 恒 0）。
> 新的 `tb_core_nb.v` 5 项用例全部 PASS。8×8 精灵实测：**1 源读事务（缓存命中时 0）+ 8 写事务，rd2 = 0**（doc 130 目标 9 达成）。
> 未跑 Efinity / map / pnr / 上板（Lead 负责）；`gfx_sprtab.v` 的 op=6 命令生成由他人并行修改，我未触碰。

---

## 一、改动清单（唯一文件：`C:\fpga_work\gfx2\rtl\gfx\gfx_core.v`）

备份：`gfx_core.v.bak-20261102-nbkey`（同目录，diff 见 `work/rtl-sim/gfx_core_nb.diff`）

| # | 行（改后） | 改动 | 目的 |
|---|---|---|---|
| 1 | 17–25 | 文件头注释新增「OP CODES」段 | 记录 0–6 语义，写明 6 号不读背景 |
| 2 | 91–92 | `localparam OP_COPY_KEY_NB = 3'd6;` | 新增命令码 |
| 3 | 189–192 | `use_bg` 上方注释 | 明确 6 号**故意不在** use_bg 列表 → 不进 S_RB_REQ |
| 4 | 273 | `pix_op`：`OP_COPY_KEY_NB: pix_op = f;` | 不引用 b（bpx 此时是 X，避免污染；值本身无所谓，key 像素被掩掉） |
| 5 | 160–165 | `reg kmask [0:127];` + `wire key_nb = (op == OP_COPY_KEY_NB);` | 每像素 1 bit「该像素命中 key，必须不写」 |
| 6 | 312–316 | S_PIX_M 里同时算 kmask：`ok_q[kc] & key_nb & (fg_q[kc] == key)` | 比较放在**已寄存的 S_PIX_M 拍**，不压 `opx → wr_mask` 组合路径 |
| 7 | 328–331 | `wr_mask = (in_range && !kmask[...]) ? 2'b11 : 0` | 把 key 掩码并入原有逐字节写掩码（原掩码只管边界裁剪） |

**时序依据（读代码确认，非猜测）**
- S_PIX_R 锁存 fg_q/bg_q/ok_q → S_PIX_M 写 opx 与 kmask → 最后一组进 S_WR_REQ → S_WR_DAT 才用 wr_data/wr_strb。
- 即 `wr_strb` 被下游采样时，opx/kmask 早已在本拍之前全部写好，组合读取安全。
- 其它 op 的 `key_nb = 0` ⇒ kmask 恒 0 ⇒ **写掩码与旧行为逐位相同**（回归见测试 B/E）。

**资源/时序代价**：+128 FF（kmask 数组）+ 8 个 16 bit 比较器放在已寄存级；`wr_mask` 输出路径只多一级「kmask 读 + 与门」。未跑综合，LUT 估计 <100。

---

## 二、仿真环境与命令

iverilog：`C:\Users\25437\iverilog\bin\iverilog.exe`（vvp 秒级）

```bash
cd /c/fpga_work/gfx2
/c/Users/25437/iverilog/bin/iverilog -o /tmp/nb.vvp -I rtl/gfx \
    rtl/gfx/gfx_core.v rtl/simple_dual_port_ram.v rtl-sim/tb_core_nb.v
/c/Users/25437/iverilog/bin/vvp /tmp/nb.vvp
```

tb：`rtl-sim/tb_core_nb.v`（工作区副本 `work/rtl-sim/tb_core_nb.v`，日志 `work/rtl-sim/nb_sim_log.txt`）
- DDR 行为模型：4096×128 bit（地址 [15:4] 索引），rd1/rd2 在 gnt 后逐拍返回数据，写模型**按 wr_strb 逐字节落盘**并记录每个写 beat（addr/data/strb）。
- 参考内存 `exp_mem` 只按**命令语义**更新（不抄 RTL 内部状态），逐字比对。
- 每个写 beat 的每个字节都按「是否落在目的矩形内 / 是否 key 像素」独立算期望 strb 与数据并比对。

## 三、仿真结果（全部 PASS）

```
=== gfx_core OP_COPY_KEY_NB (6) test ===
sprite 8x8, 10 key pixels, dst stride 128, src stride 16 (compact)

[A] op=6 COPY_KEY_NB  8x8  dst=08001000 (aligned)
  A op6 aligned: rd1_txn=1 rd2_txn=0 rd2_req_cycles=0 wr_txn=8 wr_beats_logged=8
  wr beat addr=08001000 strb=ff3c data=0871086108510841f81f08210811f81f
  wr beat addr=08001080 strb=3fff data=f81f0961095109410931092109110901
  wr beat addr=08001100 strb=ffcf data=0a710a610a510a410a31f81f0a110a01
  wr beat addr=08001180 strb=ff3f data=0b710b610b510b41f81f0b210b110b01
  wr beat addr=08001200 strb=fcff data=0c710c610c51f81f0c310c210c110c01
  wr beat addr=08001280 strb=f3ff data=0d710d61f81f0d410d310d210d110d01
  wr beat addr=08001300 strb=fff3 data=0e710e610e510e410e310e21f81f0e01
  wr beat addr=08001380 strb=3ffc data=f81f0f610f510f410f310f210f11f81f
  PASS

[B] op=5 COPY_KEY     8x8  dst=08002000 (aligned, src in cache)
  B op5 aligned: rd1_txn=0 rd2_txn=8 rd2_req_cycles=8 wr_txn=8 wr_beats_logged=8
  PASS
[C] op=6 COPY_KEY_NB  8x8  dst=08003006 (+6 bytes, misaligned)
  C op6 misaligned: rd1_txn=0 rd2_txn=0 rd2_req_cycles=0 wr_txn=8 wr_beats_logged=16
  PASS
[D] op=6 COPY_KEY_NB  dst=07000000 (outside framebuffer pool)
  D op6 out-of-range: rd1_txn=0 rd2_txn=0 rd2_req_cycles=0 wr_txn=0 wr_beats_logged=0
  PASS
[E] op=0 FILL         8x8  dst=08004000 colour=1234
  E op0 fill: rd1_txn=0 rd2_txn=0 rd2_req_cycles=0 wr_txn=8 wr_beats_logged=8
  PASS

=== RESULT: PASS (all checks) ===
```

### 3.1 任务要求的 4 点验证

| 要求 | 结果 | 证据 |
|---|---|---|
| ① 非 key 像素正确写入 | PASS | A：8 行 strb 的非零位与 data 均等于位图 fg 值；参考内存逐字相等 |
| ② **key 像素没有被写** | PASS | A：10 个 key 像素对应字节 strb 恰为 0（如行0 `ff3c`：bit0,1 与 bit6,7 = 0，对应 c=0/c=3 两个 key 像素）；参考内存该处保持预置值 |
| ③ **rd2_req 全程为 0** | PASS | A/C/D 的 `rd2_req_cycles=0`（tb 逐拍计数，不是只看握手）；B 对照为 8 |
| ④ 边界裁剪仍有效 | PASS | C：dst=+6 字节（doff=3，每行 2 beat），矩形外字节 strb 全 0（首 beat 高 6 位、次 beat 高 10 位为 0），矩形内且非 key 的字节写对；D：dst 越出 FB pool → `clipped=1`、总线零活动 |

补充：C 还证明**同一 beat 内既有 key 掩码又有边界掩码时两者正确叠加**（如行2 `f3c0`）。
D 命令返回后 `done_cnt` +1、无事务，说明 OOB 拒绝路径未被改动。

### 3.2 现有 OP_COPY_KEY(5) 回归（任务额外要求）

B 用同一精灵、同一 dst stride、缓存命中条件跑 op=5：
- 事务：`rd1=0（缓存命中）+ rd2=8 + wr=8` —— 与 doc 130 契约「COPY_KEY 8×8 读 9 写 8」中扣掉 1 次源读后完全一致；
- key 像素：写回的数据是**背景旧值**（日志里 `b000/b003/...` 即预置的 dst 内容），参考内存比对**未变化** —— 读改写语义原样保留；
- 说明新增 kmask 对 op≠6 无影响。

E 顺带回归 FILL：8 个写事务、strb 全 `ffff`、数据全 `1234`，普通写路径未变。

---

## 四、与 doc 130 估算的对照

| 命令（8×8 紧凑源） | 仿真实测事务 | doc 130 模型 |
|---|---|---|
| 擦除 FILL | 8 写 | 8 |
| 绘制 **OP_COPY_KEY_NB**（冷缓存） | 1 源读 + 8 写 = **9** | 9 |
| 绘制 **OP_COPY_KEY_NB**（源缓存命中，4000 精灵同一位图即此情形） | **0 源读 + 8 写 = 8** | — |
| 绘制 BLIT（对照） | 8 背景读 + 8 写 = 16 | 16 |

⇒ 每精灵 **16（命中）～17（冷）** 事务，doc 130 的 17 → 按 286 ns/事务估算 ≈ **18.3–19.4 ms/帧 ≈ 52–55 fps**（未含其它开销，仅事务模型估算；与 doc 130 的「全不透明 51 fps」一致）。

**dst 对齐说明（易误判，已实测）**：dst 非 8 像素对齐时每行写变成 **1 个 32 B 突发（2 beat）**，仍是**1 个事务**（C 实测 `wr_txn=8, wr_beats=16`）。所以 doc 130 的事务计数对任意 x 位置都成立，但每事务多 1 个数据 beat。

---

## 五、还没做的 / 给 Lead 的集成注意事项

1. **不要用我改的文件跑 pnr 前先确认综合资源**：新增 128 FF + 少量 LUT，若 Ti60 时序/面积紧张，可改成「wr_mask 直接比较 opx==key」（省 128 FF、但输出路径多 ~3 级逻辑）——两者我都评估过，当前选 FF 是为保时序。
2. **walker 侧不用我改**：`gfx_sprtab.v` 已由并行成员改成 flag 0→op 6、flag 1→op 4（18:41，`tb_sprtab.v` PASS）。但**二者的仿真没有串联跑过**：建议上板前做一次 sprttab→core 的联仿（或直接信任两块各自的自检 + 板测）。
3. **语义差异**：op 6 **不读背景**，所以它不能用于半透明精灵（那些必须走 op 4）；walker 的 TRANSP flag 必须正确分派。
4. **软件/驱动**：R_OP 寄存器写 6 即可，无白名单；cmd_data[351:320]=6。alpha 字段对 op 6 无意义。
5. **16×16 精灵**：仍受 compact 源 128 像素上限限制（走非紧凑路径），本次没有改；op 6 在非紧凑路径同样不读背景（S_RS_DAT 后直接 S_PIX_R）。
6. **transaction 数不变的部分**：擦除 FILL 每精灵仍 8 个事务；要再往上提 fps 需做 doc 130 的 §4（脏矩形/擦除合并）或 §4.4（每事务周期优化）。
7. **未验证项**：16×16、非紧凑源、dst 与 FB pool 上边界部分越界、多命令背靠背的极端时序 —— 这些走的是未改动的旧路径，风险低，但严格起见可让联仿覆盖。
8. 我的改动**未触碰**：gfx_regs.v / gfx_top.v / gfx_sprtab.v / 任何 .xml / 任何 bitstream；未跑 Efinity、未碰串口/FTDI。

---

## 六、文件位置

| 文件 | 位置 |
|---|---|
| RTL（已改） | `C:\fpga_work\gfx2\rtl\gfx\gfx_core.v` |
| RTL 备份 | `…\gfx\gfx_core.v.bak-20261102-nbkey` |
| 新 tb | `C:\fpga_work\gfx2\rtl-sim\tb_core_nb.v`（工作区副本 `work/rtl-sim/tb_core_nb.v`） |
| 仿真日志 | `work/rtl-sim/nb_sim_log.txt` |
| RTL diff | `work/rtl-sim/gfx_core_nb.diff` |
