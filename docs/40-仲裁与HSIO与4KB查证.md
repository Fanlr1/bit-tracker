# 三点查证结论：仲裁 · HSIO · 4KB 跨界

> 日期：2026-10-06
> 起因：`docs/24` 第七节列了三项「建模覆盖不到的」，这三点此前**只能标注「算不出来，需实测」**
> 本次通过**读厂商源码 + 下载厂商公开文档**把它们查实
> ⚠️ 本文全部结论都有**可复查的出处**（文件行号 / PDF 页码 / URL），不是推断

---

## 零、结论速览

| # | 问题 | 结论 | 严重度 |
|---|---|---|---|
| **①** | **AXI 仲裁公平性** | **🔴 `Cfg_Arb_Type = 1'b1`（优先级模式）⇒ S0（CPU）**恒优先**，视频读会被结构性饿死** | **高** —— **直接影响画面是否闪烁** |
| **②** | **AXI 突发跨 4KB 边界** | **🔴 厂商控制器【不做检查也不拆分】⇒ 契约必须由我们遵守，而我们现在**每次都在违反** | **高** —— **`docs/21` 已列为第一优先项** |
| **③** | **HSIO 能否承载 1080p60** | **🟡 文档没给 TMDS 的速率上限**（1.5 Gbps 是 LVDS/MIPI 的）；**厂商 demo 只跑到 744 Mbps（720p60 / 1080p30）** | **中** —— **决定分辨率上限** |

---

## 一、① AXI 仲裁：被结构性饿死的视频通路

### 1.1 事实

**`rtl/system_top.v` 第 975 行：**

```verilog
.Cfg_Arb_Type (1'b1),  // 1 = priority arbitration
```

**`rtl/Axi_Mux.v` 第 811 行（作者自己的注释）：**

```
//仲裁策略 0:共享;1:优先级（S0为最高优先级）；
```

**`rtl/Axi_Mux.v` 第 2534-2553 行（`Axi_Mux_Addr_Ctrl` 的通道切换状态机）：**

```verilog
S_ADDR_IDLE:
  if (Act_Cnl_Hit)      Sta_Cnl_Switch  <=  S_ADDR_ACT  ;
  if (Cfg_Arb_Type & Act_Cnl_Hit)          // ← 优先级模式（我们用的）
  begin
    Channel_Cnt     <=  {CCW{1'h0}} ;
    Channel_List    <=  {{ACN-1{1'h0}},1'h1} ;   // ★ 每次都重置回 S0
  end
  else if (Cnl_Search_En)                       // ← 共享模式
  begin
    if (Channel_List[ACN-1])                    // 令牌已到最高位
    begin
      Channel_Cnt   <=  {CCW{1'h0}} ;
      Channel_List  <=  {{ACN-1{1'h0}},1'h1} ;  // 回到 S0
    end
    else
    begin
      Channel_Cnt   <=  Channel_Cnt + {{CCW-1{1'h0}},1'h1} ;
      Channel_List  <=  {Channel_List[ACN-2:0] ,Channel_List[ACN-1] } ;  // ★ 循环左移
    end
  end
```

### 1.2 机理

| 模式 | `Channel_List` 行为 | 效果 |
|---|---|---|
| **`Cfg_Arb_Type = 1`（我们）** | **每次空闲都重置为 `{{ACN-1{0}}, 1}`** | **🔴 永远从 S0 开始扫描 ⇒ CPU 恒优先** |
| **`Cfg_Arb_Type = 0`** | **`{Channel_List[ACN-2:0], Channel_List[ACN-1]}` 循环左移** | **✅ 令牌环轮询，各通道轮流** |

**⇒ 共享模式的轮询实现是**完整的**（令牌环），不是占位代码。**

### 1.3 为什么这重要

**⇒ 这正是 `docs/24` 第二节那句警告的答案：**

