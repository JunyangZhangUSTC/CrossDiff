import Foundation

public struct TextReplacementResult: Sendable {
    public let text: String
    public let count: Int
}

public enum TextReplacementError: LocalizedError {
    case resultTooLarge

    public var errorDescription: String? {
        L("替换后的文本过大，本次替换已取消，原文未被修改。请缩小替换范围。",
          "The replacement would make the text too large. Nothing was changed. Try a smaller replacement scope.")
    }
}

/// Literal replacement shares search's UTF-16 matching and preserves every untouched source unit.
public enum TextReplacement {
    /// Protects the interactive editor from an accidental expansion into hundreds of megabytes.
    public static let maximumUTF16Length = 64 * 1024 * 1024

    public static func replacingAll(in text: String, query: String, replacement: String,
                                    ignoreCase: Bool = false,
                                    maximumLength: Int = maximumUTF16Length,
                                    cancellationCheck: () throws -> Void = {}) throws -> TextReplacementResult {
        let source = text as NSString
        let replacementLength = replacement.utf16.count
        var output = String()
        var cursor = 0, count = 0, outputLength = 0
        try TextSearch.forEachMatch(in: text, query: query, ignoreCase: ignoreCase,
                                    cancellationCheck: cancellationCheck) { range in
            let preservedLength = range.location - cursor
            guard preservedLength <= maximumLength - outputLength,
                  replacementLength <= maximumLength - outputLength - preservedLength else {
                throw TextReplacementError.resultTooLarge
            }
            output += source.substring(with: NSRange(location: cursor, length: preservedLength))
            output += replacement
            outputLength += preservedLength + replacementLength
            cursor = NSMaxRange(range)
            count += 1
        }
        try cancellationCheck()
        guard count > 0 else { return .init(text: text, count: 0) }
        guard source.length - cursor <= maximumLength - outputLength else {
            throw TextReplacementError.resultTooLarge
        }
        output += source.substring(from: cursor)
        try cancellationCheck()
        return .init(text: output, count: count)
    }
}
