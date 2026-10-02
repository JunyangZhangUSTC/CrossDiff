# Office Compare / 办公文档对比

CrossDiff 的官方只读内容比较插件，支持 `.docx`、`.xlsx`、`.pptx`。文件在本机由宿主解析，受限 JavaScript 只收到当前选定章节、工作表或幻灯片的结构快照；不执行宏、公式、外部关系或网络请求。

## 比较方式

- **Word / PowerPoint：** 提取段落、表格和幻灯片文字，用原始位置定位内容变化。原文件预览与结构差异分开。
- **Excel：** 先在选定工作表之间交叉匹配完整相同行，再按用户指定的一列或多列关键值配对修改。重复键和空键不强行匹配；重复相同行按出现顺序配对并显示歧义。
- **重排与插入分别表达：** 对相同内容和关键列配对使用最长递增子序列保留稳定顺序，避免新增一行导致后续所有行都被标记移动。位置配对不证明身份，不参与重排判断。
- **没有关键列时：** 相同行匹配后，其余行按剩余源顺序对照，明确标为位置配对，不宣称识别出记录身份。
- **类型、值、公式分别保留：** 数字使用原始字符串，公式和文件保存的缓存结果独立比较。缺失与空字符串不同，Unicode 码元精确比较。

首版不支持旧 `.doc`、`.xls`、`.ppt`，不还原完整排版，不把内容相同表述为文件或视觉效果完全相同。样式、字体和单元格格式只作辅助信息，不参与内容相同判定；未支持对象由宿主明确说明。Excel 缓存结果可能已过时，不会在比较时计算公式。

## 插件契约

清单声明 `inputKind: officeDocument`、`resultView: officeDocuments`，结果为 `crossdiff.office/1`，仅支持两方比较。需要提供 Office 原生视图的 CrossDiff 0.12.0 或更新宿主；Base 和 Full 具备同样的读取与显示能力，区别是是否预装插件。

每侧输入包含 `kind`、`sectionID`、`name`、`rows`。行包含稳定 `id`、从 1 开始的原始 `position`、`label` 和按列排序的 `cells`。单元格包含从 1 开始的 `column`、`type`、可空 `value` / `formula` / `format`。`options.keyColumns` 是最多 16 个、不重复的列号；关键列按类型、值、公式精确匹配，不自动转数字或忽略空格。

每侧最多 10,000 行、100,000 个单元格；单元格值及公式各最多 128 KiB UTF-8。宿主还限制整个请求与读取内容。算法使用散列表和 O(n log n) 顺序分析，不建立整张两两相似度矩阵。

结果仅含来源 ID、状态、匹配依据、重排和歧义标记。原生视图始终从已读取的源快照显示内容，插件不能注入替代文字或 HTML。宿主校验两侧完整覆盖、来源 ID 唯一性、真实内容状态及关键列依据。

## Development

The official read-only Office plugin compares extracted content from DOCX, XLSX and PPTX. It does not edit the originals, reconstruct full layouts, execute macros, evaluate formulas or retrieve external resources. Matching operates on one selected section per side; original row and cell positions are retained.

Excel matches exact rows across positions first, then unique user-selected composite keys. Duplicate and blank keys remain unpaired rather than being guessed. Repeated identical rows are paired by occurrence with ambiguity disclosed. Without keys, remaining rows use explicitly labelled positional comparison. A longest-increasing-subsequence backbone of exact and keyed matches distinguishes reordered pairs from shifts caused by insertion. Positional pairs do not establish identity and never claim movement.

Cell types, original numeric strings, formulas and saved cached values are compared separately. Absent values and empty strings remain distinct. Styling and layout are excluded from equality; cached formula results are not recalculated. Legacy DOC/XLS/PPT are unsupported in this version.

The host validates typed inputs, source coverage, pairing identities and content status. Results contain references to source rows, never replacement rendering content. Install this package into an Office-capable CrossDiff 0.12.0+ host; both application editions include the same native Office services.

```sh
source scripts/project-env.sh
python3 scripts/package-office-plugin.py
bash scripts/tests/check-office-plugin.sh
```
