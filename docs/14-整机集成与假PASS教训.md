# 整机集成与「假 PASS」教训

> 日期：2026-10-06
> 结论：✅ **整机（SoC + DDR3 + Axi_Mux + BitBlt + HDMI）第一次完整综合通过**
> ⚠️ 但过程暴露了一个**比所有具体 bug 都危险的坑**：**综合 PASS 不等于设计正确**

---

## 一、整机综合结果（修复后，实测）

```
   map :	PASS
exit code: 0

### Resource Summary ###
EFX_LUT4   :  10227
EFX_DSP48  :     17
EFX_DSP24  :     12
EFX_FF     :   9897
EFX_SRL8   :    727
EFX_RAM10  :     65
```

| 资源 | 用量 | Ti60F225 总量 | **占比** |
|---|---|---|---|
| **LUT4** | **10,227** | 60,800 | **16.8%** |
| **FF** | **9,897** | ~60,800 | 16.3% |
| **DSP48** | **17** | 160 | **10.6%** |
| **RAM10** | **65** | 256 | **25.4%** |
| SRL8 | 727 | 14,720 | 4.9% |

**⇒ 整机只占 LUT 的 16.8%、DSP 的 10.6%。资源完全不是瓶颈。**

### 分层明细

| 模块 | FF | LUT | DSP |
|---|---|---|---|
| `u_sapphire_soc:soc` | 4193 | 4423 | 4 |
| `u_ddr3_top:ddr3_top` | 1876 | 2162 | 0 |
| **`u_axi_mux:Axi_Mux`** | 54 | 337 | 0 |
| **`u_bitblt:bitblt_top`** | **1288** | **1495** | **25** |
| ├ `u_regs:bitblt_axi_slave` | 411 | 394 | 0 |
| ├ `u_addr:bitblt_addr_gen` | 77 | 141 | 1 |
| ├ `u_rd_src:bitblt_dma_rd` | 193 | 116 | 0 |
| ├ `u_rd_dst:bitblt_dma_rd` | 65 | 105 | 0 |
| ├ **`u_px:bitblt_pixel_engine`** | **454** | **574** | **24** |
| └ `u_wr:bitblt_dma_wr` | 83 | 160 | 0 |
| `u_video_timing:color_bar_rgb` | 42 | 86 | 0 |
| `u_dvi_encoder:dvi_encoder` | 42 | 73 | 0 |

### 与综合前推算的对照（推算方法可直接复用）

| 资源 | 推算（官方实测 + 我们实测）| 实测 | 偏差 |
|---|---|---|---|
| LUT4 | 10,456 | **10,227** | −2.2% |
| DSP48 | 17 | **17** | **0%** |
| FF | 9,764 | **9,897** | +1.4% |
| RAM | 65 | **65** | **0%** |

**⇒ 精度 2% 以内。以后估算资源可以直接用「官方 demo 实测 + 自研模块实测」相加。**

---

## 二、⚠️ 核心教训：**「map : PASS」不代表设计正确**

### 现象

第一次完整综合**报 PASS、exit 0**，但资源数字异常：

```
修复前：
EFX_LUT4   :  7236      ← 应为 ~10,227
EFX_DSP48  :     5      ← 应为 17

分层：
+u_bitblt:bitblt_top     437 FF   481 LUT    1 DSP    ← 应为 1288 / 1495 / 25
 +u_pulse:bitblt_pulse_gen  1 FF     1 LUT
 +u_rd_src:bitblt_dma_rd    1 FF     1 LUT             ← 状态机只剩 1 位
 +u_rd_dst:bitblt_dma_rd    1 FF     7 LUT
（Axi_Mux / bitblt_pixel_engine / bitblt_dma_wr 完全不在报告里）
```

**⇒ 整条数据通路（pulse → dma_rd → pixel_engine → dma_wr）被删干净，而工具不报任何错。**

### 根因

**`Axi_Mux` 的两个配置端口悬空**：

```verilog
input            Cfg_Arb_Type  ;   //(I)Config Arbitration Type
input [ACN-1:0]  Cfg_Cnl_Mask  ;   //(I)Config Channel Mask     ← 4 位
```

**`Axi_Mux` 自己的注释**：
> 通过 `Cfg_Arb_Type` 支持共享访问（0）和优先级访问（1）
> 通过 `Cfg_Cnl_Mask` 支持端口屏蔽，可用于测试和调试

