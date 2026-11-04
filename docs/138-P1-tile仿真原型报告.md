# 138 · P1 tile 仿真原型报告（2026-11-02 深夜）

> **结论先行：概念成立（P1 PASS），三个问题全部用可执行模型给出实测数字。**
> 1. **写 burst**：tile + 双轴 8px 量化后，一个 8×8 精灵 **擦除 1 burst + 绘制 1 burst = 2 burst**；1500 精灵 = **3000 burst/帧**，2000 = **4000**，4000 = **8000**（现状 raster = 16 burst/精灵 = 64000）。
> 2. **像素逐字节一致**：1500/2000/4000 精灵、6/6/3 帧、含重叠与边缘位置，raster 与 tile 两种存储**逐字节 0 差异**（2,073,600 px/帧全比）；地址越界 0、填充区未被写坏；另用 Verilog 内存模型（128-bit beat + 16-bit 字节掩码）复核 tile burst 写入格式，**0 字节差异**。
> 3. **scan 读成本**：整带读 = **1080 burst/帧、259,200 beat/帧**，与现状**完全相同** ⇒ **293.0 拍/行 = 现状 100%（19.8% 行预算）**；band→bank 转置重建逐行 PASS。预取余量：16 banks（2 band）= **6.4 行/95 µs**（比现状 10~14 行浅）；24 banks（3 band，+24 RAM10，余 34 块够）= **14.4 行/213 µs（≥ 现状）**。
> 4. **额外发现（加强结论）**：现状 raster 因 x 不对齐，7/8 的位置每行要写 **2 beat（32 B）**才写 16 B 数据（1.875× 写放大）⇒ 现状写路径 = 64000 burst + **120,000 beat** ≈ **11.27 ms**，几乎就是 op6 的 11.6 ms 全部；tile 后 = 8000 burst + 64,000 beat = **2.93 ms（3.85×）**，引擎 op6 预计 **3.2~4.0 ms**。
> 5. **最小可行改造集见 §五**：scanout 加 tile 模式（必须）+ 引擎**新增** 8×8 快路径（不动原 raster 路径）+ 固件按场景选布局。**raster 场景（菜单/标题/CPU 渲染）可原样保留**，但 SPRITE/BULLET 场景内背景与 HUD 也必须走 tile（见 §五 的坑）。
> 6. **本轮未改任何 RTL、未跑 Efinity、未碰串口**。

---

## 一、方法与校准（为什么这些数字可信）

| 环节 | 方法 | 校准来源 |
|---|---|---|
| 现状写路径 | 现有 Verilog 仿真直接测量 | `tb_tab_core2.v` 实跑：op6 稳态 **8 write burst/命令**、x=100 时 **16 beat/命令**（1.875 beat/burst 的实例）|
| 现状写耗时 | F=11.8 拍/burst + c=3.1 拍/beat | Lead 两上板点拟合；64000 burst + 120000 beat = 1.127 M 拍 = **11.27 ms**，对齐实测引擎 11.6 ms |
| tile 写 | Python 行为模型（§二）| 同一套 F+c 模型；burst/beat 数由模型实测输出 |
| 像素一致性 | Python 字节级模型，raster vs tile→raster 全帧比对 | 另用 Verilog 内存模型复核 burst 写入格式（§三）|
| scan 读 | band burst 列表 + F/c 读模型 | 现状：240-beat burst = 293 拍（板测 rdcyc 316 k/帧 ÷1080），⇒ F_read=53、c_read=1.0 |

**复现命令**（工作区根目录）：
```bash
/c/Users/25437/anaconda3/python.exe work/p1_tile_model.py          # 3 个问题的全部数字 + PASS/FAIL
/c/Users/25437/anaconda3/python.exe work/gen_tile_vectors.py       # 生成 burst 向量
/c/Users/25437/iverilog/bin/iverilog -g2012 -o /tmp/tb.vvp work/tb_tile_burst.v
/c/Users/25437/iverilog/bin/vvp /tmp/tb.vvp                        # Verilog 内存模型应用 burst
```
产物：`work/p1_tile_model.py`、`work/p1_tile_metrics.json`、`work/gen_tile_vectors.py`、`work/tb_tile_burst.v`。

**模型要点**：
- tile 布局：`addr = FB + (y>>3)*0x8000 + (x>>3)*128 + (y&7)*16 + (x&7)*2`（band 填充到 4 KB）。
- 每个 8×8 精灵命令 = **1 个 burst、8 个 16 B beat**（每 beat 一行 8 px）；key 像素用 16-bit 字节掩码（每 px 2 bit）清除。
- 场景：位置整数积分 + 边界反弹，**发命令时量化**（`x&~7, y&~7`）；10% 精灵强制同位置以制造重叠；4 种图案、每图案 10 个 key 像素。

---

## 二、Q1：写 burst 数（实测输出）

