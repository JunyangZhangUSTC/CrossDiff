import AVFoundation
import Combine
import Foundation
import CrossDiffCore

enum VideoPlaybackSide { case left, right }
enum VideoPlaybackAudio { case left, right, muted }
enum VideoPlaybackStopReason { case paused, ended, stalled, failed }

/// Coordinates source-time playback; correspondence mapping belongs to the
/// comparison model. Two native layers are a browsing preview, never an exact
/// pixel-analysis source. Exact paused frames come from VideoSourceService.
@MainActor
final class VideoPlaybackCoordinator: ObservableObject {
    let leftPlayer = AVPlayer()
    let rightPlayer = AVPlayer()
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var leftTime = CMTime.zero
    @Published private(set) var rightTime = CMTime.zero
    @Published private(set) var error: String?
    @Published private(set) var stopReason: VideoPlaybackStopReason = .paused
    @Published private(set) var audio: VideoPlaybackAudio = .muted

    var onTimeChanged: ((CMTime, CMTime) -> Void)?

    private var leftSource: VideoSource?
    private var rightSource: VideoSource?
    private var generation = 0
    private var observers: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var leftTimeObserver: Any?
    private var rightTimeObserver: Any?
    private var playbackStartHostTime: CFTimeInterval = 0
    private var expectedOffset: Double = 0
    private var lastRevisionCheck: CFTimeInterval = 0

