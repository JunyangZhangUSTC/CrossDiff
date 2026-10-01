import Foundation
import AVFoundation
import AudioToolbox
import CrossDiffCore

/// No output-device rendering, microphone access, or live playback occurs here.
/// Both engine instances enter manual mode before their mixer/input/output is accessed.
/// The tested graph/parameter methods are also used by AudioPlaybackController.
@main
struct AudioPlaybackChecks {
    static var assertions = 0
    static let sampleRate = 48_000.0
    static let toneFrequency = 1000.0, toneDuration = 2.0, padding = 0.25

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "AudioPlaybackChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        assertions += 1
    }

    static func writeTone(_ url: URL, channels: Int) throws {
        let tag = channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        let layout = AVAudioChannelLayout(layoutTag: tag)!
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = Int((toneDuration + padding * 2) * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<channels {
            for frame in 0..<count {
                let position = Double(frame) / sampleRate - padding
                let fade = max(0, min(1, position / 0.01, (toneDuration - position) / 0.01))
                buffer.floatChannelData![channel][frame] = Float(0.5 * fade * sin(2 * .pi * toneFrequency * position))
            }
        }
        try file.write(from: buffer)
    }

    static func manualEngine(channels: AVAudioChannelCount = 2) throws -> AVAudioEngine {
        var component = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_GenericOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, &component) != nil else {
            throw NSError(domain: "AudioPlaybackChecks", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "Apple GenericOutput audio component is unavailable in this execution environment; offline playback checks cannot run."])
        }
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        // Apple explicitly recommends enabling this before mainMixerNode is touched.
        // Never disable manual mode: that would reconnect the engine to a device.
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        return engine
    }

    static func render(_ url: URL, rate: Double, pitch: Double) throws -> [Float] {
        let engine = try manualEngine()
        let player = AVAudioPlayerNode(), effect = AVAudioUnitTimePitch()
        engine.attach(player); engine.attach(effect)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        try AudioAuditionGraph.connect(player: player, effect: effect, engine: engine, format: file.processingFormat)
        try AudioAuditionGraph.configure(effect, rate: rate, pitchSemitones: pitch)
        player.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(file.length), at: nil)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024)!
        try engine.start()
        defer { player.stop(); engine.stop() }
        player.play()
        try check(engine.isInManualRenderingMode && engine.manualRenderingMode == .offline, "graph remains offline")
        // The extra second drains time-pitch latency/tail without interpreting either
        // as source duration. Actual tone boundaries are measured from rendered PCM.
        let budget = Int((Double(file.length) / file.processingFormat.sampleRate / rate + 1) * sampleRate)
        var output: [Float] = []; output.reserveCapacity(budget)
        var stalled = 0
        while output.count < budget {
            let frames = AVAudioFrameCount(min(1024, budget - output.count))
            let status = try engine.renderOffline(frames, to: buffer)
            if status == .error { throw NSError(domain: "AudioPlaybackChecks", code: 2) }
            let count = Int(buffer.frameLength)
            if count > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count))
                stalled = 0
            } else {
                stalled += 1
                try check(stalled < 100, "manual rendering must advance")
            }
        }
        return output
    }

    static func measurement(_ samples: [Float]) throws -> (duration: Double, frequency: Double) {
        try check(samples.allSatisfy(\.isFinite), "rendered PCM is finite")
        // Ten-millisecond energy cells reject roundoff and identify the audible tone
        // independently of the scheduled or requested number of output samples.
        let step = Int(sampleRate / 100)
        var active: [Int] = []
        for start in stride(from: 0, to: samples.count, by: step) {
            let end = min(start + step, samples.count)
            let power = samples[start..<end].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(end - start)
            if power > 0.001 { active.append(start) }
        }
        guard let first = active.first, let last = active.last else { throw NSError(domain: "AudioPlaybackChecks.silent", code: 3) }
        let duration = Double(last + step - first) / sampleRate
        // Ignore onset/end and TimePitch boundary transients. A steady sine's upward
        // zero crossings give an independent frequency check, not the effect setting.
        let lower = first + Int(Double(last + step - first) * 0.3)
        let upper = first + Int(Double(last + step - first) * 0.7)
        var crossings: [Double] = []
        for frame in lower..<min(upper, samples.count - 1) {
            let a = Double(samples[frame]), b = Double(samples[frame + 1])
            if a <= 0, b > 0 { crossings.append(Double(frame) - a / (b - a)) }
        }
        try check(crossings.count > 100, "rendered tone has measurable periodic content")
        return (duration, Double(crossings.count - 1) * sampleRate / (crossings.last! - crossings.first!))
    }

    @MainActor
    static func main() {
        do { try runChecks() }
        catch {
            FileHandle.standardError.write(Data("Offline playback checks failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func runChecks() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mono = directory.appendingPathComponent("mono.caf"), stereo = directory.appendingPathComponent("stereo.caf")
        let surround = directory.appendingPathComponent("eight-channel.caf")
        try writeTone(mono, channels: 1); try writeTone(stereo, channels: 2); try writeTone(surround, channels: 8)
        let originalMono = try Data(contentsOf: mono), originalStereo = try Data(contentsOf: stereo)
        for rate in [0.5, 1.0, 2.0] {
            for pitch in [-12.0, 0.0, 12.0] {
                let url = pitch == 0 ? mono : stereo
                let result = try measurement(render(url, rate: rate, pitch: pitch))
                let expectedDuration = toneDuration / rate, expectedFrequency = toneFrequency * pow(2, pitch / 12)
                print(String(format: "rate %.1f, pitch %+.0f: measured %.3f s, %.2f Hz", rate, pitch, result.duration, result.frequency))
                try check(abs(result.duration - expectedDuration) < 0.12, "rendered duration at rate \(rate), pitch \(pitch): \(result.duration) vs \(expectedDuration)")
                try check(abs(result.frequency - expectedFrequency) / expectedFrequency < 0.01, "rendered frequency at rate \(rate), pitch \(pitch): \(result.frequency) vs \(expectedFrequency)")
            }
        }

        let monoSource = try AudioAnalysisEngine.load(mono), stereoSource = try AudioAnalysisEngine.load(stereo)
        let surroundSource = try AudioAnalysisEngine.load(surround)
        try check(surroundSource.channelCount == 8, "eight-channel analysis remains supported")
        let silentEngine = try manualEngine()
        let playback = AudioPlaybackController(engine: silentEngine)
        try playback.prepare(left: monoSource, right: stereoSource)
        try check(!playback.isPlaying && silentEngine.isInManualRenderingMode, "prepare never starts playback")
        // Reconfiguration also has to work after the audio unit allocated render
        // resources, not merely when the controller has never been started.
        try silentEngine.start()
        let empty = AVAudioPCMBuffer(pcmFormat: silentEngine.manualRenderingFormat, frameCapacity: 256)!
        _ = try silentEngine.renderOffline(256, to: empty)
        playback.stop()
        try playback.prepare(left: stereoSource, right: monoSource)
        try check(playback.error == nil && !silentEngine.isRunning, "prepare recovers after stopped rendering and exchanged channel counts")
        do {
            try playback.prepare(left: monoSource, right: surroundSource)
            throw NSError(domain: "AudioPlaybackChecks.accepted-eight-channels", code: 4)
        } catch AudioAuditionError.unsupportedFormat {}
        try check(!playback.isPlaying && playback.error != nil, "multichannel audition fails safely without starting engine")
        try playback.prepare(left: monoSource, right: stereoSource)
        try check(playback.error == nil && !playback.isPlaying, "valid source preparation recovers after unsupported audition")
        do {
            try AudioAuditionGraph.configure(AVAudioUnitTimePitch(), rate: .nan, pitchSemitones: 0)
            throw NSError(domain: "AudioPlaybackChecks.accepted-invalid-rate", code: 5)
        } catch AudioEngineError.invalidSettings {}
        playback.stop()
        try check(!silentEngine.isRunning, "stop leaves offline engine stopped")
        try check(try Data(contentsOf: mono) == originalMono && Data(contentsOf: stereo) == originalStereo, "audition never writes source audio")
        print("Passed \(assertions) silent offline playback checks. Hardware output, listening quality and A/B device latency are not covered.")
    }
}