```
N=1500  tile:  3000 bursts  24000 beats ->  1.10 ms | raster: 24000 bursts  45000 beats ->  4.23 ms  (3.85x)
N=2000  tile:  4000 bursts  32000 beats ->  1.46 ms | raster: 32000 bursts  60000 beats ->  5.64 ms  (3.85x)
N=4000  tile:  8000 bursts  64000 beats ->  2.93 ms | raster: 64000 bursts 120000 beats -> 11.27 ms  (3.85x)
N=4000  tile mix (25% op4 透明精灵): 9000 bursts 72000 beats -> 3.29 ms（每精灵 fill 1 + 背景读 1 + 写 1）
```

**回答**：一个 8×8 精灵"擦除+绘制"确实 = **2 个 burst**（fill 1 + draw 1）；1500→**3000**、2000→**4000**、4000→**8000**。
- 现状 raster 同一工作量 = **16 burst/精灵**（8 行 × 擦/画各一）。
- tile 不但 burst −87%，beat 也从 120,000 降到 **64,000**（−47%）：现状 x 不对齐时每行要写 2 beat 才覆盖 16 B 数据（1.875× 写放大），tile 量化后每 beat 恰好 16 B。
- 25% 半透明（op4）混排时 = **2.25 burst/精灵**（4000 → 9000 burst / 3.29 ms），仍远好于现状。

**引擎 op6 总时间估计**：现状模型 11.27 ms ≈ 实测 11.6 ms（非写部分 ≤0.4 ms）⇒ tile 后 ≈ **3.2~4.0 ms**（未含 PnR 影响）。这比 docs/137 的 5.0 ms 估计更乐观，因为核对了 1.875 beat/burst 的写放大。

---

## 三、Q2：raster vs tile 像素逐字节一致

| 场景 | 帧数 | 全帧比对（1920×1080 px/帧）| 结果 |
|---|---|---|---|
| 1500 精灵（含 10% 重叠、含透明 key）| 6 | 12,441,600 px | **0 差异** |
| 2000 精灵 | 6 | 12,441,600 px | **0 差异** |
| 4000 精灵 | 3 | 6,220,800 px | **0 差异** |
| 地址越界 / 4×8 tile 对齐 / padding 未写 | — | 逐 burst 校验 | 0 违规，padding 哨兵值未被破坏 |

**Verilog 复核**（`tb_tile_burst.v`）：把 6 笔 tile burst（3 fill + 3 draw，含 key 掩码）以"128-bit 数据 + 16-bit 字节掩码"写入 Verilog 内存模型，再与 Python 字节模型比对 64 KiB 全量：

```
TB_TILE_BURST: 6 transactions x 8 beats applied
verilog words: 4096 | expected bytes: 65536 | got bytes: 65536
byte mismatches: 0  PASS: Verilog 16-bit-strobe burst writes == Python byte model
```

**回答**：两种存储下的最终帧缓冲**逐字节相同**；tile burst 的地址/beat/字节掩码格式在 Verilog 硬件语义下同样正确。
（前提：精灵位置在**发命令时**量化到 8 px；量化后的擦除/绘制与 raster 覆盖完全相同的像素集合，因为 8×8 精灵 = 1 个 tile。）

**量化的画面代价（模型实测）**：1500 精灵场景，量化后每帧有 **6.34% 的像素**与"不量化 raster"不同（≈ 96k px 精灵面积 + 重叠/擦除边界效应）。这是纯视觉代价，供你/用户判断是否可接受。

---

## 四、Q3：scan 整带读成本与预取余量

| 项 | 现状 raster | tile 整带读 |
|---|---|---|
| 每帧 burst | 1080（每行 1 × 240 beat）| **1080**（每 band 8 burst：7×256 + 1×128 beat）|
| 每帧 beat | 259,200 | **259,200** |
| 每帧拍数（模型）| 316,440 | **316,440** |
| 每行拍数 | 293.0 | **293.0（= 100%，19.8% 行预算）** |
| 4 KB 跨界 | — | 0（band 4 KB 对齐，逐 burst 校验）|
| band→bank 转置重建 | — | **逐行 PASS**（beat i → bank=band×8+(i%8)，字地址=i/8）|

**预取余量（单次停顿容限，模型二分搜索）**：

| 缓冲 | banks | RAM10 | 容限 | 相对现状(10~14 行) |
|---|---|---|---|---|
| 2 band | 16 | 48（现状）| **95 µs = 6.4 行** | 浅 36% |
| **3 band** | **24** | **72（+24，余 34 → 够）** | **213 µs = 14.4 行** | **≥ 现状 ✅** |
| 4 band | 32 | 96（放不下）| 332 µs = 22.4 行 | — |

- 消隐期 45 行 = 66,645 拍，预取 2 band 只需 4,688 拍 ⇒ **帧首可把 16 行全部填满**（比现状消隐期 14 行略好）。
- **建议 24 banks（3 band）**：多 24 块 RAM10，仍余 10 块；不追求更大余量是因为 32 banks 放不下。
- 附带好处：4 KB 对齐的连续 band 读比现在每行 3,840 B 更规整（跨页更少）。

---

## 五、最小可行改造集（P1 通过后的动手清单）

