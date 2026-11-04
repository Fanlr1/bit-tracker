> 来源：subagent 摸排报告，2026-10-05

> **ℹ️ 这不是过时文档（2026-10-07 核对）—— 事实仍真，只是已被吸收。**
>
> 本次摸排的**事实仍然有效**（VexRiscv、AXI、中断、内存映射），只是已被 [04-硬件权威事实](04-硬件权威事实.md) 与 [34-架构总览](34-架构总览.md) 吸收。**查当前事实请优先看那两份**；本文档是当时的完整调查过程。

---

> 依据：以下结论均带文件路径 + 行号，可逐条复核

# Ti60F225 SoC 底座摸排报告（RISC-V + FPGA 异构）

## 0. 路径缩写（后文全部沿用）
| 缩写 | 实际路径（相对工作区根） |
|---|---|
| `R` | `参考资料\Ti60F225_DemoBoard_v4完整资料包\Ti60F225_DemoBoard_v4` |
| `S08` | `R\08_ti60f225_soc_demo` |
| `HJ` | `S08\09_Ti60F225_hardjtag_demo` ⬅ **主用底座** |
| `CO` | `S08\09_Ti60F225_co_debug_demo` |
| `P` | `HJ\par\ddr_demo_ti60` ⬅ **Efinity 工程目录** |
| `SW` | `P\embedded_sw\soc` |
| `D10` | `R\10_Ti60f225_sc431hai2hdmi_demo\Ti60f225_sc431hai2hdmi_v1` ⬅ **视频参考设计** |
| `DT` | `参考资料\Demo\Demo\tinyml-main\tinyml_hello_world\Ti60F225_tinyml_helloworld` |

---

## 1. SoC 底座事实清单

### 1.1 Q1：`S08` 下有哪些子工程？

**只有 2 个子目录**（确认事实，`Get-ChildItem S08` 实测）：

| 子工程 | 干什么 | 与另一个的差异 |
|---|---|---|
| `09_Ti60F225_hardjtag_demo` | **DDR3 内存测试 + Sapphire SoC 二合一**。<br>顶层 `ddr3_example_top`（`P\..\rtl\ddr3_example_top.v`）同时例化 DDR3 控制器、Sapphire SoC、1 个自定义 APB3 外设。CPU 侧软件是空壳（uart/gpio/spi/i2c demo）。 | `CO_DEBUG=1'b0`（硬 JTAG） |
| `09_Ti60F225_co_debug_demo` | 同上 | 仅 `CO_DEBUG=1'b1` |

差异实测（`Compare-Object` 两工程 settings.json + rtl 目录）：**`rtl/` 目录逐文件完全一致**；`settings.json` 仅差 3 处 —— `--base_path`、`CO_DEBUG`（`1'b0` vs `1'b1`）、`generated_date`。

> ⚠️ **目录名 08 与 09 编号错位**：`08_ti60f225_soc_demo` 下装的是两个 `09_*` 目录；这是资料包自带的命名混乱，不是缺文件。

> ⚠️ **关键结论**：`S08` 这两个工程**都没有 HDMI/VGA/DVI 输出**（实测 `ddr_demo_ti60.peri.xml` 全文无 hdmi/dvi/vga 引脚，只有 ddr3/uarts/spi/gpio/jtag 引脚）。**要满足赛题「DDR3→Framebuffer→HDMI」必须另外合并视频通路**（见 §3.6 与 `D10`）。

### 1.2 Q2：SoC 是什么？CPU 核？主频？

| 项 | 值 | 依据 |
|---|---|---|
| SoC IP | **Efinix EfxSapphireSoc**，vlnv = `efinixinc.com/soc/efx_soc@3.3.0` | `P\ip\soc\settings.json:8-13` |
| IP 生成器版本 | Efinity `2025.2.288.3.8` | `P\ip\soc\settings.json:181`；`P\ip\soc\soc_define.vh:3` |
| CPU 核 | **VexRiscv**（SpinalHDL 生成） | `P\ip\soc\soc.v:2914` `VexRiscv_469dfaa85da54d55815c0d2324d480a8 system_cores_0_logic_cpu (`；模块定义 `soc.v:14789` |
| ISA | **RV32I + M 扩展**，无 A / C / F / D | `SW\bsp\efinix\EfxSapphireSoc\include\soc.h:11-16`（`RV32I 1` / `EXT_M 1` / 其余 0） |
| CPU 数 | 1（可选 SMP，本工程未开） | `soc_config:14` `--cpuCount 1` |
| **SoC 主频** | **100 MHz** | `soc_config:30` `--systemFrequency 100000000`；`soc.h:19` `SYSTEM_CLINT_HZ 100000000`；`P\sdc\ddr3.sdc:2` `create_clock -period 10.00 core_clk` |
| I/D Cache | 各 **4 KB**，1 way，64 B/line，均使能 | `settings.json:67-74`；`soc.h:42-47` |
| MMU | **无** | `soc.h:41` `SYSTEM_CORES_0_MMU 0` |
| 复位向量 | **0xF9000000**（片内 RAM，跑 SPI-Flash bootloader） | `soc.v:19149` `IBusCachedPlugin_fetchPc_pcReg <= 32'hf9000000;` |
| 片内 RAM | 0xF9000000，**4 KB** | `soc_config:6,29`；`soc.v:11552` |
| 外设时钟 | 与内核同 100 MHz（`PeripheralClock false`） | `soc_config:16` |
| 调试 | 硬 JTAG TAP（`jtagCtrl_*`） | `HJ\rtl\ddr3_example_top.v:454-461`；`CO` 版则走 CO_DEBUG |

### 1.3 Q3：总线结构 / 主从口 / 地址映射

**SoC 对外一共有 4 组总线口**（确认事实，`P\ip\soc\soc.v:49-216` 端口表）：

