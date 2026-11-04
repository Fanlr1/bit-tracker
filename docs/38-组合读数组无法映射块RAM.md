# 组合读数组无法映射到块 RAM

> 日期：2026-10-06
> 状态：✅ **已修复，`BUILD OK`，资源完全恢复**
> 关联：`docs/36`（组合环路）、`docs/37`（队列数组越界）

---

## 一、结论

**⇒ 我在自写 FIFO 里用了一个【组合读】的寄存器数组当存储，仿真全过，综合把器件撑爆了。**

```verilog
// rtl/async_fifo_gray.v 最初的写法
reg [DW-1:0] mem [0:DEPTH-1];                    // 24 位 × 2048 深
always @(posedge wclk) if (winc) mem[...] <= wdata;
assign rdata = mem[rbin[AW-1:0]];                // ← 异步读
```

**⇒ 块 RAM 的读必须是【寄存的】，综合器无法映射这种结构，只能做成【触发器阵列 + 多路选择器】。**

---

## 二、实测代价

| 指标 | 修复前（组合读） | 修复后（同步读） | 参照（原厂商 FIFO） |
|---|---|---|---|
| **EFX_LUT4** | **55072** | **12033** | 11874 |
| **EFX_FF** | **59550** | **10608** | 10603 |
| **EFX_RAM10** | **65** | **70** | 70 |
| **`map` 耗时** | **528 s** | **47.9 s** | 49.5 s |
| **`pnr`** | **FAILED** | **OK** | OK |

**⇒ 器件只有 60800 个 LUT4，而错误版本用掉了 55072（90%）⇒ 布局布线失败。**

**🎯 而且 `RAM10` 反而【减少】了（70 → 65）—— 这是最关键的线索**：**49152（= 2048 × 24）跑到逻辑里去了，没有进 RAM。**

---

## 三、修复

### 3.1 存储改用厂商模板

```verilog
simple_dual_port_ram #(
    .DATA_WIDTH (DW),
    .ADDR_WIDTH (AW),
    .OUTPUT_REG ("FALSE")
) u_ram (
    .wdata (wdata),
    .waddr (wbin[AW-1:0]),
    .we    (winc),
    .wclk  (wclk),
    .raddr (rbin[AW-1:0]),
    .re    (rinc),
    .rclk  (rclk),
    .rdata (rdata)
);
```

**⇒ `simple_dual_port_ram` 是 Efinix 的 RTL 宏模板，也是厂商 `dual_clock_fifo` 内部用的东西，所以工具认得。**

### 3.2 连带改动：`de` 的对齐改回一拍

**⇒ `simple_dual_port_ram` 即使 `OUTPUT_REG="FALSE"` 也会寄存一次读数据**：

```verilog
always @(posedge rclk) begin
    if (re) r_rdata_1P <= ram[raddr];      // ← 寄存读，硬件约束
    r_rdata_2P <= r_rdata_1P;
end
assign rdata = (OUTPUT_REG == "TRUE") ? r_rdata_2P : r_rdata_1P;
```

**⇒ 所以 `rdata` 比 `re` 晚一拍** ⇒ **`bitblt_video_out` 的 `de` 从 `de = fifo_re` 改回 `de = de_d1`。**

---

## 四、⚠️ 这个错误顺带澄清了一件旧事

**⇒ `bitblt_video_out` 里有一条注释，我当初读的时候觉得矛盾：**

```
// o_rdata appears ONE read clock after i_re -- measured, not assumed.
// ...even with OUTPUT_REG="FALSE".
```

**⇒ 我当时的判断是「厂商 FIFO 声称 FWFT 却延迟一拍，自相矛盾」。** **⇒ 错的 —— 那正是 `simple_dual_port_ram` 的固有延迟，不是矛盾。**

**⇒ 而我改成组合读之后，`rdata` 确实变成零延迟，`tb_bitblt_video_out` 也照样 PASS（95996 项）—— 于是我以为自己「改对了」。**

**🎯 实际是：我用一个【无法综合】的结构，通过了全部仿真。**

---

## 五、教训

| # | 教训 |
|---|---|
| **1** | **仿真全过 ≠ 能综合** —— **仿真器不在乎你烧掉多少 LUT。本次是项目里第一次真正被综合拦下来** |
| **2** | **`RAM10` 数量【下降】是「存储跑到逻辑里」的强信号** —— **器件资源莫名暴涨时，先看 RAM 计数有没有反向变化** |
| **3** | **块 RAM 的读必须寄存，写 RTL 时要按模板写** —— 自写的 `reg [..] mem [..]` 加组合读，综合器不认 |
| **4** | **「注释说了一件事，实现是另一件事」时，先怀疑自己读错了** —— 我把厂商的合理注释当成了矛盾 |
| **5** | **改动数据源之后，必须重测它的延迟**（本次 test 9 测出的是一拍）|

---

## 六、连带修好的测试台缺陷

**⇒ 换存储后读延迟从 0 拍变成 1 拍，`tb_async_fifo_gray` 里三处【按 FWFT 写的采样时机】全部要改：**

| 位置 | 原假设 | 改法 |
|---|---|---|
| **`rpop` 任务** | **先采样、再拉 `re`** | **拉 `re`、等一拍、再采样** |
| **test 7 读侧** | **同上** | **同上** |
| **test 8 `fb_read`** | **同上** | **同上** |
| **test 9** | **断言「`re` 未拉高数据已在」** | **改为断言「`re` 前数据【不是】该字、`re` 后一拍才有效」** |

