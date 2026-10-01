import AppKit
import Combine
import CrossDiffCore

extension Notification.Name {
    static let crossDiffLanguageChanged = Notification.Name("CrossDiff.languageChanged")
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            Localization.language = language
            persist()
            NotificationCenter.default.post(name: .crossDiffLanguageChanged, object: nil)
        }
    }
    @Published private var preferenceFailure: PreferenceFailure?
    var errorMessage: String? {
        switch preferenceFailure {
        case .loading(let error):
            return L("无法读取设置，已使用默认设置：", "Could not read settings. Defaults are in use: ") + localizedErrorDescription(error)
        case .saving(let error):
            return L("无法保存设置，本次更改仍然有效：", "Could not save settings. Your changes still apply for this session: ") + localizedErrorDescription(error)
        case nil: return nil
        }
    }
    var locale: Locale { language.locale }

    private let preferencesURL: URL
    private var appearanceObservation: AnyCancellable?

    private enum PreferenceFailure { case loading(Error), saving(Error) }

    init(directory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let dataDirectory = directory ?? environment["CROSSDIFF_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CrossDiff", isDirectory: true)
        preferencesURL = dataDirectory.appendingPathComponent("preferences.json")

        let loaded: AppPreferences?
        var loadingError: Error?
        do { loaded = try PreferencesFile.load(from: preferencesURL) }
        catch { loaded = nil; loadingError = error }

        let defaultLanguage: AppLanguage
        #if CROSSDIFF_UI_CHECKS
        defaultLanguage = .simplifiedChinese
        #else
        defaultLanguage = loaded?.language ?? AppLanguage.preferred(for: Locale.preferredLanguages)
        #endif
        language = environment["CROSSDIFF_LANGUAGE"].flatMap(AppLanguage.init(rawValue:)) ?? defaultLanguage
        Localization.language = language
        AppAppearance.shared.isDark = loaded?.isDark ?? false
        if let loadingError {
            preferenceFailure = .loading(loadingError)
        }
        // Also retain changes made with the appearance button in the main window.
        appearanceObservation = AppAppearance.shared.$isDark.dropFirst().sink { [weak self] newValue in
            self?.persist(isDark: newValue)
        }
    }

    func retrySave() { persist() }

    private func persist(isDark: Bool? = nil) {
        do {
            try PreferencesFile.save(AppPreferences(language: language, isDark: isDark ?? AppAppearance.shared.isDark), to: preferencesURL)
            preferenceFailure = nil
        } catch {
            preferenceFailure = .saving(error)
        }
    }
}