| # | 端口 | 方向 | 位宽 | 本工程是否接线 | 地址 |
|---|---|---|---|---|---|
| 1 | `io_ddrA_*` | SoC **作 AXI4 Master** | 数据 **128 bit**、ID 8 bit、地址 32 bit | ✅ 接 `ddr3_top` | 0x00001000–0xE0000FFF |
| 2 | `axiA_*` | SoC **作 AXI4 Slave**（外部外设→SoC） | 数据 **32 bit**、ID 8 bit、地址 32 bit；含 `awlen/awburst/awcache/awregion/awqos` → **完整 AXI4，支持突发** | ❌ **未接线（悬空）** | **0xE1000000**，16 MB |
| 3 | `io_ddrMasters_0_*` | SoC **作 AXI4 Slave**（外部 Master 打进 SoC） | 数据 **32 bit**、ID 4 bit | ❌ 未接线 | 见下 |
| 4 | `io_apbSlave_0_*` | SoC **作 APB3 Slave** | PADDR **16 bit** / PWDATA 32 bit | ✅ 接自定义 `apb3_top` | 0xF8100000，64 KB |

**关键行号（`axiA_*` 定义处）**：`soc.v:54-101`（wrapper 端口）、`soc.v:487-526`（EfxSapphireSoc 内部端口）。中断回送端口 `axiAInterrupt` 在 `soc.v:73` / `soc.v:526`。

**完整 Memory Map**（源自 `soc.v` 译码器 + 软件侧 `soc.h`，两处互相印证）：

| 区域 | 基地址 | 大小 | 译码器行号 | 软件宏行号 |
|---|---|---|---|---|
| DDR3 | `0x00001000` | ~0xE0000000（配置值 3.5 GB，**物理仅 256 MB**，见 §1.4） | `soc.v:11586` `(32'h00001000 <= addr) && (addr < 32'he0001000)` | `soc.h:68` `SYSTEM_DDR_BMB 0x1000` |
| **AXI4 Slave（我们的 BitBlt）** | **`0xE1000000`** | **16 MB** | **`soc.v:11603`** `(addr & (~32'h00ffffff)) == 32'he1000000` | **`soc.h:70-71`** `SYSTEM_AXI_A_BMB 0xe1000000` / `_SIZE 0x1000000` |
| APB 桥 | `0xF8000000` | 16 MB | `soc.v:11569` | `soc.h:52-53` |
| CLINT | `0xF8B00000` | 64 KB | `soc.v:10578` | `soc.h:56-57` |
| PLIC | `0xF8C00000` | 4 MB | `soc.v:10562` | `soc.h:54-55` |
| 片内 RAM | `0xF9000000` | 4 KB | `soc.v:11552` | `soc.h:50-51` |
| UART0 | `0xF8010000` | 64 B | `soc.v:10594` | `soc.h:58-59` |
| SPI0 | `0xF8014000` | 4 KB | `soc.v:10610` | `soc.h:60-61` |
| GPIO0 | `0xF8015000` | 256 B | `soc.v:10642` | `soc.h:64-65` |
| I2C0 | `0xF8016000` | 256 B | `soc.v:10626` | `soc.h:62-63` |
| **APB Slave 0** | `0xF8100000` | 64 KB | `soc.v:10658` | **`soc.h:66-67`** `IO_APB_SLAVE_0_INPUT 0xf8100000` |

**⚠️ 极重要的一条**：CPU 访问 `0xE1000000` 被判为 **IO 访问（不走 D-Cache）**：
```
soc.v:17669  assign DBusCachedPlugin_mmuBus_rsp_isIoAccess = (((...physicalAddress & (~32'h00ffffff)) == 32'hf8000000) || ((... & (~32'h00ffffff)) == 32'he1000000));
soc.v:17660  （IBus 同理）
```
⇒ 写 BitBlt 寄存器天然无 cache 一致性问题。但**反过来**：BitBlt 引擎 DMA 读写的 DDR 缓冲区，CPU 写完后**必须 flush D-Cache**，否则引擎读到旧数据。参考 `SW\software\standalone\vexriscv\dCacheFlushDemo\src\main.c`。

**中断 ID**（`soc.h:3-10`）：`AXI_A_INTERRUPT = 30`（即外部 AXI4 slave 的中断线）、`USER_INTERRUPT_A = 16`、UART0=1、SPI0=4、I2C0=8、GPIO0={12,13}。

### 1.4 Q4：DDR3 控制器如何接入？

| 项 | 值 | 依据 |
|---|---|---|
| 接入方式 | SoC 的 `io_ddrA_*`（AXI4，128 bit）**直连** `ddr3_top` 的 `s_axi_*`（AXI4 Slave） | `HJ\rtl\ddr3_example_top.v:373-422`（SoC 例化）、`:264-366`（ddr3_top 例化）、`:387-421` 为逐信号连接 |
| DDR3 控制器 AXI 位宽 | **数据 128 bit**、地址 28 bit、**ID 4 bit** | `HJ\rtl\ddr3_controller\ddr3_parameter.vh:19-23`（`AXI_DATA_WIDTH 128` / `AXI_ADDR_WIDTH 28` / `AXI_ID_WIDTH 4`） |
| ⚠️ 位宽截断 | SoC 的 `io_ddrA_aw_payload_id` 是 **8 bit**，接到 `s_axi_awid`（4 bit）→ **高 4 位被丢弃** | 对比 `soc.v:123`（`output [7:0] io_ddrA_aw_payload_id`）与 `ddr3_example_top.v:154`（`wire [AXI_ID_WIDTH-1:0] s_axi_awid;` = 4 bit） |
| DRAM 器件 | 16 bit DQ、1 rank、8 bank、14 row、10 col | `ddr3_parameter.vh:3-17` |
| **实际容量** | **256 MB**（2^3 bank × 2^14 row × 2^10 col × 16 bit = 2^28 B） | 由 `ddr3_parameter.vh` 推导；与 `AXI_ADDR_WIDTH 28` 一致 |
| ⚠️ 配置不一致 | SoC 配置声称 DDR 有 **3.5 GB**（`--ddrASize 0xe0000000`），**远大于物理 256 MB**。写超出 0x0FFFFFFF 的地址会被 AXI 地址截断回卷。 | `soc_config:2`；`settings.json:79` |
| DDR3 时钟 | PHY 400 MHz（`sdram_clk` / `rx_cal_clk` / `tx_cal_clk` = 2.5 ns）；AXI 侧跑 `user_clk`。`ASYN_AXI_CLK=0` ⇒ `user_clk = core_clk = 100 MHz` | `ddr3.sdc:3-5`；`ddr3_parameter.vh:55` `ASYN_AXI_CLK 0`；`ddr3_example_top.v:248-253` |
| 峰值带宽 | 128 bit × 100 MHz = **1.6 GB/s**（理论） | 128 bit @100 MHz |
| PLL | `pll_inst1`（PLL_TL0）→`core_clk`；`DDR3_PLL`（PLL_TR0）→`sdram_clk`/`rx_cal_clk`/`tx_cal_clk`/`tx_cal_clk_90edge`/`clk_100m`；参考时钟 `clk_25m`（25 MHz，引脚 GPIOL_P_08） | `P\ddr_demo_ti60.peri.xml:340-377` |
| DDR3 控制器额外有 AXI 位宽转换 | `axi4_bus_ctl` + `axi_upsizer`（AXI_DW 可配，工程实例化为 128→内部） | `HJ\rtl\ddr3_controller\axi4_bus_ctl\axi4_bus_ctl.v:26-34`；`axi_upsizer.v:25` |

