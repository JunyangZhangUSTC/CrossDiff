import Foundation
import AVFoundation
import Combine
import CrossDiffCore

enum AudioComparisonSide: String, Sendable { case left, right }

enum AudioAuditionError: LocalizedError {
    case unsupportedFormat
    var errorDescription: String? {
        L("试听暂支持单声道和双声道音频；其他声道的波形、频谱与比较仍可使用。",
          "Audition currently supports mono and stereo audio. Waveforms, spectra and comparison remain available for other channel counts.")
    }
}

/// Production and offline checks use the same Apple audio-unit graph and parameters.
/// Restrict audition channels before AVAudioEngine.connect, which may raise an Objective-C
/// exception for unsupported channel layouts rather than a catchable Swift error.
enum AudioAuditionGraph {
    static func validate(_ format: AVAudioFormat) throws {
        guard (1...2).contains(format.channelCount), format.sampleRate.isFinite,
              (8_000...384_000).contains(format.sampleRate),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw AudioAuditionError.unsupportedFormat
        }
    }

    static func connect(player: AVAudioPlayerNode, effect: AVAudioUnitTimePitch,
                        engine: AVAudioEngine, format: AVAudioFormat) throws {
        try validate(format)
        // Standard Float32 is accepted by Apple audio units. setFormat provides a
        // throwable capability check before the engine's non-throwing connections.
        try effect.auAudioUnit.inputBusses[0].setFormat(format)
        try effect.auAudioUnit.outputBusses[0].setFormat(format)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
    }

    static func configure(_ effect: AVAudioUnitTimePitch, rate: Double, pitchSemitones: Double) throws {
        guard AudioContract.validAudition(rate: rate, pitch: pitchSemitones) else { throw AudioEngineError.invalidSettings }
        effect.rate = Float(rate)
        effect.pitch = Float(pitchSemitones * 100)
    }
}