**因果链**：
```
Cfg_Cnl_Mask 悬空
  ⇒ 综合器判定「S1/S2/S3 的输入不可能影响 M 侧输出」
  ⇒ 三条上游路径整条判冗余，删掉
  ⇒ bitblt 读引擎输出没人要 ⇒ 读引擎被删
  ⇒ 像素引擎没输入 ⇒ 被删
  ⇒ 写引擎没输入 ⇒ 被删
  ⇒ 数据通路全线塌方
```

**四个反常现象全部解释得通**：

| 现象 | 解释 |
|---|---|
| 读引擎只剩 1 FF | 输出到不了 M 侧 ⇒ 判冗余 |
| 像素/写引擎消失 | 连锁 |
| SoC（S0）完好 | 走另一条路径 / 掩码位不同 |
| **`bitblt_axi_slave` 完好** | **面向 SoC 的从设备侧，不经过仲裁器** |
| **`map : PASS`** | **工具删得心安理得** |

### 修复

```verilog
.Cfg_Arb_Type   (1'b1    ),   // 1 = priority arbitration
.Cfg_Cnl_Mask   (4'b1111 )    // all four channels enabled
```

**修复后所有模块资源恢复**（`bitblt_top` 437→1288 FF，`u_px` 454 FF/24 DSP 回归）。

### 唯一有效的发现手段

**核对资源数量级**。

`warn.log` 里**没有**"模块被删"的警告；`map.rpt` 里**没有**异常；**只有 `res.csv` 的分层数字不对**。

**⚠️ 而且发现它需要"知道正确的数量级"** —— 我是因为**单独综合过 `bitblt_top`（1666 LUT / 13 DSP）**，才一眼看出 7236 LUT / 5 DSP 有问题。

**⇒ 结论：每个模块的单独综合数据要留档，它是整机综合的对照基线。**

---

## 三、本次还暴露的其它问题（已修 / 待修）

| # | 问题 | 状态 |
|---|---|---|
| 1 | **AXI 位宽不匹配**：`Axi_Mux` 的 `O_M_AR_ADDR` 是 32 位，而 `ddr3_top` 的 `AXI_AW=28`；ID 类 8 位 vs `AXI_ID_WIDTH=4` | ⚠️ **待修**（当前靠隐式截断，行为可能正确但不该依赖）|
| 2 | **`Cfg_Arb_Type` / `Cfg_Cnl_Mask` 悬空** | ✅ **已修** |
| 3 | `axi_clk` 顶层端口未连接 | ✅ 正常（`ASYN_AXI_CLK=0` 时用 `core_clk`）|
| 4 | `jtag_inst1_DRCK/RESET/RUNTEST/TMS/UPDATE` 未连接 | ✅ 正常（调试核可选）|
| 5 | `ddr3_top` 资源比官方 demo 少（1876 vs 2621 FF）| ⚠️ 待查（可能是配置差异）|

---

## 四、工程环境（可复现）

```
C:\fpga_work\sys\
  ├── bitblt_system.xml        顶层 = system_top，include 路径 = ip/soc
  ├── rtl\
  │   ├── system_top.v         我们的整机顶层
  │   ├── Axi_Mux.v (+.vh)     已改 X4（4 通道）
  │   ├── bitblt_*.v           7 个
  │   ├── color_bar_rgb.v / dvi_encoder.v / encode.v
  │   ├── Interrupt.v          含 apb3_top
  │   ├── ddr3_controller\     16 个（多数加密）
  │   └── memory_test\         未例化，不影响
  └── ip\soc\soc.v             SoC（加密）
```

**综合设置**：
- **`max_threads = 8`**（不是 `-1`）—— 用户本机有 dense model 任务在跑，留出余量
- **实测：44.9 秒完成**，峰值内存 ~294 MB

**⇒ 仿真/综合对用户机器的实际占用（实测）**：
| 工具 | 耗时 | 内存峰值 |
|---|---|---|
| iVerilog（`bitblt_top` 端到端）| **0.09 s** | 抓不到（太快）|
| Questa（同一测试）| **3.2 s** | **129 MB** |
| Efinity `map`（整机）| 44.9 s | ~294 MB |

**⇒ 三者都很轻。真正吃资源的是 PnR 阶段（未测）。**