---

## 2. 数据流 / 总线拓扑（现状 ASCII 图）

```
                    ┌──────────────────────────────────────────────┐
                    │  EfxSapphireSoc @100MHz  (P\ip\soc\soc.v)     │
                    │  ┌────────────────────────────────────────┐  │
   0xF9000000 ──────┼─▶│ VexRiscv RV32IM  4KB I$ + 4KB D$       │  │
   片内RAM 4KB       │  │ 复位向量 = 0xF9000000 (SPI bootloader) │  │
   (bootloader)     │  └────────────────────────────────────────┘  │
                    │        │ 内部 BMB 交叉开关                    │
                    │        ▼                                     │
                    │  ┌───────────────────────────────────────┐   │
                    │  │ 地址译码器  soc.v:11552~11603          │   │
                    │  └───────────────────────────────────────┘   │
                    │   │        │         │          │            │
                    │   ▼        ▼         ▼          ▼            │
                    │ OCRAM   APB桥     DDR AXI4   **AXI4 Slave**  │
                    │ 0xF9…   0xF8…     (Master)   (Slave)         │
                    │                    128b/ID8   32b/ID8        │
                    └───┬────────┬──────────┬───────────┬──────────┘
                        │        │          │           │
             io_apbSlave_0      │     io_ddrA_*        axiA_*   ← ❌ 悬空
              (APB3 16b addr)   │     (AXI4 128b)        (AXI4 32b)
                        │        │          │           │
                        ▼        ▼          │           ▼
                 ┌──────────┐  UART0/SPI0/  │     ┌──────────────────┐
                 │apb3_top  │  GPIO0/I2C0   │     │  ★ 待挂载：      │
                 │(Interrupt│  (APB 外设)   │     │  BitBlt Engine   │
                 │ .v:6)    │               │     │  (自定义 AXI4    │
                 │ 已验证 ✅ │               │     │   Slave, 0xE100…│
                 └──────────┘               │     │  PLIC ID 30)     │
                                            │     └────────┬─────────┘
                                            │              │ (需要 AXI4
                                            │              │  Master 出口)
                                            ▼              ▼
                                   ┌────────────────────────────────┐
                                   │  ddr3_top  (AXI4 Slave 128b/   │
                                   │  28b addr / ID4)               │
                                   │  ← 目前只有 1 个 Slave 口，     │
                                   │    被 SoC io_ddrA 独占         │
                                   │  axi4_bus_ctl → axi_upsizer    │
                                   │  → phy_ctl (400MHz)            │
                                   └────────────┬───────────────────┘
                                                ▼
                                        DDR3 颗粒 256MB/16bit
                                                │
                    ┌───────────────────────────┴──────────────────┐
                    │  ★ 赛题要求但不在此工程：Framebuffer + HDMI   │
                    │  参考 D10 的 rtl\frame_buffer\ + rtl\dvi_tx\  │
                    └──────────────────────────────────────────────┘
```
图例：✅ = 已在 RTL 中接线且可综合通过；❌ = SoC 端口存在但顶层未连接。

---

## 3. ★ 挂载自定义 AXI4 从设备（BitBlt 引擎）的改动点清单

### 3.0 结论先行

**好消息**：SoC 侧的 AXI4 Slave 口 **已经配置好并已生成**，地址 `0xE1000000`、16 MB、32 bit 数据、8 bit ID、支持突发。**不需要动 SoC IP 本身**，只需要在顶层 RTL 里把它接出来。

**坏消息**：BitBlt 引擎要读写 DDR3，而 `ddr3_top` 只有 **1 个 AXI4 Slave 口**，已被 SoC 的 `io_ddrA` 独占。**必须自己插入一个 AXI4 互联（仲裁）**。工程里已经预置了 `src/Axi_Mux.v`（128 bit / 2 通道），但**从未例化**。

### 3.1 改动点 A：SoC IP 配置（可选，一般不用改）

| 文件 | 行号 | 现状 | 若要改地址/大小 |
|---|---|---|---|
| `P\ip\soc\settings.json` | **38** | `"Base_M_AXIS": "32'd3774873600"` = **0xE1000000** | 改这里（十进制） |
| 同上 | **81** | `"AXISlave": "1'b1"` ✅ 已使能 | 保持 |
| 同上 | **82** | `"AXISlaveSize": "16777216"` = 16 MB | 改这里 |
| `P\ip\soc\source\soc_config` | **5** | `--axiAAddress 0xe1000000` | 与上面等价（人类可读版） |
| 同上 | **26** | `--axiASize 0x1000000` | 同上 |
| 同上 | **12** | `--axiAEnable true` | 同上 |
| `P\ip\soc\settings.json` | **47** | `"USER_0_INTR": "1'b1"` / `USER_0_INTR_ID 16` | 若需额外中断线 |

