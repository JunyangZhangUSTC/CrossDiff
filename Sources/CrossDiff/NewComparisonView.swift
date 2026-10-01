import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CrossDiffCore

/// Keeps choosing the comparison and choosing its inputs in one, reversible sheet.
struct NewComparisonView: View {
    @ObservedObject var model: NewComparisonModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    private var theme: ComparisonTheme { appearance.colors }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let type = model.selectedType {
                inputPage(type)
            } else {
                typePage
            }
            footer
        }
        .frame(width: 720, height: 500)
        .foregroundStyle(Color(nsColor: theme.text))
        .background(Color(nsColor: theme.canvas))
        .tint(Color(nsColor: theme.accent))
        .preferredColorScheme(appearance.isDark ? .dark : .light)
        .environment(\.locale, settings.locale)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if model.selectedType != nil {
                Button { model.back() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("返回比较类型", "Back to Comparison Types"))
                .accessibilityLabel(L("返回比较类型", "Back to Comparison Types"))
                .accessibilityIdentifier("new-comparison.back")
                .disabled(model.busy)
            } else {
                Image(systemName: "square.on.square")
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(Color(nsColor: theme.accent))
                    .frame(width: 36)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedType?.title ?? L("新建比较", "New Comparison"))
                    .font(.system(size: 20, weight: .semibold))
                Text(model.selectedType == nil
                    ? L("选择想要比较的内容。", "Choose what you would like to compare.")
                    : L("准备好两侧内容，然后开始比较。", "Choose the two sides, then start comparing."))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                stepLabel(1, title: L("类型", "Type"), active: model.selectedType == nil)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
                stepLabel(2, title: L("内容", "Content"), active: model.selectedType != nil)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private func stepLabel(_ number: Int, title: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Text(String(number))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .frame(width: 18, height: 18)
                .background(Color(nsColor: active ? theme.accent : theme.secondaryText).opacity(active ? 0.13 : 0.08), in: Circle())
            Text(title).font(.system(size: 11, weight: active ? .medium : .regular))
        }
        .foregroundStyle(Color(nsColor: active ? theme.accent : theme.secondaryText))
    }

    private var typePage: some View {
        VStack(spacing: 12) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                    ForEach(model.types) { type in
                        Button { model.select(type) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: type.symbol)
                                    .font(.system(size: 22, weight: .light))
                                    .foregroundStyle(Color(nsColor: theme.accent))
                                    .frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(type.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text(type.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color(nsColor: theme.secondaryText))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color(nsColor: theme.secondaryText).opacity(0.7))
                            }
                            .padding(.horizontal, 15)
                            .frame(height: 75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(NewComparisonCardStyle(theme: theme))
                        .accessibilityIdentifier("new-comparison.type.\(type.id)")
                    }
                }
                .padding(1)
            }
            .scrollIndicators(.hidden)
            Button { model.showPlugins() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color(nsColor: theme.accent))
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("更多对比项", "More Comparisons")).font(.system(size: 13, weight: .medium))
                        Text(L("前往插件页，添加与管理比较能力。", "Add and manage comparison capabilities in Plugins."))
                            .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                .padding(.horizontal, 15)
                .frame(height: 60)
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(NewComparisonCardStyle(theme: theme, subtle: true))
            .accessibilityIdentifier("new-comparison.more")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity)
    }

    private func inputPage(_ type: NewComparisonType) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                NewComparisonSourceCard(model: model, type: type, side: .left, theme: theme)
                Button { model.swap() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: theme.secondaryText))
                .help(L("交换左右内容", "Swap Sides"))
                .accessibilityLabel(L("交换左右内容", "Swap Sides"))
                .accessibilityIdentifier("new-comparison.swap")
                NewComparisonSourceCard(model: model, type: type, side: .right, theme: theme)
            }
            .disabled(model.busy)
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: true)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
                    .accessibilityIdentifier("new-comparison.error")
            } else {
                Label(type.isAPI
                    ? L("粘贴 HTTP、cURL 或 HAR，也可选择文件。仅在本机解析。", "Paste HTTP, cURL or HAR, or choose files. Parsed locally on your Mac.")
                    : type.kind == .text
                    ? L("可直接粘贴文字，也可留空后在比较页编辑。", "Paste text here, or start empty and edit in the comparison.")
                    : L("也可以将项目分别拖入两侧。比较不会修改原文件。", "You can also drop an item on each side. Comparing leaves originals unchanged."),
                      systemImage: type.kind == .text ? "text.cursor" : "doc.badge.arrow.up")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Color(nsColor: theme.separator).frame(height: 0.5)
            HStack(spacing: 10) {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text(L("正在准备比较…", "Preparing comparison…"))
                        .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                Spacer()
                Button(L("取消", "Cancel")) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("new-comparison.cancel")
                if model.selectedType != nil {
                    Button(L("开始比较", "Compare")) { model.create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canCreate || model.busy)
                        .accessibilityIdentifier("new-comparison.create")
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }
}

private struct NewComparisonSourceCard: View {
    @ObservedObject var model: NewComparisonModel
    let type: NewComparisonType
    let side: Side
    let theme: ComparisonTheme
    @State private var isDropTarget = false
    private var prefix: String { "new-comparison.\(side == .left ? "left" : "right")" }
    private var input: NewComparisonInput { side == .left ? model.left : model.right }
    private var title: String { side == .left ? L("左侧", "Left") : L("右侧", "Right") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if case .text = input {
                    Text(type.isAPI ? L("粘贴内容", "Pasted Input") : L("临时文本", "Temporary Text"))
                        .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
            }.padding(14)
            Color(nsColor: theme.separator).frame(height: 0.5)
            switch input {
            case .text:
                textInput
            case .file(let url):
                selectedFile(url)
            case .empty:
                emptyInput
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 268)
        .background(Color(nsColor: theme.chrome), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(nsColor: isDropTarget ? theme.accent : theme.separator), lineWidth: isDropTarget ? 1.5 : 0.7))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: acceptDrop)
    }

    private var textInput: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if case .text(let text) = input, text.isEmpty {
                    Text(type.isAPI ? L("粘贴 HTTP、cURL 或 HAR…", "Paste HTTP, cURL or HAR…") : L("在这里粘贴文字…", "Paste text here…"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(nsColor: theme.secondaryText).opacity(0.8))
                        .padding(.horizontal, 7).padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: {
                    if case .text(let text) = input { return text }; return ""
                }, set: { model.setInput(.text($0), side: side) }))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(nsColor: theme.text))
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(side == .left ? L("左侧临时文本", "Left Temporary Text") : L("右侧临时文本", "Right Temporary Text"))
                    .accessibilityIdentifier(prefix + ".text")
            }
            .padding(8)
            .frame(maxHeight: .infinity)
            Color(nsColor: theme.separator).frame(height: 0.5)
            HStack {
                Button { model.chooseFile(side: side) } label: {
                    Label(L("选择文件…", "Choose File…"), systemImage: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: theme.accent))
                .accessibilityIdentifier(prefix + ".choose")
                Spacer(minLength: 0)
            }.font(.system(size: 11)).padding(12)
        }
    }

    private var emptyInput: some View {
        Button { model.chooseFile(side: side) } label: {
            VStack(spacing: 13) {
                Spacer(minLength: 8)
                Image(systemName: type.kind == .folder ? "folder.badge.plus" : "doc.badge.plus")
                    .font(.system(size: 32, weight: .ultraLight))
                    .foregroundStyle(Color(nsColor: theme.accent))
                Text(type.kind == .folder ? L("选择文件夹…", "Choose Folder…")
                    : type.acceptsFolders ? L("选择压缩包或文件夹…", "Choose Archive or Folder…")
                    : L("选择文件…", "Choose File…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: theme.accent))
                    .multilineTextAlignment(.center)
                Text(L("或拖放到这里", "or drop it here"))
                    .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(prefix + ".choose")
    }

    private func selectedFile(_ url: URL) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 4)
            Image(systemName: type.kind == .folder || url.hasDirectoryPath ? "folder" : type.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color(nsColor: theme.accent))
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(prefix + ".filename")
            Text(url.deletingLastPathComponent().path)
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: theme.secondaryText))
                .lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.center)
                .help(url.path)
            Spacer(minLength: 4)
            HStack(spacing: 14) {
                Button(L("重新选择…", "Choose Another…")) { model.chooseFile(side: side) }
                    .foregroundStyle(Color(nsColor: theme.accent))
                    .accessibilityIdentifier(prefix + ".choose")
                Button { model.setInput(type.acceptsTextInput ? .text("") : .empty, side: side) } label: {
                    Image(systemName: "xmark.circle")
                }
                .foregroundStyle(Color(nsColor: theme.secondaryText))
                .help(L("移除所选项目", "Remove Selected Item"))
                .accessibilityLabel(L("移除所选项目", "Remove Selected Item"))
                .accessibilityIdentifier(prefix + ".remove")
            }.buttonStyle(.plain).font(.system(size: 11))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.busy, providers.count == 1, let provider = providers.first else { return false }
        let typeID = type.id
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            guard let url else { return }
            Task { @MainActor in
                guard model.selectedType?.id == typeID, !model.busy else { return }
                model.setInput(.file(url), side: side)
            }
        }
        return true
    }
}

private struct NewComparisonCardStyle: ButtonStyle {
    let theme: ComparisonTheme
    var subtle = false

    func makeBody(configuration: Configuration) -> some View {
        NewComparisonCardSurface(configuration: configuration, theme: theme, subtle: subtle)
    }

    private struct NewComparisonCardSurface: View {
        let configuration: ButtonStyleConfiguration
        let theme: ComparisonTheme
        let subtle: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(Color(nsColor: theme.chrome), in: RoundedRectangle(cornerRadius: 10))
                .background(Color(nsColor: theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: theme.accent).opacity(configuration.isPressed ? 0.09 : hovered ? 0.045 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: hovered ? theme.accent : theme.separator).opacity(subtle && !hovered ? 0.7 : 1), lineWidth: 0.7))
                .onHover { hovered = $0 }
        }
    }
}
