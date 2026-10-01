// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Junyang Zhang. See LICENSE in the corresponding source.
"use strict";

// This algorithm lives entirely in the installable plugin, not in the host.
// The host supplies plain text and renders the returned, validated table.
function compare(request) {
    function canonical(value, depth) {
        if (depth > 32) throw new Error("JSON nesting exceeds 32 levels / JSON 嵌套超过 32 层");
        if (typeof value === "number" && (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value)))) {
            throw new Error("Unsafe JSON number; use text comparison / 数值超出安全精度，请用文本比较");
        }
        if (value === null || typeof value !== "object") return JSON.stringify(value);
        if (Array.isArray(value)) return "[" + value.map(v => canonical(v, depth + 1)).join(",") + "]";
        return "{" + Object.keys(value).sort().map(k => JSON.stringify(k) + ":" + canonical(value[k], depth + 1)).join(",") + "}";
    }
    const left = JSON.parse(request.inputs.find(input => input.role === "left").content.text);
    const right = JSON.parse(request.inputs.find(input => input.role === "right").content.text);
    const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
    const a = object(left) ? left : {"(root)": left};
    const b = object(right) ? right : {"(root)": right};
    const keys = Array.from(new Set(Object.keys(a).concat(Object.keys(b)))).sort();
    if (keys.length > 5000) throw new Error("More than 5000 keys / 超过 5000 个键");
    const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
    const rows = keys.map(key => {
        const l = own(a, key), r = own(b, key);
        const lv = l ? canonical(a[key], 0) : "";
        const rv = r ? canonical(b[key], 0) : "";
        if (lv.length > 8000 || rv.length > 8000 || key.length > 8000) {
            throw new Error("Value too large for table; use text comparison / 表格值过长，请用文本比较");
        }
        return {label: key, left: lv, right: rv, state: !l ? "added" : !r ? "removed" : lv === rv ? "same" : "changed"};
    });
    const changes = rows.filter(row => row.state !== "same").length;
    return {
        protocolVersion: 1, runID: request.runID, schema: "crossdiff.table/1", status: "completed",
        summary: {zhHans: changes + " 个键值不同", en: changes + " changed values"},
        diagnostics: [{zhHans: "按解析后的 JSON 值比较；不比较空白、键顺序或重复键。", en: "Compares parsed JSON values, excluding whitespace, object key order and duplicate keys."}],
        payload: {rows: rows}
    };
}
