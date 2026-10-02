import SwiftUI
import AppKit
import Quartz
import CrossDiffCore

/// Office originals stay read-only. Only typed content and source coordinates enter this view.
struct OfficeComparisonView: View {
    @ObservedObject var model: OfficeComparisonModel
    let leftURL: URL
    let rightURL: URL
    let execute: OfficeComparisonModel.Execute
    let executionID: String
    @ObservedObject private var appearance = AppAppearance.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var query = ""
    @State private var showKeys = false
    @State private var showNotes = false
    @State private var preview: OriginalPreview?
    @State private var detail: OfficeComparisonRow?
    @State private var columnPage = 0
    @State private var reloadID = UUID()
    private var theme: ComparisonTheme { appearance.colors }
    private var kind: OfficeDocumentKind { model.leftDocument?.kind ?? OfficeDocumentKind.from(fileExtension: leftURL.pathExtension) ?? .word }
    private var rows: [OfficeComparisonRow] { model.comparison?.rows ?? [] }
    private var leftRows: [String: OfficeRow] { Dictionary(uniqueKeysWithValues: (model.leftSection?.rows ?? []).map { ($0.id, $0) }) }
    private var rightRows: [String: OfficeRow] { Dictionary(uniqueKeysWithValues: (model.rightSection?.rows ?? []).map { ($0.id, $0) }) }
    private var columns: [Int] {
        Set((model.leftSection?.rows ?? []).flatMap { $0.cells.map(\.column) } + (model.rightSection?.rows ?? []).flatMap { $0.cells.map(\.column) }).sorted()
    }
    private var pages: [[Int]] {
        let all = columns
        return stride(from: 0, to: all.count, by: 6).map { Array(all[$0..<min(all.count, $0 + 6)]) }
    }
    private var shownColumns: [Int] { pages.isEmpty ? [] : pages[min(columnPage, pages.count - 1)] }
    private var visibleRows: [OfficeComparisonRow] {
        let left = leftRows, right = rightRows
        return rows.filter { row in
            if model.state.onlyDifferences && !row.isDifference { return false }
            guard !query.isEmpty else { return true }
            let sources = [row.leftID.flatMap { left[$0] }, row.rightID.flatMap { right[$0] }].compactMap { $0 }
            return sources.contains { source in
                source.cells.contains { ($0.value ?? "").localizedCaseInsensitiveContains(query) || ($0.formula ?? "").localizedCaseInsensitiveContains(query) }
            }
        }
    }
    private struct OriginalPreview: Identifiable { let url: URL; var id: URL { url } }
    private struct RunIdentity: Hashable { let left: URL, right: URL, execution: String, reload: UUID }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sourceCard(url: leftURL, document: model.leftDocument, selected: model.leftSection, side: .left)
                Divider()
                sourceCard(url: rightURL, document: model.rightDocument, selected: model.rightSection, side: .right)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            content
            footer
        }
        .foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
        .task(id: RunIdentity(left: leftURL, right: rightURL, execution: executionID, reload: reloadID)) {
            await model.load(left: leftURL, right: rightURL, execute: execute, executionID: executionID)
        }
        .onDisappear { model.cancel() }
        .sheet(item: $preview) { item in
            OfficeOriginalPreview(url: item.url, theme: theme)
        }
        .sheet(item: $detail) { row in
            OfficeRowDetail(row: row, left: row.leftID.flatMap { leftRows[$0] }, right: row.rightID.flatMap { rightRows[$0] }, kind: kind, theme: theme)
        }
        .onChange(of: model.state.leftSectionID) { _, _ in columnPage = 0; detail = nil }
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol).foregroundStyle(Color(nsColor: theme.accent))
                Text(kind.title + " · " + L("内容比较", "Content Compare")).font(.system(size: 13, weight: .semibold)).fixedSize()
                Spacer(minLength: 8)
                if kind == .spreadsheet {
                    Button { showKeys.toggle() } label: {
                        Label(model.state.keyColumns.isEmpty ? L("匹配关键列", "Match by Key") : L("关键列", "Keys") + " · " + model.state.keyColumns.map(OfficePresentation.columnName).joined(separator: ", "), systemImage: "key.horizontal")
                    }.popover(isPresented: $showKeys) { keyPicker }
                        .disabled(columns.isEmpty).accessibilityIdentifier("office.keys")
                }
                Button { model.invalidateSources(); reloadID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("重新读取原文件", "Reload Original Files"))
                    .accessibilityLabel(L("重新读取原文件", "Reload Original Files"))
                    .accessibilityIdentifier("office.reload").disabled(model.isLoading)
            }
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(nsColor: theme.secondaryText))
                    TextField(L("查找内容或公式", "Find content or formulas"), text: $query).textFieldStyle(.plain)
                        .accessibilityIdentifier("office.search")
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: theme.separator), lineWidth: 1))
                    .frame(maxWidth: 280)
                Toggle(L("仅差异", "Changes Only"), isOn: $model.state.onlyDifferences).toggleStyle(.checkbox)
                    .accessibilityIdentifier("office.differencesOnly")
                Spacer(minLength: 0)
                if kind == .spreadsheet && pages.count > 1 {
                    Picker(L("显示列", "Visible Columns"), selection: $columnPage) {
                        ForEach(pages.indices, id: \.self) { index in Text(pageTitle(pages[index])).tag(index) }
                    }.frame(maxWidth: 155).id(settings.language)
                }
                Label(L("只读", "Read-only"), systemImage: "lock").foregroundStyle(Color(nsColor: theme.secondaryText))
            }.font(.system(size: 11))
        }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 16).padding(.vertical, 11)
            .background(Color(nsColor: theme.chrome))
    }
    private func pageTitle(_ page: [Int]) -> String {
        guard let first = page.first, let last = page.last else { return "" }
        return OfficePresentation.columnName(first) + " – " + OfficePresentation.columnName(last)
    }
    private func sourceCard(url: URL, document: OfficeDocument?, selected: OfficeSection?, side: OfficeComparisonModel.Side) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(side == .left ? L("左侧", "LEFT") : L("右侧", "RIGHT"))
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(nsColor: theme.secondaryText))
                Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { preview = OriginalPreview(url: url) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless).help(L("预览原文件", "Preview Original File"))
                    .accessibilityLabel(L("预览原文件", "Preview Original File"))
                    .accessibilityIdentifier(side == .left ? "office.left.preview" : "office.right.preview")
            }
            if let document, !document.sections.isEmpty {
                Picker(kind.sectionTitle, selection: Binding(get: { selected?.id ?? "" }, set: { model.selectSection($0, side: side) })) {
                    ForEach(document.sections) { section in Text(OfficePresentation.sectionName(section, kind: kind)).tag(section.id) }
                }.labelsHidden().controlSize(.small).id(settings.language)
                    .accessibilityIdentifier(side == .left ? "office.left.section" : "office.right.section")
            } else {
                Text(kind.sectionTitle).font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if model.isLoading || model.isComparing {
            ProgressView(model.isLoading ? L("正在读取文档结构…", "Reading Document Structure…") : L("正在匹配内容…", "Matching Content…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            ContentUnavailableView {
                Label(L("比较未完成", "Comparison Incomplete"), systemImage: "exclamationmark.triangle")
            } description: { Text(localizedErrorDescription(error)) }
            actions: { Button(L("重试", "Try Again")) { model.invalidateSources(); reloadID = UUID() } }
        } else if model.comparison != nil {
            if visibleRows.isEmpty {
                ContentUnavailableView(L("没有符合筛选的内容", "No Matching Content"), systemImage: "text.magnifyingglass",
                    description: Text(L("调整搜索或关闭“仅差异”。空工作表或空白幻灯片也可能没有可提取的文字。", "Adjust the search or turn off Changes Only. Empty sheets and blank slides may contain no extractable text.")))
            } else if kind == .spreadsheet {
                spreadsheet
            } else {
                documentBlocks
            }
        } else {
            ContentUnavailableView(L("办公文档对比", "Office Compare"), systemImage: kind.symbol)
        }
    }
    private var spreadsheet: some View {
        GeometryReader { geometry in
            let displayed = shownColumns
            let columnWidth = max(112.0, min(180.0, (geometry.size.width - 130) / Double(max(2, displayed.count * 2))))
            let left = leftRows, right = rightRows
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(visibleRows) { row in
                            HStack(spacing: 0) {
                                gridSide(source: row.leftID.flatMap { left[$0] }, other: row.rightID.flatMap { right[$0] }, columns: displayed, width: columnWidth, removal: true)
                                correspondence(row).frame(width: 50)
                                gridSide(source: row.rightID.flatMap { right[$0] }, other: row.leftID.flatMap { left[$0] }, columns: displayed, width: columnWidth, removal: false)
                            }.frame(height: 62)
                                .overlay(alignment: .bottom) { Color(nsColor: theme.separator).opacity(0.65).frame(height: 0.5) }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            columnHeader(displayed, width: columnWidth)
                            Image(systemName: "arrow.left.arrow.right").frame(width: 50)
                            columnHeader(displayed, width: columnWidth)
                        }.font(.system(size: 10, weight: .medium)).foregroundStyle(Color(nsColor: theme.secondaryText))
                            .frame(height: 32).background(Color(nsColor: theme.chrome))
                            .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }.accessibilityIdentifier("office.grid")
        }
    }
    private func columnHeader(_ columns: [Int], width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 40)
            ForEach(columns, id: \.self) { column in
                HStack(spacing: 5) {
                    Text(OfficePresentation.columnName(column))
                    if model.state.keyColumns.contains(column) { Image(systemName: "key.fill").font(.system(size: 8)) }
                }.frame(width: width).foregroundStyle(Color(nsColor: model.state.keyColumns.contains(column) ? theme.accent : theme.secondaryText))
            }
        }
    }
    private func gridSide(source: OfficeRow?, other: OfficeRow?, columns: [Int], width: CGFloat, removal: Bool) -> some View {
        HStack(spacing: 0) {
            Text(source.map { String($0.position) } ?? "—").font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(nsColor: theme.secondaryText)).frame(width: 40, height: 62)
                .background(Color(nsColor: theme.chrome))
            ForEach(columns, id: \.self) { column in
                OfficeGridCell(cell: source?.cell(column: column), other: other?.cell(column: column), removal: removal, theme: theme)
                    .frame(width: width, height: 62)
                    .overlay(alignment: .trailing) { Color(nsColor: theme.separator).opacity(0.45).frame(width: 0.5) }
            }
        }
    }
    private var documentBlocks: some View {
        let left = leftRows, right = rightRows
        return ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(visibleRows) { row in
                    HStack(alignment: .top, spacing: 0) {
                        block(source: row.leftID.flatMap { left[$0] }, other: row.rightID.flatMap { right[$0] }, removal: true)
                        correspondence(row).frame(width: 50).padding(.top, 19)
                        block(source: row.rightID.flatMap { right[$0] }, other: row.leftID.flatMap { left[$0] }, removal: false)
                    }
                }
            }.padding(18)
        }.accessibilityIdentifier("office.blocks")
    }
    private func block(source: OfficeRow?, other: OfficeRow?, removal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(source.map { OfficePresentation.rowLabel($0, kind: kind) } ?? L("此侧无内容", "No Content on This Side"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Color(nsColor: theme.secondaryText))
                Spacer(minLength: 0)
                if let source, source.cells.count > 1 { Image(systemName: "tablecells").font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText)) }
            }
            OfficeInlineText(left: removal ? source?.text : other?.text, right: removal ? other?.text : source?.text, removal: removal, theme: theme)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
        }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: theme.separator), lineWidth: 1))
    }
    private func correspondence(_ row: OfficeComparisonRow) -> some View {
        Button { detail = row } label: {
            VStack(spacing: 5) {
                Image(systemName: OfficePresentation.icon(row)).font(.system(size: 12, weight: .medium))
                if row.ambiguous { Image(systemName: "questionmark.circle").font(.system(size: 9)) }
                else if row.moved && row.status != .equal { Image(systemName: "arrow.up.arrow.down").font(.system(size: 9)) }
            }.foregroundStyle(Color(nsColor: row.status == .equal && !row.moved ? theme.secondaryText : theme.accent))
                .frame(width: 36, height: 38).contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(OfficePresentation.matchLabel(row) + " · " + L("查看详情", "Show Details"))
            .accessibilityLabel(OfficePresentation.matchLabel(row) + " · " + L("查看详情", "Show Details"))
            .accessibilityIdentifier("office.row." + row.id)
    }
    private var keyPicker: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(L("用关键列识别同一条记录", "Identify Records by Key Columns")).font(.headline)
            Text(L("先寻找完全相同行，再使用所选列匹配修改后的记录。左右使用相同列位置；重复键或空键会标记为不确定。", "Exact rows are matched first. Selected columns then identify changed records. Columns use the same positions on both sides; duplicate or empty keys remain uncertain."))
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(columns, id: \.self) { column in
                        Toggle(isOn: Binding(get: { model.state.keyColumns.contains(column) }, set: { selected in
                            var keys = model.state.keyColumns.filter { $0 != column }
                            if selected && keys.count < 16 { keys.append(column) }
                            model.state.keyColumns = keys.sorted()
                        })) {
                            HStack {
                                Text(OfficePresentation.columnName(column)).font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(width: 32, alignment: .leading)
                                Text(keyExample(column)).lineLimit(1).truncationMode(.tail)
                            }
                        }.toggleStyle(.checkbox).disabled(!model.state.keyColumns.contains(column) && model.state.keyColumns.count >= 16)
                            .accessibilityIdentifier("office.key.\(column)")
                    }
                }.padding(.vertical, 3)
            }.frame(maxHeight: 200)
            Divider()
            HStack {
                Button(L("仅自动匹配", "Automatic Only")) { model.state.keyColumns = [] }
                Spacer()
                Button(L("完成", "Done")) { showKeys = false }.keyboardShortcut(.defaultAction)
            }.controlSize(.small)
        }.padding(20).frame(width: 370).foregroundStyle(Color(nsColor: theme.text))
            .background(Color(nsColor: theme.chrome)).presentationBackground(Color(nsColor: theme.chrome))
    }
    private func keyExample(_ column: Int) -> String {
        let cell = model.leftSection?.rows.first?.cell(column: column) ?? model.rightSection?.rows.first?.cell(column: column)
        return cell?.display.isEmpty == false ? String(cell!.display.prefix(100)) : L("关键列", "Key Column")
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(L("当前", "Current") + " " + kind.sectionTitle).fontWeight(.medium)
                if model.result?.status == .partial {
                    Label(L("部分匹配", "Partial Match"), systemImage: "exclamationmark.circle").fixedSize()
                }
                stat("equal", rows.filter { $0.status == .equal && !$0.moved }.count, L("相同", "Equal"))
                stat("plusminus", rows.filter { $0.status != .equal }.count, L("变更", "Changed"))
                stat("arrow.up.arrow.down", rows.filter(\.moved).count, L("重排", "Reordered"))
                if rows.contains(where: \.ambiguous) { stat("questionmark.circle", rows.filter(\.ambiguous).count, L("不确定", "Ambiguous")) }
                Spacer(minLength: 0)
                Button { showNotes.toggle() } label: {
                    Label(L("比较范围", "Scope"), systemImage: "info.circle")
                }.buttonStyle(.link).accessibilityIdentifier("office.scope")
            }
            if showNotes {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("当前显示所选两部分的内容对应，不代表整份文件或排版完全一致。点击中间的符号查看配对依据与完整内容。", "Results cover the two selected sections, not whole-file or layout identity. Click a symbol between the sides to inspect the match and full content."))
                        if kind == .spreadsheet {
                            Text(L("公式与保存的结果分别比较；不重新计算公式。数值保留原始精度，日期序列与格式在详情中显示。", "Formulas and saved results are compared separately; formulas are not recalculated. Numeric precision is preserved; date serials and formats are shown in details."))
                        }
                        ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, item in Text(item.localized) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100)
            }
        }.font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            .padding(.horizontal, 16).padding(.vertical, 11).background(Color(nsColor: theme.chrome))
            .overlay(alignment: .top) { Divider() }
    }
    private func stat(_ icon: String, _ count: Int, _ label: String) -> some View {
        Label("\(count) " + label, systemImage: icon).monospacedDigit().fixedSize()
    }
}

