# 2D 图形渲染加速引擎（RISC-V + FPGA 异构）

> 面向嵌入式 GUI 与 2D 游戏的硬件渲染加速引擎，运行在易灵思 Titanium **Ti60F225** 上。
> 同屏 **1500 个 8×8 精灵 @ 59.2 fps**（1080p60），CPU 每帧零像素操作。

---

## 一、这是什么

一套**可复用的 2D 图形渲染链路**：RISC-V 主控下发命令，FPGA 硬件完成全部像素搬运与合成，
DDR3 双缓冲，HDMI 1080p60 输出。

**五项硬件能力**

| 操作 | 说明 |
|---|---|
| `FILL` | 纯色填充 |
| `COPY` | 位块拷贝（BitBlt）|
| `ALPHA` | Alpha 混合 |
| `COLOR KEY` | 颜色键控去背 |
| `BLIT` | 键控 + Alpha 同时生效的混合位块传输 |

**三项架构级优化**（对应赛题"异构架构典型瓶颈"）

| 层 | 优化 | 效果 |
|---|---|---|
| **调度层** | 精灵表遍历器（`gfx_sprtab`）| CPU 每帧仅一个启动信号，寄存器操作归零 |
| **缓存层** | 四槽直接映射位图缓存 | 命中 17 周期 vs DDR 650 周期，渲染 45ms → 0.92ms |
| **传输层** | 短突发 → 整块长突发重构 | 总线有效带宽 33% → 88% |

---

## 二、实测指标

| 指标 | 数值 |
|---|---|
| 同屏精灵 | **1500 × 8×8 @ 59.2 fps** |
| 扫描欠载率 | 0.04 %（23656 帧中 9 帧）|
| CPU 每帧精灵操作 | 0 次 |
| 总线有效带宽 | 88 % |
| 大图切换 | 6 张 1920×1080 整图，53.8 fps |
| 软件渲染对比 | 同场景 3.1 fps（大图）/ 14.9 fps（精灵）→ 加速比 20× / 4× |

---

## 三、目录结构

| 目录 | 内容 |
|---|---|
| `rtl/` | **RTL 本体**：`gfx_core` / `gfx_regs` / `gfx_mem` / `gfx_scanout` / `gfx_sprtab` / `gfx_top` / `system_top_gfx` |
| `fpga/` | **Efinity 工程**：`gfx2_system.xml` + 约束 `*.peri.xml` + `*.pdefn` |
| `tb/` | 测试台（自检式）|
| `work/gfx_demo/` | **RISC-V 固件**：`main.c` / `game.h` / `gfx.h` / 资源头文件 |
| `work/docimg/` | 文档插图（流程图、引擎数据通路、实拍证据图）|
| `work/ref/` | 参考素材（DawnLike 图块）|
| `tools/` | 资源生成工具：字模点阵、精灵打包、位图转换 |
| `scripts/` | 构建与烧录脚本 |
| `docs/` | 设计文档（架构、接口、优化记录、验证报告）|

---

## 四、构建

### 1. FPGA 工程

```
Efinity 2026.1 打开 fpga/gfx2_system.xml
→ IP（Sapphire SoC / DDR3）由 XML 自动加载
→ 综合 → 布局布线 → 比特流
→ JTAG 烧录
```

### 2. 固件

```
工具链：xpack riscv-none-elf-gcc 15.2.0（rv32im_zicsr / ilp32）
头文件：work/gfx_demo/src/
链接：BSP 提供的 default.ld
```

### 3. 烧录顺序（重要）

```
1. 烧 JTAG bridge（Efinity 自带 u10660A79.bit）
2. 经 bridge 烧固件到 SPI Flash 0x380000
3. 烧应用比特流
```

> 烧比特流会覆盖 bridge —— 所以再烧固件前要重烧 bridge。

---

## 五、许可

| 部分 | 许可 |
|---|---|
| RTL / 固件 / 工具源码 | **MIT**（见 `LICENSE`）|
| 文档 | CC-BY 4.0 |
| 精灵素材（DawnLike）| **CC-BY 4.0**，署名 DawnBringer |
| 中文字模 | **SIL OFL 1.1**（Noto Sans SC 渲染）|
| printf（mpaland）| MIT |
| DDR3 / Sapphire SoC | Efinity IP 许可 |

---

## 六、致谢

- **DawnLike** by DawnBringer（CC-BY 4.0）—— 精灵图块素材
- **Noto Sans SC**（SIL OFL 1.1）—— 中文点阵字模
- **mpaland/printf**（MIT）—— 格式化输出
- 易灵思 Efinity IP —— Sapphire SoC / DDR3 控制器
