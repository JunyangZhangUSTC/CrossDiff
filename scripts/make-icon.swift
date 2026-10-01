import AppKit

// One vector composition generates the app icon, SVG source, and README artwork.
// Coordinates use a top-left origin. Nothing is fetched from the network.
struct BrandColor {
    let hex: String
    var native: NSColor {
        let value = UInt32(hex, radix: 16)!
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

final class Canvas {
    var svg: [String] = []
    let size: CGSize

    init(width: CGFloat, height: CGFloat) {
        size = CGSize(width: width, height: height)
        svg.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(width))\" height=\"\(Int(height))\" viewBox=\"0 0 \(Int(width)) \(Int(height))\" role=\"img\" aria-label=\"CrossDiff\">")
    }

    func rounded(_ rect: CGRect, radius: CGFloat, color: String, opacity: CGFloat = 1) {
        BrandColor(hex: color).native.withAlphaComponent(opacity).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        svg.append("<rect x=\"\(rect.minX)\" y=\"\(rect.minY)\" width=\"\(rect.width)\" height=\"\(rect.height)\" rx=\"\(radius)\" fill=\"#\(color)\" opacity=\"\(opacity)\"/>")
    }

    func text(_ text: String, x: CGFloat, baseline: CGFloat, size: CGFloat, weight: NSFont.Weight, color: String) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: BrandColor(hex: color).native]
        (text as NSString).draw(at: CGPoint(x: x, y: baseline - font.ascender), withAttributes: attributes)
        let safeText = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let svgWeight = weight == .semibold ? 600 : weight == .bold ? 700 : 400
        svg.append("<text x=\"\(x)\" y=\"\(baseline)\" font-family=\"-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif\" font-size=\"\(size)\" font-weight=\"\(svgWeight)\" letter-spacing=\"-0.5\" fill=\"#\(color)\">\(safeText)</text>")
    }

    func icon(at origin: CGPoint = .zero, size: CGFloat = 1024, compact: Bool = false) {
        let scale = size / 1024
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat, _ color: String, _ opacity: CGFloat = 1) {
            rounded(CGRect(x: origin.x + x * scale, y: origin.y + y * scale, width: w * scale, height: h * scale),
                    radius: radius * scale, color: color, opacity: opacity)
        }

        // The inset follows macOS icon proportions; the surrounding canvas is transparent.
        // Fine neutral rims convey material without texture, gloss, or raster effects.
        r(68, 76, 888, 888, 204, "14263E", 0.08)
        r(64, 64, 896, 896, 204, "DCE3EC")
        r(67, 67, 890, 888, 201, "F4F7FB")
        r(70, 69, 884, 880, 198, "F8FAFC")

        // A shared baseline and identical document shapes communicate comparison.
        let width: CGFloat = 252
        for x: CGFloat in [222, 550] {
            r(x, 244, width, 560, 40, "14263E", 0.075)
            r(x, 220, width, 560, 40, "273D58")
            r(x + 2, 222, width - 4, 556, 38, "304A68")
            r(x + 44, 295, 164, compact ? 36 : 28, 14, "E1EAF4")
            if !compact {
                r(x + 44, 352, 108, 24, 12, "8FA6C0")
                r(x + 44, 681, 134, 24, 12, "8FA6C0")
            }
        }

        // The minus and plus remain recognizable without relying only on red/green.
        r(198, 439, 300, 162, 34, "F2A2A8")
        r(526, 439, 300, 162, 34, "8FD4BE")
        r(286, 506, 124, 28, 14, "713846")
        r(614, 506, 124, 28, 14, "215B50")
        r(662, 458, 28, 124, 14, "215B50")
    }

    var svgDocument: String { svg.joined(separator: "\n") + "\n</svg>\n" }
}

func render(width: Int, height: Int, png: URL, svg: URL? = nil, composition: (Canvas) -> Void) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "CrossDiff.Brand", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create the artwork canvas."])
    }
    bitmap.size = NSSize(width: width, height: height)
    let context = graphics.cgContext
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    let canvas = Canvas(width: CGFloat(width), height: CGFloat(height))
    composition(canvas)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CrossDiff.Brand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode artwork as PNG."])
    }
    try data.write(to: png, options: .atomic)
    if let svg { try canvas.svgDocument.write(to: svg, atomically: true, encoding: .utf8) }
}

do {
    guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 4,
          CommandLine.arguments.count == 2 || CommandLine.arguments[2] == "--brand" else {
        throw NSError(domain: "CrossDiff.Brand", code: 3, userInfo: [NSLocalizedDescriptionKey:
            "Usage: swift scripts/make-icon.swift <output.iconset> [--brand <brand-directory>]"])
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let representations = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                           ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                           ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
    for (name, pixels) in representations {
        try render(width: pixels, height: pixels, png: directory.appendingPathComponent(name + ".png")) {
            $0.icon(size: CGFloat(pixels), compact: pixels <= 32)
        }
    }
    if CommandLine.arguments.count == 4 {
        let brand = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
        try render(width: 1024, height: 1024, png: brand.appendingPathComponent("icon-1024.png"),
                   svg: brand.appendingPathComponent("icon.svg")) { $0.icon() }
        for chinese in [false, true] {
            let name = chinese ? "hero-zh-CN" : "hero"
            try render(width: 1600, height: 520, png: brand.appendingPathComponent(name + ".png"),
                       svg: brand.appendingPathComponent(name + ".svg")) { canvas in
                canvas.rounded(CGRect(x: 0, y: 0, width: 1600, height: 520), radius: 28, color: "F4F7FB")
                canvas.rounded(CGRect(x: 1101, y: 53, width: 336, height: 414), radius: 150, color: "E8EEF6")
                canvas.text(chinese ? "原生 macOS · 免费开源" : "MACOS · FREE & OPEN SOURCE",
                            x: 100, baseline: 139, size: 18, weight: .semibold, color: "536A84")
                canvas.text("CrossDiff", x: 94, baseline: 256, size: 108, weight: .bold, color: "233952")
                canvas.text(chinese ? "看清每一处变化。" : "Native comparisons for macOS.",
                            x: 100, baseline: 322, size: 34, weight: .regular, color: "536A84")
                canvas.text(chinese ? "文本  /  文件夹  /  图片" : "Text  /  Folders  /  Images",
                            x: 100, baseline: 410, size: 23, weight: .regular, color: "657C96")
                canvas.icon(at: CGPoint(x: 1050, y: 40), size: 440)
            }
        }
        try render(width: 800, height: 180, png: brand.appendingPathComponent("wordmark.png"),
                   svg: brand.appendingPathComponent("wordmark.svg")) { canvas in
            canvas.icon(at: CGPoint(x: 0, y: 0), size: 180)
            canvas.text("CrossDiff", x: 208, baseline: 124, size: 99, weight: .semibold, color: "233952")
        }
        print("Generated CrossDiff brand artwork in \(brand.path)")
    }
    print("Generated \(representations.count) icon representations in \(directory.path)")
} catch {
    FileHandle.standardError.write(Data("Brand generation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
