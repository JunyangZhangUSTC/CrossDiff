import AVFoundation
import Combine
import CoreImage
import Foundation
import CrossDiffCore

struct VideoThumbnail { let time: Double; let image: CGImage }
struct VideoInfoItem: Identifiable { let label: String; let value: String; var id: String { label } }

@MainActor
final class VideoComparisonModel: ObservableObject {
    typealias Execute = @Sendable ([PluginInput], [String: PluginJSONValue]) async throws -> PluginComparisonResult
    @Published private(set) var state: VideoWorkspaceState
    @Published private(set) var leftImage: CGImage?
    @Published private(set) var rightImage: CGImage?
    @Published private(set) var differenceImage: CGImage?
    @Published private(set) var leftThumbnails: [VideoThumbnail] = []
    @Published private(set) var rightThumbnails: [VideoThumbnail] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSeeking = false
    @Published private(set) var thumbnailsLoading = false
    @Published private(set) var leftActualTime: Double?
    @Published private(set) var rightActualTime: Double?
    @Published private(set) var error: Error?
    private enum InspectionNotice { case color, dimensions, preview, failure(Error) }
    @Published private var notice: InspectionNotice?
    var inspectionNotice: String? {
        switch notice {
        case .color: return L("差异图仅用于明确标记为 Rec.709 SDR 的视频；HDR 或色彩标记缺失时提供画面对照。", "Difference view requires explicit Rec.709 SDR tags. HDR or untagged videos are available for visual comparison.")
        case .dimensions: return L("两侧画面或所选区域尺寸不同；可并排或擦除对照，差异图需要相同像素尺寸。", "The frames or selected regions have different sizes. Use side-by-side or wipe; difference view requires equal pixel dimensions.")
        case .preview: return L("差异图为缩略解码画面的色彩管理预览，不是编码质量评分。", "Difference view is a color-managed preview of scaled decoded frames, not a codec-quality score.")
        case .failure(let error): return localizedErrorDescription(error)
        case nil: return nil
        }
    }
    @Published private(set) var canShowPlaybackPreview = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var comparison: VideoComparisonResult?
    @Published private(set) var leftSource: VideoSource?
    @Published private(set) var rightSource: VideoSource?
    var onStateChanged: (() -> Void)?
    let playback = VideoPlaybackCoordinator()
    private var history: [VideoWorkspaceState] = [], future: [VideoWorkspaceState] = []
    private var subscriptions = Set<AnyCancellable>()
    private var generation = UUID(), frameGeneration = UUID(), seekGeneration = UUID()
    private var loadTask: Task<(VideoSource, VideoSource), Error>?
    private var frameTask: Task<Void, Never>?, thumbnailTask: Task<Void, Never>?, actionTask: Task<Void, Never>?
    private var identity: [String]?
    private var decodedLeftTime: CMTime?, decodedRightTime: CMTime?
    private var isLooping = false

