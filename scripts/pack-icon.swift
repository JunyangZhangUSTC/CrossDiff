import AppKit
import ImageIO

struct IconPackingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Modern ICNS chunks contain the original PNG bytes. The chunk type distinguishes
// the point size and Retina scale even when two representations have equal pixels.
let representations: [(name: String, type: String, pixels: Int)] = [
    ("icon_16x16", "icp4", 16),
    ("icon_16x16@2x", "ic11", 32),
    ("icon_32x32", "icp5", 32),
    ("icon_32x32@2x", "ic12", 64),
    ("icon_128x128", "ic07", 128),
    ("icon_128x128@2x", "ic13", 256),
    ("icon_256x256", "ic08", 256),
    ("icon_256x256@2x", "ic14", 512),
    ("icon_512x512", "ic09", 512),
    ("icon_512x512@2x", "ic10", 1024)
]

func appendLength(_ length: Int, to data: inout Data) throws {
    guard let value = UInt32(exactly: length) else {
        throw IconPackingError(message: "Icon data is too large for an ICNS container.")
    }
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

func packIcon(from directory: URL, to output: URL) throws {
    var chunks = Data()
    for representation in representations {
        let url = directory.appendingPathComponent(representation.name + ".png")
        let png = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == representation.pixels, image.height == representation.pixels else {
            throw IconPackingError(message: "\(url.lastPathComponent) must be a readable \(representation.pixels) × \(representation.pixels) PNG.")
        }
        chunks.append(contentsOf: representation.type.utf8)
        try appendLength(png.count + 8, to: &chunks)
        chunks.append(png)
    }

    var icon = Data("icns".utf8)
    try appendLength(chunks.count + 8, to: &icon)
    icon.append(chunks)

    // Validate the real container through macOS's independent decoder before
    // replacing the bundle resource. This catches bad chunk IDs or lengths.
    guard let source = CGImageSourceCreateWithData(icon as CFData, nil),
          CGImageSourceGetType(source) as String? == "com.apple.icns",
          CGImageSourceGetCount(source) == representations.count,
          NSImage(data: icon)?.isValid == true else {
        throw IconPackingError(message: "macOS could not read the generated ICNS container.")
    }
    var decodedSizes: [Int] = []
    for index in 0..<CGImageSourceGetCount(source) {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), image.width == image.height else {
            throw IconPackingError(message: "macOS could not decode ICNS representation \(index).")
        }
        decodedSizes.append(image.width)
    }
    guard decodedSizes.sorted() == representations.map(\.pixels).sorted() else {
        throw IconPackingError(message: "Generated ICNS representations do not match the original PNG sizes.")
    }
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try icon.write(to: output, options: .atomic)
    print("Packed and verified \(representations.count) icon representations: \(output.path)")
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw IconPackingError(message: "Usage: swift scripts/pack-icon.swift <input.iconset> <output.icns>")
    }
    try packIcon(from: URL(fileURLWithPath: CommandLine.arguments[1]),
                 to: URL(fileURLWithPath: CommandLine.arguments[2]))
} catch {
    FileHandle.standardError.write(Data("Icon packaging failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
