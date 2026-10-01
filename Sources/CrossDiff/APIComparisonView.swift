import AppKit
import SwiftUI
import CrossDiffCore

@MainActor
struct APIComparisonView: View {
    let left: StoredTextSide
    let right: StoredTextSide
    @ObservedObject var model: APIComparisonModel
    let execute: APIComparisonModel.Execute
    let executionID: String
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @State private var section = Section.all
    @State private var differencesOnly = false
    @State private var showIgnored = false
    @State private var showCredentials = false
    @State private var revealSource = false
    @State private var query = ""
    @State private var showsRules = false
    @State private var headerRules = ""
    @State private var pointerRules = ""
    @State private var reloadID = UUID()
    private var theme: ComparisonTheme { appearance.colors }
    private enum Section: String, CaseIterable {
        case all, request, response, source
        var title: String {
            switch self {
            case .all: return L("全部", "All")
            case .request: return L("请求", "Request")
            case .response: return L("响应", "Response")
            case .source: return L("原始内容", "Source")
            }
        }
    }
    private struct RunIdentity: Hashable {
        let leftPath: Data?, rightPath: Data?, leftText: Data, rightText: Data
        let execution: String, reload: UUID
    }
    private var runIdentity: RunIdentity {
        .init(leftPath: left.path.map { Data($0.utf8) }, rightPath: right.path.map { Data($0.utf8) }, leftText: Data(left.text.utf8), rightText: Data(right.text.utf8), execution: executionID, reload: reloadID)
    }
    private var rows: [APIComparisonRow] { model.comparison?.rows ?? [] }
    private var ignoredCount: Int { rows.filter { $0.state == .ignored }.count }
    private var visibleRows: [APIComparisonRow] {
        rows.filter { row in
            guard section == .all || row.section.hasPrefix(section.rawValue + ".") else { return false }
            if row.state == .ignored, !showIgnored { return false }
            if differencesOnly, row.state == .same { return false }
            // Hidden credential values are neither displayed nor searchable.
            let values = [row.path, row.label] + (row.sensitive && !showCredentials ? [] : [row.left ?? "", row.right ?? ""])
            return query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    private let sectionOrder = ["request.summary", "request.query", "request.headers", "request.body", "response.summary", "response.headers", "response.body"]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                sourceCard(left, side: .left, document: model.leftDocument, exchange: model.leftExchange)
                Divider()
                sourceCard(right, side: .right, document: model.rightDocument, exchange: model.rightExchange)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            if model.isLoading {
                ProgressView(L("正在读取调用记录…", "Reading Call Records…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if section == .source {
                sourceView
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(L("比较未完成", "Comparison Incomplete"), systemImage: "exclamationmark.triangle")
                } description: { Text(localizedErrorDescription(error)) }
                actions: { Button(L("重试", "Try Again")) { reload() } }
            } else if model.isComparing {
                ProgressView(L("正在比较请求与响应…", "Comparing Requests and Responses…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.comparison != nil {
                comparisonTable
            } else {
                ContentUnavailableView(L("API 对比", "API Compare"), systemImage: "arrow.left.arrow.right.square")
            }
            footer
        }
        .background(Color(nsColor: theme.canvas)).foregroundStyle(Color(nsColor: theme.text))
        .task(id: runIdentity) {
            await model.load(left: left, right: right, execute: execute, executionID: executionID)
        }
        .onDisappear { model.cancel(); revealSource = false; showCredentials = false }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Label(L("API 对比", "API Compare"), systemImage: "arrow.left.arrow.right.square")
                    .font(.system(size: 13, weight: .semibold)).fixedSize()
                Picker(L("比较内容", "Compare"), selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 310).id(settings.language)
                    .accessibilityIdentifier("api.sections")
                Spacer(minLength: 0)
                Button {
                    headerRules = model.state.ignoreHeaders.joined(separator: "\n")
                    pointerRules = model.state.ignoreJSONPointers.joined(separator: "\n")
                    showsRules = true
                } label: {
                    Label(ruleCount == 0 ? L("忽略规则", "Ignore Rules") : L("规则", "Rules") + " · \(ruleCount)", systemImage: "line.3.horizontal.decrease.circle")
                }.popover(isPresented: $showsRules) { rulesPopover }
                    .accessibilityIdentifier("api.ignoreRules")
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("重新读取并比较", "Reload and Compare"))
                    .accessibilityLabel(L("重新读取并比较", "Reload and Compare"))
                    .disabled(model.isLoading)
            }
            if section != .source {
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color(nsColor: theme.secondaryText))
                        TextField(L("查找字段或值", "Find a field or value"), text: $query).textFieldStyle(.plain)
                            .accessibilityIdentifier("api.search")
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                    }.padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: theme.separator), lineWidth: 1))
                        .frame(maxWidth: 310)
                    Toggle(L("仅差异", "Changes Only"), isOn: $differencesOnly).toggleStyle(.checkbox)
                        .accessibilityIdentifier("api.differencesOnly")
                    Spacer(minLength: 0)
                    Toggle(isOn: $showCredentials) {
                        Label(L("显示敏感值", "Reveal Sensitive Values"), systemImage: showCredentials ? "eye" : "eye.slash")
                    }.toggleStyle(.button)
                        .help(L("只遮罩已识别的认证头、Cookie 和常见凭据字段；其他字段或正文仍可能包含敏感信息。", "Masks recognized authentication headers, cookies and common credential fields only. Other fields and body content may still contain sensitive data."))
                        .accessibilityIdentifier("api.showCredentials")
                }.font(.system(size: 11))
            }
        }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 16).padding(.vertical, 11)
            .background(Color(nsColor: theme.chrome))
    }

    private func sourceCard(_ source: StoredTextSide, side: APIComparisonModel.Side, document: APIImportDocument?, exchange: APIExchange?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(side == .left ? L("左侧", "LEFT") : L("右侧", "RIGHT"))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(nsColor: theme.secondaryText))
                Text(source.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("粘贴的记录", "Pasted Record"))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let document { Text(document.format.rawValue.uppercased()).font(.system(size: 9, weight: .medium)).foregroundStyle(Color(nsColor: theme.secondaryText)) }
            }
            if let document, document.exchanges.count > 1 {
                Picker(L("选择调用", "Select Call"), selection: Binding(get: { exchange?.id ?? "" }, set: { model.selectEntry($0, side: side) })) {
                    ForEach(document.exchanges, id: \.id) { item in Text(APIComparisonPresentation.entryTitle(item)).tag(item.id) }
                }.labelsHidden().frame(maxWidth: .infinity).controlSize(.small)
                    .accessibilityIdentifier(side == .left ? "api.left.entry" : "api.right.entry")
            }
            HStack(spacing: 7) {
                if let method = exchange?.request?.method { badge(method, accent: true) }
                Text(exchange?.request?.url.map(APIComparisonPresentation.summaryURL) ?? (exchange?.response == nil ? L("等待记录", "Waiting for Record") : L("仅响应", "Response Only")))
                    .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if let status = exchange?.response?.statusCode { badge(String(describing: status), accent: false) }
            }.frame(height: 23)
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func badge(_ text: String, accent: Bool) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).fixedSize()
            .foregroundStyle(Color(nsColor: accent ? theme.accent : theme.text))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color(nsColor: accent ? theme.selectionBackground : theme.chrome), in: RoundedRectangle(cornerRadius: 4))
    }

    private var comparisonTable: some View {
        GeometryReader { geometry in
            let pathWidth = min(230.0, max(170.0, geometry.size.width * 0.23))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(L("字段 / 路径", "Field / Path")).frame(width: pathWidth, alignment: .leading)
                    Text(L("左侧记录", "Left Record")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("右侧记录", "Right Record")).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(Color(nsColor: theme.secondaryText))
                    .padding(.horizontal, 16).frame(height: 29).background(Color(nsColor: theme.chrome))
                Divider()
                if visibleRows.isEmpty {
                    ContentUnavailableView(L("没有符合筛选的字段", "No Matching Fields"), systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(L("调整搜索或筛选，查看其他字段。", "Adjust the search or filters to see other fields.")))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(orderedSections, id: \.self) { group in
                                let items = visibleRows.filter { $0.section == group }
                                SwiftUI.Section {
                                    ForEach(items) { row in
                                        APIDifferenceRow(row: row, pathWidth: pathWidth, showCredentials: showCredentials, theme: theme)
                                    }
                                } header: {
                                    HStack(spacing: 8) {
                                        Image(systemName: group.hasPrefix("response") ? "arrow.down.left" : "arrow.up.right")
                                        Text(sectionTitle(group)).fontWeight(.medium)
                                        Spacer()
                                        Text("\(items.count)").monospacedDigit()
                                    }.font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                                        .padding(.horizontal, 16).frame(height: 31).background(Color(nsColor: theme.chrome))
                                }
                            }
                        }
                    }.accessibilityIdentifier("api.comparisonRows")
                }
            }
        }
    }
    private var orderedSections: [String] {
        let available = Set(visibleRows.map(\.section))
        return sectionOrder.filter(available.contains) + available.subtracting(sectionOrder).sorted()
    }
    private func sectionTitle(_ value: String) -> String {
        switch value {
        case "request.summary": return L("请求 · 概览", "Request · Overview")
        case "query", "request.query": return L("请求 · 查询参数", "Request · Query Parameters")
        case "request.headers": return L("请求 · Headers", "Request · Headers")
        case "request.body": return L("请求 · Body", "Request · Body")
        case "response.summary": return L("响应 · 概览", "Response · Overview")
        case "response.headers": return L("响应 · Headers", "Response · Headers")
        case "response.body": return L("响应 · Body", "Response · Body")
        default: return value
        }
    }

    private var sourceView: some View {
        Group {
            if revealSource {
                VStack(spacing: 0) {
                    HStack {
                        Label(L("原始内容可能包含认证信息与个人数据", "Source May Contain Credentials and Personal Data"), systemImage: "eye")
                            .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                        Spacer()
                        Button(L("隐藏", "Hide")) { revealSource = false }.controlSize(.small)
                    }.padding(12)
                    Divider()
                    HStack(spacing: 0) {
                        rawPane(model.leftDocument?.source ?? "")
                        Divider()
                        rawPane(model.rightDocument?.source ?? "")
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(L("查看导入的原始内容", "View Imported Source"), systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(L("原始内容未经遮罩，可能包含认证头、Cookie 与正文中的敏感数据。HAR 将显示整个导入文件。", "Source is not masked and may include authentication headers, cookies and sensitive body data. HAR displays the entire imported file."))
                } actions: {
                    Button(L("显示原始内容", "Show Source")) { revealSource = true }
                        .accessibilityIdentifier("api.revealSource")
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func rawPane(_ value: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 14) {
                if value.count > 65_536 {
                    Text(L("原文较长，此视图仅显示前 65,536 个字符；结构化比较不受此预览上限影响。", "This view displays the first 65,536 characters. This preview limit does not affect structured comparison."))
                        .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                Text(String(value.prefix(65_536))).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                if let result = model.result {
                    Text(result.summary.localized).lineLimit(2)
                } else { Text(L("本地读取 · 不发送请求", "Local Import · No Requests Sent")) }
                if ignoredCount > 0 {
                    Button { showIgnored.toggle() } label: {
                        Text((showIgnored ? L("隐藏已忽略", "Hide Ignored") : L("查看已忽略", "Show Ignored")) + " · \(ignoredCount)")
                    }.buttonStyle(.link).accessibilityIdentifier("api.showIgnored")
                }
                Spacer(minLength: 8)
                if model.result?.status == .partial {
                    Label(L("部分结果", "Partial Result"), systemImage: "exclamationmark.circle")
                }
                Text(L("只读", "Read-only")).fixedSize()
            }
            if !model.diagnostics.isEmpty {
                DisclosureGroup(L("解析说明", "Import Notes") + " · \(model.diagnostics.count)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, item in Text(item.localized).frame(maxWidth: .infinity, alignment: .leading) }
                        }.padding(.top, 5)
                    }.frame(maxHeight: 110)
                }.accessibilityIdentifier("api.diagnostics")
            }
        }.font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
            .padding(.horizontal, 16).padding(.vertical, 10).background(Color(nsColor: theme.chrome))
            .overlay(alignment: .top) { Divider() }
    }
    private var ruleCount: Int { model.state.ignoreHeaders.count + model.state.ignoreJSONPointers.count }
    private var parsedHeaders: [String] { parseRules(headerRules) }
    private var parsedPointers: [String] { parseRules(pointerRules, trimWhitespace: false) }
    private var validRules: Bool {
        var candidate = model.state
        candidate.ignoreHeaders = parsedHeaders; candidate.ignoreJSONPointers = parsedPointers
        return candidate.isValid
    }
    private func parseRules(_ text: String, trimWhitespace: Bool = true) -> [String] {
        APIComparisonPresentation.parseRuleLines(text, trimWhitespace: trimWhitespace)
    }
    private var rulesPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("忽略规则", "Ignore Rules")).font(.headline)
            Text(L("仅影响差异判断，原始数据保持不变。默认不忽略任何字段。", "Affects difference classification only. Source data stays unchanged. Nothing is ignored by default."))
                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            ruleEditor(L("Header 名称 · 每行一个，不区分大小写", "Header Names · One per line, case-insensitive"), placeholder: "Date\nX-Request-ID", text: $headerRules)
            ruleEditor(L("Body JSON Pointer · 每行一个，包含子字段", "Body JSON Pointers · One per line, includes descendants"), placeholder: "/timestamp\n/metadata/requestId", text: $pointerRules)
            Text(L("规则同时用于左右请求与响应。JSON Pointer 使用 / 分隔；字段名中的 ~ 和 / 写成 ~0 和 ~1。", "Rules apply to both requests and responses. JSON Pointers use / separators; encode ~ and / within a field name as ~0 and ~1."))
                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            if !validRules {
                Text(L("请检查规则格式或数量。JSON Pointer 须以 / 开头。", "Check rule format or count. JSON Pointers must begin with /."))
                    .font(.caption).foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: true)))
            }
            HStack {
                Button(L("清除规则", "Clear Rules")) { model.clearRules(); headerRules = ""; pointerRules = ""; showsRules = false }
                Spacer()
                Button(L("取消", "Cancel")) { showsRules = false }
                Button(L("应用", "Apply")) { model.applyRules(headers: parsedHeaders, pointers: parsedPointers); showsRules = false }
                    .buttonStyle(.borderedProminent).disabled(!validRules)
            }.controlSize(.small)
        }.padding(20).frame(width: 390).foregroundStyle(Color(nsColor: theme.text))
            .background(Color(nsColor: theme.chrome))
            .presentationBackground(Color(nsColor: theme.chrome))
    }
    private func ruleEditor(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium))
            ZStack(alignment: .topLeading) {
                TextEditor(text: text).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(nsColor: theme.secondaryText).opacity(0.65))
                        .padding(.horizontal, 5).padding(.vertical, 1).allowsHitTesting(false)
                }
            }.padding(6).frame(height: 68).background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: theme.separator), lineWidth: 1))
        }
    }
    private func reload() { model.invalidateSources(); revealSource = false; reloadID = UUID() }
}

