> 来源：subagent 摸排报告，2026-10-05

> **ℹ️ 这不是过时文档（2026-10-07 核对）—— 事实仍真，只是已被吸收。**
>
> **板卡规格与 demo 清单仍然有效**，已被 [04](04-硬件权威事实.md) 吸收。13 个官方 demo 的清单没有变过。

---

> 依据：以下结论均带文件路径 + 行号，可逐条复核

# Ti60F225 板卡与资料摸排报告

> 全程只读，**未修改任何文件**。工作目录 `2D图形加速引擎`。所有结论带文件路径；找不到的标「未知」。

---

## 0. 三条最影响决策的结论

| # | 结论 | 证据 |
|---|---|---|
| **A** | **DDR3 控制器是「软核」`efx_ddr3_soft_controller`，且有明文 RTL 可整目录复用**（指南写的「DDR 硬核控制器 IP」与实际不符） | `ip\DdrCtrl\DdrCtrl.v:70` 例化 `efx_ddr3_soft_controller`；`rtl\ddr3_controller\` 全套明文 `.v` |
| **B** | **SOC IP 的 `CustomInstruction` 是可配选项**，tinyml 里已置 `1'b1`（官方有先例） | `08_...\ip\soc\settings.json:61`；`tinyml...\ip\sapphire_soc\settings.json` |
| **C** | **Ti60F225 的 DDR3 只有 16 bit 位宽**（AXI4 侧 128 bit）。容量够，带宽需实测 | `ddr3_parameter.vh`、`Ddr_Write.v:98` |

---

## 1. 板卡资源规格表

### 1.1 器件资源（**已证实**：来自真实 PnR 报告的「用量/总量」）

| 资源 | 总量 | 证据行 |
|---|---|---|
| **XLR（逻辑单元）** | **60,800** | `Ti60_Demo.route.rpt`：`XLRs: 8981 / 60800 (14.77%)` |
| **SRL8（8bit 移位查找表）** | **14,720** | 同上：`SRL8: 557 / 14720` |
| **Memory Blocks（`EFX_RAM10`）** | **256 块**（≈320 KB） | 同上：`Memory Blocks: 62 / 256` |
| **DSP48 块** | **160** | 同上：`DSP Blocks: 1 / 160` |
| **PLL** | **4**（每块 5 路 CLKOUT） | `ddr_demo_ti60.pt.rpt.xml`：`name="PLL" value="2 / 4"` |
| GBUF / RBUF | 32 / 32 | `Ti60_Demo.route.rpt` |
| CLKMUX / HSIO | 4 / **70** | `Ti60_Demo.pt.rpt`：`clkmux: 4/4 (100%)`、`hsio: 67/70 (95.7%)` |
| HSIO_BG / HVIO_POC / JTAG TAP / OSC / SEU | 8 / 4 / 4 / 1 / 1 | 同上 |
| 封装 / 时序模型 | **225-ball FBGA** / I3（demo 亦有 C4） | `DdrCtrl\Ti180M484_devkit\constraint.sdc` 头；`ddr_demo_ti60.peri.xml:6` |
| **FF 总量 · BRAM 端口特性** | **未知** | Efinity 只给 XLR 口径 |

> ⚠️ **不要把 `EFX_LUT4: 5487` 当容量**（`Ti60_Demo.map.rpt:5896`），那是综合后原语数，不是器件上限。

### 1.2 板上外设（**已证实**：`.peri.xml` 引脚约束）

