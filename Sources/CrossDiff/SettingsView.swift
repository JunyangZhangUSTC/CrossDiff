import SwiftUI
import CrossDiffCore

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    private var theme: ComparisonTheme { appearance.colors }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color(nsColor: theme.accent))
                        .frame(width: 44, height: 44)
                        .background(Color(nsColor: theme.accent).opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("通用", "General")).font(.system(size: 20, weight: .semibold))
                        Text(L("让 CrossDiff 更合你的习惯。", "Make CrossDiff feel at home."))
                            .font(.system(size: 12)).foregroundStyle(Color(nsColor: theme.secondaryText))
                    }
                }

                VStack(spacing: 0) {
                    HStack {
                        Label(L("语言/Language", "语言/Language"), systemImage: "globe")
                        Spacer()
                        Picker(L("语言/Language", "语言/Language"), selection: $settings.language) {
                            ForEach(AppLanguage.allCases, id: \.self) { language in
                                Text(language.nativeName).tag(language)
                            }
                        }.labelsHidden().frame(width: 168)
                    }.padding(16)

                    Divider().padding(.leading, 16)

                    HStack {
                        Label(L("外观", "Appearance"), systemImage: "circle.lefthalf.filled")
                        Spacer()
                        Picker(L("外观", "Appearance"), selection: $appearance.isDark) {
                            Text(L("浅色", "Light")).tag(false)
                            Text(L("深色", "Dark")).tag(true)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 168)
                    }.padding(16)
                }
                .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: theme.separator), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("更改立即生效，无需重新启动。", "Changes apply immediately. No restart needed."))
                    Text(L("设置仅保存在本机，不影响系统或其他应用。", "Settings stay on this Mac and do not affect other apps or system preferences."))
                }.font(.system(size: 12)).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize(horizontal: false, vertical: true)

                if let error = settings.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Button(L("重试保存", "Retry Saving")) { settings.retrySave() }.controlSize(.small)
                    }.foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: true)))
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460)
        .frame(idealHeight: 340)
        .background(Color(nsColor: theme.chrome))
        .foregroundStyle(Color(nsColor: theme.text))
        .tint(Color(nsColor: theme.accent))
        .environment(\.locale, settings.locale)
        // AppKit-backed pickers need the current environment value immediately;
        // a scene preference alone can leave their text using the previous theme.
        .environment(\.colorScheme, appearance.isDark ? .dark : .light)
        .preferredColorScheme(appearance.isDark ? .dark : .light)
    }
}
