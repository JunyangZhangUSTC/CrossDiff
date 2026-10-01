# API Compare / API 对比

Read-only, local HTTP request and response comparison. Full bundles this official
plugin; Base can install `CrossDiff-Plugin-API-0.1.0.crossdiffplugin` separately.
The host imports HTTP messages, copied cURL commands and HAR records. It does not
execute cURL, send requests, follow URLs or access files named in commands.

## What is compared

- Request method and address; query parameters with repeated values in order.
- Request and response headers. Header names are ASCII case-insensitive; ordering
  different names is irrelevant, while repeated occurrences remain distinct.
- Status code, explicitly recorded protocol details and bodies.
- JSON containers and leaves by RFC 6901 pointer, preserving type, array order,
  exact number lexemes, missing fields and null. Formatting and object-key order
  do not create differences. Number spellings such as `1` and `1.0` remain visible.
- Plain text bodies exactly as recorded. Missing or unsupported bodies are unknown,
  never silently marked equal.

Ignore rules default to empty. Named headers can be ignored case-insensitively;
JSON pointer rules include the selected node and its descendants in both bodies.
Ignored rows remain visible. Credentials are compared as original values, with
native presentation masking that the user can explicitly reveal; masking is not
anonymization of the imported source.

The restricted JavaScript algorithm receives bounded typed fields and emits
`crossdiff.api-exchange/1`. Up to 5,000 result rows and a conservative serialized
size budget are shown. A limit produces an explicitly partial result and counts
only for shown rows. This is not API execution, OpenAPI compatibility analysis,
TCP packet analysis or a log viewer.

## 中文

本插件只读、离线比较 HTTP 请求与响应，支持 HTTP 文本、复制的 cURL 命令和
HAR 记录。cURL 仅解析文本，不执行命令、不发送请求、不读取命令引用的文件。
完整版本内置插件；基础版本可以安装独立插件包。

可比较方法、地址、查询参数、请求头、状态和正文。JSON 逐字段比较，保留类型、
数组顺序、大整数原始字面值、“字段不存在”与 `null` 的区别；不因缩进或对象
字段顺序产生差异。重复请求头与查询参数按出现顺序保留。正文未记录或不支持时
显示未知。忽略请求头和 JSON 路径需明确设置，忽略项仍可查看；JSON 路径规则
包含该节点及其子节点。超过行数或大小预算时明确显示部分结果。

Build / 打包：`python3 scripts/package-api-plugin.py --output dist/plugins/CrossDiff-Plugin-API-0.1.0.crossdiffplugin`
