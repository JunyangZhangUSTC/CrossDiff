// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Junyang Zhang
/* CrossDiff PDF comparison, AGPL-3.0-only.
 * Host supplies bounded immutable page descriptors, never file access.
 * Alignment uses text and rendered preview fingerprints. "same" means these
 * representations match, not byte identity or a full-resolution visual proof.
 */
function compare(request) {
    "use strict";
    if (request.protocolVersion !== 1 || request.mode !== "pairwise" || request.inputs.length !== 2) {
        throw new Error("PDF supports exactly two inputs in pairwise mode.");
    }
    const left = request.inputs.find(function (input) { return input.role === "left"; });
    const right = request.inputs.find(function (input) { return input.role === "right"; });
    if (!left || !right) throw new Error("PDF requires left and right input roles.");
    const a = left.content.pages, b = right.content.pages;
    if (!Array.isArray(a) || !Array.isArray(b) || a.length > 200 || b.length > 200) {
        throw new Error("PDF page descriptors exceed the supported limit.");
    }
    function normalized(page) { return page.text.replace(/\s+/g, " ").trim(); }
    function valid(page, index) {
        return page.index === index && typeof page.text === "string" && page.text.length <= 65536 &&
            typeof page.fingerprint === "string" && page.fingerprint.length > 0 &&
            Number.isFinite(page.width) && page.width > 0 && Number.isFinite(page.height) && page.height > 0;
    }
    if (!a.every(valid) || !b.every(valid)) throw new Error("Invalid PDF page descriptor.");
    const na = a.map(normalized), nb = b.map(normalized);
    function wordSet(text) {
        // Unicode code-point bigrams also provide useful anchors in Chinese.
        const characters = Array.from(text.slice(0, 2048));
        const result = new Set();
        for (let i = 0; i + 1 < characters.length; i++) result.add(characters[i] + characters[i + 1]);
        return result;
    }
    const wordsA = na.map(wordSet), wordsB = nb.map(wordSet);
    function cost(i, j) {
        if (a[i].fingerprint === b[j].fingerprint && a[i].width === b[j].width && a[i].height === b[j].height) return 0;
        if (na[i] && na[i] === nb[j]) return 0.05;
        const x = wordsA[i], y = wordsB[j];
        let shared = 0;
        x.forEach(function (word) { if (y.has(word)) shared++; });
        const similarity = x.size + y.size ? 2 * shared / (x.size + y.size) : 0;
        return 1.75 - 1.4 * similarity;
    }
    const width = b.length + 1;
    const distances = new Float64Array((a.length + 1) * width);
    const steps = new Uint8Array(distances.length);
    for (let i = 1; i <= a.length; i++) { distances[i * width] = i; steps[i * width] = 1; }
    for (let j = 1; j <= b.length; j++) { distances[j] = j; steps[j] = 2; }
    for (let i = 1; i <= a.length; i++) {
        for (let j = 1; j <= b.length; j++) {
            const index = i * width + j;
            let value = distances[index - width - 1] + cost(i - 1, j - 1), step = 0;
            const remove = distances[index - width] + 1, add = distances[index - 1] + 1;
            if (remove < value - 1e-8) { value = remove; step = 1; }
            if (add < value - 1e-8) { value = add; step = 2; }
            distances[index] = value; steps[index] = step;
        }
    }
    const pairs = [];
    let i = a.length, j = b.length;
    while (i > 0 || j > 0) {
        const step = steps[i * width + j];
        if (step === 1) { pairs.push({ left: --i, right: null, kind: "removed" }); }
        else if (step === 2) { pairs.push({ left: null, right: --j, kind: "added" }); }
        else {
            i--; j--;
            const hasText = na[i].length > 0 && nb[j].length > 0;
            const equalPreview = a[i].fingerprint === b[j].fingerprint && a[i].width === b[j].width && a[i].height === b[j].height;
            let kind = equalPreview && a[i].text === b[j].text ? "same" : "changed";
            if (!hasText && equalPreview) kind = "unknown";
            if ((a[i].textTruncated || b[j].textTruncated) && kind === "same") kind = "unknown";
            pairs.push({ left: i, right: j, kind: kind });
        }
    }
    pairs.reverse();
    const changed = pairs.filter(function (pair) { return pair.kind !== "same" && pair.kind !== "unknown"; }).length;
    const unknown = pairs.filter(function (pair) { return pair.kind === "unknown"; }).length;
    const truncated = Boolean(left.content.truncated || right.content.truncated);
    const diagnostics = [{
        zhHans: "页面匹配结合可提取文字与 384 像素页面预览。匹配不代表 PDF 文件字节相同，也不是全分辨率视觉校验。",
        en: "Page alignment uses extractable text and 384-pixel page previews. A match is neither PDF byte identity nor full-resolution visual verification."
    }];
    if (a.some(function (p) { return !normalized(p); }) || b.some(function (p) { return !normalized(p); })) {
        diagnostics.push({ zhHans: "部分页面没有可提取文字，可能是扫描页或空白页；未执行 OCR。", en: "Some pages have no extractable text and may be scanned or blank. OCR was not performed." });
    }
    if (truncated) diagnostics.push({ zhHans: "页面或文字达到读取上限；结果仅覆盖已读取部分。", en: "Page or text limits were reached. Results cover only the content read." });
    return {
        protocolVersion: 1, runID: request.runID, schema: "crossdiff.document-pages/1",
        status: truncated ? "partial" : "completed",
        summary: { zhHans: changed + " 组页面有变化" + (unknown ? " · " + unknown + " 组需查看页面" : ""),
                   en: changed + " changed page pairs" + (unknown ? " · " + unknown + " require page review" : "") },
        diagnostics: diagnostics, payload: { pairs: pairs }
    };
}
