import AppKit
import PDFKit
import SwiftUI
import CrossDiffCore

@MainActor
struct PDFComparisonView: View {
    let left: URL
    let right: URL
    @ObservedObject var model: PDFComparisonModel
    let pluginName: String
    let execute: @Sendable ([PluginInput]) async throws -> PluginComparisonResult
    var executionID: String = ""
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @State private var showsPageList = true
    @State private var showsInformation = false
    private var theme: ComparisonTheme { appearance.colors }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if model.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L("正在读取 PDF 并匹配页面…", "Reading PDFs and matching pages…"))
                        .foregroundStyle(Color(nsColor: theme.secondaryText))
                    Button(L("取消", "Cancel")) { model.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(L("无法比较 PDF", "Unable to Compare PDFs"), systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(localizedErrorDescription(error))
                } actions: {
                    Button(L("重试", "Try Again")) { reload() }
                }
            } else if let pair = model.selectedPair {
                alignmentInformation
                Divider()
                HStack(spacing: 0) {
                    if showsPageList && model.alignmentMode != .manual { pageList; Divider() }
                    pagePane(url: left, document: model.leftDocument, pageIndex: pair.left, isLeft: true)
                    Divider()
                    pagePane(url: right, document: model.rightDocument, pageIndex: pair.right, isLeft: false)
                }
                Divider()
                informationBar
            } else {
                ContentUnavailableView {
                    Label(L("PDF 比较已取消", "PDF Comparison Canceled"), systemImage: "doc.text.magnifyingglass")
                } actions: {
                    Button(L("开始比较", "Compare PDFs")) { reload() }
                }
            }
        }
        .foregroundStyle(Color(nsColor: theme.text))
        .background(Color(nsColor: theme.canvas))
        .task(id: [left.absoluteString, right.absoluteString, executionID]) {
            await model.load(left: left, right: right, execute: execute, executionID: executionID)
        }
        .onDisappear { model.cancel() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { showsPageList.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .disabled(model.alignmentMode == .manual)
                .help(L("显示或隐藏页面列表", "Show or Hide Page List"))
                .accessibilityLabel(L("页面列表", "Page List"))
                .accessibilityIdentifier("pdf.pageList.toggle")
            Picker(L("PDF 比较视图", "PDF Comparison View"), selection: $model.mode) {
                ForEach(PDFComparisonMode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 210).id(settings.language)
                .accessibilityIdentifier("pdf.mode")
            alignmentMenu
            Spacer(minLength: 4)
            if model.alignmentMode != .manual {
                HStack(spacing: 8) {
                    Button { model.move(by: -1) } label: { Image(systemName: "chevron.left") }
                        .disabled(model.selectedIndex <= 0)
                        .help(L("上一组页面", "Previous Page Pair"))
                        .accessibilityLabel(L("上一组页面", "Previous Page Pair"))
                        .accessibilityIdentifier("pdf.previousPage")
                    Text(model.pairs.isEmpty ? "—" : L("第 \(model.selectedIndex + 1) / \(model.pairs.count) 组", "Pair \(model.selectedIndex + 1) / \(model.pairs.count)"))
                        .font(.system(size: 12)).monospacedDigit().fixedSize()
                        .accessibilityIdentifier("pdf.pagePosition")
                    Button { model.move(by: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(model.selectedIndex + 1 >= model.pairs.count)
                        .help(L("下一组页面", "Next Page Pair"))
                        .accessibilityLabel(L("下一组页面", "Next Page Pair"))
                        .accessibilityIdentifier("pdf.nextPage")
                }
                .buttonStyle(.borderless)
            }
            if model.mode == .pages {
                Menu {
                    ForEach(PDFComparisonZoom.allCases) { option in
                        Button { model.zoom = option } label: {
                            if option == model.zoom { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(model.zoom.title).font(.system(size: 12))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(Color(nsColor: theme.text))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: theme.separator), lineWidth: 0.5))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 126)
                .accessibilityLabel(L("页面缩放", "Page Zoom"))
                .accessibilityIdentifier("pdf.zoom")
            }
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(L("重新读取 PDF", "Reload PDFs"))
                .accessibilityLabel(L("重新读取 PDF", "Reload PDFs"))
                .accessibilityIdentifier("pdf.reload")
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Color(nsColor: theme.chrome))
        .disabled(model.isLoading)
    }

    private var alignmentMenu: some View {
        Menu {
            ForEach(PDFPageAlignmentMode.allCases) { option in
                Button { model.selectAlignmentMode(option) } label: {
                    if model.alignmentMode == option { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
                .accessibilityIdentifier("pdf.alignment.\(option.rawValue)")
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: model.alignmentMode == .manual ? "hand.point.up.left" : "rectangle.split.2x1")
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
                Text(model.alignmentMode.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(Color(nsColor: theme.text))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: theme.separator), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 144)
        .help(L("页面配对方式：按页码、智能匹配或手动配对", "Page pairing: page number, smart matching or manual pairing"))
        .accessibilityLabel(L("页面配对方式", "Page Pairing"))
        .accessibilityIdentifier("pdf.alignment.menu")
    }

    private var alignmentInformation: some View {
        HStack(spacing: 7) {
            Image(systemName: model.isSmartFallback ? "arrow.uturn.backward.circle" : "info.circle")
            // NSHostingView measures minimum bounds with a zero-width proposal.
            // Bound this status line so translated text cannot inflate the
            // window's minimum height during that measurement.
            Text(model.alignmentNotice).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true).help(model.alignmentNotice)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(nsColor: theme.secondaryText))
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color(nsColor: theme.chrome))
        .accessibilityIdentifier("pdf.alignment.notice")
    }

    private var pageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.pairs) { pair in
                        Button { model.selectedIndex = pair.id } label: {
                            HStack(spacing: 7) {
                                Image(systemName: symbol(pair.kind)).font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(pairColor(pair.kind))
                                Text("\(pair.left.map { String($0 + 1) } ?? "—")  ·  \(pair.right.map { String($0 + 1) } ?? "—")")
                                    .font(.system(size: 12)).monospacedDigit()
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(model.selectedIndex == pair.id ? Color(nsColor: theme.selectionBackground) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(model.presentationTitle(for: pair))
                        .accessibilityLabel(L("左页 \(pair.left.map { String($0 + 1) } ?? "无")，右页 \(pair.right.map { String($0 + 1) } ?? "无")，\(model.presentationTitle(for: pair))",
                                              "Left page \(pair.left.map { String($0 + 1) } ?? "none"), right page \(pair.right.map { String($0 + 1) } ?? "none"), \(model.presentationTitle(for: pair))"))
                        .accessibilityIdentifier("pdf.pair.\(pair.id)")
                        .id(pair.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selectedIndex) { _, value in proxy.scrollTo(value) }
        }
        .frame(width: 112)
        .background(Color(nsColor: theme.chrome))
    }

    private func pagePane(url: URL, document: PDFComparisonDocument?, pageIndex: Int?, isLeft: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext").foregroundStyle(Color(nsColor: theme.secondaryText))
                VStack(alignment: .leading, spacing: 3) {
                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle).help(url.path)
                    Text(pageIndex.map { L("第 \($0 + 1) 页，共 \(document?.totalPageCount ?? 0) 页", "Page \($0 + 1) of \(document?.totalPageCount ?? 0)") } ?? L("此侧无对应页面", "No Corresponding Page"))
                        .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                        .accessibilityIdentifier(isLeft ? "pdf.left.sourcePage" : "pdf.right.sourcePage")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Color(nsColor: theme.chrome))
            if model.alignmentMode == .manual, let document {
                manualPageControls(document: document, isLeft: isLeft)
            }
            Divider()
            if let pageIndex, let document {
                if model.mode == .pages {
                    PDFReadOnlyPage(document: document, pageIndex: pageIndex, zoom: model.zoom, theme: theme,
                                    label: isLeft ? L("左侧 PDF 页面", "Left PDF Page") : L("右侧 PDF 页面", "Right PDF Page"))
                } else {
                    textPane(document.pages[pageIndex], isLeft: isLeft)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: isLeft ? "plus.rectangle.on.rectangle" : "minus.rectangle")
                        .font(.system(size: 24, weight: .light))
                    Text(model.alignmentMode == .smart && !model.isSmartFallback
                         ? (isLeft ? L("此页仅在右侧找到", "This Page Was Found Only on the Right") : L("此页仅在左侧找到", "This Page Was Found Only on the Left"))
                         : L("此侧没有这个页码的页面", "There Is No Page at This Number on This Side"))
                        .font(.system(size: 12)).multilineTextAlignment(.center)
                }
                .foregroundStyle(Color(nsColor: theme.secondaryText))
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func manualPageControls(document: PDFComparisonDocument, isLeft: Bool) -> some View {
        let current = (isLeft ? model.manualLeftPage : model.manualRightPage) ?? 0
        let prefix = isLeft ? "pdf.left" : "pdf.right"
        return HStack(spacing: 8) {
            Text(L("页码", "Page")).font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
            PDFPageNumberEntry(number: current + 1, count: document.pages.count,
                               label: isLeft ? L("左侧页码", "Left Page Number") : L("右侧页码", "Right Page Number"),
                               identifier: "\(prefix).pageNumber") { model.selectManualPageNumber($0, isLeft: isLeft) }
            Text("/ \(document.pages.count)").font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Color(nsColor: theme.secondaryText))
            Spacer(minLength: 8)
            Button { model.selectManualPage(current - 1, isLeft: isLeft) } label: { Image(systemName: "chevron.left") }
                .disabled(current == 0).accessibilityIdentifier("\(prefix).previousPage")
                .help(L("上一页", "Previous Page"))
            Button { model.selectManualPage(current + 1, isLeft: isLeft) } label: { Image(systemName: "chevron.right") }
                .disabled(current >= document.pages.count - 1).accessibilityIdentifier("\(prefix).nextPage")
                .help(L("下一页", "Next Page"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.bottom, 10)
        .background(Color(nsColor: theme.chrome))
    }

    @ViewBuilder
    private func textPane(_ page: PDFPageDescriptor, isLeft: Bool) -> some View {
        if page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "doc.viewfinder").font(.system(size: 24, weight: .light))
                Text(L("此页没有可提取文字", "No Extractable Text on This Page"))
                Text(L("可能是扫描页、空白页或受复制限制；请切换到页面对照。当前未执行 OCR。", "It may be scanned, blank or copy-restricted. Use the page view to inspect it. OCR was not performed."))
                    .font(.system(size: 11)).multilineTextAlignment(.center)
            }
            .foregroundStyle(Color(nsColor: theme.secondaryText))
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if page.textTruncated {
                    Label(L("仅显示已读取的部分文字", "Showing Only the Text Read"), systemImage: "info.circle")
                        .font(.system(size: 11)).padding(8)
                        .frame(maxWidth: .infinity).background(Color(nsColor: theme.chrome))
                }
                PDFReadOnlyText(text: page.text, highlights: (model.textDiff?.rows ?? []).flatMap { isLeft ? $0.leftHighlights : $0.rightHighlights },
                                isRemoval: isLeft, theme: theme,
                                label: isLeft ? L("左侧 PDF 提取文字", "Left Extracted PDF Text") : L("右侧 PDF 提取文字", "Right Extracted PDF Text"))
            }
        }
    }

    private var informationBar: some View {
        HStack(spacing: 12) {
            if let pair = model.selectedPair {
                Label(model.presentationTitle(for: pair), systemImage: symbol(pair.kind))
                    .foregroundStyle(pairColor(pair.kind))
            }
            Spacer(minLength: 8)
            if model.result?.status == .partial {
                Label(L("部分内容", "Partial Coverage"), systemImage: "exclamationmark.circle")
            }
            Text(L("预览比较 · 无 OCR", "Preview Comparison · No OCR"))
                .foregroundStyle(Color(nsColor: theme.secondaryText))
            Button { showsInformation.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("PDF 比较范围与说明", "PDF Comparison Scope and Details"))
                .popover(isPresented: $showsInformation) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(pluginName).font(.headline)
                        Text(model.alignmentNotice).font(.system(size: 12))
                        if model.alignmentMode == .smart {
                            if !model.isSmartFallback, let summary = model.result?.summary { Text(localized(summary)) }
                            ForEach(Array((model.result?.diagnostics ?? []).enumerated()), id: \.offset) { _, diagnostic in
                                Text(localized(diagnostic)).font(.system(size: 12))
                            }
                        }
                        Text(L("每份文件最多读取 200 页、48 MB；每页最多 32,768 个 UTF-16 字符，每份文件文字预算 262,144。页面指纹来自最长边 384 像素的预览；源文件保持不变。",
                               "Reads up to 200 pages and 48 MB per file, with up to 32,768 UTF-16 units per page and 262,144 per file. Page fingerprints use previews with a 384-pixel longest edge. Source files are unchanged."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(18).frame(width: 370)
                }
            if model.alignmentMode != .manual {
                Divider().frame(height: 14)
                Button { model.move(by: -1, differencesOnly: true) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).help(L("上一处变化或待审阅页面", "Previous Change or Page to Review"))
                    .accessibilityLabel(L("上一处 PDF 差异", "Previous PDF Difference"))
                    .accessibilityIdentifier("pdf.previousDifference")
                Button { model.move(by: 1, differencesOnly: true) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).help(L("下一处变化或待审阅页面", "Next Change or Page to Review"))
                    .accessibilityLabel(L("下一处 PDF 差异", "Next PDF Difference"))
                    .accessibilityIdentifier("pdf.nextDifference")
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color(nsColor: theme.chrome))
    }

    private func reload() { Task { await model.load(left: left, right: right, execute: execute, force: true, executionID: executionID) } }
    private func localized(_ text: PluginLocalizedText) -> String { L(text.zhHans, text.en) }
    private func symbol(_ kind: PDFPagePair.Kind) -> String {
        switch kind { case .same: return "equal"; case .changed: return "circle.lefthalf.filled"; case .added: return "plus"; case .removed: return "minus"; case .unknown: return "questionmark.circle" }
    }
    private func pairColor(_ kind: PDFPagePair.Kind) -> Color {
        switch kind {
        case .added: return Color(nsColor: theme.differenceForeground(isRemoval: false))
        case .removed: return Color(nsColor: theme.differenceForeground(isRemoval: true))
        case .changed: return Color(nsColor: theme.accent)
        default: return Color(nsColor: theme.secondaryText)
        }
    }
}

/// Commit page entry on Return or focus departure. Invalid/overflowing input is
/// restored to the actual source page so the field never claims a false page.
private struct PDFPageNumberEntry: View {
    let number: Int
    let count: Int
    let label: String
    let identifier: String
    let select: (Int) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder).font(.system(size: 12)).monospacedDigit()
            .multilineTextAlignment(.center).frame(width: 50)
            .focused($focused)
            .accessibilityLabel(label).accessibilityIdentifier(identifier)
            .onAppear { draft = String(number) }
            .onChange(of: number) { _, value in draft = String(value) }
            .onChange(of: focused) { _, value in if !value { commit() } }
            .onSubmit(commit)
    }
    private func commit() {
        guard let value = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 1, value <= count else {
            draft = String(number); return
        }
        draft = String(value)
        select(value)
    }
}

