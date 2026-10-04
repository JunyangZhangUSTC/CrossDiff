import Foundation

public enum VideoSide: String, Codable, Sendable { case left, right }
public enum VideoDisplayMode: String, Codable, CaseIterable, Sendable { case sideBySide, wipe, difference }
public enum VideoAudioSide: String, Codable, CaseIterable, Sendable { case left, right, muted }

/// Normalized, top-left-origin rectangle. Stored without source pixels.
public struct VideoROI: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000001 && y + height <= 1.000001
    }
}

public struct VideoSavedRegion: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var left: VideoROI?, right: VideoROI?
    public init(id: UUID = UUID(), name: String, left: VideoROI?, right: VideoROI?) {
        self.id = id; self.name = name; self.left = left; self.right = right
    }
    public var isValid: Bool { !name.isEmpty && name.utf8.count <= 256 && (left?.isValid ?? true) && (right?.isValid ?? true) }
}

/// Only reversible viewing choices persist. Decoded frames, playback and claimed
/// content correspondence never enter a session record.
public struct VideoWorkspaceState: Codable, Equatable, Sendable {
    public var isLinked = true
    public var offsetSeconds: Double = 0
    public var alignmentLeft: VideoTime?, alignmentRight: VideoTime?
    public var referenceSide: VideoSide = .left
    public var displayMode: VideoDisplayMode = .sideBySide
    public var audioSide: VideoAudioSide = .muted
    public var wipeFraction: Double = 0.5
    public var loopEnabled = false
    public var loopStart: Double = 0
    public var loopEnd: Double = 0
    public var leftTime = VideoTime(value: 0, timescale: 600)
    public var rightTime = VideoTime(value: 0, timescale: 600)
    public var leftROI: VideoROI?, rightROI: VideoROI?
    public var regionLinked = false
    public var savedRegions: [VideoSavedRegion] = []
    public init() {}
    public var isValid: Bool {
        offsetSeconds.isFinite && abs(offsetSeconds) <= VideoContract.maximumDuration
            && ((alignmentLeft == nil && alignmentRight == nil) || (alignmentLeft?.isValid == true && alignmentRight?.isValid == true
                && alignmentLeft!.seconds <= VideoContract.maximumDuration && alignmentRight!.seconds <= VideoContract.maximumDuration
                && abs((alignmentRight!.seconds - alignmentLeft!.seconds) - offsetSeconds) < 0.000001))
            && wipeFraction.isFinite && (0...1).contains(wipeFraction)
            && loopStart.isFinite && loopEnd.isFinite && loopStart >= 0 && loopEnd >= loopStart
            && loopEnd <= VideoContract.maximumDuration && (!loopEnabled || (isLinked && loopEnd > loopStart))
            && leftTime.isValid && rightTime.isValid
            && leftTime.seconds <= VideoContract.maximumDuration && rightTime.seconds <= VideoContract.maximumDuration
            && (leftROI?.isValid ?? true) && (rightROI?.isValid ?? true)
            && savedRegions.count <= 32 && savedRegions.allSatisfy(\.isValid)
            && Set(savedRegions.map(\.id)).count == savedRegions.count
    }
    /// Half-open linked interval in the left source's time coordinates.
    public func overlap(leftStart: Double, leftEnd: Double, rightStart: Double, rightEnd: Double) -> Range<Double>? {
        let start = max(leftStart, rightStart - offsetSeconds), end = min(leftEnd, rightEnd - offsetSeconds)
        return start.isFinite && end.isFinite && end > start ? start..<end : nil
    }
}
