# AXI 互联方案对比与选型

> 日期：2026-10-05
> 目的：为 M5（BitBlt DMA）选定 DDR3 的 AXI 互联方案
> **依据：三个方案的实际文件全部读过，非印象判断**

---

## 一、问题背景

`ddr3_top` **只有 1 个 AXI4 Slave 口**，已被 SoC 的 `io_ddrA`（128 bit）独占。
BitBlt 引擎要 DMA 读写 DDR3，**必须自己插一层 AXI 互联**。

```
SoC (io_ddrA, 128b) ─┐
                     ├──[ AXI 互联 ]──> ddr3_top (128b AXI4 Slave)
BitBlt DMA (128b)  ──┘
```

**需求极简**：2 master → 1 slave，**两个 master 都只访问 DDR3**（**不需要地址译码**）。

---

## 二、三个方案的实际数据

| 维度 | **A. `Axi_Mux.v`** | **B. `efx_axi_interconnect`** | **C. `axi_interconnect_beta`** |
|---|---|---|---|
| **位置** | `08\...\par\ddr_demo_ti60\src\` | `C:\Efinity\2026.1\ipm\ip\` | `tinyml\...\src\axi\` |
| **拓扑** | **2~8 master → 1 slave** | `S_PORTS` master → `M_PORTS` slave | 多主多从 |
| **选通道** | `` `define X2 ``~`X8`（`Axi_Mux_Param.vh`）| `ComboBox` 配置 | 参数 |
| **默认配置** | `X2` → **2 通道** | `S_PORTS=1, M_PORTS=8`（**方向相反**）| — |
| **数据位宽** | 128 bit（工程实例化值）| `DATA_WIDTH`（可配）| 需查 |
| **仲裁** | `Cfg_Arb_Type`：共享(0) / 优先级(1) | `ARB_MODE = "PRIORITY"` | **固定优先级 + 轮询**（`arbiter.v` / `fixed_priority_arbiter.v` / `round_robin_priority_arbiter.v`）|
| **地址译码** | ❌ **无** | ✅ `M_REGIONS` + `AXI_S0..S7` 地址表 | ✅ crossbar 内有 |
| **连接矩阵** | 通道屏蔽 `Cfg_Cnl_Mask` | `M_CONNECT_READ` / `M_CONNECT_WRITE` | — |
| **代码量** | **2777 行 / 1 文件** | **665 行** + 子模块（≈100 KB）| **242 KB / 12 文件** |
| **语言** | Verilog | Verilog | ⚠️ **SystemVerilog** |
| **iVerilog 可仿真** | ✅ | ✅ | ❌ **不支持 SV** |
| **Questa 可仿真** | ✅ | ✅ | ✅ |
| **官方 testbench** | ❌ | ✅ `testbench\tb.v` + `efx_custom_master_model.v` / `efx_custom_slave_model.v` | ❌ |
| **实际被例化过吗** | ❌ **从未** | ❌ demo 未用 | ✅ **tinyml 工程在用** |
| **维护方** | Richard Zhu（2022-09-29, V1.2）| **Efinix 官方** | TinyML 团队 |

### 2.1 方案 A 的额外信息

`Axi_Mux.v` 文件头注释（原文）：
```
Axi 8Slave - 1Master Multiplex
支持2-8端口的AXI_Master 访问 AXI_Slave 的多路复用
通过 Cfg_Arb_Type 支持共享访问（0）和优先级访问（1）
通过 Cfg_Cnl_Mask 支持端口屏蔽，可用于测试和调试
相关文件: Axi_Mux_Param.vh -- 放置在工程根目录或修改 include 的路径

--2022-10-12  Axi_Mux_Addr_Ctrl 仿真验证
--2022-10-12  Axi_Mux_Rd_Ctrl 仿真验证
```
**⇒ 作者自己做过仿真验证，但没有任何工程例化过它。**

### 2.2 方案 B 的参数面（`source_efinity\efx_axi_interconnect.v:1-14`）

