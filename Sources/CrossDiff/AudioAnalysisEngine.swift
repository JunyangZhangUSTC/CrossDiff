import Foundation
import AVFoundation
import Accelerate
import CrossDiffCore
import Darwin

struct AudioWaveformBin: Sendable {
    let minimum: Float
    let maximum: Float
    let rms: Float
}

struct AudioSourceRevision: Equatable, Sendable {
    let device: UInt64, inode: UInt64, bytes: Int64, seconds: Int64, nanoseconds: Int64
}

struct AudioDecodedSource: Sendable {
    let url: URL
    let metadata: AudioSourceMetadata
    let waveform: [[AudioWaveformBin]]
    let revision: AudioSourceRevision
    var duration: Double { metadata.duration }
    var sampleRate: Double { metadata.sampleRate }
    var channelCount: Int { metadata.channelCount }
}

struct AudioSpectrumAnalysis: Sendable {
    let id = UUID()
    let analyzedRegion: AudioRegion
    let sampleRate: Double
    let fftSize: Int
    let hopSize: Int
    let columns: Int
    let bins: Int
    /// Time-major, calibrated one-sided amplitude in dBFS; each display bucket keeps
    /// the maximum frame power after averaging source channels, preserving transients.
    let decibels: [Float]
    /// Exact display supports around the effective sample-window centers. They need
    /// not cover edges where no complete centered analysis window is available.
    let columnRegions: [AudioRegion]
    let columnCenters: [Double]
    /// Power-mean of the same amplitude-calibrated spectrum, then converted to dB.
    let averageDecibels: [Float]
    let peakDBFS: Double
    let rmsDBFS: Double
    let isPartial: Bool
    let sourceNyquist: Double
    var region: AudioRegion { analyzedRegion }
    var frameCount: Int { columns }
    var binCount: Int { bins }
}

enum AudioEngineError: LocalizedError {
    case invalidFile, budget, decode, changed, invalidRegion, invalidSettings, noSamples
    var errorDescription: String? {
        switch self {
        case .invalidFile: return L("请选择本地常规音频文件。", "Choose a local regular audio file.")
        case .budget: return L("音频分析支持最多 2 GiB、2 小时和 8 声道的文件。", "Audio analysis supports files up to 2 GiB, 2 hours and 8 channels.")
        case .decode: return L("当前 macOS 无法解码此音频，或文件已损坏。", "This audio is damaged or cannot be decoded by this macOS version.")
        case .changed: return L("音频文件已发生变化，请重新载入。", "The audio file changed. Reload it before continuing.")
        case .invalidRegion: return L("请选择音频范围内的有效片段。", "Select a valid region within the audio.")
        case .invalidSettings: return L("音频分析参数无效。", "The audio analysis settings are invalid.")
        case .noSamples: return L("此音频没有可分析的采样。", "This audio contains no samples to analyze.")
        }
    }
}

/// All decoding is bounded and read-only. Waveform envelopes are never FFT input.
enum AudioAnalysisEngine {
    static let analysisSampleRate = 48_000.0
    static let maximumAnalysisSeconds = 30.0
    static let maximumWaveformBins = 8192

    static func revision(_ url: URL) throws -> AudioSourceRevision {
        guard url.isFileURL else { throw AudioEngineError.invalidFile }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0 else { throw AudioEngineError.invalidFile }
        guard info.st_size <= 2 * 1024 * 1024 * 1024 else { throw AudioEngineError.budget }
        return AudioSourceRevision(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), bytes: info.st_size,
                                   seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    static func validate(_ source: AudioDecodedSource) throws {
        guard try revision(source.url) == source.revision else { throw AudioEngineError.changed }
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        _ = try revision(url)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw AudioEngineError.decode }
        let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
        guard file.length > 0 else { throw AudioEngineError.noSamples }
        guard rate.isFinite, (8_000...384_000).contains(rate), (1...8).contains(channels),
              Double(file.length) / rate <= 7200 else { throw AudioEngineError.budget }
        return file
    }