private struct OfficeGridCell: View {
    let cell: OfficeCell?, other: OfficeCell?
    let removal: Bool
    let theme: ComparisonTheme
    private var changed: Bool { !OfficePresentation.sameContent(cell, other) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(OfficePresentation.value(cell)).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                .font(.system(size: 12, design: cell?.type == "number" ? .monospaced : .default))
            if let formula = cell?.formula {
                Text("ƒ  " + formula).font(.system(size: 9, design: .monospaced)).lineLimit(1).truncationMode(.tail)
            } else if cell?.type != other?.type, let type = cell?.type {
                Text(OfficePresentation.typeName(type)).font(.system(size: 9))
            }
        }.padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(Color(nsColor: cell == nil ? theme.secondaryText : changed ? theme.differenceForeground(isRemoval: removal) : theme.text))
            .background(changed && cell != nil ? Color(nsColor: theme.differenceBackground(isRemoval: removal)) : .clear)
            .help(cell.map { ($0.formula.map { "=" + $0 + "\n" } ?? "") + ($0.value ?? L("无缓存结果", "No Cached Result")) } ?? L("不存在此单元格", "Cell Not Present"))
    }
}

/// Inline spans are derived in the background and capped only for this compact preview.
private struct OfficeInlineText: View {
    let left: String?, right: String?, removal: Bool
    let theme: ComparisonTheme
    @State private var spans: [NSRange] = []
    private var text: String { String((removal ? left : right)?.prefix(4096) ?? "") }
    private struct Identity: Hashable { let left: Data?, right: Data? }
    private var identity: Identity { .init(left: left.map { Data($0.prefix(4096).utf8) }, right: right.map { Data($0.prefix(4096).utf8) }) }
    private var attributed: AttributedString {
        let value = NSMutableAttributedString(string: text, attributes: [.foregroundColor: theme.text])
        for span in spans where span.location >= 0 && NSMaxRange(span) <= value.length {
            value.addAttributes([.backgroundColor: theme.differenceBackground(isRemoval: removal), .foregroundColor: theme.differenceForeground(isRemoval: removal)], range: span)
        }
        return AttributedString(value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if (removal ? left : right) == nil {
                Text("—").foregroundStyle(Color(nsColor: theme.secondaryText))
            } else if text.isEmpty {
                Text(L("空段落", "Empty Paragraph")).foregroundStyle(Color(nsColor: theme.secondaryText))
            } else { Text(attributed).textSelection(.enabled).lineSpacing(5) }
            if ((removal ? left : right)?.count ?? 0) > 4096 {
                Text(L("预览前 4,096 字符 · 点击中间符号查看全文", "First 4,096 characters · Click the center symbol for full text"))
                    .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
        }.font(.system(size: 13))
            .task(id: identity) {
                let a = String(left?.prefix(4096) ?? ""), b = String(right?.prefix(4096) ?? "")
                let removed = removal
                let worker = Task.detached(priority: .userInitiated) { () throws -> [NSRange] in
                    let result = try TextDiffEngine.compareCancellable(a, b)
                    return result.rows.flatMap { removed ? $0.leftHighlights : $0.rightHighlights }
                }
                if let result = try? await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }), !Task.isCancelled { spans = result }
            }
    }
}

