"use strict";

// The host parses bounded local records into typed fields, preserving JSON number
// lexemes. This restricted algorithm receives data only: no HTTP client, shell or
// filesystem is available. Values are compared before native credential masking.
const API_SECTIONS = ["request.summary", "request.query", "request.headers", "request.body",
    "response.summary", "response.headers", "response.body"];
const API_MAX_ROWS = 5000;
// Conservative UTF-16 serialized-character budget below the host's 8 MiB result cap.
const API_RESULT_BUDGET = 1700000;
function apiText(zh, en) { return { zhHans: zh, en: en }; }
function apiString(value, maximum) { return typeof value === "string" && value.length <= maximum; }
function apiPointer(value) { return apiString(value, 16384) && (!value.length || value[0] === "/") && !/~(?![01])/.test(value); }
function apiHeader(value) { return apiString(value, 256) && /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(value); }
function apiUnknown(field) { return field && field.type === "bodyState" && (field.value === "missing" || field.value === "unsupported"); }
function apiInput(content) {
    if (!content || !Array.isArray(content.sections) || !content.sections.length || content.sections.length > 7 ||
        !Array.isArray(content.diagnostics) || content.diagnostics.length > 128) throw new Error("Invalid HTTP exchange");
    const sections = new Map(); let count = 0;
    for (const section of content.sections) {
        if (!section || !API_SECTIONS.includes(section.id) || sections.has(section.id) || !Array.isArray(section.fields)) throw new Error("Invalid HTTP section");
        const fields = new Map(); count += section.fields.length;
        if (count > 5000) throw new Error("HTTP field limit exceeded");
        for (const field of section.fields) {
            if (!field || !apiString(field.key, 16384) || fields.has(field.key) || !apiString(field.label, 16384) ||
                !apiString(field.type, 64) || !field.type.length || !apiString(field.value, 1048576) ||
                typeof field.sensitive !== "boolean") throw new Error("Invalid HTTP field");
            fields.set(field.key, field);
        }
        sections.set(section.id, fields);
    }
    return sections;
}
function apiRules(options) {
    options = options || {};
    const headers = options.ignoreHeaders || [], pointers = options.ignoreJSONPointers || [];
    if (!Array.isArray(headers) || headers.length > 128 || headers.some(v => !apiHeader(v)) ||
        !Array.isArray(pointers) || pointers.length > 128 || pointers.some(v => !apiPointer(v))) throw new Error("Invalid API ignore rules");
    return { headers: new Set(headers.map(v => v.toLowerCase())), pointers: pointers };
}
function apiIgnored(section, key, rules) {
    if (section.endsWith(".headers")) {
        const token = key.split("/")[1] || "";
        return rules.headers.has(token.replace(/~1/g, "/").replace(/~0/g, "~").toLowerCase());
    }
    // '$state' and '$text' are protocol markers, never JSON pointers.
    if (section.endsWith(".body") && (key === "" || key[0] === "/")) {
        return rules.pointers.some(pointer => pointer === "" || key === pointer || key.startsWith(pointer + "/"));
    }
    return false;
}
function compare(request) {
    if (!request || request.protocolVersion !== 1 || request.mode !== "pairwise" ||
        !Array.isArray(request.inputs) || request.inputs.length !== 2) throw new Error("Unsupported API request");
    const l = request.inputs.find(v => v.role === "left"), r = request.inputs.find(v => v.role === "right");
    if (!l || !r) throw new Error("Missing API inputs");
    const left = apiInput(l.content), right = apiInput(r.content), rules = apiRules(request.options);
    const rows = [], counts = { same: 0, changed: 0, added: 0, removed: 0, ignored: 0, unknown: 0 };
    const diagnostics = []; let budget = 0, partial = false;
    for (const content of [l.content, r.content]) {
        for (const text of content.diagnostics) {
            if (!text || !apiString(text.zhHans, 4096) || !apiString(text.en, 4096) || !text.zhHans || !text.en) throw new Error("Invalid HTTP diagnostics");
            if (diagnostics.length < 120) diagnostics.push(apiText(text.zhHans, text.en));
        }
    }
    outer: for (const section of API_SECTIONS) {
        const a = left.get(section) || new Map(), b = right.get(section) || new Map();
        const keys = Array.from(new Set([...a.keys(), ...b.keys()]));
        const unknownBody = section.endsWith(".body") && (apiUnknown(a.get("$state")) || apiUnknown(b.get("$state")));
        // Stable source order within a section keeps JSON arrays and repeated fields
        // legible; key lookup means reordered object properties and headers stay equal.
        for (const key of keys) {
            const av = a.get(key), bv = b.get(key);
            let state;
            if (unknownBody || apiUnknown(av) || apiUnknown(bv)) state = "unknown";
            else if (apiIgnored(section, key, rules)) state = "ignored";
            else if (!av) state = "added";
            else if (!bv) state = "removed";
            else state = av.type === bv.type && av.value === bv.value ? "same" : "changed";
            const row = { id: "api-" + rows.length, section: section, path: key, label: (av || bv).label,
                left: av ? av.value : null, right: bv ? bv.value : null,
                leftType: av ? av.type : null, rightType: bv ? bv.type : null,
                state: state, sensitive: !!((av && av.sensitive) || (bv && bv.sensitive)) };
            const cost = JSON.stringify(row).length;
            if (rows.length >= API_MAX_ROWS || cost > API_RESULT_BUDGET - budget) { partial = true; break outer; }
            budget += cost; counts[state]++; rows.push(row);
        }
    }
    if (partial) diagnostics.push(apiText("结果达到显示上限，仅展示已比较的部分字段；以下计数不是全部差异。", "Result display limit reached; only a partial set of compared fields is shown. Counts below are not totals."));
    if (rules.headers.size || rules.pointers.length) diagnostics.push(apiText("忽略规则由用户明确设置；被忽略字段保留在结果中，可单独查看。", "Ignore rules are explicit user choices. Ignored fields remain in the result and can be inspected."));
    if (counts.unknown) diagnostics.push(apiText("正文缺失或格式不支持时，无法判断内容是否相同。", "Missing or unsupported bodies cannot be judged equal."));
    const hasRequest = s => s.has("request.summary"), hasResponse = s => s.has("response.summary");
    if (!hasRequest(left) || !hasRequest(right) || !hasResponse(left) || !hasResponse(right)) {
        diagnostics.push(apiText("仅比较记录中实际存在的请求或响应，未记录的部分不代表相同。", "Only requests and responses present in these records are compared. Unrecorded parts are not evidence of equality."));
    }
    const differences = counts.changed + counts.added + counts.removed;
    const summary = apiText((partial ? "已显示：" : "") + differences + " 处字段差异 · " + counts.ignored + " 项忽略 · " + counts.unknown + " 项未知",
        (partial ? "Shown: " : "") + differences + " field differences · " + counts.ignored + " ignored · " + counts.unknown + " unknown");
    return { protocolVersion: 1, runID: request.runID, schema: "crossdiff.api-exchange/1", status: partial ? "partial" : "completed",
        summary: summary, diagnostics: diagnostics, payload: { rows: rows, partial: partial } };
}