enum APIComparisonPresentation {
    static func parseRuleLines(_ text: String, trimWhitespace: Bool) -> [String] {
        var seen = Set<Data>()
        return text.components(separatedBy: .newlines).map { trimWhitespace ? $0.trimmingCharacters(in: .whitespaces) : $0 }
            .filter { !$0.isEmpty && seen.insert(Data($0.utf8)).inserted }
    }
    /// The compact heading intentionally omits credentials, query and fragments.
    /// Full values remain in the structured comparison or explicit source view.
    static func summaryURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return L("请求地址", "Request URL") }
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        return components.string ?? L("请求地址", "Request URL")
    }
    static func entryTitle(_ exchange: APIExchange) -> String {
        "\(Int(exchange.id).map { String($0 + 1) } ?? exchange.id) · " + [exchange.request?.method, exchange.request?.url.map(summaryURL), exchange.response?.statusCode]
            .compactMap { $0 }.joined(separator: " ")
    }
}

private struct APIDifferenceRow: View {
    let row: APIComparisonRow
    let pathWidth: CGFloat
    let showCredentials: Bool
    let theme: ComparisonTheme
    private var ignored: Bool { row.state == .ignored }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: stateIcon).font(.system(size: 10)).frame(width: 12).padding(.top, 2)
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
                VStack(alignment: .leading, spacing: 3) {
                    Text(fieldLabel).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    if row.path != row.label && row.path.hasPrefix("/") {
                        Text(row.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color(nsColor: theme.secondaryText)).textSelection(.enabled)
                    }
                    if row.sensitive {
                        Label(L("凭据字段", "Credential Field"), systemImage: "lock").font(.system(size: 9))
                            .foregroundStyle(Color(nsColor: theme.secondaryText))
                    }
                    if ignored { Text(L("已忽略", "Ignored")).font(.system(size: 9)).foregroundStyle(Color(nsColor: theme.secondaryText)) }
                }
            }.padding(.vertical, 9).padding(.trailing, 10).frame(width: pathWidth, alignment: .leading)
            value(row.left, type: row.leftType, removal: true)
            value(row.right, type: row.rightType, removal: false)
        }.padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Color(nsColor: theme.separator).opacity(0.55).frame(height: 0.5) }
    }
    private var stateIcon: String {
        switch row.state {
        case .same: return "equal"
        case .changed: return "arrow.left.arrow.right"
        case .added: return "plus"
        case .removed: return "minus"
        case .ignored: return "eye.slash"
        case .unknown: return "questionmark.circle"
        }
    }
    private var fieldLabel: String {
        if row.section.hasSuffix(".summary") {
            switch row.path {
            case "method": return L("请求方法", "Method")
            case "url": return L("请求地址", "URL")
            case "httpVersion": return L("HTTP 版本", "HTTP Version")
            case "status": return L("状态码", "Status Code")
            case "statusText": return L("状态说明", "Status Text")
            default: break
            }
        }
        if row.path == "$state" { return L("正文状态", "Body Availability") }
        return row.label
    }
    private func displayValue(_ value: String?, type: String?, hidden: Bool) -> String {
        guard let value else { return L("未提供", "Not Present") }
        if hidden { return "••••••••" }
        if type == "bodyState" {
            switch value {
            case "missing": return L("未记录 · 内容未知", "Not Recorded · Unknown")
            case "unsupported": return L("暂不支持 · 内容未知", "Unsupported · Unknown")
            case "empty": return L("已记录 · 空正文", "Recorded · Empty")
            case "json": return "JSON"
            case "text": return L("文本", "Text")
            default: break
            }
        }
        if type == "object" { return "{ }" }
        if type == "array" { return "[ ]" }
        return value.isEmpty ? "\"\"" : String(value.prefix(4_096))
    }
    private func value(_ value: String?, type: String?, removal: Bool) -> some View {
        let changed = row.state == .changed || row.state == (removal ? .removed : .added)
        let hidden = row.sensitive && !showCredentials && value != nil
        return VStack(alignment: .leading, spacing: 4) {
            Text(displayValue(value, type: type, hidden: hidden))
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .foregroundStyle(Color(nsColor: value == nil || ignored ? theme.secondaryText : changed ? theme.differenceForeground(isRemoval: removal) : theme.text))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let type, row.leftType != row.rightType {
                Text(type).font(.system(size: 9, weight: .medium)).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            if !hidden, (value?.count ?? 0) > 4_096 {
                Text(L("此单元格仅预览前 4,096 个字符", "Cell Preview: First 4,096 Characters"))
                    .font(.system(size: 9)).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
        }.padding(.horizontal, 9).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .background(changed ? Color(nsColor: theme.differenceBackground(isRemoval: removal)) : .clear)
    }
}
