import Foundation

/// Normalized source coordinates after orientation, with a top-left origin.
public struct PhotoRegion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = PhotoRegion()
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000001 && y + height <= 1.000001
    }
}

public struct PhotoRegionPair: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var left: PhotoRegion
    public var right: PhotoRegion
    public init(id: UUID = UUID(), name: String, left: PhotoRegion, right: PhotoRegion) {
        self.id = id; self.name = name; self.left = left; self.right = right
    }
}

public struct PhotoWorkspaceState: Codable, Equatable, Sendable {
    public var leftRegion: PhotoRegion = .full
    public var rightRegion: PhotoRegion = .full
    public var linkedRegions = false
    public var regions: [PhotoRegionPair] = []
    public var leftXMPPath: String?
    public var rightXMPPath: String?
    public init() {}
    public var isValid: Bool {
        leftRegion.isValid && rightRegion.isValid && regions.count <= 32
            && Set(regions.map(\.id)).count == regions.count
            && regions.allSatisfy { $0.left.isValid && $0.right.isValid && $0.name.utf8.count <= 256 }
    }
}

public struct PhotoCurvePoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct PhotoRecordedCurve: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let points: [PhotoCurvePoint]
    public let source: String
    public init(id: String, name: String, points: [PhotoCurvePoint], source: String) {
        self.id = id; self.name = name; self.points = points; self.source = source
    }
}

public struct PhotoMetadataItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: PluginLocalizedText
    public let value: String
    public init(id: String, label: PluginLocalizedText, value: String) {
        self.id = id; self.label = label; self.value = value
    }
}

/// Library-derived distributions, normalized by valid sample count, never UI pixels.
public struct PhotoStatistics: Codable, Equatable, Sendable {
    public let red: [Double]
    public let green: [Double]
    public let blue: [Double]
    public let lightness: [Double]
    public let hue: [Double]
    public let saturation: [Double]
    public let neutralFraction: Double
    public let analyzedPixels: Int
    public let sampleWidth: Int
    public let sampleHeight: Int
    public let sampled: Bool
    public let analysisSpace: String
    public init(red: [Double], green: [Double], blue: [Double], lightness: [Double], hue: [Double],
                saturation: [Double], neutralFraction: Double, analyzedPixels: Int,
                sampleWidth: Int, sampleHeight: Int, sampled: Bool, analysisSpace: String) {
        self.red = red; self.green = green; self.blue = blue; self.lightness = lightness
        self.hue = hue; self.saturation = saturation; self.neutralFraction = neutralFraction
        self.analyzedPixels = analyzedPixels; self.sampleWidth = sampleWidth; self.sampleHeight = sampleHeight
        self.sampled = sampled; self.analysisSpace = analysisSpace
    }
    public var pluginContent: PluginJSONValue {
        // Only bounded aggregate data crosses into the restricted plugin.
        func bins(_ values: [Double]) -> PluginJSONValue { .array(values.map(PluginJSONValue.number)) }
        return .object(["red": bins(red), "green": bins(green), "blue": bins(blue),
            "lightness": bins(lightness), "hue": bins(hue), "saturation": bins(saturation),
            "neutralFraction": .number(neutralFraction), "analyzedPixels": .number(Double(analyzedPixels)),
            "sampled": .bool(sampled), "analysisSpace": .string(analysisSpace)])
    }
}
