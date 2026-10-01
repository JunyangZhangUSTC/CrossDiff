# 摄影对比 / Photography Comparison

用于照片和参考作品的只读影调、配色与局部区域比较。完整版预装；基础版可安装同一插件包。普通图片的默认打开行为仍使用基础图片比较，摄影分析从“新建… → 摄影”进入。

Read-only tone, color and region comparison for photographs and reference images. Included in Full and installable in Base. Ordinary image opening keeps the basic image comparison; choose **New… → Photography** for analysis.

## 实现与边界 / Implementation and boundaries

- Apple ImageIO、Core Image 负责读取、色彩管理与 RAW 显影；OpenCV 负责 HSL 转换和直方图。插件中的 JavaScript 只比较宿主提供的聚合统计，不读取图片像素、文件路径或元数据，不实现底层摄影算法。
- RGB、HSL 明度和饱和度各 256 个分箱，色相 360 个分箱；均按有效采样像素数归一化。`S < 0.02` 为近中性色，不计入色相分布，所以色相总和等于 `1 - neutralFraction`。
- 输入分析空间必须一致。当前为统一 sRGB SDR 显示空间，明度为 HSL lightness，不是物理亮度或场景曝光。动态范围外的 RAW/HDR 信息不由这些分布表征。
- 输出说明仅陈述选区分布和百分比差异，不推断作者的曝光、HSL 滑块、白平衡、曲线参数，也不给作品打分。
- RAW 支持取决于具体机型、压缩模式和 macOS。扩展名只用于选择文件，不保证某型号可以解码。XMP 曲线只在源文件或用户显式选择的侧车文件中有记录时展示，不反推，不写回。

Apple ImageIO and Core Image handle decoding, color management and RAW development; OpenCV supplies HSL conversion and histograms. Restricted JavaScript compares only aggregate statistics supplied by the host. It receives no image pixels, file paths, metadata or file access. The plugin describes distributions rather than reconstructing editing settings, scene exposure or image quality. RAW support is camera-, compression- and macOS-dependent. Recorded XMP curves are shown when available; nothing is inferred or written back.

## 接口 / Contract

`photoAnalysis` → `crossdiff.photography/1`, `pairwise` only. Protocol 1 remains unchanged; older hosts reject the unsupported input kind.

Each input's `content` contains:

| Field | Constraint |
| --- | --- |
| `red`, `green`, `blue`, `lightness`, `saturation` | 256 finite values in `[0, 1]`, sum ≈ 1 |
| `hue` | 360 finite values in `[0, 1]`, sum ≈ `1 - neutralFraction` |
| `neutralFraction` | Finite value in `[0, 1]` |
| `analyzedPixels` | Positive integer, at most 100,000,000 |
| `sampled` | Whether analysis uses reduced samples |
| `analysisSpace` | Nonempty description, same on both sides |

`payload.findings` is an array of at most eight `{ "zhHans": "…", "en": "…" }` objects. Both translations are required; each is limited to 2,048 UTF-8 bytes. Standard result `diagnostics` describe interpretation and sampling limits. Host and plugin independently validate statistics before interpreting them.

## 打包与检查 / Package and check

在项目根目录执行 / From the project root:

```sh
bash scripts/tests/check-photography-plugin.sh
```

单独生成插件 / Build the standalone package:

```sh
source scripts/project-env.sh
python3 scripts/package-photography-plugin.py
```

产物 / Output: `dist/Plugins/Photography.crossdiffplugin`.

Release assets, edition bundles and the offline plugin catalog share `scripts/plugin_inventory.py`, including exact package hashes. This directory uses the repository's [AGPL-3.0-only license](../../../LICENSE) and [notices](../../../NOTICE).
