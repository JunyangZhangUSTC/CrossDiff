import AppKit
import SwiftUI
import CrossDiffCore

struct AboutView: View {
    let onClose: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    private var theme: ComparisonTheme { appearance.colors }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("开发版", "Development")
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 68, height: 68).accessibilityHidden(true)
            VStack(spacing: 5) {
                Text("CrossDiff").font(.system(size: 23, weight: .semibold))
                Text(L("版本 \(version)", "Version \(version)"))
                    .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            Text(L("对比一切，把每一处变化看清。", "Compare everything. See every change."))
                .font(.callout).multilineTextAlignment(.center).padding(.vertical, 3)
            Link(destination: URL(string: "https://github.com/JunyangZhangUSTC/CrossDiff")!) {
                HStack(spacing: 5) {
                    Text("GitHub · JunyangZhangUSTC/CrossDiff")
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium))
                }.font(.system(size: 12))
            }
            .foregroundStyle(Color(nsColor: theme.accent))
            .help(L("在浏览器中打开项目仓库", "Open the project repository in your browser"))
            .accessibilityIdentifier("about.github")
            Rectangle().fill(Color(nsColor: theme.separator)).frame(width: 250, height: 0.5).padding(.vertical, 3)
            VStack(spacing: 4) {
                Text(L("免费开源 · GNU AGPL v3", "Free & open source · GNU AGPL v3"))
                Text("© 2026 Junyang Zhang")
            }.font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            Button(L("好", "OK"), action: onClose).keyboardShortcut(.defaultAction)
                .buttonStyle(.bordered).padding(.top, 4)
        }
        .padding(24).frame(width: 380, height: 350)
        .foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
        .tint(Color(nsColor: theme.accent)).preferredColorScheme(appearance.isDark ? .dark : .light)
        .environment(\.locale, settings.locale)
        .onExitCommand(perform: onClose)
    }
}
