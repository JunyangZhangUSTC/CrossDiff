import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// Language names remain recognizable when the interface uses another language.
    public var nativeName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    public var locale: Locale { Locale(identifier: rawValue) }

    public static func preferred(for identifiers: [String]) -> AppLanguage {
        guard let first = identifiers.first else { return .english }
        return first.lowercased().hasPrefix("zh") ? .simplifiedChinese : .english
    }
}

/// Core errors and background comparisons can read the language without accessing UI state.
/// The setting is app-local; it never modifies system language preferences.
public enum Localization {
    private static let lock = NSLock()
    private static var storedLanguage = AppLanguage.preferred(for: Locale.preferredLanguages)

    public static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return storedLanguage }
        set { lock.lock(); defer { lock.unlock() }; storedLanguage = newValue }
    }
}

public func L(_ chinese: String, _ english: String) -> String {
    Localization.language == .simplifiedChinese ? chinese : english
}

/// Translate common operating-system failures using the app language, rather than the
/// system language. Keep project-defined LocalizedError messages and avoid exposing
/// NSError userInfo, file contents, or decoding diagnostics in unexpected failures.
public func localizedErrorDescription(_ error: Error) -> String {
    if error is DecodingError {
        return L("数据格式无法识别或内容已损坏。", "The data format is not recognized or the contents are damaged.")
    }
    if let localized = error as? LocalizedError, let message = localized.errorDescription {
        return message
    }

    let systemError = error as NSError
    if systemError.domain == NSCocoaErrorDomain {
        switch CocoaError.Code(rawValue: systemError.code) {
        case .fileReadNoPermission, .fileWriteNoPermission:
            return L("没有访问该文件或文件夹的权限。请检查访问权限后重试。", "Permission to access this file or folder was denied. Check its permissions and try again.")
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return L("找不到该文件或文件夹，可能已被移动或删除。", "The file or folder could not be found. It may have been moved or deleted.")
        case .fileWriteFileExists:
            return L("目标位置已有同名文件或文件夹。", "A file or folder with the same name already exists at the destination.")
        case .fileWriteOutOfSpace:
            return L("磁盘空间不足，无法保存。请释放一些空间后重试。", "There is not enough disk space to save. Free up some space and try again.")
        case .fileWriteVolumeReadOnly:
            return L("目标磁盘为只读，无法写入。请选择可写入的位置。", "The destination disk is read-only. Choose a writable location.")
        case .fileReadCorruptFile, .propertyListReadCorrupt, .coderReadCorrupt:
            return L("数据格式无法识别或内容已损坏。", "The data format is not recognized or the contents are damaged.")
        case .fileReadInapplicableStringEncoding, .fileReadUnknownStringEncoding, .fileWriteInapplicableStringEncoding:
            return L("无法使用此字符编码读取或保存文本。", "The text cannot be read or saved using this character encoding.")
        case .fileReadTooLarge:
            return L("文件过大，无法读取。", "The file is too large to read.")
        case .userCancelled:
            return L("操作已取消。", "The operation was canceled.")
        default: break
        }
    }
    if systemError.domain == NSPOSIXErrorDomain {
        switch systemError.code {
        case 1, 13: // EPERM, EACCES
            return L("没有访问该文件或文件夹的权限。请检查访问权限后重试。", "Permission to access this file or folder was denied. Check its permissions and try again.")
        case 2: // ENOENT
            return L("找不到该文件或文件夹，可能已被移动或删除。", "The file or folder could not be found. It may have been moved or deleted.")
        case 17: // EEXIST
            return L("目标位置已有同名文件或文件夹。", "A file or folder with the same name already exists at the destination.")
        case 28: // ENOSPC
            return L("磁盘空间不足，无法保存。请释放一些空间后重试。", "There is not enough disk space to save. Free up some space and try again.")
        case 30: // EROFS
            return L("目标磁盘为只读，无法写入。请选择可写入的位置。", "The destination disk is read-only. Choose a writable location.")
        default: break
        }
    }
    return L("操作未能完成（\(systemError.domain)，错误 \(systemError.code)）。", "The operation could not be completed (\(systemError.domain), error \(systemError.code)).")
}