private struct OfficeRowDetail: View {
    let row: OfficeComparisonRow
    let left: OfficeRow?, right: OfficeRow?
    let kind: OfficeDocumentKind
    let theme: ComparisonTheme
    @Environment(\.dismiss) private var dismiss
    private var columns: [Int] { Set((left?.cells ?? []).map(\.column) + (right?.cells ?? []).map(\.column)).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(OfficePresentation.matchLabel(row)).font(.headline)
                    Text(OfficePresentation.basisLabel(row.basis)).font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                Spacer()
                Button(L("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(18)
            Divider()
            if row.ambiguous {
                Label(L("存在重复内容、重复键或空键，不能确认唯一对应。", "Repeated content, duplicate keys or empty keys prevent a unique correspondence."), systemImage: "questionmark.circle")
                    .font(.system(size: 11)).padding(14)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(columns, id: \.self) { column in
                        VStack(alignment: .leading, spacing: 8) {
                            if kind == .spreadsheet { Text(OfficePresentation.columnName(column)).font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                            HStack(alignment: .top, spacing: 18) {
                                cellDetail(left?.cell(column: column), position: left?.position, removal: true)
                                cellDetail(right?.cell(column: column), position: right?.position, removal: false)
                            }
                        }
                    }
                }.padding(18)
            }
        }.frame(width: 760, height: 510).foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
    }
    private func cellDetail(_ cell: OfficeCell?, position: Int?, removal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text((removal ? L("左侧", "Left") : L("右侧", "Right")) + (position.map { " · \($0)" } ?? ""))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Color(nsColor: theme.secondaryText))
            Text(OfficePresentation.value(cell)).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let cell {
                Text(OfficePresentation.typeName(cell.type)).font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                if let formula = cell.formula {
                    Text(L("公式", "Formula") + "\n=" + formula).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text(cell.value == nil ? L("保存的结果：未提供", "Saved Result: Not Available") : L("上方数值是保存的结果，未重新计算。", "The value above is the saved result; it has not been recalculated."))
                        .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                if let format = cell.format { Text(L("格式记录", "Format Record") + ": " + format).font(.system(size: 10)).textSelection(.enabled) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: theme.chrome), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct OfficeOriginalPreview: View {
    let url: URL
    let theme: ComparisonTheme
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent).font(.headline).lineLimit(1)
                    Text(L("系统预览 · 当前磁盘文件 · 可用格式与版式由 macOS 决定", "System Preview · Current File on Disk · Format and layout support depend on macOS"))
                        .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                Spacer()
                Button(L("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("office.preview.done")
            }.padding(16)
            Divider()
            OfficeQuickLook(url: url).accessibilityIdentifier("office.originalPreview")
        }.frame(width: 800, height: 560).foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
    }
}
private struct OfficeQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem?.previewItemURL ?? nil) != url { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

enum OfficePresentation {
    static func columnName(_ value: Int) -> String {
        guard value > 0 else { return "—" }
        var value = value, text = ""
        while value > 0 { value -= 1; text = String(UnicodeScalar(65 + value % 26)!) + text; value /= 26 }
        return text
    }
    static func sameContent(_ a: OfficeCell?, _ b: OfficeCell?) -> Bool {
        OfficeContract.cellsEqual(a, b)
    }
    static func value(_ cell: OfficeCell?) -> String {
        guard let cell else { return "—" }
        guard let value = cell.value else { return cell.formula == nil ? L("空值", "Empty Value") : L("无缓存结果", "No Cached Result") }
        return value.isEmpty ? "\"\"" : value
    }
    static func sectionName(_ section: OfficeSection, kind: OfficeDocumentKind) -> String {
        if kind == .presentation {
            let firstBody = section.rows.first { !$0.label.hasPrefix("Note ") }
            if firstBody?.cells.first?.value?.split(separator: "\n").first == nil,
               section.name.hasPrefix("Slide "), let number = Int(section.name.dropFirst(6)) {
                return L("幻灯片", "Slide") + " \(number)"
            }
        }
        guard kind == .word else { return section.name }
        if section.id == "body" { return L("正文", "Body") }
        let components = section.id.split(separator: "-", maxSplits: 1)
        let title: String
        switch components.first {
        case "header": title = L("页眉", "Header")
        case "footer": title = L("页脚", "Footer")
        case "footnotes": title = L("脚注", "Footnotes")
        case "endnotes": title = L("尾注", "Endnotes")
        case "comments": title = L("批注", "Comments")
        default: return section.name
        }
        return title + (components.count > 1 ? " " + components[1] : "")
    }
    static func rowLabel(_ row: OfficeRow, kind: OfficeDocumentKind) -> String {
        if kind == .presentation && row.label.hasPrefix("Note ") { return L("演讲者备注", "Speaker Note") + " \(row.position)" }
        let title = kind == .presentation ? L("内容块", "Block") : row.cells.count > 1 ? L("表格行", "Table Row") : L("段落", "Paragraph")
        return title + " \(row.position)"
    }
    static func typeName(_ type: String) -> String {
        switch type {
        case "number", "n": return L("数值", "Number")
        case "string", "text", "s", "inlineStr": return L("文本", "Text")
        case "boolean", "bool", "b": return L("布尔值", "Boolean")
        case "date", "d": return L("日期", "Date")
        case "error", "e": return L("错误值", "Error")
        case "blank": return L("空单元格", "Blank Cell")
        default: return type
        }
    }
    static func icon(_ row: OfficeComparisonRow) -> String {
        switch row.status { case .equal: return row.moved ? "arrow.up.arrow.down" : "equal"; case .modified: return "arrow.left.arrow.right"; case .added: return "plus"; case .removed: return "minus" }
    }
    static func matchLabel(_ row: OfficeComparisonRow) -> String {
        let text: String
        switch row.status { case .equal: text = L("内容相同", "Equal Content"); case .modified: text = L("内容修改", "Modified Content"); case .added: text = L("新增", "Added"); case .removed: text = L("删除", "Removed") }
        return text + (row.moved ? " · " + L("重排", "Reordered") : "") + (row.ambiguous ? " · " + L("不确定", "Ambiguous") : "")
    }
    static func basisLabel(_ basis: OfficeMatchBasis) -> String {
        switch basis {
        case .exact: return L("匹配依据：完全相同的内容，不受原行号限制。", "Matched by exact content, regardless of original position.")
        case .key: return L("匹配依据：所选关键列的唯一值。", "Matched by a unique value in the selected key columns.")
        case .position: return L("按剩余位置对照；这不证明它们是同一条记录。", "Compared by remaining position; this does not prove record identity.")
        case .unmatched: return L("未找到确定的另一侧对应项。", "No definite counterpart was found.")
        }
    }
}
private extension OfficeDocumentKind {
    var symbol: String { switch self { case .word: return "doc.richtext"; case .spreadsheet: return "tablecells"; case .presentation: return "rectangle.on.rectangle" } }
    var sectionTitle: String { switch self { case .word: return L("文档部分", "Document Section"); case .spreadsheet: return L("工作表", "Sheet"); case .presentation: return L("幻灯片", "Slide") } }
}
