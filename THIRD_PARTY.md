# 第三方组件与许可

本项目主体（RTL / 固件 / 工具 / 脚本）以 **MIT** 许可发布（见 `LICENSE`）。
下列第三方组件按各自许可使用：

| 组件 | 来源 | 许可 | 使用方式 |
|---|---|---|---|
| **DawnLike 图块素材** | DawnBringer（opengameart.org）| **CC-BY 4.0** | 选取部分图块转为 RGB565 精灵，已署名 |
| **Noto Sans SC 点阵字模** | Google / Adobe | **SIL OFL 1.1** | 渲染为 32×32 点阵嵌入固件，作品不分发字体文件 |
| **mpaland/printf** | mpaland | **MIT** | `print_full.h` 内保留原作者版权头 |
| **DDR3 控制器 / Sapphire SoC** | Efinity IP | Efinity 许可 | 工程内实例化使用 |
| **TMDS 编码器** | 本项目自研 | MIT | `rtl/dvi_encoder.v` |

## 致谢

- **DawnLike** by DawnBringer —— 精灵图块素材（CC-BY 4.0）
- **Noto Sans SC** —— 中文点阵字模（SIL OFL 1.1）
- **mpaland/printf** —— 格式化输出（MIT）
- 易灵思 Efinity IP —— Sapphire SoC / DDR3 控制器
