# tb_mux_video 调查：从组合环路到换 FIFO

> 日期：2026-10-06
> 状态：**环路已根治（换 FIFO）；剩下一个数据流问题待查**
> ⚠️ 全部改动都在仿真层，**从未上板**

---

## 一、结论速览

| 项 | 状态 |
|---|---|
| **仿真卡在 t=130.6 µs** | ✅ **根治** —— 换掉厂商 FIFO，现在跑完全程 1.12 ms |
| **新 FIFO `async_fifo_gray.v`** | ✅ **153 项独立验证 + iVerilog/Questa 双过** |
| **`wcnt` 满时报 0** | ✅ **修好**（位宽 `AW` → `AW+1`）|
| **`tb_bitblt_video_out`** | ✅ **95996 项全过** |
| **`tb_mux_video`** | ⚠️ **跑完了，但 `pixels errors = 20528/22448`** —— **另一个独立问题** |

---

## 二、根因：厂商 FIFO 的状态输出组合依赖 handshake 输入

### 2.1 机理

**`dual_clock_fifo.v`（厂商代码）的【每一个】状态输出都组合依赖于 handshake 输入**：

```verilog
// line 471
assign w_empty = ((r_waddrg_2P == r_raddrg_1P) & (r_wflag_1P == r_rflag_1P)) ? 1'b1 :
                 (i_re & ((r_waddrg_1P == r_raddrg_1P) & (r_wflag_1P == r_rflag_1P))) ? 1'b1 :
                 1'b0;
// line 353 —— 同构
assign w_full  = ... (i_we & ...) ...;

// 派生输出
assign o_empty  = w_empty_P;                      // 依赖 i_re
assign o_aempty = w_empty_P | (...);              // 依赖 i_re
assign o_full   = w_full_P;                       // 依赖 i_we
assign o_afull  = w_full_P | (...);               // 依赖 i_we
assign o_rcnt   = w_full_P ? 0 : rd_cnt[...];     // 依赖 w_full_P
```

**而 `bitblt_video_out.v` 把状态直接接回 handshake**：

```verilog
wire fifo_we = splitting & ~fifo_full;
wire fifo_re = de_raw   & ~fifo_empty;
```

**⇒ 双向环路。**

### 2.2 这个环路是**每次构建都在生产路径上**的

**⇒ 不是测试台的问题，`bitblt_top` / `system_top` 里用的也是这份代码。**

### 2.3 环路只在特定条件闭合

| 测试台 | 是否触发 | 原因 |
|---|---|---|
| **`tb_fifo_latency`** | ❌ | 只写 3 个 word，从不到边界 |
| **`tb_bitblt_video_out`** | ❌ | 单行场景 |
| **`tb_mux_video`** | ✅ | 跑到第 4 行时撞上 |

### 2.4 两个仿真器的表现截然不同

| 仿真器 | 表现 |
|---|---|
| **iVerilog** | **静默挂起** —— 时间停止推进、CPU 满载、**无任何信号变化**（VCD 里看不到，因为值稳定）|
| **Questa** | **`vsim-3601 Iteration limit 10000000 reached at time 130615 ns`** |

**⇒ 教训**：**判断仿真是否卡住，跑 Questa 看 `Iteration` 数** —— 一次定性。**别用日志尾部**（重定向有缓冲，能滞后十几分钟，我因此误判三次）。

---

## 三、四次失败的修复尝试

| # | 方案 | `tb_bitblt_video_out` | 失败原因 |
|---|---|---|---|
| **①** | 只延迟 `empty` | FAIL 95847 | **`i_re` 项是「读完即空」的提前预警，延迟它 ⇒ 多读一拍 ⇒ 读指针超前 ⇒ `wr_cnt` 溢出 ⇒ `o_wcnt` 饱和 ⇒ `need_line` 永久为假** |
| **②** | 改用 `o_rcnt` | FAIL 96000 | **语义不对：`o_rcnt = w_full_P ? 0 : ...`，满和空都报 0** |
| **③** | 自己数 `wr_cnt`/`rd_cnt` | FAIL 95999 | **跨时钟域比较两个自由运行的二进制计数器，无界** |
| **④** | 成对延迟 `de_raw`+`empty` | FAIL 95848 | **改变了脉冲相位，无法用固定级数对齐** |

