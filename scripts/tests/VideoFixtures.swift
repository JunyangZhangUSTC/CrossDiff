import AVFoundation
import CoreGraphics
import Foundation

/// Deterministic, locally generated media with explicit source PTS truth. No
/// user's files, microphone, screen capture, or network input are used.
enum VideoFixtures {
    static let variableTimes: [CMTime] = [0, 40, 140, 180, 450, 500, 820].map { CMTime(value: $0, timescale: 1_000) }

    static func write(to url: URL, times: [CMTime], end: CMTime, rotated: Bool = false,
                      colorTagged: Bool = true, codec: AVVideoCodecType = .h264) async throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = 60_000
        var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: 320, AVVideoHeightKey: 180]
        if codec == .h264 || codec == .hevc {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 1_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30, AVVideoAllowFrameReorderingKey: true]
        }
        if colorTagged {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 60_000
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw FixtureError.writer("Cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.writer("Cannot start writer") }
        writer.startSession(atSourceTime: .zero)
        for (index, time) in times.enumerated() {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? FixtureError.writer("Encoding failed") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { throw FixtureError.writer("Cannot create pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<180 { for x in 0..<320 {
                    let offset = y * stride + x * 4
                    bytes[offset] = UInt8(30 + index * 13 % 180)
                    bytes[offset + 1] = UInt8(50 + (x / 40) * 16)
                    bytes[offset + 2] = UInt8(30 + index * 29 % 180)
                    bytes[offset + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? FixtureError.writer("Cannot append frame") }
        }
        writer.endSession(atSourceTime: end)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.writer("Cannot finish writer") }
    }

    static func edit(to url: URL, source: VideoSource, ranges: [(CMTimeRange, CMTime)]) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let movie = try AVMutableMovie(settingsFrom: nil, options: nil)
        movie.defaultMediaDataStorage = AVMediaDataStorage(url: url, options: nil)
        for (range, target) in ranges {
            try movie.insertTimeRange(range, of: source.asset, at: target, copySampleData: true)
        }
        try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
    }

    enum FixtureError: Error { case writer(String) }
}