    init() {
        for player in [leftPlayer, rightPlayer] {
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .pause
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
        }
        leftTimeObserver = leftPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.leftTime = self.leftPlayer.currentTime()
                self.checkPlaybackContinuity()
                self.onTimeChanged?(self.leftTime, self.rightPlayer.currentTime())
            }
        }
        rightTimeObserver = rightPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in if let self { self.rightTime = self.rightPlayer.currentTime() } }
        }
    }

    deinit {
        if let leftTimeObserver { leftPlayer.removeTimeObserver(leftTimeObserver) }
        if let rightTimeObserver { rightPlayer.removeTimeObserver(rightTimeObserver) }
        notifications.forEach(NotificationCenter.default.removeObserver)
        leftPlayer.pause()
        rightPlayer.pause()
    }

    func configure(left: VideoSource, right: VideoSource) {
        shutdown()
        leftSource = left
        rightSource = right
        leftPlayer.replaceCurrentItem(with: AVPlayerItem(asset: left.asset))
        rightPlayer.replaceCurrentItem(with: AVPlayerItem(asset: right.asset))
        error = nil
        leftTime = left.metadata.timeRange.start
        rightTime = right.metadata.timeRange.start
        observe(leftPlayer)
        observe(rightPlayer)
        setAudio(.muted)
    }

    func setAudio(_ selection: VideoPlaybackAudio) {
        audio = selection
        leftPlayer.isMuted = selection != .left
        rightPlayer.isMuted = selection != .right
    }

    func seek(left: CMTime, right: CMTime) async {
        pause()
        let token = generation
        guard let leftSource, let rightSource else { return }
        do {
            try validateTime(left, source: leftSource)
            try validateTime(right, source: rightSource)
            async let leftFinished = exactSeek(leftPlayer, time: left, token: token)
            async let rightFinished = exactSeek(rightPlayer, time: right, token: token)
            let completed = await (leftFinished, rightFinished)
            guard token == generation, !Task.isCancelled else { return }
            guard completed.0 && completed.1 else { throw VideoSourceError.decodeFailed }
            try VideoSourceService.validate(source: leftSource)
            try VideoSourceService.validate(source: rightSource)
            leftTime = leftPlayer.currentTime()
            rightTime = rightPlayer.currentTime()
            error = nil
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            fail(error.localizedDescription)
        }
    }

    func seek(side: VideoPlaybackSide, time: CMTime) async {
        pause()
        let token = generation
        let player = side == .left ? leftPlayer : rightPlayer
        guard let source = side == .left ? leftSource : rightSource else { return }
        do {
            try validateTime(time, source: source)
            let completed = await exactSeek(player, time: time, token: token)
            guard token == generation, !Task.isCancelled else { return }
            guard completed else { throw VideoSourceError.decodeFailed }
            try VideoSourceService.validate(source: source)
            if side == .left { leftTime = player.currentTime() } else { rightTime = player.currentTime() }
            error = nil
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            fail(error.localizedDescription)
        }
    }

    func play() async {
        pause()
        let token = generation
        guard let leftSource, let rightSource else { return }
        isPreparing = true
        error = nil
        defer { if generation == token { isPreparing = false } }
        do {
            try validateTime(leftPlayer.currentTime(), source: leftSource)
            try validateTime(rightPlayer.currentTime(), source: rightSource)
            // Readiness is bounded and cancellable. Playback never silently
            // starts one side while the other is still preparing.
            for attempt in 0..<400 {
                try Task.checkCancellation()
                guard token == generation else { return }
                if leftPlayer.currentItem?.status == .failed || rightPlayer.currentItem?.status == .failed { throw VideoSourceError.unsupported }
                if leftPlayer.currentItem?.status == .readyToPlay && rightPlayer.currentItem?.status == .readyToPlay { break }
                if attempt == 399 { throw VideoSourceError.decodeFailed }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            async let leftReady = preroll(leftPlayer, token: token)
            async let rightReady = preroll(rightPlayer, token: token)
            let ready = await (leftReady, rightReady)
            guard token == generation, !Task.isCancelled else { return }
            guard ready.0 && ready.1 else { throw VideoSourceError.decodeFailed }
            try VideoSourceService.validate(source: leftSource)
            try VideoSourceService.validate(source: rightSource)
            let lhs = leftPlayer.currentTime()
            let rhs = rightPlayer.currentTime()
            expectedOffset = rhs.seconds - lhs.seconds
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: 0.1, preferredTimescale: 1_000_000_000)
            playbackStartHostTime = ProcessInfo.processInfo.systemUptime + 0.1
            isPlaying = true
            leftPlayer.setRate(1, time: lhs, atHostTime: hostTime)
            rightPlayer.setRate(1, time: rhs, atHostTime: hostTime)
        } catch is CancellationError {
            if token == generation { pause() }
        } catch {
            if token == generation { fail(error.localizedDescription) }
        }
    }

    func pause() {
        generation &+= 1
        isPlaying = false
        isPreparing = false
        stopReason = .paused
        for player in [leftPlayer, rightPlayer] {
            player.pause()
            player.cancelPendingPrerolls()
            player.currentItem?.cancelPendingSeeks()
        }
        leftTime = leftPlayer.currentTime()
        rightTime = rightPlayer.currentTime()
    }

    func shutdown() {
        pause()
        observers.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        leftPlayer.replaceCurrentItem(with: nil)
        rightPlayer.replaceCurrentItem(with: nil)
        leftSource = nil
        rightSource = nil
        leftTime = .zero
        rightTime = .zero
        error = nil
        setAudio(.muted)
    }

    private func validateTime(_ time: CMTime, source: VideoSource) throws {
        try VideoSourceService.validate(source: source)
        guard time.isValid, time.seconds.isFinite, CMTimeRangeContainsTime(source.metadata.timeRange, time: time) else {
            throw VideoSourceError.outsideVideoRange
        }
    }

    private func observe(_ player: AVPlayer) {
        guard let item = player.currentItem else { return }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                // Both players can emit end notifications. Once the first has
                // paused the pair, a second event must not cancel the loop's seek.
                guard let self, let item, self.owns(item), self.isPlaying else { return }
                self.pause()
                self.stopReason = .ended
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.owns(item), self.isPlaying else { return }
                self.pause()
                self.stopReason = .stalled
                self.error = L("一侧视频暂时无法继续，两侧已暂停。", "One video stalled. Both sides have been paused.")
            }
        })
        observers.append(item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.owns(item), item.status == .failed else { return }
                self.fail(L("视频播放失败，两侧已暂停。", "Video playback failed. Both sides have been paused."))
            }
        })
        observers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak player] _, _ in
            Task { @MainActor in
                guard let self, let player, self.isPlaying, player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                self.pause()
                self.stopReason = .stalled
                self.error = L("正在等待视频画面，两侧已暂停。", "Waiting for video frames. Both sides have been paused.")
            }
        })
    }

    private func owns(_ item: AVPlayerItem) -> Bool { leftPlayer.currentItem === item || rightPlayer.currentItem === item }

    private func checkPlaybackContinuity() {
        guard isPlaying, ProcessInfo.processInfo.systemUptime - playbackStartHostTime > 0.5 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastRevisionCheck > 1 {
            lastRevisionCheck = now
            do {
                if let leftSource { try VideoSourceService.validate(source: leftSource) }
                if let rightSource { try VideoSourceService.validate(source: rightSource) }
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
        let left = leftPlayer.currentTime().seconds
        let right = rightPlayer.currentTime().seconds
        if !left.isFinite || !right.isFinite || abs((right - left) - expectedOffset) > 0.15 {
            pause()
            stopReason = .stalled
            error = L("两侧播放时间出现偏离，已暂停以重新定位。", "Playback times drifted apart. Both sides are paused for repositioning.")
        }
    }

    private func fail(_ message: String) {
        pause()
        stopReason = .failed
        error = message
    }

    private func exactSeek(_ player: AVPlayer, time: CMTime, token: Int) async -> Bool {
        guard token == generation, !Task.isCancelled else { return false }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let completion = VideoPlaybackCompletion(continuation)
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    Task { @MainActor in completion.finish(finished) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    guard !completion.completed else { return }
                    if self.generation == token { player.currentItem?.cancelPendingSeeks() }
                    completion.finish(false)
                }
            }
        }, onCancel: {
            Task { @MainActor in if self.generation == token { player.currentItem?.cancelPendingSeeks() } }
        })
    }

    private func preroll(_ player: AVPlayer, token: Int) async -> Bool {
        guard token == generation, !Task.isCancelled else { return false }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let completion = VideoPlaybackCompletion(continuation)
                player.preroll(atRate: 1) { ready in
                    Task { @MainActor in completion.finish(ready) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    guard !completion.completed else { return }
                    if self.generation == token { player.cancelPendingPrerolls() }
                    completion.finish(false)
                }
            }
        }, onCancel: {
            Task { @MainActor in if self.generation == token { player.cancelPendingPrerolls() } }
        })
    }
}

@MainActor
private final class VideoPlaybackCompletion {
    private var continuation: CheckedContinuation<Bool, Never>?
    var completed: Bool { continuation == nil }
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