**⇒ 共同错误**：**每次都用「推演」得到时序关系就动手，而从不测量。**

---

## 四、解法：自己写一个 `full`/`empty` 寄存的 FIFO

### 4.1 关键设计点

**⇒ 标准格雷码 FIFO 的 `full` 【也】组合依赖 `we`（它要预测「下一拍是否满」）** —— **所以换 FIFO 本身不解决问题。**

**⇒ 真正的区别是【把 `full`/`empty` 做成寄存器输出】**：

```verilog
// 厂商（组合）⇒ i_we → o_full → i_we  成环
assign o_full = w_full_P;

// 新（寄存）⇒ 无从 i_we 回来的组合路径
always @(posedge wclk) wfull <= wfull_n;
```

**⇒ 无延迟代价**：**写操作本身就是下一拍的事，寄存的 `full` 一样及时。**

### 4.2 `rtl/async_fifo_gray.v`

| 特性 | 说明 |
|---|---|
| **指针** | **格雷码，各多一位区分满/空** |
| **跨域** | **两级同步器** |
| **`full`/`empty`** | **寄存器输出** |
| **`rdata`** | **组合（真 FWFT）** |
| **`wcnt_o`** | **`AW+1` 位**（见 §5）|

### 4.3 验证：`tb/tb_async_fifo_gray.v`

**⇒ 153 项检查，覆盖**：

| # | 测试 |
|---|---|
| **1** | **复位状态** |
| **2** | **单字往返** |
| **2b** | **`wcnt` 占用计数（写 5 读 2 ⇒ 应为 3）** |
| **3** | **写满：恰好吸收 2^AW 个，`wfull` 置位** |
| **4** | **满时写被忽略（指针不动）** |
| **5** | **排空顺序正确，`rempty` 置位** |
| **6** | **空时读被忽略** |
| **7** | **同时读写 64 字，顺序正确** |
| **8** | **★ 组合反馈：`we = ~wfull`、`re = ~rempty`（厂商死在这里）** |
| **9** | **★ 延迟测量：确认是真 FWFT（`re` 未拉高数据已在）** |

**⇒ 两个仿真器结果**：

```
iVerilog : checks=153  errors=0  RESULT: PASS
Questa   : checks=153  errors=0  RESULT: PASS   Iteration: 1     ← ★
```

**⇒ `Iteration: 1` vs 厂商的 `Iteration limit 10000000` —— 相差一千万倍，这是无可辩驳的判据。**

### 4.4 换入 `bitblt_video_out` 的改动（4 处）

| 项 | 厂商 | 新 | 说明 |
|---|---|---|---|
| **例化** | `dual_clock_fifo_wrapper` | `async_fifo_gray` | —— |
| **`de` 对齐** | **`de = de_d1`（延迟一拍）** | **`de = fifo_re`（组合）** | **★ 关键**：厂商 `rdata` 在 `re` 后一拍，新的是同拍（test 9 实测）|
| **`wcnt` 端口** | `o_wcnt` | `wcnt_o` | —— |
| **`wcnt` 位宽** | `[FIFO_AW-1:0]` | `[FIFO_AW:0]` | 见 §5 |

**⇒ 这次【一次成功】**（`tb_bitblt_video_out` 95996 项全过）—— **因为先测了延迟再改，而不是推演。**

---

## 五、顺手修掉的坑：`wcnt` 满时报 0

**⇒ 我在写新 FIFO 时把 `wcnt_o` 定义成 `[AW-1:0]`**：

```verilog
assign wcnt_o = wbin[AW-1:0] - rbin_s2[AW-1:0];    // 只算低 AW 位
```

**⇒ 深度是 2^AW，满时指针差 = 2^AW，其低 AW 位【全是 0】** ⇒ **满时报 0。**

**🚨 这和厂商 `o_rcnt`「满时也报 0」是【一模一样的缺陷】—— 我在换 FIFO 时把它复制了过来。**

**⇒ 症状**：`wcnt=0` 与 `fifo_full=1` 同时出现 ⇒ `need_line` 判断基于错值。