    init(state: VideoWorkspaceState = .init()) {
        self.state = state.isValid ? state : .init()
        playback.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        playback.$isPlaying.dropFirst().removeDuplicates().sink { [weak self] playing in
            guard !playing else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isPlaying, !self.isSeeking, !self.isLoading else { return }
                self.recordPosition(); self.inspectFrames()
            }
        }.store(in: &subscriptions)
        playback.$stopReason.dropFirst().sink { [weak self] reason in
            guard reason == .ended else { return }
            Task { @MainActor [weak self] in
                guard let self, self.playback.stopReason == .ended, self.state.loopEnabled else { return }
                self.restartLoop()
            }
        }.store(in: &subscriptions)
        playback.onTimeChanged = { [weak self] left, right in self?.checkLoop(left: left, right: right) }
    }
    /// Snapshot the live clocks without scheduling another persistence write.
    /// This also covers quitting during playback before onDisappear can run.
    var persistedState: VideoWorkspaceState {
        var value = state
        if hasSources {
            let a = leftPlayer.currentTime(), b = rightPlayer.currentTime()
            if a.isValid, b.isValid, a.value >= 0, b.value >= 0 {
                value.leftTime = .init(value: a.value, timescale: a.timescale)
                value.rightTime = .init(value: b.value, timescale: b.timescale)
            }
        }
        return value.isValid ? value : state
    }
    var leftPlayer: AVPlayer { playback.leftPlayer }
    var rightPlayer: AVPlayer { playback.rightPlayer }
    var leftTime: Double { playback.leftTime.seconds.isFinite ? playback.leftTime.seconds : 0 }
    var rightTime: Double { playback.rightTime.seconds.isFinite ? playback.rightTime.seconds : 0 }
    var leftDuration: Double { leftSource?.metadata.duration.seconds ?? 0 }
    var rightDuration: Double { rightSource?.metadata.duration.seconds ?? 0 }
    var leftName: String { leftSource?.url.lastPathComponent ?? "A" }
    var rightName: String { rightSource?.url.lastPathComponent ?? "B" }
    var leftMetadata: [VideoInfoItem] { metadata(leftSource) }
    var rightMetadata: [VideoInfoItem] { metadata(rightSource) }
    var isPlaying: Bool { playback.isPlaying }
    var hasSources: Bool { leftSource != nil && rightSource != nil }
    var isLinked: Bool { state.isLinked }
    var offsetSeconds: Double { state.offsetSeconds }
    var displayMode: VideoDisplayMode {
        get { state.displayMode }
        set { stop(); update { $0.displayMode = newValue }; inspectFrames() }
    }
    var audioSide: VideoAudioSide { get { state.audioSide } set { setAudioSide(newValue) } }
    var referenceSide: VideoSide {
        get { state.referenceSide }
        set { stop(); update { $0.referenceSide = newValue; $0.loopEnabled = false; $0.loopStart = 0; $0.loopEnd = 0 } }
    }
    var wipeFraction: Double { get { state.wipeFraction } set { update(history: false) { $0.wipeFraction = min(1, max(0, newValue)) } } }
    var loopEnabled: Bool {
        get { state.loopEnabled }
        set { update { $0.loopEnabled = newValue && $0.isLinked && $0.loopEnd > $0.loopStart } }
    }
    var loopStart: Double { state.loopStart }
    var loopEnd: Double { state.loopEnd }
    var leftROI: VideoROI? { get { state.leftROI } set { setROI(newValue, side: .left) } }
    var rightROI: VideoROI? { get { state.rightROI } set { setROI(newValue, side: .right) } }
    var regionLinked: Bool { get { state.regionLinked } set { update { $0.regionLinked = newValue } } }
    var savedRegions: [VideoSavedRegion] { state.savedRegions }
    var status: String {
        if let message = playback.error { return message }
        if isLoading { return L("正在读取本地视频…", "Reading local videos…") }
        if isSeeking || playback.isPreparing { return L("正在定位画面…", "Positioning frames…") }
        if !hasSources { return L("选择两个视频开始比较", "Choose two videos to compare") }
        if !isLinked { return L("独立定位 · 找到对应画面后，点击“对齐当前帧”", "Independent positioning · Find corresponding frames, then align them") }
        return offsetSeconds == 0
            ? L("同时间浏览 · 不代表内容已匹配", "Same-time browsing · Content correspondence is not confirmed")
            : L("手动偏移 \(String(format: "%+.3f", offsetSeconds)) 秒 · 未执行自动内容匹配", "Manual offset \(String(format: "%+.3f", offsetSeconds)) s · No automatic content matching")
    }

    func load(left: URL, right: URL, execute: @escaping Execute, executionID: String) async {
        let requested = [left.absoluteString, right.absoluteString, executionID]
        if identity == requested, hasSources { inspectFrames(); return }
        cancel()
        let token = UUID(); generation = token
        isLoading = true; error = nil; notice = nil; comparison = nil
        let previous = loadTask
        let worker = Task.detached(priority: .userInitiated) {
            _ = await previous?.result
            try Task.checkCancellation()
            async let a = VideoSourceService.load(url: left)
            async let b = VideoSourceService.load(url: right)
            return try await (a, b)
        }
        loadTask = worker
        do {
            let pair = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard generation == token else { return }
            let inputs = [input(pair.0, side: .left), input(pair.1, side: .right)]
            let result = try await execute(inputs, [:])
            let compared = try VideoComparisonResult.parse(result)
            try Task.checkCancellation()
            guard generation == token else { return }
            try VideoSourceService.validate(source: pair.0); try VideoSourceService.validate(source: pair.1)
            leftSource = pair.0; rightSource = pair.1; comparison = compared; identity = requested
            playback.configure(left: pair.0, right: pair.1)
            playback.setAudio(playbackAudio(state.audioSide))
            var a = restoredTime(state.leftTime, source: pair.0)
            var b = restoredTime(state.rightTime, source: pair.1)
            if isLinked {
                if let overlap {
                    if !overlap.contains(a.seconds) { a = time(overlap.lowerBound) }
                    if abs((b.seconds - a.seconds) - offsetSeconds) > 0.000000001 { b = mappedRight(a) }
                } else { update(history: false) { $0.isLinked = false; $0.loopEnabled = false } }
            }
            await playback.seek(left: a, right: b)
            guard generation == token, !Task.isCancelled else { return }
            isLoading = false; loadTask = nil
            if state.loopEnd > (referenceSide == .left ? leftDuration : rightDuration) { update(history: false) { $0.loopEnabled = false; $0.loopStart = 0; $0.loopEnd = 0 } }
            recordPosition(); inspectFrames(); loadThumbnails(pair.0, pair.1, token: token)
        } catch is CancellationError { if generation == token { isLoading = false } }
        catch { if generation == token, !Task.isCancelled { self.error = error; isLoading = false } }
    }

    func cancel() {
        recordPosition()
        generation = UUID(); frameGeneration = UUID(); seekGeneration = UUID()
        loadTask?.cancel(); frameTask?.cancel(); thumbnailTask?.cancel(); actionTask?.cancel()
        playback.shutdown(); identity = nil
        leftSource = nil; rightSource = nil; leftImage = nil; rightImage = nil; differenceImage = nil
        leftThumbnails = []; rightThumbnails = []; leftActualTime = nil; rightActualTime = nil
        isLoading = false; isSeeking = false; thumbnailsLoading = false; isLooping = false
    }
    func stop() { actionTask?.cancel(); seekGeneration = UUID(); isSeeking = false; playback.pause(); recordPosition(); inspectFrames() }
    func togglePlayback() {
        if isPlaying || playback.isPreparing { stop(); return }
        guard hasSources, !isLoading, !isSeeking else { return }
        actionTask?.cancel(); frameTask?.cancel(); frameGeneration = UUID()
        actionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer { if !Task.isCancelled, !self.isPlaying { self.inspectFrames() } }
            if self.isLinked {
                guard let overlap = self.overlap else { self.setError(zh: "两侧没有可联动播放的时间范围，请调整偏移。", en: "There is no overlapping playback range. Adjust the offset."); return }
                let current = self.leftTime
                let target = overlap.contains(current) ? current : overlap.lowerBound
                let aTime = abs(target - self.leftTime) < 0.000000001 ? self.playback.leftTime : self.time(target)
                await self.playback.seek(left: aTime, right: self.mappedRight(aTime))
            }
            guard !Task.isCancelled else { return }
            if self.state.loopEnabled {
                let current = self.referenceSide == .left ? self.leftTime : self.rightTime
                if current < self.loopStart || current >= self.loopEnd { await self.performSeek(side: self.referenceSide, seconds: self.loopStart) }
            }
            guard !Task.isCancelled, self.playback.error == nil else { return }
            if self.displayMode != .sideBySide { self.update(history: false) { $0.displayMode = .sideBySide } }
            await self.playback.play()
        }
    }
    func seek(side: VideoSide, seconds: Double) {
        guard seconds.isFinite, hasSources else { return }
        actionTask?.cancel(); playback.pause()
        actionTask = Task { [weak self] in await self?.performSeek(side: side, seconds: seconds) }
    }
    private func performSeek(side: VideoSide, seconds: Double, exact: CMTime? = nil) async {
        guard !Task.isCancelled, let leftSource, let rightSource else { return }
        let seekToken = UUID(); seekGeneration = seekToken
        isSeeking = true; frameTask?.cancel(); frameGeneration = UUID(); error = nil
        defer { if seekGeneration == seekToken { isSeeking = false } }
        var a = leftTime, b = rightTime
        if isLinked {
            guard let overlap else { setError(zh: "偏移后没有重叠范围，可关闭联动独立定位。", en: "No overlap at this offset. Unlink the videos to position them independently."); return }
            let proposed = side == .left ? seconds : seconds - offsetSeconds
            a = min(max(proposed, overlap.lowerBound), max(overlap.lowerBound, overlap.upperBound - 0.000001))
            b = a + offsetSeconds
        } else if side == .left { a = bounded(seconds, source: leftSource) }
        else { b = bounded(seconds, source: rightSource) }
        var aTime = time(a), bTime = time(b)
        if let exact, abs((side == .left ? a : b) - exact.seconds) < 0.000000001 {
            if side == .left { aTime = exact; if isLinked { bTime = mappedRight(exact) } }
            else { bTime = exact; if isLinked { aTime = mappedLeft(exact) } }
        }
        await playback.seek(left: aTime, right: bTime)
        guard !Task.isCancelled, seekGeneration == seekToken else { return }
        recordPosition(); inspectFrames()
    }
    func step(_ direction: Int) {
        guard let source = referenceSide == .left ? leftSource : rightSource, !isLoading else { return }
        actionTask?.cancel(); playback.pause(); isSeeking = true
        let side = referenceSide, position = side == .left ? playback.leftTime : playback.rightTime
        actionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let seekToken = UUID(); self.seekGeneration = seekToken
            defer { if self.seekGeneration == seekToken { self.isSeeking = false } }
            do {
                if let next = try await VideoSourceService.adjacentSampleTime(source: source, from: position, direction: direction) {
                    try Task.checkCancellation()
                    await self.performSeek(side: side, seconds: next.seconds, exact: next)
                }
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error } }
        }
    }
    func setLinked(_ linked: Bool) {
        stop(); update { $0.isLinked = linked; if !linked { $0.loopEnabled = false } }
        if linked { seek(side: referenceSide, seconds: referenceSide == .left ? leftTime : rightTime) }
    }
    func setAudioSide(_ side: VideoAudioSide) { update { $0.audioSide = side }; playback.setAudio(playbackAudio(side)) }
    func alignCurrentFrames() {
        let a = decodedLeftTime ?? playback.leftTime, b = decodedRightTime ?? playback.rightTime
        guard a.isValid, b.isValid else { return }
        stop()
        update {
            $0.offsetSeconds = (b - a).seconds; $0.isLinked = true
            $0.alignmentLeft = .init(value: a.value, timescale: a.timescale)
            $0.alignmentRight = .init(value: b.value, timescale: b.timescale)
        }
        actionTask = Task { [weak self] in await self?.performSeek(side: .left, seconds: a.seconds, exact: a) }
    }
    func setOffset(_ value: Double) {
        guard value.isFinite, abs(value) <= VideoContract.maximumDuration else { return }
        let position = playback.leftTime
        stop(); update { $0.offsetSeconds = value; $0.alignmentLeft = nil; $0.alignmentRight = nil }
        if isLinked { actionTask = Task { [weak self] in await self?.performSeek(side: .left, seconds: position.seconds, exact: position) } }
    }
    func resetAlignment() { setOffset(0) }
    func setLoop(start: Double, end: Double) {
        guard isLinked, let overlap else {
            setError(zh: "请先启用联动，再循环查看两侧对应范围。", en: "Enable linked browsing before looping a pair of ranges."); return
        }
        let offset = referenceSide == .left ? 0 : offsetSeconds
        guard start.isFinite, end.isFinite, end > start, start >= overlap.lowerBound + offset, end <= overlap.upperBound + offset else {
            setError(zh: "循环范围必须位于两侧有效视频的重叠范围内。", en: "The loop must stay within both videos' overlapping range."); return
        }
        error = nil; update { $0.loopStart = start; $0.loopEnd = end; $0.loopEnabled = true }
    }
    func clearLoop() { update { $0.loopEnabled = false; $0.loopStart = 0; $0.loopEnd = 0 } }
    func setROI(_ region: VideoROI?, side: VideoSide) {
        guard region?.isValid ?? true else { return }
        stop(); update {
            if side == .left { $0.leftROI = region } else { $0.rightROI = region }
            if $0.regionLinked { $0.leftROI = region; $0.rightROI = region }
        }; inspectFrames()
    }
    func resetROI() { stop(); update { $0.leftROI = nil; $0.rightROI = nil }; inspectFrames() }
    func saveRegion(name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = VideoSavedRegion(name: title, left: leftROI, right: rightROI)
        guard savedRegions.count < 32, region.isValid else { return }; update { $0.savedRegions.append(region) }
    }
    func restoreRegion(_ id: UUID) {
        guard let region = savedRegions.first(where: { $0.id == id }) else { return }
        stop(); update { $0.leftROI = region.left; $0.rightROI = region.right }; inspectFrames()
    }
    func removeRegion(_ id: UUID) { update { $0.savedRegions.removeAll { $0.id == id } } }
    func undo() {
        guard let value = history.popLast() else { return }
        stop(); future.append(state); state = value; changed(); restoreSettings()
    }
    func redo() {
        guard let value = future.popLast() else { return }
        stop(); history.append(state); state = value; changed(); restoreSettings()
    }
    private func restoreSettings() {
        playback.setAudio(playbackAudio(audioSide))
        guard let a = leftSource, let b = rightSource else { return }
        let aTime = restoredTime(state.leftTime, source: a), bTime = restoredTime(state.rightTime, source: b)
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let token = UUID(); self.seekGeneration = token; self.isSeeking = true
            defer { if self.seekGeneration == token { self.isSeeking = false } }
            await self.playback.seek(left: aTime, right: bTime)
            guard !Task.isCancelled, self.seekGeneration == token else { return }
            self.recordPosition(); self.inspectFrames()
        }
    }
    private func update(history saveHistory: Bool = true, _ edit: (inout VideoWorkspaceState) -> Void) {
        var value = state; edit(&value)
        if value.loopEnabled, value.isLinked, let a = leftSource?.metadata.timeRange, let b = rightSource?.metadata.timeRange {
            let range = value.overlap(leftStart: a.start.seconds, leftEnd: CMTimeRangeGetEnd(a).seconds,
                                      rightStart: b.start.seconds, rightEnd: CMTimeRangeGetEnd(b).seconds)
            let start = value.loopStart - (value.referenceSide == .right ? value.offsetSeconds : 0)
            let end = value.loopEnd - (value.referenceSide == .right ? value.offsetSeconds : 0)
            if range == nil || start < range!.lowerBound || end > range!.upperBound { value.loopEnabled = false }
        }
        guard value.isValid, value != state else { return }
        if saveHistory { history.append(state); if history.count > 64 { history.removeFirst() }; future = [] }
        state = value; changed()
    }
    private func changed() { canUndo = !history.isEmpty; canRedo = !future.isEmpty; onStateChanged?() }
    private func recordPosition() {
        guard hasSources else { return }
        let a = playback.leftTime, b = playback.rightTime
        guard a.isValid, b.isValid, a.value >= 0, b.value >= 0 else { return }
        update(history: false) { $0.leftTime = .init(value: a.value, timescale: a.timescale); $0.rightTime = .init(value: b.value, timescale: b.timescale) }
    }
    private var overlap: Range<Double>? {
        guard let a = leftSource?.metadata.timeRange, let b = rightSource?.metadata.timeRange else { return nil }
        return state.overlap(leftStart: a.start.seconds, leftEnd: CMTimeRangeGetEnd(a).seconds,
                             rightStart: b.start.seconds, rightEnd: CMTimeRangeGetEnd(b).seconds)
    }
    private func checkLoop(left: CMTime, right: CMTime) {
        guard isPlaying, !isLooping else { return }
        let current = referenceSide == .left ? left.seconds : right.seconds
        if state.loopEnabled, current >= loopEnd { restartLoop(); return }
        if let a = leftSource, let b = rightSource,
           left >= CMTimeRangeGetEnd(a.metadata.timeRange) || right >= CMTimeRangeGetEnd(b.metadata.timeRange) {
            if state.loopEnabled { restartLoop() } else { stop() }
        }
    }
    private func restartLoop() {
        guard state.loopEnabled, isLinked, !isLooping, hasSources else { return }
        isLooping = true; playback.pause(); actionTask?.cancel()
        actionTask = Task { [weak self] in
            guard let self else { return }; defer { self.isLooping = false }
            guard !Task.isCancelled else { return }
            await self.performSeek(side: self.referenceSide, seconds: self.loopStart)
            guard !Task.isCancelled, self.playback.error == nil else { return }
            await self.playback.play()
        }
    }
    private func inspectFrames() {
        guard let a = leftSource, let b = rightSource, !isPlaying, !isLoading else { return }
        let previous = frameTask; previous?.cancel()
        let token = UUID(); frameGeneration = token
        let aTime = playback.leftTime, bTime = playback.rightTime, aROI = leftROI, bROI = rightROI
        leftImage = nil; rightImage = nil; differenceImage = nil; leftActualTime = nil; rightActualTime = nil
        notice = nil; canShowPlaybackPreview = false; decodedLeftTime = nil; decodedRightTime = nil
        frameTask = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    async let first = Self.captureFrame(source: a, at: aTime)
                    async let second = Self.captureFrame(source: b, at: bTime)
                    let pair = await (first, second)
                    try Task.checkCancellation()
                    var difference: CGImage?
                    if a.metadata.supportsSDRInspection, b.metadata.supportsSDRInspection,
                       let first = try? pair.0.get(), let second = try? pair.1.get() {
                        difference = Self.difference(first.image, second.image, aROI, bROI)
                    }
                    return (pair.0, pair.1, difference)
                }
                let pair = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.frameGeneration == token, !self.isPlaying else { return }
                let first = try? pair.0.get(), second = try? pair.1.get()
                self.leftImage = first?.image; self.rightImage = second?.image; self.differenceImage = pair.2
                self.leftActualTime = first?.actualTime.seconds; self.rightActualTime = second?.actualTime.seconds
                self.decodedLeftTime = first?.actualTime; self.decodedRightTime = second?.actualTime
                let failures: [Error] = [pair.0, pair.1].compactMap { if case .failure(let error) = $0 { return error }; return nil }
                if let failure = failures.first {
                    self.notice = .failure(failure)
                    self.canShowPlaybackPreview = failures.allSatisfy { error in
                        guard let failure = error as? VideoSourceError else { return false }
                        switch failure { case .unavailableSampleIndex, .unverifiedFrameTime, .decodeFailed: return true; default: return false }
                    }
                } else if !a.metadata.supportsSDRInspection || !b.metadata.supportsSDRInspection {
                    self.notice = .color
                } else if pair.2 == nil {
                    self.notice = .dimensions
                } else { self.notice = .preview }
            } catch is CancellationError {} catch {
                guard let self, self.frameGeneration == token, !Task.isCancelled else { return }
                self.notice = .failure(error)
                if let failure = error as? VideoSourceError {
                    switch failure {
                    case .unavailableSampleIndex, .unverifiedFrameTime, .decodeFailed: self.canShowPlaybackPreview = true
                    default: self.canShowPlaybackPreview = false
                    }
                }
            }
        }
    }
    private func loadThumbnails(_ a: VideoSource, _ b: VideoSource, token: UUID) {
        thumbnailsLoading = true
        thumbnailTask = Task { [weak self] in
            do {
                async let first = VideoSourceService.thumbnails(source: a)
                async let second = VideoSourceService.thumbnails(source: b)
                let pair = try await (first, second); try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.leftThumbnails = pair.0.map { .init(time: $0.actualTime.seconds, image: $0.image) }
                self.rightThumbnails = pair.1.map { .init(time: $0.actualTime.seconds, image: $0.image) }
            } catch { /* Thumbnail failure must not prevent playback and exact inspection. */ }
            if let self, self.generation == token { self.thumbnailsLoading = false }
        }
    }
    nonisolated private static func captureFrame(source: VideoSource, at time: CMTime) async -> Result<VideoFrame, Error> {
        do { return .success(try await VideoSourceService.frame(source: source, at: time)) }
        catch { return .failure(error) }
    }
    nonisolated private static func difference(_ a: CGImage, _ b: CGImage, _ ar: VideoROI?, _ br: VideoROI?) -> CGImage? {
        func crop(_ image: CGImage, _ roi: VideoROI?) -> CGImage? {
            guard let roi else { return image }
            return image.cropping(to: CGRect(x: roi.x * Double(image.width), y: roi.y * Double(image.height),
                width: roi.width * Double(image.width), height: roi.height * Double(image.height)).integral)
        }
        guard let a = crop(a, ar), let b = crop(b, br), a.width == b.width, a.height == b.height,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let filter = CIFilter(name: "CIDifferenceBlendMode") else { return nil }
        filter.setValue(CIImage(cgImage: a), forKey: kCIInputImageKey)
        filter.setValue(CIImage(cgImage: b), forKey: kCIInputBackgroundImageKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
        return context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace)
    }
    private func input(_ source: VideoSource, side: VideoSide) -> PluginInput {
        let m = source.metadata
        let data = VideoSourceMetadata(id: side.rawValue, name: source.url.lastPathComponent,
            duration: .init(value: m.duration.value, timescale: m.duration.timescale),
            width: Int(m.displaySize.width.rounded()), height: Int(m.displaySize.height.rounded()),
            nominalFrameRate: Double(m.nominalFrameRate), codec: m.codec, hasAudio: m.hasAudio, isHDR: m.isHDR)
        return .init(id: side.rawValue, role: side == .left ? .left : .right, name: data.name, content: data.pluginContent)
    }
    private func metadata(_ source: VideoSource?) -> [VideoInfoItem] {
        guard let m = source?.metadata else { return [] }
        return [.init(label: L("画面尺寸", "Dimensions"), value: "\(Int(m.displaySize.width)) × \(Int(m.displaySize.height))"),
                .init(label: L("时长", "Duration"), value: String(format: "%.3f s", m.duration.seconds)),
                .init(label: L("标称帧率", "Nominal frame rate"), value: String(format: "%.3f fps", m.nominalFrameRate)),
                .init(label: L("编码", "Codec"), value: m.codec),
                .init(label: L("音轨", "Audio"), value: m.hasAudio ? L("有", "Present") : L("无", "None")),
                .init(label: L("色彩原色", "Color primaries"), value: m.colorPrimaries ?? L("未标记", "Untagged")),
                .init(label: L("传递函数", "Transfer function"), value: m.transferFunction ?? L("未标记", "Untagged"))]
    }
    private func restoredTime(_ stored: VideoTime, source: VideoSource) -> CMTime {
        let exact = CMTime(value: stored.value, timescale: stored.timescale)
        return CMTimeRangeContainsTime(source.metadata.timeRange, time: exact) ? exact : time(bounded(exact.seconds, source: source))
    }
    private func mappedRight(_ left: CMTime) -> CMTime {
        if let a = state.alignmentLeft, let b = state.alignmentRight {
            return left - CMTime(value: a.value, timescale: a.timescale) + CMTime(value: b.value, timescale: b.timescale)
        }
        return left + timeOffset(offsetSeconds)
    }
    private func mappedLeft(_ right: CMTime) -> CMTime {
        if let a = state.alignmentLeft, let b = state.alignmentRight {
            return right - CMTime(value: b.value, timescale: b.timescale) + CMTime(value: a.value, timescale: a.timescale)
        }
        return right - timeOffset(offsetSeconds)
    }
    private func timeOffset(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: max(0, seconds), preferredTimescale: 1_000_000_000) }
    private func bounded(_ value: Double, source: VideoSource) -> Double {
        let range = source.metadata.timeRange, start = range.start.seconds
        return min(max(start, value), max(start, CMTimeRangeGetEnd(range).seconds - 0.000001))
    }
    private func playbackAudio(_ value: VideoAudioSide) -> VideoPlaybackAudio { value == .left ? .left : value == .right ? .right : .muted }
    private func setError(zh: String, en: String) { error = PluginAppError(zh: zh, en: en) }
}