> 视频读是【实时且不能等】的 —— 即使总带宽充裕，如果 AXI 仲裁让它排队太久，FIFO 会空、画面会出现闪烁。**这是延迟问题，不是带宽问题。**

**⇒ 当时只能写「需要知道仲裁策略 ⇒ 算不出来」。现在知道了，而且是最坏的那种：CPU（S0）每一次取指/访存都可能打断视频行突发的连续性。**

### 1.4 修法与代价

| 项 | 说明 |
|---|---|
| **改法** | **`system_top.v:975` 的 `1'b1` → `1'b0`** —— **一行** |
| **收益** | **视频（S4）与 CPU（S0）轮流获得授权，不再被结构性压制** |
| **代价** | **CPU 的 AXI 延迟上升**（要等轮到自己）—— **但 `docs/24` 五.2 算过：CPU 每帧只写约 8 个寄存器 ≈ 0.8 µs，开销极小** |
| **⚠️ 风险** | **轮询只保证「公平」，不保证「够快」** —— 轮到视频时能否连续拿到足够 beat，还取决于其它 master 是否同时抢 |
| **⚠️ 为什么不建议现在改** | **现有全部仿真都在 `=1` 下跑绿；而 `tb_mux_video` **只覆盖 S0/S4**，S1/S2/S3（BitBlt 三个口）从未并发过 ⇒ 改了也**没有测试台能证明它变好** |

**⇒ 建议：记为板上待验项 —— 先烧当前配置看画面闪不闪；闪了再改 `Cfg_Arb_Type` 做 A/B 对比。**

---

## 二、② AXI 突发跨 4KB：厂商不兜底

### 2.1 事实：厂商文档没有任何相关承诺

**来源：`https://www.elitestek.com/uploads/soft/231018/ddr3-controller-core-ug-v1.6.pdf`（24 页，v1.6）**

**全文关于 AXI 突发的**全部**内容：**

```
行  44: ● Supports burst length of 8
行 330: axi_alen[7:0]   Input  Read or write address channel burst length.
行 331: axi_asize[2:0]  Input  Read or write address channel transfer size.
行 332: axi_aburst[1:0] Input  Read or write address channel burst type.
```

**⇒ 控制器只是把 `alen` / `asize` / `aburst` **透传下去**。全文唯一出现 `4KB` 的地方是【内部校准流程】（从 `0x0000` 读到 `0x1000` 自检），与用户突发无关。**

**⇒ 没有任何「跨边界自动拆分」或「跨界会报错」的说明。**

### 2.2 旁证：数字上的巧合

**`rtl/ddr3_controller/ddr3_parameter.vh`：**