> ⚠️ **改 `settings.json` 必须用 Efinity IP Manager 重新生成 IP**（会重写 `ip/soc/soc.v`、`soc_define.vh`、`source/hardware/netlist/*`）。**手改 settings.json 不生效。**
> ✅ 但**本工程无需改** —— 现有配置已经就是我们想要的。

**对照组（证明地址可配）**：`D10\ip\sapphire_soc\source\soc_config:3,21` 同一 IP 被配成 `--axiAAddress 0x01000000` + `--axiAEnable true`，且 `:15` `--ddrAEnable false`（该设计的 SoC 完全不接 DDR3）。

### 3.2 改动点 B：顶层 RTL —— 接出 `axiA_*` 并例化 BitBlt（**核心改动**）

**文件**：`HJ\rtl\ddr3_example_top.v`（486 行，工程顶层模块，见 `P\ddr_demo_ti60.xml:9`）

| 步骤 | 位置 | 具体动作 |
|---|---|---|
| B1 | 在 `:140-227`（Wire declarations 区）之后 | 新增 `wire [7:0] axiA_awid; ...` 等约 **30 根线**（可直接照抄 `P\ip\soc\soc.v:487-526` 的位宽表） |
| B2 | 在 `:463`（`soc u_sapphire_soc(...)` 结束）之后 | 在 `u_sapphire_soc` 例化体内**追加端口连接**：`.axiA_awvalid(axiA_awvalid), .axiA_awready(axiA_awready), ...` 共 31 个 `axiA_*` + 1 个 `.axiAInterrupt(axiA_interrupt)`。**照抄 `soc.v:222-269` 的端口名** |
| B3 | 在 `:479`（`apb3_top` 例化结束）之后 | 新增 `bitblt_top u_bitblt(...)` 例化，把 B1 的线接进去 |
| B4 | `:126`（端口列表末尾）之前 | 若引擎需要对外输出（如 HDMA 直出、LED），在模块端口表里加端口 |
| B5 | `:261` 附近 | `sys_rst = pll_locked & user_pll_locked` —— 可作为 BitBlt 的复位源；`user_clk`（`:249/252`）作为 `axi_aclk` |

**现成可抄的例化样板**（两个，任选）：
- `P\ip\soc\soc.v:222-269` —— 端口名/位宽的权威清单
- `D10\rtl\axi4_slave.v:22-76` —— **Efinix 官方 AXI4 Slave 模板**，端口名一字不差对得上

### 3.3 改动点 C：AXI4 互联（BitBlt Master + SoC Master → DDR3 Slave）

| 方案 | 做法 | 优缺点 |
|---|---|---|
| **C1（推荐）复用 `src/Axi_Mux.v`** | 该文件**已在工程文件表里**（`P\ddr_demo_ti60.xml:40`），且参数**恰好匹配**：`AXI_DATA_WIDTH = 128`（`:423`）、`SLAVE_ID_WIDTH = 8`（`:411`）、`\`define X2`（`:43`）= 2 通道。只需在顶层例化：S0=SoC `io_ddrA_*`，S1=BitBlt master，M=`ddr3_top` `s_axi_*` | ✅ 代码现成、128 bit 对齐<br>⚠️ 需处理 **ID 宽度 8→4**（`ddr3_parameter.vh:21` `AXI_ID_WIDTH 4`）；把 `SLAVE_ID_WIDTH` 覆写成 4，或改 `AXI_ID_WIDTH` |
| C2 自己写 AXI4 Crossbar | 手写仲裁 | 工作量大，不建议 |
| C3 绕开互联 | BitBlt 走 `io_ddrMasters_0_*`（SoC 的 32 bit AXI slave 口，`settings.json:139` `AXIMaster 1'b1` 已使能），由 SoC 内部交叉开关转发到 DDR | ✅ 不用写互联<br>❌ 只有 32 bit、多一跳、吞吐低 |

**C1 需要改的文件行号**：

| 文件 | 行号 | 动作 |
|---|---|---|
| `HJ\rtl\ddr3_example_top.v` | `:264-366` | `ddr3_top` 例化的 `s_axi_*` 连接从直连 SoC 改为接 `Axi_Mux` 的 M 口 |
| 同上 | `:373-422` | `soc` 例化的 `io_ddrA_*` 改接 `Axi_Mux` 的 S0 口 |
| 同上 | 新增 | 例化 `Axi_Mux`；`Cfg_Arb_Type`（`:392`）接 0（共享）或 1（优先级）；`Cfg_Cnl_Mask`（`:393`，`[ACN-1:0]`）接 `2'b11` |
| `P\src\Axi_Mux.v` | `:43` | `\`define X2` 保持（2 通道）；如需 3 通道改 X3 |
| 同上 | `:411` | `parameter SLAVE_ID_WIDTH = 8;` → 若直连 DDR3 需改 4（或改 `ddr3_parameter.vh:21`） |
| `P\src\Axi_Mux.v` | `:45` | `\`include "Axi_Mux_Param.vh"` —— 该文件在 `P\src\Axi_Mux_Param.vh`，路径已对 |
| `P\ddr_demo_ti60.xml` | `:97` | `<efx:param name="include" value="ip/soc" .../>` —— **`Axi_Mux.v` 用的是 `\`include`，需确认综合器能找到 `Axi_Mux_Param.vh`**（它在 `src/` 而 include 路径是 `ip/soc`，**这是个坑**，可能要补 include 路径或把 Param 文件挪到能找到的位置） |

### 3.4 改动点 D：工程文件表（必须登记新 .v）

**文件**：`P\ddr_demo_ti60.xml`

