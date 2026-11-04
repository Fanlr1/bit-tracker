# 57 - Efinity Logic Analyzer 调试记录（2026-10-13 凌晨）

> **与 docs/56 的关系**：56 记录的是 **AXI 从机读通道**那条排查线（16 轮，结论见该文档）；
> 本文记录的是**改用硬件 Logic Analyzer 取证**这条线。两条线都要读，才能接上次日的进度。

---

## 一、结论摘要

| 项 | 状态 |
|---|---|
| **JTAG 冲突根因** | ✅ **找到并解决** —— `JTAG_USER1` 被 SoC 内置的 `SystemDebugger` 占用，改用 `USER2` |
| **调试核插入比特流** | ✅ **成功** —— `debug_top.stub.v` / `debug_top.post.vdb` 生成，比特流增大 88 KB |
| **Debugger 激活 la0 面板** | ❌ **未成功** —— 按钮始终灰色，无法与板上调试核建立通道 |
| **波形采集** | ❌ 未完成（因此"AR 有没有到达从机"仍无直接证据）|

**⇒ 净成果**：把 Logic Analyzer 从"完全打不通"推进到"调试核已进比特流，只差 Debugger 侧最后一环"。

---

## 二、关键发现：JTAG 资源冲突

### 证据（Efinity Console 原文）

```
Start Debugger Step Instantiate Jtag.
...efx_pt_jtag_util.py... --action "add" --jtag_user "JTAG_USER1" ...
== Create default setting and pin name
ERROR: Jtag resource -- JTAG_USER1 has been occupied
...Exit code = 3
Running Debugger Step 3 failed
End Debugger Flow
```

### 说明

| 事实 | 依据 |
|---|---|
| SoC 自带 `SystemDebugger` 常驻 JTAG | `soc.v` 内有模块 `SystemDebugger_469dfaa85da54d55815c0d2324d480a8` |
| 它占用了 `JTAG_USER1` | 上方的 `JTAG_USER1 has been occupied` |
| 官方 demo 用 `USER2` 规避 | 官方 `debug_profile.wizard.json` 里 `"jtag_user": "USER2"` |

### 修复动作

```
1. 重新打开 Debug Wizard
2. Connection Settings → JTAG USER TAP：USER1 → USER2
3. 重新选信号 → Finish
```

### 修复后的产物对比（这是"成功"的硬证据）

| 产物 | 改 USER2 之前 | 改之后 |
|---|---|---|
| `work_dbg\debug_top.stub.v` | ❌ 不存在 | ✅ 1213 字节 |
| `work_dbg\debug_top.v` | ⚠️ 存在（空壳）| ✅ 355742 字节 |
| `outflow\debug_top.post.vdb` | ❌ 不存在 | ✅ 46063 字节 |
| `outflow\edb_top.map.rpt` | ❌ 不存在 | ✅ 15105 字节 |
| `outflow\bitblt_system.bit` | 2165184 | **2252991**（+88 KB）|

**⇒ 与官方 demo 的产物清单完全对应**，说明调试核真的被插入了。

---

## 三、操作链（按时间）

| 时间 | 操作 | 结果 |
|---|---|---|
| 00:10 | 手工改工程 XML 三项 debug 配置 | 开启 debug |
| 00:21 | 构建（手写 profile，selected_nets 空）| ❌ 调试核未插入 |
| 00:29 | 用 **GUI 的 Debug Wizard** 选 8 个信号、点 Finish | profile 有信号了 |
| 00:32 | 构建 | ⚠️ 仍缺 stub/post.vdb |
| 00:40 | 在 Debugger 里烧写 | ❌ 按钮灰 |
| 01:16 | （Synthesize 时的 Console）| 🔎 **发现 `JTAG_USER1 has been occupied`** |
| 01:19 | 改 `USER2`，重选 9 个信号，Finish | ✅ |
| 01:34 | 构建完成 | ✅ **stub/post.vdb 出现，比特流 +88 KB** |
| 01:34 | 命令行 `reflash.bat` 烧写 | ✅ 成功（Device ID 0x10660A79）|
| 01:35 | Debugger 烧写 | ❌ `Unable to read data from FTDI`（与 openocd 抢通道）|
| 01:43 | Debugger 烧写（重试）| ✅ `Programming operation completed` |
| 01:46 | 点刷新 / 重开窗口 | ❌ **la0 按钮始终灰** |

---

## 四、已探明的配置（可复用）

### 工程 XML（`C:\fpga_work\sys\bitblt_system.xml`）

```xml
<!-- synthesis 段 -->
<efx:param name="enable-mark-debug" value="1" value_type="e_option" />

<!-- debugger 段 -->
<efx:debugger>
    <efx:param name="work_dir" value="work_dbg" value_type="e_string" />
    <efx:param name="auto_instantiation" value="on" value_type="e_bool" />
    <efx:param name="profile" value="debug_profile.wizard.json" value_type="e_string" />
</efx:debugger>
```

**⇒ 备份：`bitblt_system.xml.bak-20261013-before-debug`（回退用）**

### Debug Profile（`C:\fpga_work\sys\debug_profile.wizard.json`）