```
`define AXI_DATA_WIDTH  128      // 16 字节/拍
`define AXI_ADDR_WIDTH  28       // 256 MB
`define BURST_MODE      "8"
```

**⇒ `arlen` 8 位 ⇒ 最大 256 拍 ⇒ 256 × 16 B = **4096 B = 4 KB 整**。**

**⇒ AXI4 规范原文是「A burst must not cross a 4KB boundary」，且**这是 master 的责任** —— 从设备不负责拆分。** **⇒ `256 拍 × 16 B` 正好等于 4 KB，这个数字不是巧合，它就是契约的边界。**

### 2.3 我们目前的违规

**⇒ `bitblt_video_out` 的行突发起始地址 = `fb_base + row × stride`。**

```
640 像素 × 4 字节 = 2560 字节/行
4096 ÷ 2560 = 1.6              ← 不是整数
⇒ 行起始地址【永远对不齐】4096 ⇒ 每 1.6 行就跨界一次
```

**⇒ 640×480 时每 4 行必然跨界；若宽度提到 1920，则**每一行**都跨界（一行 7680 字节 > 4 KB）。**

### 2.4 修法：让 stride 对齐 4096（比拆分突发更优雅）

**⇒ 如果**每行起始地址都是 4096 的倍数**，而每行长度 ≤ 4096，则**永不跨界，一次突发搞定，连拆分行状态机都不用改。**

| 宽度 | 自然 stride | 对齐后 stride | 浪费 | 备注 |
|---|---|---|---|---|
| **640** | **2560** | **4096** | **每行 1536 B（37.5%）** | **当前配置，改 stride 即可** |
| **1024** | **4096** | **4096** | **✅ 0** | **同时也是 `ARLEN` 的上限** |
| **800** | 3200 | 4096 | 每行 896 B（22%） | |

**🎯 注意 1024 宽这个值：它【同时】满足 `ARLEN ≤ 255 拍`（1024 px ÷ 4 px/beat = 256 拍）和 `stride 天然 4KB 对齐`。两个独立约束在同一个数上重合。**

### 2.5 ⚠️ 边界：这个结论的适用范围

| 已证明 | 未证明 |
|---|---|
| **厂商文档没有承诺处理跨界** | **跨界后【实际】会发生什么** —— 自动拆分 / 挂死 / 静默错数据，**三者无法从现有材料判定** |
| **AXI4 规范要求 master 保证不跨界** | **`ddr3_top` 内部（加密）是否另有保护** |
| **我们目前确实在跨界** | **板上是否真的因此出错** —— **只能实测** |

**⇒ `docs/21-板上待验清单.md` 把「4KB 跨界」列为第一优先项（"直接决定能不能出图"）—— 这个排序是对的。**

---

## 三、③ HSIO 与 1080p60：文档没给 TMDS 的上限

### 3.1 事实

**来源：`https://www.efinixinc.com/docs/titanium60-ds-v3.2.pdf`（85 页，v3.2）**

**第 88-92 行（Features）：**

```
— High-speed I/O (HSIO), configurable as:
  – LVDS, subLVDS, Mini-LVDS, and RSDS (RX, TX, and bidirectional), up to 1.5 Gbps
  – MIPI lane I/O (DSI and CSI) in high-speed (HS) low-power (LP) modes, up to 1.5 Gbps
  – Single-ended and differential I/O
```

**第 1469 行（HSIO Configured as LVDS）：**

```
• Up to 1.5 Gbps.
• Up to 10-bit serialization to support protocols such as 8b10b encoding.
```

**第 1491-1503 行（`Table 14: Full and Half Rate Serialization`）：**

```
Full rate : Data rate 800 Mbps, SerDes factor 8, fast clock 800 MHz
Half rate : Data rate 800 Mbps, SerDes factor 8, fast clock 400 MHz (800/2)
```

### 3.2 🚨 关键：1.5 Gbps 不是 TMDS 的规格

**⇒ `1.5 Gbps` 这个数字挂在 **LVDS / subLVDS / Mini-LVDS / RSDS** 和 **MIPI** 名下。** **⇒ 而 **HDMI TMDS 是单端的**，既不是 LVDS 也不是 MIPI。** **⇒ 文档里【没有给单端模式下的串行速率上限】。**

**⇒ 所以「1.5 Gbps vs 1080p60 需要的 1.485 Gbps」这个比较【不成立】—— 我此前拿它当依据是错的。**

### 3.3 有用的部分：10 位串行化 + 半速率模式

**⇒ `Up to 10-bit serialization to support protocols such as 8b10b encoding` ⇒ **HSIO 的串行器支持 10 位，正是 TMDS 需要的（8b/10b）。**

**⇒ 而速率要靠 PLL 出串行时钟：**

| 模式 | 1080p60 需要 | 说明 |
|---|---|---|
| **全速率** | **串行时钟 1.485 GHz** | **文档示例里最高出现 800 MHz** ⇒ **不可行** |
| **半速率** | **串行时钟 742.5 MHz** | **< 800 MHz** ⇒ **可行，但贴着示例上沿** |

### 3.4 最硬的旁证：厂商自己只跑到 744 Mbps

**来源：官方 demo 的 SDC（`参考资料\...\Ti60F225_IMX219_HDMI_1080P\outflow\Ti60_Demo.pt.sdc`）**