### 必须改
| # | 文件 | 改什么 | 风险 |
|---|---|---|---|
| 1 | `gfx_scanout.v` | 新增 **tile 模式**：预取从"2 行/请求"改为 **1 band/请求**（8 burst，4 KB 切分）；beat→(bank, 字地址) 转置；**原 raster 模式保留**（模式位选择）| 中 |
| 2 | `gfx_regs.v` / `gfx_top.v` | `R_FBCFG(0x4C)` 加 1 bit tile 模式（随 fb_commit 一起生效）；band stride 由 `fb_w×8×2` 推导（0x8000），`fb_stride` 在 tile 模式下改语义 | 低 |
| 3 | `gfx_core.v` | **只新增** tile 快路径状态：`TILE_FILL / TILE_COPY_KEY_NB / TILE_BLIT`（8×8、1 burst 128 B；op4 多一次 128 B 背景读）。**现有 raster 行/段路径一行不动** | 中（加法式，可回退）|
| 4 | `gfx_sprtab.v` | SPRITE/BULLET 场景发射 tile 命令（x,y 量化）；其它场景/老路径保持 | 低 |
| 5 | 固件 | 按场景选布局（scene 切换时随 commit 切模式）；SPRITE/BULLET 位置量化；截图/自检按 tile 解码 | 低-中 |
| — | **FB 常量** | `FB_A/FB_B/SPR_BASE` **一个都不用改**（band 填充 0x8000×135 = 0x438000）| 无 |
| — | `gfx_mem.v` | **不用改**：tile 写 8 beat、scan band burst ≤256 beat 都在现有接口内（`rd0_beats[8:0]`、`wr_beats[4:0]` 均够用）| 无 |

### "其他场景走原路径"的兼容策略 —— 可行，但有两个坑
- ✅ **可行**：一个 FB 每帧只有一种布局；用 `R_FBCFG` 的 tile 位随 `fb_commit` 原子切换，**SC_FILL / CPU 渲染 / gallery / 菜单全部保持 raster 原路径**（不重写、不回归）。
- ⚠️ **坑 1**：SPRITE/BULLET 场景**不只有精灵**——背景（全宽渐变 7 段）和 HUD 也在同一个 FB 里，必须 tile 化：
  - 背景 = 全宽 solid/渐变 = **band 连续填充**（tile 布局下整 band 是连续 30,720 B）；建议新增 `TILE_BAND_FILL` 命令，用现有 31-beat burst 拆 62 次/burst-band（整屏约 8,370 burst ≈ **10.5 ms，每场景一次**，可接受；不需要改 gfx_mem）；
  - HUD 文字/图标 = 8×8 字形/图元 → **直接复用精灵快路径**（位置量化到 8 px）。
- ⚠️ **坑 2**：CPU 直接写 FB 的路径（自检、UART 截图、CPU 渲染回退）在 tile 场景要按 tile 解码/编码；SPRITE/BULLET 场景的**自检 6/6 期望值需要重写**。

### 建议实施顺序（每步可停）
1. **P2（scanout 单点验证，~1 天）**：scanout tile 模式 + 固件在 tile 布局下用现有命令画一张静态图（用 8×8 精灵 + band 填充）→ 上板验证 scan 读/DVI；
2. **P3（引擎快路径，~1 天）**：core 三个 tile 命令 + walker；SIM 对照 TB（复用本 P1 模型做 golden）→ 上板 SPRITE 场景；
3. **P4**：4000 精灵整机 + 量化视觉调参。

---

## 六、风险与时间

| # | 风险 | 等级 | 说明/缓解 |
|---|---|---|---|
| 1 | **PnR/DVI 黑屏抽签** | 🔴 高 | docs/135：DVI 稳定性由布局决定，曾 30 seed 全失败；本方案 scanout 增加转置逻辑 + 24 banks（+24 RAM10），LUT/RAM 变化会重洗布局。缓解：保留黄金 bit、分阶段上板、P2 先单独验证 |
| 2 | 正确性（转置/翻页/epoch/裁剪）| 🟡 中 | P1 已证像素等价与转置正确；剩余风险在 RTL 实现与模式切换的原子性 |
| 3 | **量化视觉代价** | 🟡 中 | 模型实测 6.34% 像素/帧不同；用户已同意"先试试"，P4 再调（可先只量化横向）|
| 4 | scan 余量（16 banks 仅 6.4 行）| 🟡 中 | 推荐 24 banks（14.4 行，≥现状）；不加也可先试，band 读更连续 |
| 5 | 时间（11-4 交付）| 🔴 高 | 最小集乐观 **2~3 天**（含 1~2 轮 PnR 抽卡 + 上板验证）；P2/P3 任何一步不顺都建议停在黄金版 |
| 6 | 帧率上限 | 🟡 中 | 引擎降到 ~3.5 ms 后瓶颈转到 CPU（12.6 ms）与 vsync；本方案主要治**黑屏/under**，60fps 需 CPU 侧配合 |

**结论给 Lead**：P1 概念验证通过；建议按 P2→P3 分阶段落地（先 scanout 单点、再引擎快路径），每阶段都保留回退。若时间只剩 1 天，建议只做 **P2 + 引擎快路径的 8×8 精灵子集**，并接受"菜单/标题仍为 raster 模式"。