/// Playback state is independent from analysis. No source is opened for writing.
@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var activeSide: AudioComparisonSide = .left
    @Published private(set) var playhead = 0.0
    @Published var looping = false
    @Published private(set) var error: Error?
    private let engine: AVAudioEngine
    private let leftPlayer = AVAudioPlayerNode(), rightPlayer = AVAudioPlayerNode()
    private let leftPitch = AVAudioUnitTimePitch(), rightPitch = AVAudioUnitTimePitch()
    private var sources: [AudioComparisonSide: AudioDecodedSource] = [:]
    private var files: [AudioComparisonSide: AVAudioFile] = [:]
    private var activeRegion: AudioRegion?
    private var activeRate = 1.0, activePitch = 0.0, scheduledStart = 0.0
    private var timer: Timer?
    private var runID = UUID()
    private var transitionTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        for node in [leftPlayer, rightPlayer, leftPitch, rightPitch] as [AVAudioNode] { engine.attach(node) }
    }

    deinit {
        timer?.invalidate(); transitionTask?.cancel(); fadeTask?.cancel(); engine.stop()
    }

    func prepare(left: AudioDecodedSource, right: AudioDecodedSource) throws {
      do {
        stop()
        engine.stop()
        files = [:]; sources = [:]
        var opened: [AudioComparisonSide: AVAudioFile] = [:]
        let candidates: [AudioComparisonSide: AudioDecodedSource] = [.left: left, .right: right]
        // Validate both inputs first; a rejected side cannot leave a previously
        // prepared file available for accidental playback.
        for (side, source) in candidates {
            try AudioAnalysisEngine.validate(source)
            let file = try AVAudioFile(forReading: source.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            try AudioAuditionGraph.validate(file.processingFormat)
            opened[side] = file
        }
        for (side, file) in opened {
            let player = node(side), effect = pitchNode(side)
            engine.disconnectNodeOutput(player); engine.disconnectNodeOutput(effect)
            try AudioAuditionGraph.connect(player: player, effect: effect, engine: engine, format: file.processingFormat)
        }
        files = opened; sources = candidates
        error = nil
      } catch {
        files = [:]; sources = [:]
        for side in [AudioComparisonSide.left, .right] {
            engine.disconnectNodeOutput(node(side)); engine.disconnectNodeOutput(pitchNode(side))
        }
        self.error = error; throw error
      }
    }

    func play(side: AudioComparisonSide, region: AudioRegion, rate: Double = 1,
              pitchSemitones: Double = 0, from position: Double? = nil) {
        transitionTask?.cancel(); fadeTask?.cancel()
        runID = UUID()
        let wasPlaying = isPlaying, previousTime = playhead, previousDuration = activeRegion?.duration
        transitionTask = Task { [weak self] in
            guard let self else { return }
            if wasPlaying {
                let previous = self.node(self.activeSide), volume = previous.volume
                for step in 1...8 {
                    do { try await Task.sleep(nanoseconds: 2_000_000) } catch { return }
                    previous.volume = volume * Float(8 - step) / 8
                }
                self.updatePlayhead()
            }
            guard !Task.isCancelled else { return }
            var start = position
            if wasPlaying, let position, let previousDuration, previousDuration > 0 {
                start = position + max(0, self.playhead - previousTime) / previousDuration * region.duration
                if start! >= region.end { start = region.start }
            }
            self.playNow(side: side, region: region, rate: rate, pitchSemitones: pitchSemitones, from: start)
        }
    }

    private func playNow(side: AudioComparisonSide, region: AudioRegion, rate: Double,
                         pitchSemitones: Double, from position: Double?) {
        do {
            guard let source = sources[side], let file = files[side], region.validated(duration: source.duration),
                  AudioContract.validAudition(rate: rate, pitch: pitchSemitones) else { throw AudioEngineError.invalidRegion }
            try AudioAnalysisEngine.validate(source)
            let start = max(region.start, min(position ?? region.start, region.end))
            guard start < region.end else { return }
            stopImmediately(resetPlayhead: false)
            activeSide = side; activeRegion = region; activeRate = rate; activePitch = pitchSemitones
            scheduledStart = start; playhead = start
            let player = node(side), effect = pitchNode(side), sampleRate = file.processingFormat.sampleRate
            player.volume = 0
            try AudioAuditionGraph.configure(effect, rate: rate, pitchSemitones: pitchSemitones)
            let first = AVAudioFramePosition((start * sampleRate).rounded(.down))
            let end = min(file.length, AVAudioFramePosition((region.end * sampleRate).rounded(.up)))
            guard end > first, end - first <= Int64(UInt32.max) else { throw AudioEngineError.budget }
            let token = UUID(); runID = token
            player.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(end - first),
                                   at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.runID == token else { return }
                    if self.looping {
                        self.play(side: side, region: region, rate: rate, pitchSemitones: pitchSemitones)
                    } else {
                        self.pause(); self.playhead = region.end
                    }
                }
            }
            if !engine.isRunning { try engine.start() }
            player.play()
            isPlaying = true; error = nil
            fadeTask = Task { [weak self, weak player] in
                for step in 1...8 {
                    do { try await Task.sleep(nanoseconds: 2_000_000) } catch { return }
                    guard let self, self.runID == token else { return }
                    player?.volume = Float(step) / 8
                }
            }
            let ticker = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updatePlayhead() }
            }
            timer = ticker; RunLoop.main.add(ticker, forMode: .common)
        } catch { self.error = error; stopImmediately(resetPlayhead: false); engine.stop() }
    }

    func pause() {
        transitionTask?.cancel(); fadeTask?.cancel()
        runID = UUID()
        updatePlayhead()
        node(activeSide).pause(); engine.pause(); isPlaying = false
        timer?.invalidate(); timer = nil
    }

    func stop(resetPlayhead: Bool = true) {
        transitionTask?.cancel(); fadeTask?.cancel()
        stopImmediately(resetPlayhead: resetPlayhead)
        engine.stop()
    }

    private func stopImmediately(resetPlayhead: Bool) {
        runID = UUID()
        leftPlayer.stop(); rightPlayer.stop()
        timer?.invalidate(); timer = nil
        isPlaying = false
        if resetPlayhead { playhead = 0 }
    }

    private func updatePlayhead() {
        guard isPlaying, let file = files[activeSide], let region = activeRegion else { return }
        let player = node(activeSide)
        if let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) {
            playhead = max(region.start, min(region.end, scheduledStart + Double(time.sampleTime) / file.processingFormat.sampleRate))
            let remaining = (region.end - playhead) / activeRate
            if remaining < 0.025 { player.volume = Float(max(0, remaining / 0.025)) }
        }
    }

    private func node(_ side: AudioComparisonSide) -> AVAudioPlayerNode { side == .left ? leftPlayer : rightPlayer }
    private func pitchNode(_ side: AudioComparisonSide) -> AVAudioUnitTimePitch { side == .left ? leftPitch : rightPitch }
}
