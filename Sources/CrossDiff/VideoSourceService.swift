import AVFoundation
import CoreGraphics
import Foundation
import CrossDiffCore

struct VideoSourceRevision: Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let fileNumber: UInt64
}

struct VideoMetadata: Sendable {
    let duration: CMTime
    let timeRange: CMTimeRange
    let displaySize: CGSize
    let nominalFrameRate: Float
    let hasAudio: Bool
    let codec: String
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let isHDR: Bool
    let supportsSDRInspection: Bool
    let canStepPrecisely: Bool
}

/// An immutable identity for the file and its selected video track. AVFoundation
/// objects stay read-only; each image request owns a separate generator/cursor.
struct VideoSource: @unchecked Sendable {
    let id: UUID
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let metadata: VideoMetadata
    let revision: VideoSourceRevision
    fileprivate let sampleMappings: [CMTimeMapping]
}

struct VideoFrame: @unchecked Sendable {
    let image: CGImage
    let requestedTime: CMTime
    let actualTime: CMTime
    let sourceID: UUID
}

enum VideoSourceError: LocalizedError {
    case localFileRequired, unreadableFile, noVideo, multipleVideoTracks, unsupported, protectedContent
    case invalidTiming, sourceChanged, unavailableSampleIndex, outsideVideoRange
    case unverifiedFrameTime, decodeFailed

    var errorDescription: String? {
        switch self {
        case .localFileRequired: return L("只能打开本机的视频文件。", "Only local video files can be opened.")
        case .unreadableFile: return L("无法读取这个视频文件。", "This video file cannot be read.")
        case .noVideo: return L("文件中没有视频画面轨道。", "The file has no video track.")
        case .multipleVideoTracks: return L("此文件含多个视频轨道，首版请先选择单一画面轨道的文件。", "This file contains multiple video tracks. Please use a single-video-track file in this preview.")
        case .unsupported: return L("系统无法播放或解码这个视频，也可能包含不允许的外部媒体引用。", "The system cannot play or decode this video. External media references are also prohibited.")
        case .protectedContent: return L("不支持受保护的视频。", "Protected videos are not supported.")
        case .invalidTiming: return L("视频没有有效的有限时间范围。", "The video does not have a valid finite time range.")
        case .sourceChanged: return L("源视频已在外部改变，请重新打开。", "The source video changed outside CrossDiff. Please reopen it.")
        case .unavailableSampleIndex: return L("此视频不提供精确帧索引，仍可播放，但无法逐帧检视。", "This video has no precise sample index. Playback is available, but exact frame inspection is not.")
        case .outsideVideoRange: return L("此时间没有视频画面。", "There is no video frame at this time.")
        case .unverifiedFrameTime: return L("无法确认取出画面的真实时间，已停止精确比较。", "The extracted frame time could not be verified. Exact comparison has stopped.")
        case .decodeFailed: return L("无法解码这个位置的画面。", "The frame at this position could not be decoded.")
        }
    }
}