| 行号 | 现状 | 动作 |
|---|---|---|
| `:9` | `<efx:top_module name="ddr3_example_top"/>` | 保持不变（除非改顶层名） |
| `:11-42` | 42 个 `<efx:design_file .../>` 条目 | **新增** `<efx:design_file name="rtl/bitblt_*.v" .../>`（BitBlt 全部 .v）|
| `:39` | `src/Interrupt.v` | 保留（`apb3_top` 在用） |
| `:40` | `src/Axi_Mux.v` | 保留（方案 C1 要用） |
| `:46` | `<efx:sdc_file name="sdc/ddr3.sdc"/>` | **若 BitBlt 跑在 200 MHz `axi_clk`（`ddr3.sdc:6`）需补时序约束**；跑 100 MHz `core_clk` 则沿用 |
| `:53-55` | `<efx:ip instance_name="soc" path="ip/soc/settings.json" ooc="false">` | 保留 |
| `:97` | `include = ip/soc` | 见 §3.3 的 include 坑 |

**约束文件**：`P\ddr_demo_ti60.peri.xml`（引脚分配）—— 若 BitBlt 需要新引脚（如 LED/中断指示灯），在此新增 `<efxpt:comp_gpio>`；否则不用改。

### 3.5 改动点 E：中断

| 文件 | 行号 | 动作 |
|---|---|---|
| `HJ\rtl\ddr3_example_top.v` | 新增 | BitBlt 的 `irq` → SoC 的 `axiAInterrupt`（`soc.v:526`） |
| — | — | 该中断在 PLIC 里是 **ID 30**（`soc.h:5` `SYSTEM_PLIC_SYSTEM_AXI_A_INTERRUPT 30`） |
| 驱动 | — | 见 §3.7 |

### 3.6 改动点 F：视频通路（赛题必需，本工程完全没有）

| 需要什么 | 从哪里抄 | 关键文件 |
|---|---|---|
| DDR3 双缓冲 / Bank 切换 | `D10\rtl\frame_buffer\` | `frame_buffer.v` / `ddr_buffer.v` / `ddr_rd_buffer.v` / `ddr_wr_buffer.v` / `bank_switch.v` |
| VGA/时序发生器（640×480@60Hz） | `D10\rtl\vga\` | `vga_gen.v` |
| HDMI/DVI TMDS 输出 | `D10\rtl\dvi_tx\` | `dvi_encoder.v_encrypted.v` 等 |
| 顶层合并示例 | `D10\rtl\ti60f225_oob_top.v` | `:490` `frame_buffer #(` 例化、`:571` `ddr3_top u_ddr3_top` 例化 |

> ⚠️ `D10` 的 frame_buffer/vga/dvi_tx 是 **128 bit 视频通路**（`top_soc_oob.v:170-171` `VIDEOIN_WIDTH=128 / VIDEOOUT_WIDTH=128`），与 DDR3 AXI 128 bit 对齐，可直接复用。

### 3.7 改动点 G：软件驱动（RISC-V 侧）

**现成模板，一字不改就能当 BitBlt 驱动骨架**：

| 文件 | 行号 | 内容 |
|---|---|---|
| `SW\software\standalone\axi4\axi4Demo\src\main.c` | **27-32** | `#ifdef SYSTEM_AXI_A_BMB` → `#define AXI SYSTEM_AXI_A_BMB`（**= 0xE1000000**） |
| 同上 | **159-169** | 写入/读回校验循环：`write_u32(i, AXI + i); ... read_u32(AXI + i);` |
| 同上 | **71-88** | 中断初始化：`plic_set_threshold` / `plic_set_enable(..., SYSTEM_PLIC_SYSTEM_AXI_A_INTERRUPT, 1)` / `csr_write(mtvec, trap_entry)` / `csr_set(mie, MIE_MEIE)` |
| 同上 | **102-115** | `trap()` 分发 |
| 同上 | **123-141** | `axiInterrupt()` → `plic_claim` / `plic_release` |
| 同上 | **18** | 注释：「Please ensure the AXI4 Master is enabled in Sapphire Soc」—— 注意措辞与配置项 `AXISlave` 不一致，**以 `soc_config`/`soc.h` 为准** |
| `SW\software\standalone\axi4\axi4Demo\makefile` | 全 19 行 | 复制此 makefile 即可新建 `bitbltDemo` 工程 |
| `SW\software\standalone\driver\io.h` | **33-69** | `read_u32/write_u32` + `writeReg_u32/readReg_u32` 宏 —— 寄存器驱动基元 |
| `SW\software\standalone\driver\apb3_cl.h` | **27-125** | **自定义外设驱动头文件的完整范例**（偏移宏 + 位域 struct + 读写函数声明） |

---

## 4. Q6：软件开发栈