**⚠️ 另外修掉 test 8 写侧一个**第三次**出现的同类错误**：**`we = ~wfull` 而没有等待 ⇒ 满时那个字被丢弃而循环变量照加 ⇒ 实际写入少于 40 个 ⇒ 读侧永远等不到第 40 个 ⇒ 超时。** **⇒ 同一形状的错误（满时跳过 / 空时跳过）在这个测试台里出现过三次。**

---

## 七、修复后的完整验证

### 7.1 回归（16 个测试台全过）

```
PASS=16  FAIL=0   (9.5 s)
REGRESSION: PASS
```

### 7.2 综合

```
map OK 47.9s  interface OK 13.4s  pnr OK 33.7s  pgm OK 1.7s
BUILD OK (97.7 s)

EFX_LUT4  : 12033
EFX_DSP48 : 31
EFX_FF    : 10608
EFX_RAM10 : 70
bitstream : 1981.8 KB
```

### 7.3 时序（setup slack，ns）

| 时钟 | 换 FIFO 前 | 现在 | 判断 |
|---|---|---|---|
| **core_clk** | 2.603 | **2.725** | ✅ |
| **sdram_clk** | 0.468 | **0.399** | ⚠️ |
| **rx_cal_clk** | 0.278 | **0.432** | ✅ |
| **tx_cal_clk** | 0.300 | **0.227** | ⚠️ **触发 0.25 警告，全机最薄** |
| **tx_cal_clk_90edge** | 0.434 | **0.353** | ⚠️ |
| **pix_clk** | 35.690 | **36.141** | ✅ |

**⇒ `tx_cal_clk` 0.227 ns 是当前最薄的一处。** **⇒ 它在历史上于 0.188~0.479 之间摆动，是板上第一件要盯的事（`bringup.ps1` 第 1 步 DDR3 校准即可暴露）。**

---

## 八、顺手修的脚本缺陷（`build-all.ps1`）

**⇒ 排查过程中，`build-all.ps1` 暴露了三个「让失败看起来像成功」的地方。都已修复并【逐个实测】。**

### 8.1 失败时仍打印上一次的报告

**⇒ 第一次 `pnr` 失败时，summary 显示的是**【上一次构建的】资源和时序**（16:46 的旧数据），**看起来完全像构建成功。** **⇒ 我自己就被它误导过一次。**

**修法（两道防线）**：
1. **失败时在 summary 顶部打红框警告**
2. **资源和时序报告都加上【写入时间戳】**

### 8.2 工具链缺失时【静默跳过】driver，仍报 BUILD OK

```powershell
if ($fail -eq 0 -and -not $RtlOnly -and (Test-Path $Toolchain)) {
    ... 编译 driver ...
} elseif (-not (Test-Path $Toolchain)) {
    Write-Host 'NOTE: toolchain not found ... -- skipping driver'
}
```

**⇒ 跳过本身是合理的**（只想出比特流时不需要工具链），**但 `$fail` 保持 0 ⇒ 报 `BUILD OK`，而 `bitblt_demo.bin` 根本没重新生成。**

**修法**：**引入 `$driverState`，四种取值并在 summary 里始终显示**：

| 取值 | 含义 |
|---|---|
| **`built`** | 正常编译 |
| **`skipped (-RtlOnly)`** | 有意跳过 |
| **`skipped - an earlier step failed`** | 前面步骤失败连带 |
| **`SKIPPED - toolchain not found`** | 工具链缺失 |

**⇒ 而且 driver 那一行【没有 `.bin` 时明确报 `NO bitblt_demo.bin on disk`】。**

### 8.3 实测结果

```
=== map / interface / pnr / pgm ===        全 OK
NOTE: driver NOT built. Toolchain not found at:       ← 只出现一次
resources:   (map report written 10-06 18:09:03)      ← 时间戳
timing (...): (timing report written 10-06 18:09:50)  ← 时间戳
WARNING: slack 0.227 ns is thin                       ← 阈值警告
bitstream: 1981.8 KB   2026-10-06 18:09:53
driver   : 6.4 KB   2026-10-06 17:54:00   [SKIPPED - toolchain not found]
BUILD OK  (96 s)   exit: 0
```

**⇒ `driver` 的时间戳（17:54）与 `bitstream`（18:09）相差 15 分钟，加上状态标注 ⇒ 旧文件一眼可辨。** **⇒ 改之前它只显示 `6.4 KB`，看不出任何问题。**

**⚠️ 验证手段**：**用 `-Toolchain 'C:\nonexistent_tc'` 制造失败** —— **不碰任何 RTL，安全，且能完整走一遍失败路径。**

**⚠️ 未覆盖的**：**「步骤失败」那条分支（`skipped - an earlier step failed`）没有实测过** —— 因为脚本的前置检查很完备（假 `-Efinity`、假 `-SysDir` 都在参数校验阶段就 `exit 2`），**要触发它必须让 map/pnr 真的失败。**

---

## 九、归档与清理

| 项 | 结果 |
|---|---|
| **脚本归档** | **`work\scripts\`：新增 `bringup.ps1` / `build-all.ps1` / `run-regression.ps1` / `vcd_delta.py` / `vcd_hotspots.py`，更新 `sim.ps1`**（旧版备份为 `sim.ps1.bak-20261006`）|
| **RTL 归档** | **`rtl\video\`：`async_fifo_gray.v`（新）、`bitblt_video_out.v`（更新）** |
| **TB 归档** | **`tb\`：`tb_async_fifo_gray.v`（新）、`tb_mux_video.v`（更新）** |
| **垃圾清理** | **删除 29 个 VCD，共 287 MB**（含工作区根目录误留的 90.3 MB 与 `fpga_work\sys\` 的 12.4 MB 延迟波形）|

**⇒ 两个 ZIP 参考资料（300 MB + 930 MB）完好未动。**