```
create_clock -period 13.4409 clk_pixel        ⇒ 74.4 MHz
create_clock -period 6.7204  clk_pixel_2x     ⇒ 148.8 MHz
create_clock -waveform {0.3360 1.0081} -period 1.3441 clk_pixel_10x   ⇒ 744 MHz
```

**⇒ `clk_pixel_10x` = 744 MHz 就是 TMDS 的串行位时钟 ⇒ **744 Mbps/lane**。**

**⇒ 74.4 MHz 像素时钟对应 **720p60**（标准 74.25 MHz）或 **1080p30** —— **两者都不是 1080p60（需 148.5 MHz）。**

**🚨 所以：目录名写着 `HDMI_1080P` 的那个官方 demo，实际像素时钟是 74.4 MHz。厂商**验证过的最高 TMDS 速率是 744 Mbps**，而 1080p60 需要 1.485 Gbps —— **是它的两倍**。**

### 3.5 对分辨率规划的直接影响

| 分辨率@帧率 | 像素时钟 | TMDS/lane | 判断 |
|---|---|---|---|
| **640×480@60** | **25.2 MHz** | **252 Mbps** | **✅ 当前配置** |
| **1024×768@60** | **65 MHz** | **650 Mbps** | **✅ 低于 744，安全** |
| **1280×720@60** | **74.25 MHz** | **742.5 Mbps** | **✅ 约等于厂商 demo 的速率** |
| **1920×1080@30** | **74.25 MHz** | **742.5 Mbps** | **✅ 同上** |
| **1920×1080@60** | **148.5 MHz** | **1485 Mbps** | **⚠️ 是厂商已验证值的 2 倍；文档未给上限** |

**⇒ 结论：**安全区到 742.5 Mbps（≈720p60 / 1080p30）**。** **⇒ 1080p60 需要跑到厂商 demo 的两倍速率，**在板上试之前不能假定可行**。**

---

## 三·补、方案 B 已实施并用正反配对验证

> **日期：2026-10-06 晚** **⇒ ① 与 ③ 要等板子，但 ② 不需要 —— 它是纯配置改动，当天就做了。**

### 改动（RTL 一行未动）

| # | 文件 | 改动 |
|---|---|---|
| **1** | **`work/bitblt_demo/src/main.c`** | **`FB_STRIDE` 由 `FB_W*4`（2560）改为 `FB_STRIDE_BYTES = 4096`，并新增 `FB_STRIDE_PX`（=1024，供地址运算）** |
| **2** | **同上，3 处像素偏移** | **`(y+row)*FB_W` → `(y+row)*FB_STRIDE_PX`**（`draw_char` / `clear_fb` / `blit_sprite`）|
| **3** | **同上，软件清屏基准** | **原来是 `for (i=0;i<FB_W*FB_H;i++) dst[i]=…` 的线性遍历 —— stride 有 padding 后会**清不满**，改为按行清** |
| **4** | **`tb/tb_bitblt_video_out.v`** | **新增 AXI4 4KB 跨界断言，默认 `STRIDE` 改为 4096** |

**⇒ RTL 侧零改动**：`fb_stride` 早就是 `BLT_FB_CFG`（0x3C）的 [15:0]，而 `line_addr <= fb_base + (rd_row * fb_stride)` 自动跟着变。

### 验证：同一个测试台，只换 stride

**⇒ 断言公式（每个突发）：`araddr[11:0] + (arlen+1)×16 <= 4096`。**

| | **`+stride=2560`（旧）** | **`+stride=4096`（新）** |
|---|---|---|
| **checks** | **95996** | **95996** |
| **errors** | **0** | **0** |
| **AR bursts** | **151** | **151** |
| **AR 4K-aligned** | **19** | **✅ 151（全部）** |
| **AR crossing** | **🔴 76（50.3%）** | **✅ 0** |
| **RESULT** | **FAIL** | **PASS** |

