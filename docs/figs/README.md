# docs/figs 的生成顺序

生成脚本在 `work/`（一次性，可重跑）：

| 顺序 | 脚本 | 产出 |
|---|---|---|
| 1 | `gen_diagrams2.py` | `fig2-engine.svg` —— **但它也会生成一份 fig1（第三版）** |
| 2 | `gen_fig1.py` | `fig1-system.svg`（第四版，当前） —— **必须后跑，否则被步骤 1 覆盖** |

⚠️ 2026-10-07 踩过：只跑 `gen_diagrams2.py` 会把 fig1 退回第三版，
而第三版的 DVI→HDMI 箭头穿过 `apb3_top` 框。**改完图后确认两个 svg 的大小**：
fig1 应是 9052 B，fig2 应是 10878 B。

SVG → PNG 用 Edge headless：

```
msedge --headless --disable-gpu --hide-scrollbars \
       --screenshot=<out.png> --window-size=1200,600 \
       --default-background-color=FFFFFFFF file:///<in.svg>
```

（文件路径含中文和空格时，空格要换成 %20。）