/// Local, read-only, bounded decoding. No whole-film index, pixel cache, or
/// transcode is created. Unsupported timing/color remains an explicit capability.
enum VideoSourceService {
    static func load(url: URL) async throws -> VideoSource {
        try Task.checkCancellation()
        guard url.isFileURL else { throw VideoSourceError.localFileRequired }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let revision = try revision(url: resolved)
        let asset = AVURLAsset(url: resolved, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        let duration = try await asset.load(.duration)
        let protected = try await asset.load(.hasProtectedContent)
        guard !protected else { throw VideoSourceError.protectedContent }
        guard try await asset.load(.isPlayable) else { throw VideoSourceError.unsupported }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { throw VideoSourceError.noVideo }
        guard videoTracks.count == 1 else { throw VideoSourceError.multipleVideoTracks }
        guard try await track.load(.isDecodable) else { throw VideoSourceError.unsupported }
        let trackRange = try await track.load(.timeRange)
        let segments = try await track.load(.segments)
        var mappings: [CMTimeMapping] = []
        for segment in segments where !segment.isEmpty {
            let mapping = segment.timeMapping
            guard valid(mapping.source.start), valid(mapping.source.duration), mapping.source.duration > .zero,
                  valid(mapping.target.start), valid(mapping.target.duration), mapping.target.duration > .zero else { continue }
            mappings.append(mapping)
        }
        mappings.sort { $0.target.start < $1.target.start }
        // Empty edits may precede the first real frame. Keep the original asset
        // timeline, but start inspection at actual video rather than an empty edit.
        let range: CMTimeRange
        if let first = mappings.first, let last = mappings.last {
            range = CMTimeRange(start: first.target.start, end: last.target.end)
        } else {
            range = trackRange
        }
        guard valid(duration), duration > .zero, valid(range.start), valid(range.duration), range.duration > .zero else {
            throw VideoSourceError.invalidTiming
        }
        let transform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let formats = try await track.load(.formatDescriptions)
        let frameRate = try await track.load(.nominalFrameRate)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let precise = try await asset.load(.providesPreciseDurationAndTiming)
        let hasCursors = try await track.load(.canProvideSampleCursors)
        let format = formats.first
        let size = format.map { CMVideoFormatDescriptionGetPresentationDimensions($0, usePixelAspectRatio: true, useCleanAperture: true) } ?? naturalSize
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw VideoSourceError.unsupported }
        let descriptions: [NSDictionary] = formats.map { (CMFormatDescriptionGetExtensions($0) as NSDictionary?) ?? NSDictionary() }
        let primary = descriptions.first?[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        let transfer = descriptions.first?[kCMFormatDescriptionExtension_TransferFunction] as? String
        let matrix = descriptions.first?[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
        let hdr = descriptions.contains { description in
            let value = description[kCMFormatDescriptionExtension_TransferFunction] as? String
            return value == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) || value == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        }
        // Conservative M1 analysis contract: only explicitly tagged Rec.709 SDR
        // throughout the track. Missing or changing tags never imply sRGB.
        let verifiedSDR = !descriptions.isEmpty && descriptions.allSatisfy {
            ($0[kCMFormatDescriptionExtension_ColorPrimaries] as? String) == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String) &&
            ($0[kCMFormatDescriptionExtension_TransferFunction] as? String) == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String) &&
            ($0[kCMFormatDescriptionExtension_YCbCrMatrix] as? String) == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        }
        let source = VideoSource(id: UUID(), url: resolved, asset: asset, track: track, metadata: VideoMetadata(
            duration: duration, timeRange: range, displaySize: CGSize(width: bounds.width, height: bounds.height),
            nominalFrameRate: frameRate, hasAudio: !audio.isEmpty,
            codec: format.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "—",
            colorPrimaries: primary, transferFunction: transfer, yCbCrMatrix: matrix,
            isHDR: hdr, supportsSDRInspection: verifiedSDR, canStepPrecisely: precise && hasCursors && !mappings.isEmpty), revision: revision, sampleMappings: mappings)
        try Task.checkCancellation()
        try validate(source: source)
        return source
    }

    static func validate(source: VideoSource) throws {
        guard try revision(url: source.url) == source.revision else { throw VideoSourceError.sourceChanged }
    }

    /// Select the actual sample covering the requested source time. Never use
    /// nominalFrameRate for positioning (in particular for VFR and B-frames).
    static func sampleTime(source: VideoSource, at requested: CMTime) throws -> CMTime {
        try Task.checkCancellation()
        try validate(source: source)
        guard source.metadata.canStepPrecisely else { throw VideoSourceError.unavailableSampleIndex }
        guard valid(requested), let mapping = source.sampleMappings.first(where: { CMTimeRangeContainsTime($0.target, time: requested) }) else {
            throw VideoSourceError.outsideVideoRange
        }
        let mediaTime = CMTimeMapTimeFromRangeToRange(requested, fromRange: mapping.target, toRange: mapping.source)
        guard let cursor = source.track.makeSampleCursor(presentationTimeStamp: mediaTime) else { throw VideoSourceError.unavailableSampleIndex }
        let sample = cursor.presentationTimeStamp
        guard valid(sample), sample <= mediaTime else { throw VideoSourceError.outsideVideoRange }
        // Cursor currentSampleDuration is a decode duration, not a reliable
        // presentation interval for reordered VFR. The segment rejects empty
        // edits; the precise generator subsequently verifies this sample PTS.
        let assetTime = CMTimeMapTimeFromRangeToRange(sample, fromRange: mapping.source, toRange: mapping.target)
        // An edit may begin part-way through a sample; its visible start is then
        // the edit boundary, not a fabricated negative or pre-edit timestamp.
        return max(mapping.target.start, assetTime)
    }

    static func adjacentSampleTime(source: VideoSource, from time: CMTime, direction: Int) async throws -> CMTime? {
        try Task.checkCancellation()
        let current = try sampleTime(source: source, at: time)
        guard let index = source.sampleMappings.firstIndex(where: { CMTimeRangeContainsTime($0.target, time: current) }) else { throw VideoSourceError.outsideVideoRange }
        let mapping = source.sampleMappings[index]
        let mediaTime = CMTimeMapTimeFromRangeToRange(current, fromRange: mapping.target, toRange: mapping.source)
        guard let cursor = source.track.makeSampleCursor(presentationTimeStamp: mediaTime) else { throw VideoSourceError.unavailableSampleIndex }
        let currentSample = cursor.presentationTimeStamp
        let step: Int64 = direction >= 0 ? 1 : -1
        for _ in 0..<256 {
            if cursor.stepInPresentationOrder(byCount: step) != step { break }
            let next = cursor.presentationTimeStamp
            if (step > 0 && next > currentSample) || (step < 0 && next < currentSample) {
                guard CMTimeRangeContainsTime(mapping.source, time: next) else { break }
                try Task.checkCancellation()
                try validate(source: source)
                return CMTimeMapTimeFromRangeToRange(next, fromRange: mapping.source, toRange: mapping.target)
            }
        }
        // Step across edits in presentation order, skipping real empty intervals.
        let nextIndex = index + (step > 0 ? 1 : -1)
        guard source.sampleMappings.indices.contains(nextIndex) else { return nil }
        let neighbor = source.sampleMappings[nextIndex].target
        if step > 0 { return try sampleTime(source: source, at: neighbor.start) }
        let tick = CMTime(value: 1, timescale: max(neighbor.start.timescale, neighbor.duration.timescale))
        return try sampleTime(source: source, at: max(neighbor.start, neighbor.end - tick))
    }

    static func frame(source: VideoSource, at requested: CMTime, maxDimension: Int = 1600) async throws -> VideoFrame {
        let sample = try sampleTime(source: source, at: requested)
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .cleanAperture
        let dimension = min(2048, max(64, maxDimension))
        generator.maximumSize = CGSize(width: dimension, height: dimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await withTaskCancellationHandler(operation: {
            try await generator.image(at: sample)
        }, onCancel: { generator.cancelAllCGImageGeneration() })
        try Task.checkCancellation()
        try validate(source: source)
        guard valid(result.actualTime), CMTimeCompare(sample, result.actualTime) == 0 else { throw VideoSourceError.unverifiedFrameTime }
        return VideoFrame(image: result.image, requestedTime: requested, actualTime: result.actualTime, sourceID: source.id)
    }

    /// At most sixteen <=160px images; thumbnail colors are browsing previews,
    /// not measurement data. Frames are generated serially to bound decode work.
    static func thumbnails(source: VideoSource, count: Int = 10) async throws -> [VideoFrame] {
        let count = min(16, max(1, count))
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .cleanAperture
        generator.maximumSize = CGSize(width: 160, height: 160)
        var frames: [VideoFrame] = []
        return try await withTaskCancellationHandler(operation: {
            for index in 0..<count {
                try Task.checkCancellation()
                try validate(source: source)
                let requested = source.metadata.timeRange.start + CMTimeMultiplyByFloat64(source.metadata.timeRange.duration, multiplier: (Double(index) + 0.5) / Double(count))
                guard source.sampleMappings.contains(where: { CMTimeRangeContainsTime($0.target, time: requested) }) else { continue }
                let result = try await generator.image(at: requested)
                try Task.checkCancellation()
                guard valid(result.actualTime) else { throw VideoSourceError.decodeFailed }
                frames.append(VideoFrame(image: result.image, requestedTime: requested, actualTime: result.actualTime, sourceID: source.id))
            }
            try validate(source: source)
            return frames
        }, onCancel: { generator.cancelAllCGImageGeneration() })
    }

    private static func revision(url: URL) throws -> VideoSourceRevision {
        guard url.isFileURL else { throw VideoSourceError.localFileRequired }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let number = attributes[.systemFileNumber] as? NSNumber else { throw VideoSourceError.unreadableFile }
        return VideoSourceRevision(size: size.uint64Value, modified: modified, fileNumber: number.uint64Value)
    }

    private static func valid(_ time: CMTime) -> Bool { time.isValid && !time.isIndefinite && time.seconds.isFinite }
    private static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "—"
    }
}
