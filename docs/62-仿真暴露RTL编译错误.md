# 62 - 仿真从未覆盖当前 RTL：一个前向引用错误（2026-10-14 凌晨）

> **接 docs/61。** 本文记录"板子卡在 sprite copy"之后的第一次仿真介入。
> **一句话**：**当前比特流里的 RTL 根本通不过 vlog** —— `bitblt_axi_slave.v` 有 3 处前向引用
> （iverilog 容忍、Questa 拒绝），所以**此前所有板上调试所依据的 RTL 从未被仿真覆盖过**。
> 修掉这三处之后，顶层仿真第一次跑起来，并立刻暴露出 1 个真实失败。

## 一、根本发现：RTL 编译不过

| 信号 | 使用处 | 声明处 | 后果 |
|---|---|---|---|
| `wr_go` | L296（FSM 的 IDLE 分支）| L314 | vlog-2730 未定义 |
| `rd_got` | L440（`axi_arready` 赋值）| L519 | vlog-2730 未定义 |
| `rvalid_r` | L440（同上）| L520 | vlog-2730 未定义 |

**修复**：三个声明上移到 L276 附近（`awreadyReg/arreadyReg` 之后、任何使用之前），逻辑一字未改。

**⚠️ 这条记录反过来解释了很多事**：
- 文件自己在 L327-329 就写着"Questa rejects a forward reference that iverilog accepts" —— 同一个坑又踩了一次；
- **Efinity 综合链容忍它**（板子能跑），**Questa 不容忍**（仿真跑不起来）⇒ 两边行为分叉；
- 所以"仿真全绿"与"板上挂死"从来不是矛盾：**仿真跑的是另一份 RTL**。

## 二、修复后顶层仿真的真实结果

命令（注意 RTL 在 `src/`、tb 在 `tb/`）：

```powershell
& 'scripts\sim.ps1' -Top tb_bitblt_top `
  -Files 'src/bitblt_top.v src/bitblt_axi_slave.v src/bitblt_addr_gen.v src/bitblt_pixel_engine.v src/bitblt_dma_rd.v src/bitblt_dma_wr.v src/bitblt_pulse_gen.v src/bitblt_monitor.v src/bitblt_sprite_walker.v src/bitblt_sprite_state.v src/alpha_blend.v tb/tb_bitblt_top.v' `
  -PrimLibs 'C:\Efinity\2026.1\sim_models\verilog\efx_dsp48.v'
```

| 项 | 结果 |
|---|---|
| vlog | **Errors: 0**（修复前 6 个错误）|
| 仿真 | 跑到 `$finish`，t=45466 ns |
| 结论 | `RESULT: FAILED with 1 error(s)` |
| 唯一失败 | `FAIL blend value: got 10001f00 want 10xxxxxx (fg=10005a02 bg=xxxxxxxx)` |

**blend 失败的性质（未完）**：期望值里 `bg=xxxxxxxx` ⇒ 测试台自己的参考背景是 x，
即**用例本身没有把背景写进去**（疑似用例缺陷，待确认），但它真实存在且此前无人见过。

## 三、板上卡点：仿真给了否定证据

把 tb 的 P4 用例从 **8×2（1 个 burst）** 改成 **64×64（16 KB = 32 个 burst）** 后：

| 观察 | 值 | 含义 |
|---|---|---|
| rd0 发出的 AR | **99** = 3×(1 描述符 + 32 burst) | 源引擎**确实**按 compact_src 一次性读完 16 KB |
| 是否挂死 | **没有**，正常完成 | **数据通路逻辑是通的** |
| 总时长 | 100 µs 仿真时间 | 正常推进 |

⇒ **板上卡死来自仿真里不存在的因素**，按嫌疑排序：

1. **DDR 背压**：真实 DDR 不会立刻给数据，FIFO 会满 ⇒ `m_axi_rready` 拉低；
   而 `Axi_Mux` 要求"一个 burst 一旦开始必须收完"（docs/61 的教训）；
2. **FIFO 满导致 burst 中途撤 rready** ⇒ 跨模块死锁（tb 的读模型是**模式生成器**，
   永远立即返回，**从不施加背压**，所以这条路径在仿真里根本不存在）；
3. 长 burst 下的通道仲裁（`r_cnl_num` 卡住，docs/61 现场观测到过）。

## 四、下一步（建议顺序）

| # | 动作 | 为什么 |
|---|---|---|
| 1 | **给 tb 的 axi_rd_slave 加背压/间隙**（每 beat 随机延迟、burst 间停顿）| 复现"FIFO 满 ⇒ 撤 rready"路径，这是唯一还没被仿真覆盖的机制 |
| 2 | 同时确认 blend 用例的 `bg` 是否为用例缺陷 | 该失败要么是真 bug，要么是假警报，不能留着 |
| 3 | 用仿真验证修复后再 clean build + 上板 | 避免再拿"没仿真过的 RTL"上板 |

## 五、本轮改动清单

| 文件 | 改动 | 备份 |
|---|---|---|
| `rtl/bitblt_axi_slave.v` | 3 处前向引用声明上移（逻辑不变）| `git diff` 可查；原文件已同步 `C:\fpga_work\sys\rtl` |
| `tb/tb_bitblt_top.v` | P4 用例 8×2 → 64×64（复现板上大矩形）| 同上 |
| `work/bitblt_demo/src/bitblt.h` | `blt_wait` 加超时（2×10^7 周期）+ 卡点落探针 32/33/34 | `.bak-20261014-before-waittimeout` |
| `work/bitblt_demo/src/main.c` | sprite 段加探针 40-43 | `.bak-20261014-before-waittimeout` |

**⚠️ 烧写区（`C:\fpga_work`）里的应用源码已改但未重新综合上板**：
下一次上板前必须走 `build-all.ps1` + `flash-app.bat` + `reflash.bat`。

## 六、可复现命令

```powershell
# 仿真（先 sync，注意 src/ 与 tb/ 前缀）
& 'scripts\sync.ps1' -Source '.'
& 'scripts\sim.ps1' -Top tb_bitblt_top -Files '<如上>' -PrimLibs '<efx_dsp48.v>'

# 单看 vlog 是否能过（最快的 RTL 体检，10 秒）
& 'C:\altera_pro\26.1.1\questa_fse\win64\vlog.exe' src/bitblt_axi_slave.v   # 在 C:\fpga_work 下
```