| 项 | 值 | 依据 |
|---|---|---|
| **IDE / SDK** | **Eclipse 系**（Efinix Efinity 自带 RISC-V SDK，基于 SaxonSoc/Eclipse Embedded）。工程里有完整 `.metadata/.plugins/org.eclipse.*` 工作区、`.cproject`、`.project` | `SW\bsp\.metadata\...`；`SW\software\standalone\gpio\gpioDemo\.cproject` / `.project` |
| 构建系统 | **GNU make**（每个 demo 一个 makefile） | `SW\software\standalone\axi4\axi4Demo\makefile:1-19` |
| **工具链前缀** | **`riscv-none-embed-`**（xPack RISC-V GNU Toolchain） | `SW\software\standalone\common\riscv64-unknown-elf.mk:1` `RISCV_BIN ?= riscv-none-embed-` |
| 编译选项 | `-march=rv32im -mabi=ilp32 -DUSE_GP`；默认 `-g3 -Og`（DEBUG=yes） | `riscv64-unknown-elf.mk:55-56`；`bsp\...\include\soc.mk:1` `RV_M=yes`、`:7-8` `DEBUG?=yes DEBUG_OG?=yes` |
| **编译产物** | `.elf` / `.hex` / `.bin` / `.asm`（+ `.map`） | `common\standalone.mk:27,33-43` |
| 链接脚本 | `${BSP_PATH}/linker/default.ld`；**代码段在 `0x00001000`，长度 124 K，栈 4 K** | `SW\bsp\efinix\EfxSapphireSoc\linker\default.ld:7,17`；对齐 `settings.json:20-21` `LDSize 124` / `LDStackSize 4` |
| 编译命令 | `cd <demo目录> && make`（需先 `make clean`），Eclipse 里则是 Build Project | `makefile` 三段 include |
| **启动/下载流程** | ① 片内 RAM（0xF9000000）里烧的是 **SPI-Flash bootloader**（`bootloader_124K.bin/hex`）；<br>② 上电后 bootloader 用 **SPI0** 把用户固件从 Flash 偏移 **`0x00380000`** 拷到 **`0x00001000`**，长度 **`0x01F000`**（124 KB），然后跳转执行 | `SW\software\standalone\bootloader\src\bootloaderConfig.h:14-19,25-29,39-43`；`P\ip\soc\EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol*.bin`（4 个 9216 B 文件 = 片内 RAM 初值） |
| **把用户程序打进 FPGA 位流** | `python3 binGen.py -b <app>.bin -f <fpu 0/1> -s <ram size>` → 重新生成 `ip/soc/*_logic_ram_symbol*.bin` | `SW\tool\README-binGen.txt:17-22,44` |
| 调试器配置 | OpenOCD：`sapphire_soc_32bit-cpu.xml` / `-csr.xml` / `-fpu.xml` / `-reg.xml` / `sapphire_soc_xsvd.json` | `SW\bsp\efinix\EfxSapphireSoc\openocd\` |
| Eclipse 调试启动配置 | `gpioDemo_ti.launch` / `gpioDemo_trion.launch` / `gpioDemo_tz.launch`（Ti/Trion/Ti-Zynq 三种芯片模板） | `SW\software\standalone\gpio\gpioDemo\*.launch` |
| **示例 C 代码** | standalone 下 **16 个类别 / 24 个示例工程** | 见下 |

**16 个类别**（`SW\software\standalone\` 下目录）：`apb3`、`application`、`axi4`、`bootloader`、`common`、`customInstruction`、`driver`、`fpu`、`gpio`、`i2c`、`smp`、`spi`、`timer`、`uart`、`vexriscv`

**24 个示例工程**（有 `src/main.c` 的）：`apb3Demo`、`memTest`、**`axi4Demo`**、`bootloader`、`customInstructionDemo`、`fpuDemo`、`gpioDemo`、`inlineAsmDemo`、`i2cDemo`、`i2cEepromDemo`、`i2cMasterDemo`、`i2cMasterInterruptDemo`、`i2cSlaveDemo`、`smpDemo`、`spiDemo`、`clintTimerInterruptDemo`、`nestedInterruptDemo`、`userTimerDemo`、`watchdogDemo`、`uartEchoDemo`、`uartInterruptDemo`、`dCacheFlushDemo`、`iCacheFlushDemo`、`semihostingDemo`
`application\` 下另有 3 个 benchmark：`coremark`、`dhrystone`、`memTest`

> ⚠️ **`D10` 的 SoC 配置里 `ramHex` 指向一个 `mipi_cammera.hex`，但那是别人机器上的绝对路径，本机不存在**（`D10\ip\sapphire_soc\source\soc_config:1`）。用 `D10` 当参考设计时要注意重建软件。

---

## 5. Q7：现成的 AXI4 / APB3 外设模板

### 5.1 ★★★ 首选：Efinix 官方 `axi4_slave.v`（**AXI4 从设备黄金模板**）

**文件**：`D10\rtl\axi4_slave.v`（506 行）

| 行号 | 内容 |
|---|---|
| `:5-7` | 文件头：「A simple axi4 slave wrapper example design to interface with soc axi4 signals. This example design includes a 4KB onchip-RAM」 |
| `:22-76` | **完整 AXI4 端口表**，与 `soc.v:487-526` 的 `axiA_*` **逐位对应**（`axi_awid[7:0]` / `axi_awaddr[31:0]` / `axi_awlen[7:0]` / `axi_awqos[3:0]` / `axi_awregion[3:0]` …） |
| `:27` | `output axi_interrupt` → 对应 `soc.v:526` 的 `axiAInterrupt` |
| `:79-82` | 状态机 `IDLE / WR / WR_RESP / RD` |
| `:246-282` | `awsize` 解码 + **突发地址自增**（支持 FIXED/INCR/WRAP 三种 burst） |
| `:437-465` | **custom logic 区** —— 用 `generate` 环 + `user_dual_port_ram` 搭 4 KB BRAM；**这部分就是要替换成 BitBlt 引擎的地方** |

**变体（同一个模板，被改成硬件加速器）**：`DT\src\hw_accel\hw_accel_axi4.v`（443 行）
- `:25-70` 端口签名**与 `axi4_slave.v` 完全相同**
- `:407-441` **导出用户接口**：`usr_we` / `usr_waddr` / `usr_wdata` / `usr_re` / `usr_raddr` / `usr_rdata` / `usr_rvalid` + `axi_interrupt`
  ```verilog
  :437  assign usr_we    = axi_wready & axi_wvalid & axi_wstrb[0];
  :438  assign usr_waddr = awaddrReg;
  :439  assign usr_wdata = axi_wdata;
  :440  assign usr_re    = busRead;
  :441  assign usr_raddr = araddrReg;
  ```
- `:433` `assign axi_rlast = usr_rvalid_hold; //For non-burst mode, rlast equals to rvalid` —— **非突发模式简化版**
- `:435` `assign axi_interrupt = 1'b0;` —— 中断留白，等用户接
> ⚠️ `hw_accel_axi4.v` 和 `DT` 里的 `axi4_slave.v` **都只是登记在文件表里、并未被例化**（实测 `DT\src\tinyml_soc_top.v:486` 只例化了 `sapphire_soc`；`hw_accel_axi4` 全工程无例化）。**它们是「可抄的模板」而非「跑通的实例」。**