**⇒ 修法**：`wcnt_o` 改成 `[AW:0]`，满时报 2^AW（2048）。**连带改 `video_out` 的 `fifo_wcnt` 位宽与 `wcnt16` 拼接。**

---

## 六、✅ 本节所述问题已解决（见 `docs/37`）

**⇒ 当时记录的残留症状：**

```
wcnt 恒定 2048       ⇒ FIFO 长期满
splitting=1 且卡住    ⇒ 写侧在等空间
need_line 被 !splitting 挡住 ⇒ 不发新读
AR bursts S4 = 4     ⇒ 只读 4 行（地址全对）
rows seen = 35       ⇒ 却显示 35 行
```

**⇒ 算术上的矛盾（4 次读只提供 2544 个像素，却显示 35 行 = 22400 个）正是线索。**

### 根因（2026-10-06 查明）

**⇒ 不在 RTL，在【测试台的队列数组越界】：**

```verilog
localparam QD = 4;
reg [7:0] q_len [0:QD-1];      // ← 只有 4 个位置（0..3）
reg [2:0] q_wr  = 3'd0;        // ← 3 位指针，走到 8 才回绕
```

**⇒ 第 5 个 AR 写 `q_len[4]` ⇒ 越界 ⇒ 读回 `x` ⇒ `cur_len = x` ⇒ `m_rlast = (beat_idx == x) = x` ⇒ `if (x)` **按假处理** ⇒ burst 结束条件静默失效 ⇒ `beat_idx` 涨到 5644 ⇒ 每次握手都重写同一批像素 ⇒ 灌满 FIFO ⇒ 卡住 `splitting` ⇒ 只读 4 行。**

**⇒ 修复：数组改成 `[0:7]`（匹配指针回绕点），并把非空判据改为 `q_wr != q_rd`。**

**⇒ 结果：`pixel errors = 0`、`AR bursts S4 = 37`、`RESULT: PASS`。** **详见 `docs/37-队列数组越界根因.md`。**

### ⚠️ 排查过程中的两个错误判断，值得记下

| 我的判断 | 实际 |
|---|---|
| **「`Axi_Mux` 把 beat 放大 7.6 倍」** | **错** —— **`v_rvalid` 与 `m_rvalid` 之间只隔一层与门（`S_R_Valid = R_Act_Cnl_List & M_R_Valid`），本就是同一个信号** |
| **「`q_cnt` 虚高导致越界启动」** | **错** —— **改完判据后数字一模一样；而且我随后加的数组初始化也用了 `QD` 作上界，同样没覆盖索引 4，所以也无效** |

**⇒ 教训：「改了没效果」是【排除假设】的强信号，那时就该转向，而不是接着改。**

---

## 七、可复用的教训

| # | 教训 | 依据 |
|---|---|---|
| **1** | **判断仿真是否卡住：跑 Questa 看 `Iteration` 数，或看 `$fflush` 的实时输出** | **日志重定向有缓冲，我因此误判三次** |
| **2** | **VCD 的「无 delta churn」【不能】排除组合环路** | **环路里信号值最终稳定，VCD 只记录变化** |
| **3** | **换数据源之前【先测它的延迟】** | **四次失败 vs 一次成功的唯一区别** |
| **4** | **「状态输出组合依赖 handshake 输入」的 IP 【不能】用于组合反馈** | **这是接口契约问题，改哪根线都没用** |
| **5** | **位宽：深度 2^N 的 FIFO，占用计数必须 N+1 位** | **否则满时报 0** |

---

## 八、当前文件状态

```
rtl/async_fifo_gray.v           新增，153 项验证通过
rtl/bitblt_video_out.v          已换 FIFO，4 处改动
tb/tb_async_fifo_gray.v         新增
tb/tb_mux_video.v               修掉 end_win 先用后声明、q_cnt 双赋值；加分段进度与 $fflush

备份：
  bitblt_video_out.v.bak-20261006-before-fifo-swap
  bitblt_video_out.v.failed-attempts-20261006      （四次失败尝试存档）

回归状态（iVerilog）：
  tb_bitblt_video_out   95996 checks   0 errors   PASS
  tb_async_fifo_gray      153 checks   0 errors   PASS
  tb_mux_video                        20528 errors  FAIL（数据流问题）
```