| 外设 | 规格 | 引脚 |
|---|---|---|
| **DDR3** | **16 bit**：`dq[15:0]`、`dqs[1:0]`、`dm[1:0]`、`ba[2:0]`、`addr[15:0]`、`cke[0]`、`cs_n[0]`、`odt[0]`、差分 `ck`；**1 rank** | `ddr_demo_ti60.peri.xml:88-264` |
| **HDMI TX** | 4 对 LVDS（1 clk + 3 data），`serial_width=10`，`diff_type=lvds` | `tmds_tx_clk`=GPIOR_PN_10 / `data0`=PN_13 / `data1`=PN_11 / `data2`=PN_12 |
| **HDMI RX** | 4 对 LVDS，`serial_width=10`，149.5MHz 参考 | `hdmi_rx_clk`=PN_19 / `d0`=PN_16 / `d1`=PN_18 / `d2`=PN_17 |
| HDMI 辅助 | HPD / 5V 检测 / I2C | GPIOR_N_15 / GPIOR_P_15 / GPIOR_P_14·N_14 |
| **MIPI DSI TX** | **4 lane** D-PHY | clk=`GPIOT_PN_01`，data=`PN_04/PN_05/PN_03/PN_00` |
| **MIPI CSI RX** | **4 lane** D-PHY | clk=`GPIOT_PN_09`，data 含 `PN_06` |
| 摄像头 I2C / 复位 | — | GPIOR_20 / GPIOR_18 / GPIOR_16 |
| MIPI 屏控制 | POWER / POWER1 / RST / RST1 | GPIOL_06 / GPIOR_15 / GPIOL_04 / GPIOR_12 |
| **千兆以太网** | RGMII 4 位 + MDIO | `rxc`=P_09、`rxd[3:0]`=N_07·N_06·P_00·N_05、`txc`=P_07、`txd[3:0]`=P_06·P_05·N_09·N_10、`mdc`=N_11、`mdio`=P_11 |
| **UART** | `txd`=GPIOR_28 / `rxd`=GPIOL_02（与 SOC UART0 同脚） | `17_..._uart_demo\top.peri.xml` |
| **按键** | **4 个** | GPIOL_07 / GPIOR_22 / GPIOR_21 / GPIOL_03 |
| **LED** | **8 个** | GPIOR_27 / GPIOR_24 / GPIOL_P_12 / GPIOL_P_02 / GPIOL_N_12 / GPIOL_P_15 / GPIOL_N_15 / GPIOL_N_02 |
| **晶振** | **25 MHz**（P_08，HDMI/DDR3 参考）、**27 MHz**（P_10）、**50 MHz**（GPIOR_29） | `LED_8bit_Test.peri.xml`；官方 `C:\Efinity\2026.1\examples\helloworld\Ti60F225_kit.isf:114` 确认 `REFCLK_FREQ 25.0` + `PLL_TL0` |
| **SPI Flash（配置）** | ss/sclk/d0/d1 | GPIOL_P_01 / N_01 / P_03 / N_03 |
| **JTAG** | 芯片级 4 线 + 用户 TAP | GPIOR_15 / 12 / 16 / 19 |

### 1.3 引脚约束里能看出什么

| 文件 | 内容 |
|---|---|
| **`.peri.xml`** | 引脚/外设约束主文件：IO Bank 电压、`comp_gpio`、`pll`、`lvds`、`mipi_dphy`、`comp_output_clock`、`osc` |
| `.sdc` | 时钟定义、IO delay（DDR 精确到 `CLKOUT~编号`）、clock group |
| `.pinout.csv/.rpt` | 球号级分配（如 `K15`） |
| `.isf` | 可导入的接口配置脚本 |

---

## 2. 13 + 2 个 demo 一览表