    static func load(_ url: URL) throws -> AudioDecodedSource {
        try Task.checkCancellation()
        let version = try revision(url), file = try open(url)
        let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
        let frames = file.length
        let bucketFrames = max(1, Int64(ceil(Double(frames) / Double(maximumWaveformBins))))
        let count = Int((frames + bucketFrames - 1) / bucketFrames)
        var minima = Array(repeating: Array(repeating: Float.infinity, count: count), count: channels)
        var maxima = Array(repeating: Array(repeating: -Float.infinity, count: count), count: channels)
        var energies = Array(repeating: Array(repeating: Double(0), count: count), count: channels)
        var counts = Array(repeating: Int64(0), count: count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768) else { throw AudioEngineError.decode }
        while file.framePosition < frames {
            try Task.checkCancellation()
            let position = file.framePosition
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(32768, frames - position))) }
            catch { throw AudioEngineError.decode }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { throw AudioEngineError.decode }
            var offset = 0
            while offset < Int(buffer.frameLength) {
                let absolute = position + Int64(offset), bucket = Int(absolute / bucketFrames)
                let size = min(Int(buffer.frameLength) - offset, Int(bucketFrames - absolute % bucketFrames))
                counts[bucket] += Int64(size)
                for channel in 0..<channels {
                    let values = UnsafeBufferPointer(start: data[channel] + offset, count: size)
                    guard values.allSatisfy({ $0.isFinite }) else { throw AudioEngineError.decode }
                    minima[channel][bucket] = min(minima[channel][bucket], vDSP.minimum(values))
                    maxima[channel][bucket] = max(maxima[channel][bucket], vDSP.maximum(values))
                    let rms = vDSP.rootMeanSquare(values.map(Double.init))
                    energies[channel][bucket] += rms * rms * Double(size)
                }
                offset += size
            }
        }
        guard try revision(url) == version else { throw AudioEngineError.changed }
        let waveform = (0..<channels).map { channel in (0..<count).map { index in
            AudioWaveformBin(minimum: minima[channel][index], maximum: maxima[channel][index],
                             rms: Float(sqrt(energies[channel][index] / Double(max(1, counts[index])))))
        }}
        return AudioDecodedSource(url: url, metadata: AudioSourceMetadata(id: UUID().uuidString, name: url.lastPathComponent,
            duration: Double(frames) / rate, sampleRate: rate, channelCount: channels,
            frameCount: String(frames), format: url.pathExtension.isEmpty ? "Audio" : url.pathExtension.uppercased()), waveform: waveform, revision: version)
    }

    /// Arithmetic channel mean is an explicit matching/overview mix, not a replacement for per-channel waveforms.
    private static func streamMono(url: URL, region: AudioRegion?, sampleRate: Double, selectedChannel: Int? = nil,
                                   consume: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { throw AudioEngineError.invalidSettings }
        let version = try revision(url), file = try open(url), sourceRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / sourceRate
        let selected = region ?? AudioRegion(start: 0, end: duration)
        guard selected.start.isFinite, selected.end.isFinite, selected.start >= 0,
              selected.end > selected.start, selected.end <= duration + 0.00001 else { throw AudioEngineError.invalidRegion }
        let first = Int64((selected.start * sourceRate).rounded(.down))
        let last = min(file.length, Int64((selected.end * sourceRate).rounded(.up)))
        file.framePosition = first
        guard let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384),
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
              let destinationFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 16384),
              let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: 8192),
              let converter = AVAudioConverter(from: monoFormat, to: destinationFormat) else { throw AudioEngineError.decode }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var readFailure: Error?
        var drained = false
        while !drained {
            try Task.checkCancellation()
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { requested, inputStatus in
                do {
                    try Task.checkCancellation()
                    guard file.framePosition < last else { inputStatus.pointee = .endOfStream; return nil }
                    let amount = min(Int64(max(1, requested)), min(16384, last - file.framePosition))
                    try file.read(into: decoded, frameCount: AVAudioFrameCount(amount))
                    guard decoded.frameLength > 0, let planes = decoded.floatChannelData,
                          let target = mono.floatChannelData?[0] else { throw AudioEngineError.decode }
                    mono.frameLength = decoded.frameLength
                    let channels = Int(decoded.format.channelCount), length = Int(decoded.frameLength)
                    for i in 0..<length {
                        var sum: Double = 0
                        if let selectedChannel {
                            guard (0..<channels).contains(selectedChannel) else { throw AudioEngineError.invalidSettings }
                            sum = Double(planes[selectedChannel][i])
                        } else { for channel in 0..<channels { sum += Double(planes[channel][i]) } }
                        let value = Float(sum / Double(selectedChannel == nil ? channels : 1))
                        guard value.isFinite else { throw AudioEngineError.decode }
                        target[i] = value
                    }
                    inputStatus.pointee = .haveData
                    return mono
                } catch { readFailure = error; inputStatus.pointee = .endOfStream; return nil }
            }
            if let readFailure { throw readFailure }
            if let failure { throw failure }
            if output.frameLength > 0, let samples = output.floatChannelData?[0] {
                try consume(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            }
            switch status {
            case .endOfStream: drained = true
            case .error: throw AudioEngineError.decode
            case .haveData, .inputRanDry: break
            @unknown default: throw AudioEngineError.decode
            }
        }
        guard try revision(url) == version else { throw AudioEngineError.changed }
        try Task.checkCancellation()
    }

    static func readMono(url: URL, start: Double = 0, duration: Double? = nil, sampleRate: Double = 16_000,
                         maximumFrames: Int = 2_000_000, channel: Int? = nil) throws -> [Float] {
        let file = try open(url)
        let end = min(Double(file.length) / file.processingFormat.sampleRate, start + (duration ?? maximumAnalysisSeconds))
        guard maximumFrames > 0, maximumFrames <= 8_000_000, (end - start) * sampleRate <= Double(maximumFrames) else { throw AudioEngineError.budget }
        var samples = [Float](); samples.reserveCapacity(Int(max(0, (end - start) * sampleRate)))
        try streamMono(url: url, region: AudioRegion(start: start, end: end), sampleRate: sampleRate, selectedChannel: channel) { buffer in
            guard samples.count + buffer.count <= maximumFrames else { throw AudioEngineError.budget }
            samples.append(contentsOf: buffer)
        }
        return samples
    }

    /// Writes Float32 little-endian mono for the fixed native matching engine, never into a source file.
    static func exportMonoPCM(url: URL, output: URL, sampleRate: Double = 16_000, source knownSource: AudioDecodedSource? = nil) throws {
        guard url.standardizedFileURL != output.standardizedFileURL, !FileManager.default.fileExists(atPath: output.path),
              output.isFileURL else { throw AudioEngineError.invalidFile }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pcm-part")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AudioEngineError.invalidFile }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: temporary) } }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        // Use the highest-energy source channel for fingerprints: a stereo arithmetic
        // mean can erase antiphase recordings. This choice never changes the displayed spectra.
        let source = try knownSource ?? load(url)
        guard source.url.standardizedFileURL == url.standardizedFileURL else { throw AudioEngineError.invalidFile }
        try validate(source)
        guard let frames = Int64(source.metadata.frameCount), frames > 0 else { throw AudioEngineError.invalidFile }
        let bucketFrames = max(1, Int64(ceil(Double(frames) / Double(maximumWaveformBins))))
        let energies = source.waveform.map { channel in channel.enumerated().reduce(Double(0)) { sum, pair in
            let length = min(bucketFrames, max(0, frames - Int64(pair.offset) * bucketFrames))
            return sum + Double(pair.element.rms) * Double(pair.element.rms) * Double(length)
        }}
        let channel = energies.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        try streamMono(url: url, region: nil, sampleRate: sampleRate, selectedChannel: channel) { buffer in
            let bytes = buffer.map { $0.bitPattern.littleEndian }
            try bytes.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        }
        try validate(source)
        try handle.synchronize()
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: output)
        completed = true
    }

    static func analyze(source: AudioDecodedSource, region: AudioRegion?, settings: AudioAnalysisSettings) throws -> AudioSpectrumAnalysis {
        try validate(source)
        let selected = region ?? AudioRegion(start: 0, end: source.duration)
        guard selected.start >= 0, selected.end > selected.start, selected.end <= source.duration + 0.00001 else { throw AudioEngineError.invalidRegion }
        let n = settings.fftSize, hop = settings.hopSize
        guard settings.isValid else { throw AudioEngineError.invalidSettings }
        // Fine hops may request millions of transforms. Bound analysis work as well as storage.
        let maximumFrames = max(1, min(8192, 32_000_000 / (n * source.channelCount)))
        let windowBudget = Double(n + hop * (maximumFrames - 1)) / analysisSampleRate
        let end = min(selected.end, selected.start + min(maximumAnalysisSeconds, windowBudget))
        let actual = AudioRegion(start: selected.start, end: end)
        // Complex FFT avoids the special real-FFT packing and factor-of-two convention.
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(n))), FFTRadix(kFFTRadix2)) else { throw AudioEngineError.decode }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let gain = vDSP.sum(window), bins = n / 2 + 1
        var channels = [[Float]](), scales = [Float]()
        var peak: Float = 0, rmsPower = 0.0
        for channel in 0..<source.channelCount {
            let samples = try readMono(url: source.url, start: actual.start, duration: actual.duration,
                sampleRate: analysisSampleRate, maximumFrames: 1_500_000, channel: channel)
            guard !samples.isEmpty, channels.first.map({ $0.count == samples.count }) ?? true else { throw AudioEngineError.noSamples }
            let channelPeak = vDSP.maximumMagnitude(samples)
            peak = max(peak, channelPeak)
            let rms = vDSP.rootMeanSquare(samples.map(Double.init)); rmsPower += rms * rms
            scales.append(max(1, channelPeak)); channels.append(samples)
        }
        let sampleCount = channels[0].count
        let frameCount = max(1, 1 + max(0, sampleCount - n + hop - 1) / hop)
        let stride = max(1, Int(ceil(Double(frameCount * bins) / 2_000_000)))
        let columns = (frameCount + stride - 1) / stride
        var displayPower = [Double](repeating: 0, count: columns * bins)
        var power = [Double](repeating: 0, count: bins)
        var real = [Float](repeating: 0, count: n), imaginary = real
        var framePower = [Double](repeating: 0, count: bins)
        var centers = [Double](repeating: 0, count: columns)
        var centerCounts = [Int](repeating: 0, count: columns)
        for frame in 0..<frameCount {
            try Task.checkCancellation()
            let start = frame * hop, column = frame / stride
            for bin in 0..<bins { framePower[bin] = 0 }
            for channel in 0..<source.channelCount {
                let samples = channels[channel], fftScale = scales[channel]
                for i in 0..<n { real[i] = (start + i < samples.count ? samples[start + i] / fftScale : 0) * window[i]; imaginary[i] = 0 }
                real.withUnsafeMutableBufferPointer { re in imaginary.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
                }}
                for frequency in 0..<bins {
                    let scale: Float = frequency == 0 || frequency == n / 2 ? 1 : 2
                    let amplitude = Double(hypot(real[frequency], imaginary[frequency])) * Double(scale) * Double(fftScale) / Double(gain)
                    let energy = amplitude * amplitude / Double(source.channelCount)
                    framePower[frequency] += energy
                }
            }
            for frequency in 0..<bins {
                power[frequency] += framePower[frequency]
                displayPower[column * bins + frequency] = max(displayPower[column * bins + frequency], framePower[frequency])
            }
            // A zero-padded final/short window is located at the midpoint of its
            // actual source samples, rather than beyond the source timeline.
            centers[column] += actual.start + (Double(start) + Double(min(n, sampleCount - start)) / 2) / analysisSampleRate
            centerCounts[column] += 1
        }
        for column in 0..<columns {
            centers[column] = min(actual.end, max(actual.start, centers[column] / Double(centerCounts[column])))
        }
        let regions: [AudioRegion] = (0..<columns).map { index in
            guard columns > 1 else { return actual }
            let lower = index == 0 ? centers[0] - (centers[1] - centers[0]) / 2 : (centers[index - 1] + centers[index]) / 2
            let upper = index == columns - 1 ? centers[index] + (centers[index] - centers[index - 1]) / 2 : (centers[index] + centers[index + 1]) / 2
            return AudioRegion(start: max(actual.start, lower), end: min(actual.end, upper))
        }
        let pixels = displayPower.map { Float(max(-160, 10 * log10(max($0, 1e-16)))) }
        try validate(source)
        return AudioSpectrumAnalysis(analyzedRegion: actual, sampleRate: analysisSampleRate, fftSize: n,
            hopSize: hop, columns: columns, bins: bins, decibels: pixels, columnRegions: regions, columnCenters: centers,
            averageDecibels: power.map { max(-160, 10 * log10(max($0 / Double(frameCount), 1e-16))) }.map(Float.init),
            peakDBFS: 20 * log10(max(Double(peak), 1e-8)), rmsDBFS: 10 * log10(max(rmsPower / Double(source.channelCount), 1e-16)),
            isPartial: end < selected.end, sourceNyquist: min(source.sampleRate, analysisSampleRate) / 2)
    }
}