```verilog
module `IP_MODULE_NAME(efx_axi_interconnect) #(
    parameter PROTOCOL        = "AXI4",
    parameter ARB_MODE        = "PRIORITY",
    parameter S_PORTS         = 1,
    parameter M_PORTS         = 8,
    parameter ID_WIDTH        = 8,
    parameter DATA_WIDTH      = 32,
    parameter USER_WIDTH      = 3,
    parameter ADDR_WIDTH      = 32,
    parameter M_REGIONS       = 1,
    parameter M_CONNECT_READ  = {M_PORTS{{S_PORTS{1'b1}}}},
    parameter M_CONNECT_WRITE = {M_PORTS{{S_PORTS{1'b1}}}},
    parameter STRB_WIDTH      = DATA_WIDTH/8
)
```

⚠️ **方向易错**：
- `S_PORTS` = **上游 master 数**（interconnect 对它们表现为 slave）
- `M_PORTS` = **下游 slave 数**
- **默认 `1→8`，我们要 `2→1`**

---

## 三、收益分析（结合真实需求）

| 方案 | 它提供的能力 | 我们用得上的部分 | 净收益 |
|---|---|---|---|
| **A** | 2~8→1 纯仲裁 | ✅ **全部用得上** | ⭐⭐⭐ **最贴合** |
| **B** | 参数化 / 地址译码 / 官方 tb | 地址译码**用不上**；官方 tb 有用 | ⭐⭐ |
| **C** | 多主多从 / 双仲裁器 / SV | 大部分**用不上** | ⭐ 集成成本 > 收益 |

### 结论：**选 A**

**理由**：不是 A "更先进"，而是 **A 做的事正好等于我们要做的事**。
B 和 C 的能力（地址译码、多从设备、双仲裁策略）**我们一条都用不到**，却要承担 IP 生成 / 242 KB SV 集成的成本。

---

## 四、⚠️ 选 A 的前提：必须先排掉两个已知的雷

| # | 雷 | 说明 | 处理 |
|---|---|---|---|
| **1** | **`include "Axi_Mux_Param.vh"` 路径** | 工程 XML 的 include 路径是 `ip/soc`，而 `Axi_Mux_Param.vh` 在 `src/` | 加 include 路径 / 挪文件 / 改成相对路径 |
| **2** | **ID 宽度 8 ↔ 4 不匹配** | `Axi_Mux` 的 `SLAVE_ID_WIDTH = 8`，而 `ddr3_parameter.vh` 的 `AXI_ID_WIDTH = 4`；SoC 侧 `io_ddrA_aw_payload_id` 也是 8（接 4 位会被截断高 4 位）| 改 `SLAVE_ID_WIDTH` 或改 `ddr3_parameter.vh` |

**排雷方式（不需要板子）**：

```
1. 把 Axi_Mux.v + Axi_Mux_Param.vh 复制进试综合工程 C:\fpga_work\syn\
2. 加一个薄顶层例化它（2 主 1 从）
3. 跑 efx_run.bat --flow map
4. 通过 = 这条路能走；报错 = 看是 include 还是 ID 问题
```

**成本**：约半小时。**收益**：M5 的接口一次写对，不返工。

---

## 五、如果 A 排雷失败，退到 B

**B 的优势是官方 + 有 testbench**，可以在 C 之前先试它：

- `source_exp\efx_custom_master_model.v`（主侧激励模型）
- `source_exp\efx_custom_slave_model.v`（从侧响应模型）
- `testbench\tb.v`（顶层，跑完报 `SIMULATION PASSED/FAILED`）
- `source_exp\top.v`（示例集成，318 行，含完整端口连线）

**注意**：示例 `top.v` 是 `S_PORTS=1, M_PORTS=8` 配置 —— **跑通它只证明 IP 本身没问题，不代表 2→1 配置对**，仍需自己配着验。

---

## 六、方案 A 排雷结果（2026-10-05 实测）✅

### 结论：**可用，且两个雷都没爆**

```
Running: efx_run_map.py bitblt_syn_test --family Titanium --device Ti60F225 ...
   map :	PASS
exit code: 0

### Resource Summary ###
EFX_LUT4   :  366
EFX_FF     :   41
```

**一个 2→1 AXI 互联只花 366 个 LUT** —— 相对 60,800 XLR 的总量可忽略。

### 两个雷的实际状态

| # | 雷 | 实测结果 |
|---|---|---|
| **1** | `include "Axi_Mux_Param.vh"` 路径 | ✅ **不是问题** —— 只要 `.vh` 与 `.v` **同目录**，Efinity 默认就能找到，**无需配 include 路径** |
| **2** | ID 宽度 8 ↔ 4 | ⚠️ **综合层面无问题**（8 位 ID 本身合法）；**集成时需决策**（见下）|

### ID 宽度的集成决策（待定）

**事实**：
- `Axi_Mux` 内部用 **8 位 ID**（`SLAVE_ID_WIDTH = 8`，`:411`）
- DDR3 控制器只有 **4 位**（`ddr3_parameter.vh: AXI_ID_WIDTH 4`）
- SoC 的 `io_ddrA_aw_payload_id` 也是 **8 位**，**直连 DDR3 时高 4 位本来就被丢弃**

| 选项 | 做法 | 评价 |
|---|---|---|
| **A1** | 改 `SLAVE_ID_WIDTH = 4`，M 侧直连 DDR3 | ✅ **推荐** —— 内部一致，无隐含截断 |
| **A2** | 保持 8 位，M 侧只接 `[3:0]` | 与 SoC 直连行为一致，但**两个 master 的低 4 位 ID 可能撞车** |

**⇒ 倾向 A1**，并在集成时给两个 master 分配不同的 ID 空间。

### 警告（全部无害）

| 警告 | 判定 |
|---|---|
| `Removing redundant signal : Shift_Out[...]` | `Axi_Mux` 内部优化，不影响功能 |
| `expression size N truncated to fit in target size N` | 同上，内部位宽处理 |
| `bitblt_axi_slave.v` 端口 unconnected | ⚠️ **上一次综合的残留** —— `warn.log` 是**累积追加**的（日志里有 3 次 "Synthesis Started"），不是本次产生 |

### 复现方法

```powershell
# 文件就位（.vh 必须与 .v 同目录）
C:\fpga_work\syn\src\Axi_Mux.v            (127.9 KB)
C:\fpga_work\syn\src\Axi_Mux_Param.vh     (0.9 KB)

# 工程 XML
<efx:top_module name="Axi_Mux" />
<efx:design_file name="src/Axi_Mux.v" ... />

# SDC —— 注意端口名是 Sys_Clk，不是 clk
create_clock -name Sys_Clk -period 10.000 [get_ports {Sys_Clk}]

# 跑
cd C:\fpga_work\syn
C:\Efinity\2026.1\bin\efx_run.bat bitblt_syn_test.xml --flow map
```

### 对 M5 的影响

**M5 的 DMA 只需接到 `Axi_Mux` 的 `S1_*` 端口**，端口清单已确认：

```
I_S1_AW_ID / I_S1_AW_ADDR / I_S1_AW_LEN / I_S1_AW_SIZE / I_S1_AW_BURST / I_S1_AW_LOCK
I_S1_AW_VALID / O_S1_AW_READY
I_S1_W_ID / I_S1_W_DATA / I_S1_W_LAST / I_S1_W_STRB / I_S1_W_VALID / O_S1_W_READY
O_S1_B_ID / O_S1_B_VALID / I_S1_B_READY
I_S1_AR_* / O_S1_AR_READY / O_S1_R_ID / O_S1_R_DATA / O_S1_R_LAST / O_S1_R_RESP
O_S1_R_VALID / I_S1_R_READY
```

**同时确认**：`AXI_DATA_WIDTH = 128`（`:423`）**正好匹配 DDR3**，不用改。