| # | Demo | 用途一句话 | 顶层模块 | IP | 相关性 |
|---|---|---|---|---|---|
| 01 | Key_led_osc | 4 键 + 8 LED + 25/27/50M 时钟选择 | `LED_8bit_Test` | 无 | **低**（唯一带 tb：`led_ctrl_tb.v`） |
| 02 | hdmi_demo | HDMI **RX→TX 回环**（DVI 解码→YUV/RGB→DDR3→TMDS） | `example_top` | 旧版 `ddr3_controller.vh` + `efx_fifo`5.1 | **高**：整条 HDMI↔DDR 链路 |
| 03 | hdmi_tx_demo | 纯 HDMI TX 彩条（1920×1536） | `top` | 无 IPM | **中**：改分辨率可作基线 |
| 04 | GE_demo | 千兆以太网（RGMII + 自写 MAC/ARP/ICMP/UDP） | `top` | 无 | **低** |
| 05 | lvds_loop_demo | LVDS 回环 + PRBS 误码 | `lvds_loopback_top` | 无 | **低** |
| 07 | MIPI_C2D_Demo | **SC431HAI（CSI）→debayer→DDR3→DSI 屏** | `ti60f225_oob_top` | `efx_csi2_rx`5.9 + `efx_dsi_tx`5.13 | **高**：`rtl\frame_buffer\` 是完整 DDR 帧缓冲 |
| **08** | **soc_demo** | **Sapphire RISC-V SOC + DDR3 读写测试 + AXI Mux** | `ddr3_example_top` | `efx_soc`**3.3.0** | **★最高：赛题底座唯一现成答案** |
| 09 | hdmi2dsi_Demo | HDMI→MIPI DSI 屏 | `ti60f225_demo` | `efx_dsi_tx`5.13 | **中** |
| 10 | sc431hai2hdmi | 摄像头 CSI→**HDMI**（带 SOC） | `ti60f225_oob_top` | csi 5.9 + dsi 5.13 + `efx_soc`2.2.9 | **高** |
| 11 | MIPI_CSI_loop | CSI 自发自收回环（RGB1.4G / YUV1.0G 两版） | `top`(SV) | csi2_rx 5.15 + csi2_tx 5.14 | 低-中 |
| 12 | mipi_dsi_loop | DSI 回环 | `TI60F225_MIPI_dsi` | dsi_tx 5.11 + dsi_rx 5.3 | 低-中 |
| 13 | carrychain | 进位链原语示范 | `carry_chain_top` | 无 | **低** |
| 17 | uart_demo | UART 收发 + LED + 软 FIFO | `top` | 无 | **中**：纯 RTL UART 作调试通道 |
| D1 | **IMX219_HDMI_1080P** | IMX219/SC2210→ISP→DDR3→HDMI 1080P60 | `example_top` | csi 5.7 + **`efx_ddr3_soft_controller`5.1** + **7 个 `efx_fifo`** | **★最高（IP 最全）**：`AXI4_AWARMux.v`、`ddr_rw_ctrl.v`、`rgb2dvi.v` |
| D2 | **tinyml-main** | Efinix TinyML 平台（RISC-V + 加速器 + DMA） | `tinyml_soc_top` | `efx_soc`3.2.1(**CustomInstruction=1**) + `efx_dma`6.4 + fifo 7.2×2 | **中-高**：**`src\axi\axi_interconnect_beta\` 是完整 AXI4 Crossbar**；`hw_accel_axi4.v` 是「AXI4 从设备+加速器」模板 |

**空缺编号** 06/14/15/16 在资料包中**不存在**（顶层目录已确认，非解压遗漏）。

---

## 3. Efinity 工程结构

```
<工程名>\
├── <工程名>.xml          ★ device/top_module/源文件/sdc/IP 清单（IP 清单在这里！）
├── <工程名>.peri.xml     ★ 引脚与外设约束
├── debug_profile.json    调试探针配置
├── debug_TEMPLATE.v      调试逻辑模板
├── debug_top.v           ★ 实际被综合的顶层（包装用户设计）
├── la0_waveform.vcd/.gtkw
├── src\  rtl\            用户 RTL
├── sdc\                  ★ 时序约束
├── ip\<ip名>\            ★ IP Manager 生成物
│   ├── settings.json     ★★ VLNV + 全部配置 + 生成时间（唯一权威）
│   ├── <ip>.v/.sv        包装文件
│   ├── <ip>_tmpl.v/.vhd  例化模板
│   ├── <ip>_define.vh    参数宏
│   ├── source\hardware\netlist\  加密网表 + 各仿真器分支
│   ├── Testbench\        IP 自带仿真平台
│   └── <board>_devkit\   IP 自带示例工程（含独立 .xml/.peri.xml/.sdc）
├── embedded_sw\          ★ RISC-V 软件（bsp + software\standalone|freeRTOS）
├── outflow\              ★ 全流程输出
│   ├── *.map.v/.map.rpt        综合网表 / 报告（Resource Summary）
│   ├── *.pt.rpt / *.pt.sdc     接口设计报告 / SDC 模板
│   ├── *.place.rpt             XLR / Memory / DSP 总量
│   ├── *.route.rpt             ★ 用量/总量
│   ├── *.timing.rpt / *.pinout.csv / *.interface.csv
│   ├── *.hex / *.bit / *.bitbin  烧录文件
│   └── *_template.v / *_or.ini
├── work_syn\ work_pnr\ work_pt\ work_dbg\   中间文件
```

| 关键文件 | 作用 | 要点 |
|---|---|---|
| `.xml` | 工程定义 | `<efx:top_module>` `<efx:design_file>` `<efx:sdc_file>` **`<efx:ip_info>`（IP 实例清单）** |
| `.peri.xml` | 引脚约束 | IO Bank 电压 / `comp_gpio` / `pll` / `lvds` / `mipi_dphy` |
| `.sdc` | 时序 | `create_clock` / `set_*_delay -reference_pin` / `set_clock_groups` |
| `ip/` | IP 生成物 | **`settings.json` 判版本** |
| `outflow/` | 输出 | **`.route.rpt` 有器件总量** |
| 仿真 | — | `efx_run.bat <proj>.xml --flow rtlsim|mapsim`，调外部 iVerilog/ModelSim |

---

## 4. 可复用 IP 清单

### 4.1 核心 IP

| IP 实例 | VLNV（lib / **name** / ver） | 用途 | 接口 | 关键位宽 | 工程 |
|---|---|---|---|---|---|
| **`DdrCtrl`** | memory_controller / **`efx_ddr3_soft_controller`** / **5.1** | **DDR3 控制器（软核）** | **AXI4**（读/写各一套） | AXI addr 32 / data **128** / strb 16 / ID 8；DFI addr 16 / ba 3 / dq 16(hi,lo) | D1 |
| **`soc`** | soc / **`efx_soc`** / **3.3.0** | **Sapphire RISC-V SOC** | **AXI4 M(DDR 128b) + AXI4 S(16MB) + AXI4 M(32b) + APB S** | 100MHz，Cache 4K，DDR=0xE0000000，CustomInstr=0 | 08 ×2 |
| **`sapphire_soc`** | soc / **`efx_soc`** / **3.2.1** | 同上（更强） | 同上 | 300MHz，**CustomInstr=1**，LDSize 262140 | tinyml |
| **`sapphire_soc`** | soc / **`efx_soc`** / **2.2.9** | 同上（旧） | 同上 | 100MHz，**DDR=0**（走 AXI-Stream） | 10 |
| **`dma`** | bridges_and_adaptors / **`efx_dma`** / **6.4** | **8 通道 DMA** | **AXI4(128b) + 原生(32/64b)** | MemExtWidth 128 / BufferWidth 64 / BufferWords 1024 / BufferCount 2 | tinyml |
| **`efx_fifo`** | memory / **`efx_fifo_top`** / **5.1** | 通用 FIFO | 原生 | **DATA_WIDTH 256，读写不对称 4:1**（256写/64读），TITANIUM | 02 |
| `hw_accel_dma_in/out_fifo` | memory / **`efx_fifo_top`** / **7.2** | TinyML DMA 出入口 FIFO | 原生 | — | tinyml |
| **`csi_rx`** | mipi / **`efx_csi2_rx`** / **5.7** | **MIPI CSI-2 RX** | **原生像素流 + AXI-Lite 寄存器** | 2 lane，byteclk 187MHz，FIFO 2048 | D1 |
| **`csi_rx_controller`** | mipi / **`efx_csi2_rx`** / **5.9** | 同上 | 同上 | **4 lane**，byteclk 70MHz，FIFO 4096，Continuous | 07 |
| **`mipi_csi_rx`** | mipi / **`efx_csi2_rx`** / **5.15** | 同上（最新） | 同上 | 4 lane，byteclk 175MHz | 11 |
| **`efx_csi2_tx`** | mipi / **`efx_csi2_tx`** / **5.14** | CSI-2 TX | 原生 | 4 lane，175MHz | 11 |
| **`dsi_tx`** | mipi / **`efx_dsi_tx`** / **5.13** | **MIPI DSI TX（点屏）** | 原生 + 命令 FIFO | 4 lane，125MHz，MAX_HRES 1920，Pack_48 | 07 / 09 / D1 |
| **`efx_dsi_tx`** | mipi / **`efx_dsi_tx`** / **5.11** | 同上（旧） | 同上 | MAX_HRES 1080 | 12 |
| **`mipi_dsi_rx`** | mipi / **`efx_dsi_rx`** / **5.3** | DSI RX | 原生 | 4 lane，125MHz | 12 |

### 4.2 只在 D1 出现的 FIFO 家族（**同一 IP 多次实例化**）

| IP | 用途 | 关键参数 |
|---|---|---|
| `W0_FIFO` / `_8` / `_32` / `_64` | 写路径位宽转换 | 4 个不同位宽变体 |
| `R0_FIFO` / `_8` / `_16` | 读路径位宽转换 | 3 个变体 |
| `FIFO_W48R24` | 非对称（写48/读24） | 像素格式转换 |

> 需要 FIFO 时**只需在 IP Manager 生成一次 `efx_fifo_top` 并多实例化**，不必逐个抄。

### 4.3 Efinity 2026.1 自带 IP 池（这些 demo 未用）

`C:\Efinity\2026.1\ipm\ip\` 下有 **`efx_axi_interconnect`（官方 AXI4 互联）**、`efx_axi_data_fifo`、`efx_axi_stream_switch`、`efx_apb3_2_axi4_lite`、`efx_bram`、`efx_cordic`、`efx_divider`、`efx_data_pipeline`、`efx_tsemac`、`efx_soc_rv64`、`efx_pcie_dma`、`efx_hyper_ram_2`、`efx_sdram_controller`、`efx_uart`、`efx_i2c_controller`、`efx_dphy` 等。

---

## 5. DDR3 控制器

### 5.1 两套并存 —— 必须分清

| 版本 | 位置 | 形态 |
|---|---|---|
| **A. IP Manager 软核** | `D1\ip\DdrCtrl\` | `DdrCtrl.v` 可读包装壳（216KB）+ 内部加密网表 |
| **B. 纯 RTL 源码（推荐）** | `08_...\rtl\ddr3_controller\` | **全明文**：`ddr3_top.v`、`axi4_bus_ctl\`(2 文件)、`local_bus_ctl\`、`memory_bus_ctl\`、`phy_ctl\`(8 文件)、`ddr3_parameter.vh` |
| C. 旧版 | `02_hdmi_demo\...\ddr3_controller.vh` | 仅 `DRAM_WIDTH 16` / `DDR3_MODE 2`，非 IPM 产物 |

> **⇒ 建议复用 B**：iVerilog 可编译、可仿真、可改。（A 的加密网表 iVerilog **跑不了**。）

### 5.2 关键参数（`ddr3_parameter.vh`，B 版）

| 项 | 值 | 项 | 值 |
|---|---|---|---|
| `DQ_WIDTH` | **16** | `DATA_WIDTH` | 16 |
| `DRAM_WIDTH` | 8（x8 颗粒×2） | **`ADDR_WIDTH`** | **28** |
| `DQS_WIDTH`/`DM_WIDTH` | 2 / 2 | **`AXI_DATA_WIDTH`** | **128** |
| `BANK_WIDTH` | **3** | **`AXI_ADDR_WIDTH`** | **28**（08）/ **32**（tinyml） |
| `ROW_WIDTH` | **14** | `AXI_ID_WIDTH` | 4（08）/ 8（其他） |
| `COL_WIDTH` | **10** | `tCK` | 2500ps → **DDR3-800（400MHz）** |
| `RANKS`/`CS`/`CKE` | 1 / 1 / 1 | `CL` / `CWL` | 6 / 5 |
| `BURST_MODE` | `"8"` | `MEM_ADDR_ORDER` | `BANK_ROW_COLUMN` |

### 5.3 A 版（IP）与 B 版参数**不一致** ⚠️

| 项 | A 版 `DdrCtrl` | B 版 SOC demo |
|---|---|---|
| `freq` | **384 MHz** | 400 MHz |
| `row` | **16** | **14** |
| `cas_latency` | 5 | `CL=6` |

> `.peri.xml` 有 `ddr_addr[15:0]`（16 根）与 A 版 `row=16` 一致；B 版只用到 14 行。**两者隐含容量不同 ⇒ 上板前必须核对实际颗粒型号。**

### 5.4 时钟架构（已证实）

| 时钟 | 周期 | 频率 | 来源 |
|---|---|---|---|
| `clk_in` | 40 ns | **25 MHz** | 板载晶振 |
| `sdram_clk` | 2.5 ns | **400 MHz** | `DDR3_PLL` = `PLL_BL0`（25M×4÷2） |
| `rx_cal_clk` / `tx_cal_clk` / `_90edge` | 2.5 ns | **400 MHz**（90° 动态相位） | 同 PLL |
| `axi_clk` | 5 ns | **200 MHz** | 同 PLL |
| `core_clk` | 10 ns | **100 MHz** | `SYS_PLL` = `PLL_TL0`（25M×4÷4） |
| `peripheralClk` | 10 ns | **100 MHz** | SOC 外设 |

### 5.5 「怎么读写」示例 —— **有三套**

| 示例 | 位置 | 说明 |
|---|---|---|
| **① AXI4 读写状态机（最佳参考）** | `08_...\rtl\common\Ddr_Write.v` / `Ddr_Read.v`（各 ~950 行，**详细中文注释**） | 参数 `AXI_DATA_WIDTH=128` / `DDR_DATA_WIDTH=16` / FIFO 深度 512 / 队列 16；含 `Ddr_Addr_Bus_Control` 地址队列、128→32 位宽转换乒乓、`BBus_Process` 写响应 ID 管理、`Ddr_Rd_Data` DQS 采集、校验和 |
| **② 官方 DDR3 自测套件** | `08_...\rtl\memory_test\`（13 文件） | `memory_test.v` / `test_seq.v` / `wr_drive.v` / `rd_drive.v` / `addr_gen.v` / `len_gen.v` / `data_gen.v` / `check.v` / `axi4_m_gen.v` / `PrbsAnyGenerator.v` + 统计 ⇒ **可直接做 DDR bring-up** |
| **③ 应用级视频帧读写** | `D1\src\ddr_rw_ctrl.v` + `src\axi\axi4_ctrl.v` + `axi4_AWARMux.v` | 更接近赛题用法 |

### 5.6 AXI 互联 / 多主仲裁

| 实现 | 位置 | 说明 |
|---|---|---|
| **手写轻量 AXI Mux** | `08_...\src\Axi_Mux.v` + `Axi_Mux_Param.vh` | 宏 `X2..X8` 选 `Axi_Chnanel_Num`（2~8 通道）⇒ **加一个「加速器主设备」最省事** |
| **完整 AXI4 Crossbar** | `tinyml\src\axi\axi_interconnect_beta\`（10 文件） | `crossbar.v` / `arbiter.v` / 固定与轮询优先级仲裁 / `master_coupler.v` / `slave_coupler.v` |
| 官方 IP | `efx_axi_interconnect` | 未被任何 demo 使用 |
| AXI 全双工→半双工 | `tinyml\src\axi\axi_full_to_half_duplex.v` | 省资源 |

---

## 6. 「确认的事实」 vs 「推测」

### ✅ 确认的事实

1. 器件 `Ti60F225` / `Titanium` / timing `I3`（`ddr_demo_ti60.peri.xml:6`、`.xml:4-6`）
2. 资源总量：**XLR 60,800 · SRL8 14,720 · Memory Blocks 256 · DSP48 160 · PLL 4**（`Ti60_Demo.route.rpt`、`ddr_demo_ti60.pt.rpt.xml`）
3. DDR3 **16 bit 数据位宽**、`ba[2:0]`、`addr[15:0]`（`.peri.xml` + `ddr3_parameter.vh`）
4. DDR3 400 MHz / AXI 200 MHz / core 100 MHz（`sdc\ddr3.sdc`）
5. 控制器 = **`efx_ddr3_soft_controller` 5.1 软核**，**有明文 RTL**（`DdrCtrl.v:70`、`rtl\ddr3_controller\`）
6. HDMI 收发各 4 对 LVDS、`serial_width=10`、RX 参考 148.5 MHz（`DDR3_MC.peri.xml`）
7. MIPI CSI/DSI 各 **4 lane**，D-PHY 在 `GPIOT_PN_*`（`ti60f225_oob.peri.xml`）
8. 板载晶振 **25 / 27 / 50 MHz**（`LED_8bit_Test.peri.xml` + `Ti60F225_kit.isf:114`）
9. 按键 4 个、LED 8 个
10. SOC `efx_soc` 3.3.0 / 100MHz / `DDRWidth=128` / `CustomInstruction=1'b0`（`ip\soc\settings.json`）
11. tinyml SOC `efx_soc` 3.2.1 / 300MHz / **`CustomInstruction=1'b1`** / `efx_dma` 6.4
12. 有完整 AXI4 Crossbar 参考实现（`tinyml\src\axi\axi_interconnect_beta\`）
13. 赛题原文：**基础 640×480@60Hz；高阶 Alpha 混合 + Color Keying + 同屏 Sprite 极限**（`work\extract\...选题指南-易灵思.txt:156-206`）
14. 平台：**Ti60F225I3 开发板**，标配 MIPI CSI-2 / HDMI / DDR3 / 千兆以太网，推荐摄像头 **SC431HAI**（同上 `:40-54`）

### ⚠️ 推测（需现场核对）

| # | 推测 | 依据 | 核实方式 |
|---|---|---|---|
| P1 | DDR3 容量 = **2Gb = 256MB** | row14×col10×bank3×16bit | 颗粒丝印 / 原理图 |
| P2 | **DDR3-800**（400MHz 时钟） | `tCK=2500ps` | 同上 + 跑 DDR 自测 |
| P3 | DDR3 带宽 ≈ **800 MB/s 理论** | 16bit × 400MHz × 2 沿 | `memory_test` 实测 |
| P4 | 以太网为**千兆** | RGMII 4 位 + MDIO | PHY 丝印 |
| P5 | 04/07 demo 的 LED 映射与 01 冲突 | 两 peri 对比 | 现场点灯 |
| P6 | `clk_27m` 用于 LVDS/MIPI | 命名 | 看 05/11/12 的 PLL 参考 |
| P7 | Memory Block 单块 = **10 kbit** ⇒ 总计 320 KB | 原语名 `EFX_RAM10` | 查数据手册 |
| P8 | DSI 可点 1920×1080 屏 | 子卡 PDF 名 + `MAX_HRES=1920` | 人眼看屏 |
| P9 | 板上有 HDMI RX（不只 TX） | `hdmi_rx_*` 4 对 LVDS | 看板上座子 |

### ❓ 未知

| # | 项 | 卡在哪 |
|---|---|---|
| U1 | DDR3 颗粒**型号/厂商/标称容量** | 只有 PDF 原理图（本次不读 PDF） |
| U2 | 是 **HDMI 还是 DVI**（CEC/音频/HDCP） | 同上 |
| U3 | HDMI 的 **EDID/DDC** 走 FPGA 还是外部 | 同上 |
| ~~U4~~ | ~~板载 **Flash 型号/容量**~~ | **✅ 已查明（2026-10-08）：8 MB · GD25LQ64** |
| U5 | **SD 卡 / PHY 型号 / USB** | 同上 |
| U6 | **FF 总量、BRAM 端口配置** | Efinity 报告不给 |
| U7 | 06/14/15/16 号 demo | 顶层目录无此目录 |
| U8 | 「每象限 1 个 PLL」 | 由 `PLL_TL0/TR0/BL0/BR0` 命名推 |

---

## 7. 后续工作建议

| 优先级 | 动作 | 依据 |
|---|---|---|
| **P0** | **底座选 `08_ti60f225_soc_demo`**（已含 RISC-V + AXI Mux + DDR3 读写 + 自测 + UART） | §5.5①②、§5.6 |
| **P0** | **DDR3 直接拷 `08_...\rtl\ddr3_controller\` + `rtl\common\Ddr_{Read,Write}.v`**（纯 RTL，可仿真） | §5.1 B |
| **P1** | HDMI 输出复用 `03_hdmi_tx_demo\rtl\hdmi_src\`，把 `HACT/VACT` 从 1920×1536 改成 640×480 并核对标准 640×480@60 时序 | §2 #03 |
| **P1** | 加速器挂 AXI4：先用 `08\src\Axi_Mux.v`（改宏 `X2`）；不够再上 `efx_axi_interconnect` 或 tinyml crossbar | §5.6 |
| **P2** | FIFO 用 IP Manager 生成一次 `efx_fifo_top` 后多实例化 | §4.2 |
| **P2** | 想加 **RISC-V 自定义指令**：SOC IP 置 `CustomInstruction=1'b1`（tinyml 已有先例） | 结论 B |
| **P3** | 摄像头输入：`07` 的 `rtl\frame_buffer\` + `csi_rx_controller` 5.9 最完整 | §2 #07 |

---

**已读到的关键文件清单（供复核）**
- `参考资料\Demo\Demo\Ti60F225_IMX219_HDMI_1080P\Ti60F225_IMX219_HDMI_1080P\outflow\Ti60_Demo.route.rpt`（器件资源总量）
- `...\Ti60_Demo.map.rpt`（综合资源用量 + 全部 IP 文件清单）
- `...\Ti60_Demo.pt.rpt`（接口资源占用 + 全局时钟分配）
- `...\ip\DdrCtrl\settings.json` / `DdrCtrl.v` / `DdrCtrl\Ti180M484_devkit\constraint.sdc`
- `...\ip\csi_rx\settings.json`
- `参考资料\Ti60F225_DemoBoard_v4完整资料包\Ti60F225_DemoBoard_v4\08_ti60f225_soc_demo\09_Ti60F225_co_debug_demo\` 下：`par\ddr_demo_ti60\ddr_demo_ti60.xml`、`.peri.xml`、`ip\soc\settings.json`、`sdc\ddr3.sdc`、`rtl\ddr3_controller\ddr3_parameter.vh`、`rtl\common\Ddr_Read.v`、`Ddr_Write.v`、`par\ddr_demo_ti60\src\Axi_Mux_Param.vh`
- `...\02_Ti60F225_hdmi_demo\...\efinity_project\DDR3_MC.peri.xml`、`ip\efx_fifo\settings.json`、`ddr3_controller.vh`
- `...\07_Ti60F225_MIPI_C2D_Demo\...\ti60f225_oob.peri.xml`、`ip\csi_rx_controller\settings.json`、`ip\dsi_tx\settings.json`
- `...\11_TI60F225_MIPI_CSI_loop_demo\...\ip\{mipi_csi_rx,efx_csi2_tx}\settings.json`
- `...\12_mipi_dsi_loop_demo\...\ip\{mipi_dsi_rx,efx_dsi_tx}\settings.json`
- `...\10_Ti60f225_sc431hai2hdmi_demo\...\ip\sapphire_soc\settings.json`
- `...\01_Ti60F225_Key_led_osc_demo\01_Ti60F225_key_demo\LED_8bit_Test.peri.xml` + `.xml`
- `...\03_hdmi_tx_demo\hdmi_tx_demo_v2\hdmi_tx.peri.xml`、`rtl\top.v`
- `...\04_Ti60f225_GE_demo\...\led_test.peri.xml`、`led_demo.xml`
- `...\17_Ti60F225_uart_demo\17_Ti60F225_uart_demo\top.peri.xml`
- `参考资料\Demo\Demo\tinyml-main\`（`README.md`、`Ti60F225_tinyml_helloworld.xml`、`ip\{dma,sapphire_soc,hw_accel_*}\settings.json`、`src\source.f`、`src\ddr3_controller\ddr3_parameter.vh`）
- `C:\Efinity\2026.1\examples\helloworld\Ti60F225_kit.isf`（官方 kit 引脚约束）
- `C:\Efinity\2026.1\ipm\ip\`（本机 IP 目录清单）
- `work\extract\全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-易灵思.txt`（**赛题原文，PDF 已被前人提取成文本**）

**未做**：未修改任何文件；未读任何 PDF；未安装/未运行任何程序。

---

## ⚠️ 修正说明（2026-10-05 追加）

本文是**摸排阶段的历史记录**。下列结论**已被后续核实推翻**，原文保留以便追溯：

| 原文位置 | 原结论 | 修正后 |
|---|---|---|
| §5.5 表格 ① | `Ddr_Write.v` / `Ddr_Read.v` = 「AXI4 读写状态机（**最佳参考**）」 | ❌ **它是 DDR3 控制器【内部的写通道】** —— 5 个时钟域（`Clk_TxCmd/TxDqs/TxDq/Core/Axi`）+ **直连 DDR 物理引脚**（`O_Ddr_Cs_In/Odt/Dm_Hi/Dm_Lo`）+ PHY 接口。**不是可复用的 AXI Master** |
| §5.5 表格 ② | `axi4_m_gen.v` 属「官方 DDR3 自测套件，可直接做 DDR bring-up」 | ⚠️ 用途描述没错，但**实现加密**；且它是 **32 位**默认参数、带内存测试的 error 比对逻辑，**不适合直接改造为像素搬运** |

**正确做法见 `docs/07-接口约定.md` §三**：M5 应抄 `Demo\...\IMX219_HDMI_1080P\src\axi\axi4_ctrl.v`（**128 位**、明文、自带 `axi4_ctrl_tb.v`）。

---

## ⭐ 板载 Flash 与加载模式（2026-10-08 从官方设计说明读出）

> **来源**：`参考资料/TI60F225I3-V4_DEMO板软硬件设计说明.pdf`（106 页，用 `work/pylibs/pypdf` 提取）。
> **全文已存 `work/board_manual_text.txt`**，以后不必重新解析 PDF。

### 一、Flash 容量与型号（第 7 页概述 + 第 33 页「七、Flash」）

| 项 | 值 |
|---|---|
| **容量** | **8 MB** |
| **型号** | **GD25LQ64**（= 64 Mbit = 8 MB，与容量自洽） |
| **用途** | **原文：「用于存储 FPGA 的程序，也可以用于用户数据存储」** |
| **布局提示** | **原文：「注意 FLASH 的第 6 脚 CLK 上一般不需要预留电容」** |

**⇒ ⭐ 这解释了那个「最多烧三到四套」的说法：8 MB ÷ 2.5 MB（厂商 demo 镜像大小）≈ **3.2**。**
**⇒ 但那只是**固化到 Flash** 时的限制 —— **JTAG 下载（`.bit`）不占 Flash**，想换就重下。**

| 镜像 | 大小 | 8 MB 能放几套 |
|---|---|---|
| **厂商 demo（如 `hdmi_tx.bit`）** | **2.2 – 2.5 MB** | **≈ 3 套** |
| **我们的 `bitblt` 设计（15712 LUT4，同量级）** | **≈ 2.2 MB** | **≈ 3 套** |
| **SoC 固化镜像 `soc_combine_hex.hex`** | **10.51 MB** | **⚠️ **超过 8 MB，放不下**** |

**⇒ 最后一行值得注意：那个 10.51 MB 是**同时含逻辑 + SoC 软件**的合成镜像，它比整个 Flash 还大。**
**⇒ 而我们的驱动是在调试时下载到 DDR 运行的，**不需要固化进 Flash** ⇒ 我们只固**逻辑部分**。**

### 二、加载模式验证管脚（第 35 页「九、加载模式验证管脚」）

**⇒ 原文：「Demo 板预留了 J6 排针座」，用于外部下载器（AS 模式）：**

| J6 针 | FPGA Pin Name | Pin Num | Bank 电压 |
|---|---|---|---|
| **J6.1** | **VCCIO1A** | — | **1.8V** |
| **J6.2** | **GPIOL_P_01_SSL_N** | **P1** | **1.8V** |
| **J6.3** | **GPIOL_P_03_CDI0** | **M1** | **1.8V** |
| **J6.4** | **GPIOL_N_03_CDI1** | **L1** | **1.8V** |
| **J6.5** | **GPIOL_P_04_CDI2** | **H5** | **1.8V** |
| **J6.6** | **GPIOL_N_04_CDI3** | **H4** | **1.8V** |
| **J6.7** | **GPIOL_N_01_CCK** | **N1** | **1.8V** |
| **J6.8** | **GND** | — | — |

**⇒ 但更省事的固化路径是 **USB + JTAG Bridge**（`SPI Active using JTAG Bridge`）—— **不用接 J6**。见 [05](05-官方设计说明精读.md) 行 476。**

### 三、⚠️ 用户 IO 的一处**文档自身矛盾**（第 34 页）

**⇒ 正文写：「Ti60F225-DK 上配置了 **4 个 LED** 和两个按键」。**
**⇒ 而同一页的表格列了 **LED0 ~ LED7，共 8 个**。**
**⇒ [05](05-官方设计说明精读.md) 行 124 早已把这个冲突记在 §7 不一致表里 —— **现在确认是文档自己的问题，表格比正文可信**。**

**⇒ ⚠️ 而电压分两档，那对**板上验证有实际影响**：**

| LED | 电压 |
|---|---|
| **LED0 ~ LED1** | **3.3V** |
| **LED2 ~ LED7** | **⚠️ 1.8V** |

**⇒ 按键：KEY0 `GPIOL_07`(C4, TL, 3.3V) · KEY1 `GPIOR_22`(P14, BR, 3.3V) · KEY2 `GPIOR_21`(N14, BR, 3.3V) · KEY3 `GPIOL_03`(A3, TL, 3.3V)。**

### 四、UART（第 35 页「十、UART」）

| 信号 | FPGA Name | Pin Num | 方向 |
|---|---|---|---|
| **UART_RX** | **GPIOL_02** | **R4** | **FPGA 为 input** |
| **UART_TX** | **GPIOR_28** | **R14** | **FPGA 为 output** |

**⇒ 经 **FT4232** 芯片接到 USB。** **⇒ 与 [02](02-板卡资源与demo清单.md) 行 59 记的一致（那【已【记过）。**

