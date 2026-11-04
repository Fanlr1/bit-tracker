# Questa 仿真环境（已完全打通）

> 日期：2026-10-05
> 状态：✅ **端到端验证通过** —— `vlog` 编译加密 IP + DSP48 原语 + `vsim` 跑断言全 PASS
> 用途：**新会话/新机器复现这套环境的唯一依据**

---

## 一、环境构成

| 项 | 值 |
|---|---|
| 仿真器 | **Questa - Altera FPGA Starter Edition 26.1.1.130**（引擎版本 2025.3）|
| 安装路径 | `C:\altera_pro\26.1.1\questa_fse\win64\` |
| 可执行文件 | `vsim.exe` / `vlog.exe` / `vlib.exe` / `vmap.exe` |
| **License 文件** | `C:\Users\25437\flexlm\LR-196860_License.dat`（1343 B，绑定 MAC `F8EDFC6F60AB`）|
| **仿真工作区** | **`C:\fpga_work\`**（纯 ASCII —— 必须，见 §二.②）|
| Efinity 原语模型 | `C:\Efinity\2026.1\sim_models\verilog\` |
| 对照仿真器 | iVerilog 12.0 @ `C:\Users\25437\iverilog\bin\` |

---

## 二、三条硬约束（全是实测踩出来的）

### ① license 变量是 `SALT_LICENSE_SERVER`，**不是** `LM_LICENSE_FILE`

| 环境变量 | 结果 |
|---|---|
| `LM_LICENSE_FILE` | ❌ `Unable to checkout a license` |
| **`SALT_LICENSE_SERVER`** | ✅ **通过** |

⚠️ 官方授权邮件里那句 *"establish an environment variable (LM_LICENSE_FILE)"* **是过时说法**（Siemens 已改用 SALT 授权机制）。

### ② 路径必须是**纯 ASCII**

Questa 内部 sqlite3 **无法处理中文路径**：

```
sqlite3_open C:/Users/25437/Desktop/竞赛/嵌入式.../work/_lib.qdb
             →  unable to open database file     （中文全变乱码）
```

**⇒ 中文工作区不能直接跑仿真**，必须用 `C:\fpga_work\`。手工补建 `_temp` 目录**无效**，换 ASCII 路径才是正解。

### ③ `vlog` 免 license，`vsim` 要 license

| 工具 | 需要 license？ | 说明 |
|---|---|---|
| **`vlog`**（编译 / **解密加密 IP**） | ❌ 不需要 | 所以加密 IP 的**解密验证**不受 license 影响 |
| **`vsim`**（仿真） | ✅ 需要 | 必须设 `SALT_LICENSE_SERVER` |

---

## 三、已验证能力

| 能力 | 状态 | 证据 |
|---|---|---|
| 编译 **Efinix 加密 IP** | ✅ | `wr_drive.v` 解密成功，`Errors: 0` |
| 仿真 **Efinity DSP48 原语** | ✅ | `EFX_DSP48` + 15 个子模块编译通过 |
| 跑 **Alpha 混合**断言 | ✅ | `full-fg` / `full-bg` / `half` **3/3 PASS** |
| 与 **iVerilog 结果对照** | ✅ | 两套仿真器结论一致 |

---

## 四、用法

### 方式 1：`.cmd`（推荐）

```cmd
cd C:\fpga_work
scripts\sim.cmd tb_alpha_blend "src\alpha_blend.v tb\tb_alpha_blend.v" "C:\Efinity\2026.1\sim_models\verilog\efx_dsp48.v"
```

**参数格式**：`TOP "文件1 文件2 ..." "原语1 原语2 ..."`

- 用**引号包住列表**，内部用**空格**分隔
- ⚠️ **绝不要用逗号分隔**（原因见 §五.1）
- 第三个参数可省略

### 方式 2：直接调 `.ps1`

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\fpga_work\scripts\sim.ps1 `
  -Top tb_alpha_blend `
  -Files "src\alpha_blend.v tb\tb_alpha_blend.v" `
  -PrimLibs "C:\Efinity\2026.1\sim_models\verilog\efx_dsp48.v"
```

### 方式 3：iVerilog（日常快速迭代）

```powershell
$env:Path += ';C:\Users\25437\iverilog\bin'
iverilog -g2005 -o sim.out a.v tb_a.v "C:\Efinity\2026.1\sim_models\verilog\efx_dsp48.v"
vvp sim.out
```

**两套都保留**：iVerilog 秒级启动、适合日常；Questa 处理加密 IP / SystemVerilog / 大规模设计。

### 源码同步

`C:\fpga_work\scripts\sync.ps1` 把工作区的 RTL 同步到 ASCII 仿真区：

```cmd
powershell -ExecutionPolicy Bypass -File C:\fpga_work\scripts\sync.ps1 -Source "<工作区路径>"
```

---

## 五、踩过的坑（按调试代价排序，**都有实测证据**）

| # | 坑 | 症状 | 正解 |
|---|---|---|---|
| **1** | **`cmd.exe` 把 `,` `;` `=` 当参数分隔符** | `"a.v,b.v"` 到 cmd 里**已被拆成两个参数**，导致后续参数**整体错位一格**；曾把 `efx_dsp48.v` 挤掉，报 `Module 'EFX_DSP48' is not defined` | **引号 + 空格**分隔 |
| **2** | **PowerShell `-File` 不把多个裸参数收进 `[string[]]`** | 只绑定第一个，其余变**位置参数**（曾把源文件塞进 `-Work`，报 `Cannot find path`）| 参数声明为 **`[string]`**，脚本内部 Split |
| **3** | **Questa 不支持中文路径** | `sqlite3_open ... unable to open database file` | 用 **`C:\fpga_work\`** |
| **4** | **执行策略禁止 `.ps1`** | `无法加载文件...禁止运行脚本` | `.cmd` 里加 **`-ExecutionPolicy Bypass`**（只影响当次进程，**不改系统**）|
| **5** | **`.cmd` 里有非 ASCII 字符** | `'Questa' is not recognized...` —— 注释行被吃坏 | **`.cmd` 保持全 ASCII**（cmd 按 ANSI 解码）|
| **6** | **`pwsh` 不在 PATH** | `'pwsh' is not recognized` | fallback 用 `powershell`（本机 DSH 用的就是 PS 5.1）|
| **7** | `C:\flexlm` 无写权限 | `对路径...的访问被拒绝` | license 改放**用户目录**（`C:\Users\25437\flexlm\`）|

> **★ 根规律**：**cmd 和 PowerShell 都会"替你先解释一遍"参数** —— cmd 认逗号分号等号，PowerShell 的 `-File` 不做贪婪数组绑定。
> 凡是要按字面传递的东西，**用引号包成单个字符串、由脚本自己解析**，最不容易出错。

---

## 六、备份位置

脚本已备份到工作区（防 `C:\fpga_work` 被误删）：

- `work\scripts\sim.ps1`
- `work\scripts\sim.cmd`
- `work\scripts\sync.ps1`

---

## 七、待办

| # | 事项 | 说明 |
|---|---|---|
| 1 | **永久配置 `SALT_LICENSE_SERVER`** | 目前是 wrapper 临时设；若要让 **Efinity 的 `--modelsim` 开关**也能直接调 Questa，需写入系统环境变量（**尚未执行，等用户授权**）|
| 2 | 把 Questa 加进 PATH | 同上，为了 Efinity 命令行集成 |
| 3 | 验证 Efinity `efx_run --flow rtlsim --modelsim` | 需要 1+2 完成后才能测 |
