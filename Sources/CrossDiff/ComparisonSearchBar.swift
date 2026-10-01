import SwiftUI
import CrossDiffCore

struct ComparisonSearchBar: View {
    @ObservedObject var session: ComparisonSession
    @ObservedObject private var settings = AppSettings.shared
    private enum Field: Hashable { case find, replacement }
    @FocusState private var focused: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 14)
                TextField(L("查找原文", "Find in Source Text"), text: $session.searchQuery)
                    .textFieldStyle(.roundedBorder).focused($focused, equals: .find)
                    .frame(minWidth: 150, maxWidth: 310)
                    .onSubmit { session.navigateSearch(1) }
                    .accessibilityIdentifier("comparison.find")
                Toggle(L("忽略大小写", "Ignore Case"), isOn: $session.searchIgnoreCase)
                    .toggleStyle(.checkbox).fixedSize()
                Text(session.searchStatus).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
                    .help(session.searchLimited
                        ? L("每侧仅显示前 10,000 个匹配；全部替换仍会处理所选范围内的所有匹配。", "Up to 10,000 matches are shown per side. Replace All still processes every match in the selected scope.")
                        : L("查找原文，不包含删除预览中额外显示的已删除内容。", "Find searches the source text, excluding deleted text shown only in the preview."))
                if session.searching { ProgressView().controlSize(.mini) }
                Spacer(minLength: 4)
                Button { session.showSearch(replacing: !session.isReplaceVisible) } label: {
                    Label(L("替换", "Replace"), systemImage: session.isReplaceVisible ? "chevron.down" : "chevron.right")
                }
                .help(L("显示或隐藏替换选项", "Show or hide replacement options"))
                .accessibilityIdentifier("comparison.toggleReplace")
                Button { session.navigateSearch(-1) } label: { Image(systemName: "chevron.up") }
                    .help(L("上一个匹配（⇧⌘G）", "Previous Match (⇧⌘G)"))
                    .accessibilityLabel(L("上一个搜索匹配", "Previous Search Match"))
                    .disabled(session.searchMatches.isEmpty || session.searching)
                Button { session.navigateSearch(1) } label: { Image(systemName: "chevron.down") }
                    .help(L("下一个匹配（⌘G）", "Next Match (⌘G)"))
                    .accessibilityLabel(L("下一个搜索匹配", "Next Search Match"))
                    .disabled(session.searchMatches.isEmpty || session.searching)
                Button { session.closeSearch() } label: { Image(systemName: "xmark") }
                    .help(L("关闭查找（Esc）", "Close Find (Esc)"))
                    .accessibilityLabel(L("关闭查找", "Close Find"))
            }
            if session.isReplaceVisible {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).frame(width: 14)
                    TextField(L("替换为（留空即删除）", "Replace With (Empty Deletes)"), text: $session.replacementText)
                        .textFieldStyle(.roundedBorder).focused($focused, equals: .replacement)
                        .frame(minWidth: 150, maxWidth: 310)
                        .onSubmit { session.replaceCurrentMatch() }
                        .accessibilityIdentifier("comparison.replaceWith")
                    Text(L("范围", "Scope")).foregroundStyle(.secondary)
                    Picker(L("替换范围", "Replacement Scope"), selection: $session.replacementScope) {
                        ForEach(ReplacementScope.allCases) { scope in Text(scope.title).tag(scope) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .id(settings.language)
                    .accessibilityIdentifier("comparison.replaceScope")
                    Spacer(minLength: 4)
                    if session.replacing {
                        ProgressView().controlSize(.mini)
                        Button(L("取消", "Cancel")) { session.cancelReplacement() }
                    } else {
                        Button(L("替换", "Replace")) { session.replaceCurrentMatch() }
                            .disabled(!session.canReplaceCurrentMatch)
                            .accessibilityIdentifier("comparison.replaceCurrent")
                        Button(L("全部替换", "Replace All")) { session.replaceAllMatches() }
                            .disabled(!session.canReplaceAllMatches)
                            .accessibilityIdentifier("comparison.replaceAll")
                    }
                }
                if let status = session.replacementStatus {
                    Text(status).font(.system(size: 11))
                        .foregroundStyle(session.replacementError == nil ? Color.secondary : Color.red)
                        .lineLimit(2).padding(.leading, 24)
                }
            }
        }
        .font(.system(size: 12)).controlSize(.small).buttonStyle(.borderless)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .onAppear { focused = .find }
        .onExitCommand { session.closeSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .crossDiffFocusSearch)) { notification in
            if notification.object as? UUID == session.id { focused = .find }
        }
    }
}