/// Draw PDFKit pages directly inside a native scroll view. PDFView's tiled
/// layer pipeline can leave a composed host surface blank despite valid pages;
/// this page surface has an ordinary AppKit drawing lifecycle and no PDF actions.
private struct PDFReadOnlyPage: NSViewRepresentable {
    let document: PDFComparisonDocument
    let pageIndex: Int
    let zoom: PDFComparisonZoom
    let theme: ComparisonTheme
    let label: String

    func makeNSView(context: Context) -> PDFPageViewport { PDFPageViewport() }
    func updateNSView(_ view: PDFPageViewport, context: Context) {
        view.update(document: document.document, index: pageIndex, zoom: zoom, theme: theme, label: label)
    }
}

private final class PDFPageViewport: NSView {
    private let scroll = NSScrollView()
    private let canvas = PDFPageCanvas()
    private var source: PDFDocument?
    private var index: Int?
    private var zoom = PDFComparisonZoom.fit
    private var resetPosition = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = canvas
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { nil }

    func update(document: PDFDocument, index: Int, zoom: PDFComparisonZoom, theme: ComparisonTheme, label: String) {
        if source !== document || self.index != index {
            source = document; self.index = index; canvas.page = document.page(at: index)
            resetPosition = true
        }
        if self.zoom != zoom { self.zoom = zoom; resetPosition = true }
        canvas.theme = theme; scroll.backgroundColor = theme.canvas
        canvas.setAccessibilityLabel(label)
        needsLayout = true; canvas.needsDisplay = true
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        guard let page = canvas.page else { return }
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        let size = NSSize(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
        let viewport = scroll.contentSize
        guard viewport.width > 0, viewport.height > 0, size.width > 0, size.height > 0 else { return }
        let fit = min(max(1, viewport.width - 32) / size.width, max(1, viewport.height - 32) / size.height)
        let scale = zoom.scale ?? fit
        let paper = NSSize(width: size.width * scale, height: size.height * scale)
        canvas.frame = NSRect(x: 0, y: 0, width: max(viewport.width, paper.width + 32), height: max(viewport.height, paper.height + 32))
        canvas.paperRect = NSRect(x: (canvas.bounds.width - paper.width) / 2,
                                  y: (canvas.bounds.height - paper.height) / 2, width: paper.width, height: paper.height)
        canvas.scale = scale
        canvas.needsDisplay = true
        if resetPosition {
            scroll.contentView.scroll(to: NSPoint(x: max(0, (canvas.bounds.width - viewport.width) / 2),
                                                 y: max(0, canvas.bounds.height - viewport.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            resetPosition = false
        }
    }
}

private final class PDFPageCanvas: NSView {
    var page: PDFPage?
    var paperRect = NSRect.zero
    var scale: CGFloat = 1
    var theme = ComparisonTheme.light
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("pdf.page.canvas")
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        theme.canvas.setFill(); bounds.fill()
        guard let page, let context = NSGraphicsContext.current?.cgContext, paperRect.width > 0 else { return }
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(paperRect)
        context.clip(to: paperRect)
        context.translateBy(x: paperRect.minX, y: paperRect.minY)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        theme.separator.setStroke()
        let outline = NSBezierPath(rect: paperRect); outline.lineWidth = 0.5; outline.stroke()
    }
}

private struct PDFReadOnlyText: NSViewRepresentable {
    let text: String
    let highlights: [NSRange]
    let isRemoval: Bool
    let theme: ComparisonTheme
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = NSTextView(frame: .zero)
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 14, height: 14)
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        scroll.backgroundColor = theme.canvas; editor.backgroundColor = theme.canvas
        editor.textColor = theme.text
        editor.selectedTextAttributes = [.backgroundColor: theme.selectionBackground, .foregroundColor: theme.selectionText]
        editor.setAccessibilityLabel(label)
        let coordinator = context.coordinator
        guard coordinator.text != text || coordinator.highlights != highlights || coordinator.theme != theme else { return }
        let selection = editor.selectedRange()
        let textChanged = coordinator.text != text
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let styled = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: theme.text, .paragraphStyle: paragraph
        ])
        for range in highlights where range.location >= 0 && NSMaxRange(range) <= styled.length {
            styled.addAttributes([.backgroundColor: theme.differenceBackground(isRemoval: isRemoval),
                                  .foregroundColor: theme.differenceForeground(isRemoval: isRemoval)], range: range)
        }
        editor.textStorage?.setAttributedString(styled)
        if textChanged { editor.setSelectedRange(NSRange(location: 0, length: 0)); scroll.contentView.scroll(to: .zero) }
        else if NSMaxRange(selection) <= styled.length { editor.setSelectedRange(selection) }
        coordinator.text = text; coordinator.highlights = highlights; coordinator.theme = theme
    }
    final class Coordinator {
        var text: String?
        var highlights: [NSRange] = []
        var theme: ComparisonTheme?
    }
}