**⇒ 两个要点**：

1. **`checks`/`errors` 两边完全相同 ⇒ 改 stride 没有破坏任何像素数据**，只是把行距拉开（每行 384 像素的 padding，从不显示）
2. **反例这一半必不可少** —— **只跑 4096 得到 PASS 无法排除「断言根本没生效」；2560 得到 FAIL 才证明检查真的在工作**

**⇒ `19` 这个数字还自洽**：`stride=2560` 时对齐需 `2560×row ≡ 0 (mod 4096)` ⇒ `5×row ≡ 0 (mod 8)` ⇒ **row 必须是 8 的倍数**；**149 行 ÷ 8 ≈ 18.6 ⇒ 19 个**，与实测吻合。

### 代价与后续

| 项 | 值 |
|---|---|
| **显存** | **1.17 MB → 1.88 MB / 缓冲**（双缓冲 2.35 → 3.75 MB），**256 MB DDR3 完全够** |
| **端到端** | **`FULL CHAIN OK (110.4 s)`** —— **16/16 回归 + 综合 + 布线 + 比特流 + 驱动全过** |
| **资源** | **LUT4 12033 / FF 10608 / RAM10 70 —— 与改动前完全一致**（印证 RTL 未动）|
| **⚠️ 仍未验证** | **板上实际显示是否正常** —— **测试台能证明「突发不跨界」，但证明不了「`ddr3_top` 遇到跨界会怎样」，因为那需要真实控制器** |

**⇒ 所以 `docs/21` 第一优先项的状态从「待改」变为：「改造已完成待上板确认」。** **⇒ 若板上仍出错，说明跨界不是根因，要往别处查（仲裁、时序、DDR3 校准）。**

---

## 四、这三条如何改变 `docs/24` 的结论

| `docs/24` 原文 | 现在 |
|---|---|
| **七.「AXI 仲裁公平性 —— 需要知道 `Axi_Mux` 的仲裁策略」** | **✅ 已查明：优先级模式，S0 恒优先（§1）** |
| **七.「交叉 4KB 的实际代价 —— 取决于 `ddr3_top` 是否拆分突发，未知」** | **✅ 部分查明：文档无承诺（§2）；**实际代价仍需板上测**** |
| **二.「视频读不能等，若仲裁让它排队太久会闪烁」** | **✅ 坐实：当前配置就是这种情形（§1）** |
| **四.1「每 4 行必然跨界」** | **✅ 坐实，并给出修法：stride 对齐 4096（§2.4）** |

---

## 五、可复查的出处清单

| 材料 | 位置 |
|---|---|
| **Elitestek DDR3 控制器 UG v1.6** | **`C:\fpga_work\refs\ddr3-controller-core-ug-v1.6.pdf`（24 页）** |
| **Elitestek SDRAM 控制器 UG v2.4** | **`C:\fpga_work\refs\sdram-controller-core-ug-v2.4.pdf`（20 页）** |
| **Efinix Ti60 数据手册 v3.2** | **`C:\fpga_work\refs\titanium60-ds-v3.2.pdf`（85 页）** |
| **三份 PDF 的提取文本** | **`C:\fpga_work\refs\txt\*.txt`** |
| **提取脚本** | **`C:\fpga_work\refs\extract.py`（用 DSH bundled Python 3.12.14 + 项目自带的 pypdf 6.19.0）** |
| **仲裁器源码** | **`rtl/Axi_Mux.v` 行 811 / 2534-2553；`rtl/system_top.v` 行 975** |
| **官方 1080P demo 的 SDC** | **`参考资料\Demo\Demo\Ti60F225_IMX219_HDMI_1080P\...\outflow\Ti60_Demo.pt.sdc`** |

**⚠️ 下载的 PDF 与提取文本【不在 git 仓库里】**（`C:\fpga_work\refs\` 在工作区之外，且属于厂商资料）—— **需要时重新下载即可，URL 已列在上表。**