### 5.2 ★★★ 唯一「已跑通」的自定义外设实例：`src/Interrupt.v`

**文件**：`P\src\Interrupt.v`（51 行，SpinalHDL 生成）

| 行号 | 内容 |
|---|---|
| `:6-18` | `module apb3_top` —— **APB3** 从设备（非 AXI），端口 `apb_paddr[31:0]` / `apb_psel[0:0]` / `apb_penable` / `apb_pwrite` / `apb_pwdata[31:0]` / `apb_prdata[31:0]` / `apb_pslverror` + `output sig` |
| `:38-48` | 一个地址为 0 的可写寄存器 `_zz_sig <= apb_pwdata[0]` |
| — | **被例化**：`HJ\rtl\ddr3_example_top.v:466-479` |
| — | **在工程文件表**：`P\ddr_demo_ti60.xml:39` |
| — | 对应地址 **0xF8100000**（`soc.h:66`），驱动头文件 `SW\software\standalone\driver\apb3_cl.h` |

> 💡 这是**本工程唯一一个「外设 + 已例化 + 已登记 + 有驱动头文件」四件套齐全的范例**。挂 AXI4 时把它的模式照搬即可（只是把 APB3 换成 AXI4）。

### 5.3 非 AXI 的参考实现

| 文件 | 用途 |
|---|---|
| `D10\rtl\apb3_slave.v:22-45` | APB3 从设备官方模板（`ADDR_WIDTH=12` / `NUM_REG=4`，`apb3LED`/`apb3MemoryStart`/`apb3Interrupt`） |
| `D10\rtl\soc_oob\apb3_slave_oob.v:36` | 上面模板的 OOB 定制版 |
| `R\04_Ti60f225_GE_demo\...\rtl\tse_test\apb3_2_axi4_lite.v:18` | **APB3 → AXI4-Lite 桥**（若想用 APB 口挂 AXI-Lite 外设） |
| `R\04_Ti60f225_GE_demo\...\rtl\tse_test\axi4_st_mux.v` | AXI4 简单复用器 |
| `HJ\rtl\memory_test\axi4_m_gen.v:22` | AXI4 **Master** 发生器（内存测试用），可参考 master 侧时序 |
| `HJ\rtl\memory_test\axi4_onlym_gen.v:22` | 同上精简版 |
| `HJ\rtl\ddr3_controller\axi4_bus_ctl\axi_upsizer.v:25,865,1369` | `axi_upsizer` / `axi_register_slice` / `axic_register_slice` —— 位宽转换与流水寄存，**做突发+FIFO 时可直接复用** |
| `HJ\rtl\ddr3_controller\common\efx_fifo_v2.3\efx_fifo_wrapper.v` | Efinity 官方 FIFO 原语封装（赛题要求「内部 FIFO」） |
| `D10\rtl\frame_buffer\DC_FIFO.v` | 跨时钟 FIFO 实例 |

> ⚠️ **注意**：`soc.v` 里 GPIO/UART/SPI/I2C 这些 SoC 内置外设**全是 APB 接口**（`soc.v:10562-10658` 的译码器 + `soc.h:58-65`），**没有 AXI4 封装的 GPIO/UART**。想「拿 GPIO 当 AXI4 模板」是行不通的 —— **AXI4 模板只有 §5.1 那两个**。

---

## 6. 确认的事实 vs 推测

### ✅ 确认的事实（均有文件 + 行号，且多为交叉验证）
1. SoC = Efinix EfxSapphireSoc 3.3.0，CPU = VexRiscv RV32IM，无 MMU/FPU，1 核
2. SoC 主频 100 MHz（`soc_config` + `soc.h` + `sdc` 三处一致）
3. **SoC 有 AXI4 Slave 口，地址 0xE1000000，16 MB，32 bit 数据，8 bit ID，支持 burst** —— 配置已使能，RTL 端口已生成，但顶层未接线
4. **PLIC 里 AXI slave 中断 = ID 30**
5. CPU 访问 0xE1000000 判为 IO（不过 D-Cache）
6. 地址译码器逐条地址（8 条外设 + OCRAM + DDR + AXI + APB 桥）
7. DDR3 = 128 bit AXI / 28 bit 地址 / 4 bit ID；SoC 侧 8 bit ID 被截断
8. DDR3 物理 256 MB（16 bit × 8 bank × 2^14 row × 2^10 col）
9. `08` 两个子工程 rtl 完全一致，仅 `CO_DEBUG` 不同
10. `08` 工程**无 HDMI/VGA/DVI**
11. `src/Axi_Mux.v` 已登记但**未例化**；参数恰好 128 bit / ID 8 / X2
12. 工具链 `riscv-none-embed-`，`-march=rv32im -mabi=ilp32`，GNU make，Eclipse 工程
13. Bootloader 从 SPI Flash `0x00380000` 拷 124 KB 到 `0x00001000`
14. 存在官方 AXI4 slave 模板两份（`D10\rtl\axi4_slave.v`、`DT\...\hw_accel_axi4.v`），均未例化
15. `axi4Demo` 软件模板存在且基地址宏就是 `SYSTEM_AXI_A_BMB` = 0xE1000000

