import AppKit
import Combine

@MainActor
final class AppAppearance: ObservableObject {
    static let shared = AppAppearance()
    @Published var isDark = false { didSet { apply() } }
    var colors: ComparisonTheme { ComparisonTheme(isDark: isDark) }

    func apply() {
        NSApplication.shared.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

/// Explicit paired colors shared by SwiftUI chrome and the cached AppKit editors.
/// These colors do not depend on the appearance active when an editor is created.
struct ComparisonTheme: Equatable {
    let isDark: Bool
    static let light = ComparisonTheme(isDark: false)
    static let dark = ComparisonTheme(isDark: true)

    var canvas: NSColor { color(0xFCFCFD, 0x191C21) }
    var chrome: NSColor { color(0xF8F9FB, 0x20242B) }
    var text: NSColor { color(0x282A2E, 0xE8EBF0) }
    var secondaryText: NSColor { color(0x646C78, 0xB0BAC8) }
    var separator: NSColor { color(0xDEE2E8, 0x373E49) }
    var accent: NSColor { color(0x355F99, 0xA0C6FF) }
    var photoLeft: NSColor { color(0x355F99, 0xA0C6FF) }
    var photoRight: NSColor { color(0xAA5C1A, 0xF3B977) }
    var selectionBackground: NSColor { color(0xC5DAFA, 0x344F76) }
    var selectionText: NSColor { color(0x1B2637, 0xFFFFFF) }
    var navigationOutline: NSColor { color(0x6194D8, 0x96BCED) }
    var navigationFill: NSColor { color(0x6194D8, 0x96BCED) }

    func differenceBackground(isRemoval: Bool, selected: Bool = false) -> NSColor {
        if isRemoval { return selected ? color(0xFADDE1, 0x553139) : color(0xFCE8EB, 0x432C33) }
        return selected ? color(0xD7EEDC, 0x284C36) : color(0xE6F3E9, 0x253D2E)
    }

    func differenceForeground(isRemoval: Bool) -> NSColor {
        isRemoval ? color(0xB42335, 0xFFA7B5) : color(0x146C32, 0x91E6AA)
    }

    private func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        let hex = isDark ? dark : light
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                       green: CGFloat((hex >> 8) & 0xff) / 255,
                       blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