| 字段 | 值 |
|---|---|
| `jtag_user` | **USER2** ← 关键 |
| `data_depth` | 4096 |
| `top_module` | system_top |
| `selected_nets` | 9 个：reg_arvalid / reg_arready / reg_rvalid / reg_rready / reg_awvalid / reg_awready / reg_wvalid / reg_wready / reg_bvalid |
| `db_checksum` | ⚠️ **始终为空**（与官方 demo 的差异，可能影响 Debugger 匹配）|

---

## 五、未解决的问题

### 现象
**⇒** Efinity Debugger 的 `la0` 面板按钮（`Run` / `Run Continuous` / `Run Immediate`）**始终为灰色**，尽管：
- 比特流含调试核（产物齐全、体积增大）
- `Debugging` 行已选 `1 - 0x10660a79` + `USER2`
- `Device Status` 为绿色、Console 显示 `Device is in user mode!`
- 反复点刷新、重开窗口、重新加载 profile 均无效

### 可疑方向（按可能性排序）

| # | 方向 | 判别方法 |
|---|---|---|
| 1 | **JTAG 链上两个 tap 需额外选择**（SoC 的 SystemDebugger 在 USER1，我们的核在 USER2）| 对比官方 demo 的 `Debugging` 行显示内容（它有 `la0~la3`）|
| 2 | `db_checksum` 为空，Debugger 无法把 profile 与板上核匹配 | 让 profile 生成时带上 checksum（需工程 elaborate 完成后重做 Wizard）|
| 3 | Debugger 必须在**它自己烧写之后**重新扫描一次，而当前流程没触发 | 观察 Console 烧写后是否出现 "Refreshing..." |
| 4 | 调试核端口/JTAG 用户配置在综合时未真正生效（尽管产物存在）| 查看 `edb_top.map.rpt` 内容 |

---

## 六、踩坑记录（重要，避免重犯）

| # | 坑 | 现象 | 正确做法 |
|---|---|---|---|
| 1 | **openocd 与 Efinity Debugger 抢 JTAG** | 用 openocd 读过板子后，Debugger 按钮变灰、`Unable to read data from FTDI` | **二选一**。要用 Debugger 时全程别碰 openocd |
| 2 | **手写 debug profile 无效** | 试过 `debug_cores` 格式与字符串数组，`mark_debug.json` 里 `selected_nets` 始终为空 | **必须用 GUI 的 Debug Wizard** 生成 |
| 3 | **Efinity 不支持跨层信号引用** | `system_top.v` 里写 `u_bitblt.u_regs.rd_active` → `external reference remains unresolved` | 走正规端口逐层引出 |
| 4 | **map 分步流程不触发 debug** | `efx_run --flow map` 命令行里没有任何 debug 参数 | debug 插入靠 **GUI 的 Synthesize/P&R** |
| 5 | **VDB 路径错位** | `pnr` 报 `work_pnr_sys\bitblt_system.vdb does not exist`（实际在 `outflow\`）| 构建前把 `outflow\*.vdb` 复制到 `work_pnr_sys\`（见 `scripts/build-with-debug.ps1`）|
| 6 | **PowerShell 变量被外层展开** | `pwsh -Command "...$f..."` → `foreach 后缺少变量名称` | 用 `-File` 调脚本，避免嵌套 |
| 7 | **误读按钮状态** | 把灰按钮当成可用，导致用户反复重试 | 让用户确认，不要从截图猜 |

---

## 七、下一步（两个方向）

### 方向 A：打通 Logic Analyzer（继续取证）

1. 逐项对比官方 demo（`ti60f225_oob`）与我们的 Debugger 配置 —— **它真正用过 Logic Analyzer**（有 `la0~la3_waveform.vcd`）
2. 重点看：它有多个 debug 核（la0/la1）时，`Debugging` 行显示什么；是否有额外的 tap 选择步骤
3. 尝试：先让工程完整 elaborate → 重做 Debug Wizard（期望生成 `db_checksum`）→ 再构建

### 方向 B：绕开 Logic Analyzer，直接验证"SoC 是否发读请求"

**⇒ 既然调试核已能进比特流，最实用的替代方案是：把一个信号引到**空闲引脚**，用万用表/LED 直接看电平。**

候选信号：`reg_arvalid`（SoC 是否发读请求）、`reg_awvalid`（对照，已知会动）。

**⇒ 优点：不依赖任何调试软件，且与前 16 轮的结论（问题在 SoC 侧）直接对接。**

---

## 八、当前环境状态（次日接手用）

| 项 | 值 |
|---|---|
| 板上比特流 | `2252991` 字节版（**含调试核**），01:34 构建、01:43 由 Debugger 烧写 |
| 工程 XML | `enable-mark-debug=1` / `auto_instantiation=on` / `profile=debug_profile.wizard.json` |
| profile | `jtag_user=USER2`、9 个信号、`db_checksum` 空 |
| RTL | `rtl/bitblt_axi_slave.v` = 原始版 + `dbg_observ` 端口（未启用调试核时可正常工作）|
| 备份 | `bitblt_system.xml.bak-20261013-before-debug`、`bitblt_axi_slave.v.bak-*`（多个）|
| 构建脚本 | `C:\fpga_work\scripts\build-with-debug.ps1`（含 VDB 路径绕过）|
