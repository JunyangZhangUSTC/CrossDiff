"use strict";
// The host supplies a bounded, typed snapshot. This algorithm never opens files,
// renders documents, evaluates spreadsheet formulas or follows relationships.
function officeText(zh, en) { return { zhHans: zh, en: en }; }
function officeString(value, maximum) { return typeof value === "string" && value.length <= maximum; }
function officeInput(content) {
    if (!content || !["word", "spreadsheet", "presentation"].includes(content.kind) ||
        !officeString(content.sectionID, 128) || !content.sectionID.length || !officeString(content.name, 4096) ||
        !Array.isArray(content.rows) || content.rows.length > 10000) throw new Error("Invalid Office section");
    const ids = new Set(); let previous = 0, count = 0;
    for (const row of content.rows) {
        if (!row || !officeString(row.id, 128) || !row.id.length || ids.has(row.id) ||
            !Number.isInteger(row.position) || row.position <= previous || row.position > 1048576 ||
            !officeString(row.label, 4096) || !Array.isArray(row.cells)) throw new Error("Invalid Office row");
        ids.add(row.id); previous = row.position; count += row.cells.length;
        if (count > 100000) throw new Error("Office cell limit exceeded");
        let column = 0;
        for (const cell of row.cells) {
            if (!cell || !Number.isInteger(cell.column) || cell.column <= column || cell.column > 16384 ||
                !officeString(cell.type, 64) || !cell.type.length ||
                !(cell.value === null || officeString(cell.value, 131072)) ||
                !(cell.formula === null || officeString(cell.formula, 131072)) ||
                !(cell.format === null || officeString(cell.format, 4096))) throw new Error("Invalid Office cell");
            column = cell.column;
        }
    }
    return content.rows;
}
function officeCell(cell) { return [cell.column, cell.type, cell.value == null ? null : cell.value, cell.formula == null ? null : cell.formula]; }
function officeCanonical(row) { return JSON.stringify(row.cells.map(officeCell)); }
function officeKey(row, columns) {
    if (!columns.length) return null;
    const cells = [];
    for (const column of columns) {
        const cell = row.cells.find(value => value.column === column);
        if (!cell || cell.value === null || !cell.value.length) return null;
        cells.push(officeCell(cell));
    }
    return JSON.stringify(cells);
}
function officeCounts(values) {
    const counts = new Map(); values.forEach(value => { if (value !== null) counts.set(value, (counts.get(value) || 0) + 1); }); return counts;
}
// Keep one longest order-preserving backbone. Insertions shift addresses but do
// not change pair order; only pairs outside this backbone are moved.
function officeMarkMoves(rows, right) {
    const indices = new Map(right.map((row, index) => [row.id, index]));
    const paired = rows.filter(row => row.leftID !== null && row.rightID !== null && (row.basis === "exact" || row.basis === "key"));
    const tails = [], tailRows = [], previous = [];
    paired.forEach((row, index) => {
        const value = indices.get(row.rightID); let low = 0, high = tails.length;
        while (low < high) { const middle = (low + high) >>> 1; if (tails[middle] < value) low = middle + 1; else high = middle; }
        previous[index] = low ? tailRows[low - 1] : -1;
        tails[low] = value; tailRows[low] = index;
    });
    const retained = new Set(); let current = tailRows[tails.length - 1];
    while (current !== undefined && current >= 0) { retained.add(current); current = previous[current]; }
    paired.forEach((row, index) => { row.moved = !retained.has(index); });
}
function compare(request) {
    if (!request || request.protocolVersion !== 1 || request.mode !== "pairwise" ||
        !Array.isArray(request.inputs) || request.inputs.length !== 2) throw new Error("Unsupported Office request");
    const l = request.inputs.find(input => input.role === "left"), r = request.inputs.find(input => input.role === "right");
    if (!l || !r || l.content.kind !== r.content.kind) throw new Error("Office document families must match");
    const left = officeInput(l.content), right = officeInput(r.content), options = request.options || {};
    const columns = options.keyColumns === undefined ? [] : options.keyColumns;
    if (Object.keys(options).some(key => key !== "keyColumns") || !Array.isArray(columns) || columns.length > 16 ||
        new Set(columns).size !== columns.length || columns.some(value => !Number.isInteger(value) || value < 1 || value > 16384) ||
        (columns.length && l.content.kind !== "spreadsheet")) throw new Error("Invalid Office key columns");
    const leftSignatures = left.map(officeCanonical), rightSignatures = right.map(officeCanonical);
    const leftExactCounts = officeCounts(leftSignatures), rightExactCounts = officeCounts(rightSignatures);
    const leftKeys = left.map(row => officeKey(row, columns)), rightKeys = right.map(row => officeKey(row, columns));
    const leftKeyCounts = officeCounts(leftKeys), rightKeyCounts = officeCounts(rightKeys);
    const buckets = new Map();
    right.forEach((row, index) => {
        const key = officeCanonical(row);
        if (!buckets.has(key)) buckets.set(key, { indices: [], next: 0 });
        buckets.get(key).indices.push(index);
    });
    const used = new Set(), pairs = new Array(left.length);
    left.forEach((row, leftIndex) => {
        const signature = leftSignatures[leftIndex], bucket = buckets.get(signature);
        const index = bucket && bucket.indices[bucket.next++];
        if (index !== undefined) {
            used.add(index);
            pairs[leftIndex] = { right: index, basis: "exact", ambiguous: leftExactCounts.get(signature) > 1 || rightExactCounts.get(signature) > 1 };
        }
    });
    if (columns.length) {
        const unique = new Map();
        rightKeys.forEach((key, index) => { if (key !== null && rightKeyCounts.get(key) === 1 && !used.has(index)) unique.set(key, index); });
        leftKeys.forEach((key, index) => {
            if (pairs[index] || key === null || leftKeyCounts.get(key) !== 1 || !unique.has(key)) return;
            const rightIndex = unique.get(key); used.add(rightIndex);
            pairs[index] = { right: rightIndex, basis: "key", ambiguous: false };
        });
    } else {
        const remaining = right.map((_, index) => index).filter(index => !used.has(index));
        let cursor = 0;
        left.forEach((_, index) => {
            if (pairs[index] || cursor >= remaining.length) return;
            const rightIndex = remaining[cursor++]; used.add(rightIndex);
            pairs[index] = { right: rightIndex, basis: "position", ambiguous: false };
        });
    }
    const ambiguousKey = key => columns.length > 0 && (key === null || leftKeyCounts.get(key) > 1 || rightKeyCounts.get(key) > 1);
    const rows = left.map((row, index) => {
        const pair = pairs[index];
        return { id: "", leftID: row.id, rightID: pair ? right[pair.right].id : null,
            status: pair ? (leftSignatures[index] === rightSignatures[pair.right] ? "equal" : "modified") : "removed",
            moved: false, ambiguous: pair ? pair.ambiguous : ambiguousKey(leftKeys[index]), basis: pair ? pair.basis : "unmatched" };
    });
    officeMarkMoves(rows, right);
    // Insert new rows near their next paired right-side neighbour while keeping
    // the left source order. Unmatched trailing rows remain at the end.
    const anchors = new Map(); pairs.forEach((pair, index) => { if (pair) anchors.set(pair.right, index); });
    const additions = new Map(); let anchor = left.length;
    for (let index = right.length - 1; index >= 0; index--) {
        if (anchors.has(index)) { anchor = anchors.get(index); continue; }
        if (!used.has(index)) {
            if (!additions.has(anchor)) additions.set(anchor, []);
            additions.get(anchor).push({ id: "", leftID: null, rightID: right[index].id, status: "added", moved: false, ambiguous: ambiguousKey(rightKeys[index]), basis: "unmatched" });
        }
    }
    const ordered = [];
    for (let index = 0; index <= rows.length; index++) {
        if (additions.has(index)) ordered.push(...additions.get(index).reverse());
        if (index < rows.length) ordered.push(rows[index]);
    }
    ordered.forEach((row, index) => { row.id = "office-" + index; });
    const counts = { equal: 0, modified: 0, added: 0, removed: 0, moved: 0, ambiguous: 0 };
    ordered.forEach(row => { counts[row.status]++; if (row.moved) counts.moved++; if (row.ambiguous) counts.ambiguous++; });
    const diagnostics = [officeText("比较提取的内容、单元格类型、公式与文件保存的缓存值；不重新计算公式，版式与样式不参与相同判定。",
        "Compares extracted content, cell types, formulas and saved cached values. Formulas are not recalculated; layout and styling are outside equality checks.")];
    if (ordered.some(row => row.basis === "position")) diagnostics.push(officeText(
        "未匹配内容按剩余源顺序对照，标记为位置配对；这不是身份一致的证明。Excel 可选择关键列改进配对。",
        "Unmatched content is compared in remaining source order and labelled positional. This does not establish identity; choose key columns in Excel for explicit pairing."));
    if (counts.ambiguous) diagnostics.push(officeText(
        "重复的相同行按出现顺序配对；重复或空关键值未强行配对。歧义标记不代表内容一定不同。",
        "Repeated identical rows are paired by occurrence. Duplicate or blank keys are not forced into pairs. Ambiguity does not necessarily mean different content."));
    const summary = officeText(counts.modified + " 项修改 · " + counts.added + " 项新增 · " + counts.removed + " 项删除 · " + counts.moved + " 项重排",
        counts.modified + " modified · " + counts.added + " added · " + counts.removed + " removed · " + counts.moved + " reordered");
    return { protocolVersion: 1, runID: request.runID, schema: "crossdiff.office/1", status: "completed",
        summary: summary, diagnostics: diagnostics, payload: { rows: ordered } };
}