### ⚠️ 我的推测（需验证）
1. **`Axi_Mux.v` 的用途推测**：参数（128 bit / ID 8 / 2 通道）与「SoC + 一个自定义 Master 共享 DDR3」的需求高度吻合，且被登记进文件表却未例化 —— 推测是板卡厂商预留的互联，专门给「加自定义 AXI Master」用。**未找到任何文档或注释证实。**
2. **推荐架构推测**：BitBlt 用「AXI4 Slave（控制，0xE1000000）+ AXI4 Master（数据，经 Axi_Mux 进 DDR3）」双口结构最合理。也可只用 `io_ddrMasters_0` 单口，但仅 32 bit。
3. **DDR3 容量推测**：256 MB 是我从 `ddr3_parameter.vh` 的 bank/row/col/DQ 位宽**推算**的，**没有找到 DDR3 颗粒型号或原理图佐证**。`soc_config` 的 3.5 GB 与之矛盾。
4. **CD10 的 frame_buffer/vga/dvi_tx 可直接复用**是推测 —— 我确认了这些模块存在及其 128 bit 位宽注释，但**没有逐行核对它与 `08` 工程的 DDR3 AXI 接口是否 100% 兼容**。
5. **PLL `out_divider` 算术未解开**：`peri.xml` 里 `pll_inst1` out_divider=27 → 应为 100 MHz，`DDR3_PLL` out_divider=8 → 400 MHz、=32 → 100 MHz。后两者自洽（VCO=3200 MHz），前者不自洽（VCO 需为 2700 MHz）。**我以 `sdc/ddr3.sdc:1-8` 的约束值为准**（这是综合/时序实际用的）。

---

## 7. 还没搞清楚的问题

| # | 问题 | 影响 | 建议下一步 |
|---|---|---|---|
| 1 | **`io_ddrMasters_0` 的地址映射是什么？** 外部 Master 从该口看到的地址空间在哪？ | 决定 C3 方案是否可行 | grep `soc.v` 中 `io_ddrMasters_0` 的译码/桥接逻辑 |
| 2 | **DDR3 颗粒实际型号与容量**（256 MB 是推算） | 帧缓冲能开几个、多大 | 查板卡原理图 PDF / `R\子卡原理图`（PDF 本次跳过） |
| 3 | **`soc_config` 的 `ddrASize 0xe0000000`（3.5 GB）与物理 256 MB 矛盾**，SoC 是否对地址做了重映射？ | 影响 framebuffer 基地址选择 | 查 `soc.v` 中 DDR 区域的 `BmbToAxi4SharedBridge` 地址处理 |
| 4 | **`Axi_Mux.v` 的 `\`include "Axi_Mux_Param.vh"` 能否被 Efinity 综合找到**（工程 include 路径是 `ip/soc`，而 Param 文件在 `src/`） | 直接决定 C1 方案能否编译 | 试综合，或把 Param 挪位置/加 include 路径 |
| 5 | **ID 宽度 8 vs 4 的正确处理方式**：改 `Axi_Mux` 的 `SLAVE_ID_WIDTH` 还是改 `ddr3_parameter.vh:21`？ | 影响突发交织正确性 | 读 `soc.v` 的 `axiA`/`io_ddrA` ID 生成逻辑，读 `axi4_bus_ctl.v` 是否依赖 ID |
| 6 | **`D10` 的 frame_buffer 如何选取 DDR3 帧缓冲基地址 / 换页寄存器** | 双缓冲实现细节 | 精读 `D10\rtl\frame_buffer\frame_buffer.v` + `bank_switch.v`（本次未深入） |
| 7 | **`D10` 的 HDMI 输出是 HDMI 还是 DVI**（`dvi_tx` 目录名 vs 赛题要求 HDMI） | 是否满足赛题 | 读 `D10\rtl\ti60f225_oob_top.v` 的 dvi_tx 例化段 + `D10\rtl\dvi_tx\packet_assembler.sv` |
| 8 | **`D10` 的 SoC 是否真的被例化**？`rtl/soc_oob/top_soc_oob.v`（215 行）只有声明、无实例；`ti60f225_oob_top.v` 里 grep 不到 `sapphire_soc` | 影响 `D10` 作为参考设计的可用性 | grep `D10` 全工程的 `sapphire_soc` 例化；查 `ti60f225_oob.xml` 的 top_module |
| 9 | **`settings.json` 手改是否真的无效**（是否需要 IP Manager 重生成） | 影响改动流程 | 用 Efinity 打开工程试改，或对比 `ip/soc/soc.v` 的 UUID 与 settings.json 的对应关系 |
| 10 | **`CO_DEBUG` 具体是什么机制**（co_debug vs hardjtag 的下载/调试差异） | 影响选哪个工程当底座 | 查 Efinity 文档 / `P\debug_profile.json` |
| 11 | **是否有工程外的 SoC 文档**（Efinix Sapphire SoC UG）说明 `axiA` 的握手细节（是否支持 outstanding、max burst） | 影响 BitBlt 突发设计 | 赛题资料包里没找到（PDF 本次跳过） |

---

## 8. 给父 agent 的 3 条行动建议

1. **底座选 `HJ = S08\09_Ti60F225_hardjtag_demo\par\ddr_demo_ti60`**（`CO` 版只是 debug 方式不同，hardjtag 更通用）。AXI4 Slave 口**开箱即用**，无需改 SoC IP。
2. **AXI4 从设备模板直接用 `D10\rtl\axi4_slave.v` 或 `DT\src\hw_accel\hw_accel_axi4.v`** —— 端口名与 `soc.v:487-526` 严格对齐，可零改动对接。软件侧直接抄 `SW\software\standalone\axi4\axi4Demo\`。
3. **最大的未解风险是「BitBlt 如何 DMA 进 DDR3」**（§3.3 + 开放问题 #1/#4/#5）。建议优先做一次最小验证：先只挂 AXI4 Slave 做寄存器读写（跑通 `axi4Demo`），再解决 Master 侧互联。

---

## ⚠️ 修正说明（2026-10-05 追加）

本文是**摸排阶段的历史记录**。下列结论**已被后续核实推翻**，原文保留以便追溯：

| 原文位置 | 原结论 | 修正后 |
|---|---|---|
| §5.3 表格 | `axi4_m_gen.v` = 「AXI4 Master 发生器，可参考 master 侧时序」 | ⚠️ **它的实现是加密的**（`pragma protect`）。整个 `memory_test` 目录 16 个文件**几乎全部加密**，只能看端口、抄不了逻辑 |

**正确做法见 `docs/07-接口约定.md` §三**：M5 应抄 `Demo\...\IMX219_HDMI_1080P\src\axi\axi4_ctrl.v`（128 位、明文、带 testbench）。
