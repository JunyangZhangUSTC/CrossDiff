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

/// RGB is an overview of three distributions, never a combined numerical channel.
public enum PhotoHistogramChannel: String, Codable, CaseIterable, Sendable {
    case perceptualLightness, rgb, red, green, blue
}

public enum PhotoHistogramLayout: String, Codable, CaseIterable, Sendable {
    case separated, overlay, difference
}

public enum PhotoPreviewChannel: String, Codable, CaseIterable, Sendable {
    case original, red, green, blue
}

/// Inclusive histogram bins. RGB overview brushes must name one concrete channel.
public struct PhotoHistogramRange: Equatable, Sendable {
    public let channel: PhotoHistogramChannel
    public let lowerBin: Int
    public let upperBin: Int
    public var isValid: Bool { channel != .rgb }
    public init(channel: PhotoHistogramChannel, lowerBin: Int, upperBin: Int) {
        self.channel = channel
        self.lowerBin = max(0, min(255, min(lowerBin, upperBin)))
        self.upperBin = max(0, min(255, max(lowerBin, upperBin)))
    }
}

public struct PhotoWorkspaceState: Codable, Equatable, Sendable {
    public var leftRegion: PhotoRegion = .full
    public var rightRegion: PhotoRegion = .full
    public var linkedRegions = false
    public var regions: [PhotoRegionPair] = []
    public var leftXMPPath: String?
    public var rightXMPPath: String?
    public var histogramChannel: PhotoHistogramChannel = .perceptualLightness
    public var histogramLayout: PhotoHistogramLayout = .separated
    public var previewChannel: PhotoPreviewChannel = .original
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case leftRegion, rightRegion, linkedRegions, regions, leftXMPPath, rightXMPPath
        case histogramChannel, histogramLayout, previewChannel
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        leftRegion = try values.decode(PhotoRegion.self, forKey: .leftRegion)
        rightRegion = try values.decode(PhotoRegion.self, forKey: .rightRegion)
        linkedRegions = try values.decode(Bool.self, forKey: .linkedRegions)
        regions = try values.decode([PhotoRegionPair].self, forKey: .regions)
        leftXMPPath = try values.decodeIfPresent(String.self, forKey: .leftXMPPath)
        rightXMPPath = try values.decodeIfPresent(String.self, forKey: .rightXMPPath)
        histogramChannel = try values.decodeIfPresent(PhotoHistogramChannel.self, forKey: .histogramChannel) ?? .perceptualLightness
        histogramLayout = try values.decodeIfPresent(PhotoHistogramLayout.self, forKey: .histogramLayout) ?? .separated
        previewChannel = try values.decodeIfPresent(PhotoPreviewChannel.self, forKey: .previewChannel) ?? .original
    }
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
    /// CIE Lab L* in 256 bins spanning 0...100; distinct from legacy HSL L.
    public let perceptualLightness: [Double]
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
                sampleWidth: Int, sampleHeight: Int, sampled: Bool, analysisSpace: String,
                perceptualLightness: [Double] = []) {
        self.red = red; self.green = green; self.blue = blue; self.lightness = lightness
        self.hue = hue; self.saturation = saturation; self.neutralFraction = neutralFraction
        self.analyzedPixels = analyzedPixels; self.sampleWidth = sampleWidth; self.sampleHeight = sampleHeight
        self.sampled = sampled; self.analysisSpace = analysisSpace
        self.perceptualLightness = perceptualLightness
    }
    /// The overview has no single distribution; callers render its R/G/B separately.
    public func values(for channel: PhotoHistogramChannel) -> [Double] {
        switch channel {
        case .perceptualLightness: return perceptualLightness
        case .rgb: return []
        case .red: return red
        case .green: return green
        case .blue: return blue
        }
    }

    /// Histogram estimate in 0...1 (multiply by 100 for L*). Endpoint bins stay 0/1.
    public func percentile(_ fraction: Double, channel: PhotoHistogramChannel) -> Double? {
        guard fraction.isFinite, (0...1).contains(fraction),
              let distribution = validDistribution(for: channel) else { return nil }
        let total = distribution.reduce(0, +)
        let target = fraction * total
        var cumulative = 0.0
        for (index, value) in distribution.enumerated() where value > 0 {
            cumulative += value
            if cumulative >= target { return Double(index) / 255 }
        }
        return distribution.lastIndex(where: { $0 > 0 }).map { Double($0) / 255 }
    }

    public func fraction(in range: PhotoHistogramRange) -> Double {
        guard range.isValid, let distribution = validDistribution(for: range.channel) else { return 0 }
        return min(1, max(0, distribution[range.lowerBin...range.upperBin].reduce(0, +)))
    }

    private func validDistribution(for channel: PhotoHistogramChannel) -> [Double]? {
        let distribution = values(for: channel)
        guard analyzedPixels > 0, distribution.count == 256,
              distribution.allSatisfy({ $0.isFinite && $0 >= 0 }),
              distribution.reduce(0, +).isFinite, distribution.reduce(0, +) > 0 else { return nil }
        return distribution
    }

    private enum CodingKeys: String, CodingKey {
        case red, green, blue, lightness, perceptualLightness, hue, saturation, neutralFraction
        case analyzedPixels, sampleWidth, sampleHeight, sampled, analysisSpace
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        red = try values.decode([Double].self, forKey: .red)
        green = try values.decode([Double].self, forKey: .green)
        blue = try values.decode([Double].self, forKey: .blue)
        lightness = try values.decode([Double].self, forKey: .lightness)
        perceptualLightness = try values.decodeIfPresent([Double].self, forKey: .perceptualLightness) ?? []
        hue = try values.decode([Double].self, forKey: .hue)
        saturation = try values.decode([Double].self, forKey: .saturation)
        neutralFraction = try values.decode(Double.self, forKey: .neutralFraction)
        analyzedPixels = try values.decode(Int.self, forKey: .analyzedPixels)
        sampleWidth = try values.decode(Int.self, forKey: .sampleWidth)
        sampleHeight = try values.decode(Int.self, forKey: .sampleHeight)
        sampled = try values.decode(Bool.self, forKey: .sampled)
        analysisSpace = try values.decode(String.self, forKey: .analysisSpace)
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
