import Foundation
import AVFoundation
import CrossDiffCore

@main
struct AudioEngineChecks {
    static var assertions = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: "AudioEngineChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        assertions += 1
    }
    static func near(_ value: Double, _ expected: Double, _ tolerance: Double, _ message: String) throws {
        try check(abs(value - expected) <= tolerance, "\(message): got \(value), expected \(expected)")
    }
    static func write(_ url: URL, seconds: Double = 0.5, sampleRate: Double = 48000, channels: Int = 2,
                      sample: (Int, Int) -> Float) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: url.pathExtension == "aiff"]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels { for frame in 0..<frames { buffer.floatChannelData![channel][frame] = sample(frame, channel) } }
        try file.write(from: buffer)
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tone = directory.appendingPathComponent("tone.wav"), anti = directory.appendingPathComponent("antiphase.wav")
        let aiff = directory.appendingPathComponent("tone.aiff"), silence = directory.appendingPathComponent("silence.wav")
        let dc = directory.appendingPathComponent("dc.wav"), nyquist = directory.appendingPathComponent("nyquist.wav")
        let signal: (Int, Int) -> Float = { frame, _ in Float(0.5 * sin(2 * .pi * 1500 * Double(frame) / 48000)) }
        try write(tone, sample: signal)
        try write(anti) { frame, channel in signal(frame, channel) * (channel == 0 ? 1 : -1) }
        try write(aiff, sample: signal)
        try write(silence) { _, _ in 0 }
        try write(dc) { _, _ in 0.25 }
        try write(nyquist) { frame, _ in frame % 2 == 0 ? 0.25 : -0.25 }
        let original = try Data(contentsOf: tone)
        let source = try AudioAnalysisEngine.load(tone)
        try near(source.duration, 0.5, 0.00001, "source duration")
        try check(source.channelCount == 2 && source.sampleRate == 48000, "source channel/sample-rate metadata")
        try check(source.metadata.isValid, "valid source metadata")
        try check(source.waveform.count == 2 && source.waveform[0].count <= 8192, "bounded per-channel waveform")
        try near(Double(source.waveform[0].map(\.maximum).max()!), 0.5, 0.0001, "waveform peak")
        try check(source.waveform[0].allSatisfy { $0.minimum <= $0.maximum && $0.rms.isFinite }, "waveform finite and ordered")
        let decodedAIFF = try AudioAnalysisEngine.load(aiff)
        try check(decodedAIFF.duration == source.duration && decodedAIFF.channelCount == source.channelCount, "AIFF decoder")
        let spectrum = try AudioAnalysisEngine.analyze(source: source, region: nil, settings: .init())
        try check(spectrum.bins == 1025 && spectrum.columns > 0, "real STFT dimensions")
        try check(spectrum.decibels.count == spectrum.columns * spectrum.bins, "spectrogram layout")
        try check(spectrum.decibels.allSatisfy(\.isFinite), "spectrogram finite")
        let peakBin = spectrum.averageDecibels.enumerated().max { $0.element < $1.element }!.offset
        try check(peakBin == 64, "1500 Hz tone FFT bin")
        try near(Double(spectrum.averageDecibels[64]), -6.0206, 0.08, "Hann coherent amplitude calibration")
        try near(spectrum.peakDBFS, -6.0206, 0.005, "sample peak dBFS")
        try near(spectrum.rmsDBFS, -9.0309, 0.005, "RMS dBFS")
        let reversed = try AudioAnalysisEngine.analyze(source: AudioAnalysisEngine.load(anti), region: nil, settings: .init())
        try near(Double(reversed.averageDecibels[64]), Double(spectrum.averageDecibels[64]), 0.005, "antiphase stereo power survives")
        let silent = try AudioAnalysisEngine.analyze(source: AudioAnalysisEngine.load(silence), region: nil, settings: .init())
        try check(silent.decibels.allSatisfy { $0 == -160 }, "silence has finite display floor")
        let constant = try AudioAnalysisEngine.analyze(source: AudioAnalysisEngine.load(dc), region: nil, settings: .init())
        try near(Double(constant.averageDecibels[0]), -12.0412, 0.08, "DC is not doubled")
        let last = try AudioAnalysisEngine.analyze(source: AudioAnalysisEngine.load(nyquist), region: nil, settings: .init())
        try near(Double(last.averageDecibels[1024]), -12.0412, 0.08, "Nyquist is not doubled")
        let selected = try AudioAnalysisEngine.analyze(source: source, region: .init(start: 0.2, end: 0.35), settings: .init())
        try check(selected.analyzedRegion == AudioRegion(start: 0.2, end: 0.35), "exact selected source range")
        let short = try AudioAnalysisEngine.analyze(source: source, region: .init(start: 0.2, end: 0.201), settings: .init())
        try check(short.columns == 1 && short.decibels.allSatisfy(\.isFinite), "short frame zero padding")
        let highResolution = try AudioAnalysisEngine.analyze(source: source, region: nil, settings: .init(fftSize: 4096, hopSize: 1024))
        try near(Double(highResolution.averageDecibels[128]), -6.0206, 0.15, "FFT-size invariant calibration")
        let fineHop = try AudioAnalysisEngine.analyze(source: source, region: nil, settings: .init(fftSize: 256, hopSize: 1))
        try check(fineHop.isPartial && fineHop.analyzedRegion.end < source.duration, "computation budget declared partial")
        try check(fineHop.decibels.count <= 2_010_000, "display storage budget")
        try check(fineHop.hopSize == 1, "display bucketing does not rewrite the actual FFT hop")
        try check(spectrum.columnRegions.count == spectrum.columns && spectrum.columnCenters.count == spectrum.columns, "spectrogram source-time geometry")
        try near(spectrum.columnCenters[0], 1024.0 / 48000, 1e-8, "first full-window center")
        try check(spectrum.columnRegions[0].start > spectrum.region.start, "no stretching the first frame into unanalyzed center times")
        try check(spectrum.columnRegions.allSatisfy { $0.validated(duration: source.duration) }, "column ranges stay within original source")
        try check(short.columnRegions == [short.region] && short.columnCenters[0] >= short.region.start && short.columnCenters[0] <= short.region.end, "zero-padded short-window location")
        let impulse = directory.appendingPathComponent("transient.wav")
        try write(impulse, seconds: 12) { frame, channel in frame == 1152 ? (channel == 0 ? 0.5 : -0.5) : 0 }
        let transient = try AudioAnalysisEngine.analyze(source: AudioAnalysisEngine.load(impulse), region: nil,
                                                      settings: .init(fftSize: 2048, hopSize: 128))
        try check(transient.columns < 4400, "transient fixture exercises temporal display reduction")
        try near(Double(transient.decibels[64]), -60.206, 0.05, "time bucket preserves the strongest omitted-between-steps impulse frame")
        try check(transient.hopSize == 128, "true hop retained after peak aggregation")
        try check(zip(transient.columnRegions, transient.columnRegions.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-8 }, "adjacent display time buckets are contiguous")
        let export = directory.appendingPathComponent("antiphase.f32")
        try? FileManager.default.removeItem(at: export)
        try AudioAnalysisEngine.exportMonoPCM(url: anti, output: export)
        let bytes = try Data(contentsOf: export)
        try near(Double(bytes.count / 4), 8000, 2, "stream resampler output duration")
        let energy = bytes.withUnsafeBytes { raw -> Double in
            let values = raw.bindMemory(to: Float.self)
            return values.reduce(0) { $0 + Double($1 * $1) } / Double(values.count)
        }
        try check(energy > 0.1, "matching selected channel avoids antiphase cancellation")
        do { try AudioAnalysisEngine.exportMonoPCM(url: anti, output: export); throw NSError(domain: "overwrite", code: 1) }
        catch AudioEngineError.invalidFile { assertions += 1 }
        let samples = try AudioAnalysisEngine.readMono(url: tone, start: 0.25, duration: 0.1, sampleRate: 16000)
        try near(Double(samples.count), 1600, 2, "resampled selected-region length")
        do { _ = try AudioAnalysisEngine.analyze(source: source, region: .init(start: -1, end: 1), settings: .init()); throw NSError(domain: "region", code: 1) }
        catch AudioEngineError.invalidRegion { assertions += 1 }
        let cancel = Task.detached { try Task.checkCancellation(); return try AudioAnalysisEngine.load(tone) }
        cancel.cancel()
        do { _ = try await cancel.value; throw NSError(domain: "cancel", code: 1) }
        catch is CancellationError { assertions += 1 }
        try check(try Data(contentsOf: tone) == original, "analysis preserves source bytes")
        let symlink = directory.appendingPathComponent("link.wav")
        try? FileManager.default.removeItem(at: symlink)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: tone)
        do { _ = try AudioAnalysisEngine.load(symlink); throw NSError(domain: "symlink", code: 1) }
        catch AudioEngineError.invalidFile { assertions += 1 }
        let old = source.revision
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: tone.path)
        try check(try AudioAnalysisEngine.revision(tone) != old, "source revision detects external change")
        do { try AudioAnalysisEngine.validate(source); throw NSError(domain: "changed", code: 1) }
        catch AudioEngineError.changed { assertions += 1 }
        print("Audio engine checks passed: \(assertions) assertions. WAV/AIFF, calibrated FFT, antiphase channels, bounded selections, resampling, cancellation and source preservation.")
    }
}
