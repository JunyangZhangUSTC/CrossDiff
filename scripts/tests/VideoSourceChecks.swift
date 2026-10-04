import AVFoundation
import CoreGraphics
import Foundation

@main
struct VideoSourceChecks {
    static var count = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        count += 1
    }

    @MainActor
    static func checkPlayback(left: VideoSource, right: VideoSource) async throws {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.configure(left: left, right: right)
        require(coordinator.leftPlayer.isMuted && coordinator.rightPlayer.isMuted, "No sound before user action")
        coordinator.setAudio(.left)
        require(!coordinator.leftPlayer.isMuted && coordinator.rightPlayer.isMuted, "Only left audio")
        coordinator.setAudio(.right)
        require(coordinator.leftPlayer.isMuted && !coordinator.rightPlayer.isMuted, "Only right audio")
        coordinator.setAudio(.muted)
        await coordinator.seek(left: .zero, right: CMTime(value: 1, timescale: 2))
        require(coordinator.error == nil, "Valid linked seek")
        require(coordinator.leftTime == .zero && coordinator.rightTime == CMTime(value: 1, timescale: 2), "Each side retains its source time")
        let old = Task { await coordinator.seek(left: CMTime(value: 1, timescale: 4), right: CMTime(value: 3, timescale: 4)) }
        await Task.yield()
        await coordinator.seek(left: CMTime(value: 1, timescale: 2), right: CMTime(value: 1, timescale: 1))
        await old.value
        require(abs(coordinator.leftTime.seconds - 0.5) < 0.001 && abs(coordinator.rightTime.seconds - 1) < 0.001, "Latest seek wins")
        await coordinator.play()
        require(coordinator.isPlaying && coordinator.error == nil, "Both ready and preroll before playback")
        try await Task.sleep(nanoseconds: 300_000_000)
        require(coordinator.leftPlayer.currentTime().seconds > 0.5, "Left playback advances")
        require(coordinator.rightPlayer.currentTime().seconds > 1, "Right playback advances")
        require(abs(coordinator.rightPlayer.currentTime().seconds - coordinator.leftPlayer.currentTime().seconds - 0.5) < 0.08, "Shared host clock retains source offset")
        try await Task.sleep(nanoseconds: 700_000_000)
        require(!coordinator.isPlaying, "Either ending pauses both")
        require(coordinator.leftPlayer.rate == 0 && coordinator.rightPlayer.rate == 0, "Both stopped at end")
        await coordinator.seek(left: CMTime(value: 2, timescale: 1), right: CMTime(value: 1, timescale: 1))
        require(coordinator.error != nil && !coordinator.isPlaying, "Out-of-range seek fails visibly")
        coordinator.shutdown()
        require(coordinator.leftPlayer.currentItem == nil && coordinator.rightPlayer.currentItem == nil, "Shutdown releases items")
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vfrURL = root.appendingPathComponent("variable.mov")
        try await VideoFixtures.write(to: vfrURL, times: VideoFixtures.variableTimes, end: CMTime(seconds: 1, preferredTimescale: 1_000))
        let source = try await VideoSourceService.load(url: vfrURL)
        require(source.metadata.canStepPrecisely, "A generated QuickTime file must provide precise sample cursors")
        require(source.metadata.displaySize == CGSize(width: 320, height: 180), "Display dimensions")
        require(!source.metadata.hasAudio, "No imaginary audio track")
        require(source.metadata.supportsSDRInspection, "Tagged Rec709 source is eligible for SDR inspection")
        require(!source.metadata.isHDR, "SDR must not claim HDR")
        require(source.metadata.codec == "avc1", "H.264 codec metadata")
        require(source.metadata.duration == CMTime(seconds: 1, preferredTimescale: 1_000), "Actual asset duration")
        for (index, pts) in VideoFixtures.variableTimes.enumerated() {
            let frame = try await VideoSourceService.frame(source: source, at: pts, maxDimension: 128)
            require(frame.actualTime == pts, "Precise decoded frame must have true PTS")
            require(frame.sourceID == source.id, "Frame source identity")
            require(frame.image.width <= 128 && frame.image.height <= 128, "Frame pixel bound")
            let forward = try await VideoSourceService.adjacentSampleTime(source: source, from: pts, direction: 1)
            require(forward == (index + 1 < VideoFixtures.variableTimes.count ? VideoFixtures.variableTimes[index + 1] : nil), "Forward VFR step must use adjacent sample")
            let backward = try await VideoSourceService.adjacentSampleTime(source: source, from: pts, direction: -1)
            require(backward == (index > 0 ? VideoFixtures.variableTimes[index - 1] : nil), "Backward VFR step must use adjacent sample")
        }
        let between = CMTime(value: 300, timescale: 1_000)
        let covering = try await VideoSourceService.frame(source: source, at: between)
        require(covering.actualTime == CMTime(value: 180, timescale: 1_000), "Between VFR samples choose the covering actual frame, not fps arithmetic")
        require(covering.requestedTime == between, "Requested and actual source times remain distinct")
        let thumbnails = try await VideoSourceService.thumbnails(source: source, count: 100)
        require(thumbnails.count == 16, "Thumbnail count bounded")
        require(thumbnails.allSatisfy { $0.image.width <= 160 && $0.image.height <= 160 }, "Thumbnail dimensions bounded")
        require(thumbnails.allSatisfy { $0.sourceID == source.id }, "Thumbnail identity")
        do {
            _ = try await VideoSourceService.frame(source: source, at: CMTime(seconds: 1, preferredTimescale: 1_000))
            fatalError("End-exclusive time must not freeze last frame")
        } catch VideoSourceError.outsideVideoRange { count += 1 }
        do {
            _ = try await VideoSourceService.frame(source: source, at: CMTime(value: -1, timescale: 1_000))
            fatalError("Negative source time accepted")
        } catch VideoSourceError.outsideVideoRange { count += 1 }
        do {
            _ = try await VideoSourceService.load(url: URL(string: "https://example.invalid/video.mov")!)
            fatalError("Network URL accepted")
        } catch VideoSourceError.localFileRequired { count += 1 }
        do {
            _ = try await VideoSourceService.load(url: root)
            fatalError("Directory accepted")
        } catch VideoSourceError.unreadableFile { count += 1 }
        let broken = root.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: broken)
        do {
            _ = try await VideoSourceService.load(url: broken)
            fatalError("Corrupt file accepted")
        } catch { count += 1 }
        let cancelled = Task { () -> [VideoFrame] in
            return try await VideoSourceService.thumbnails(source: source)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation ignored") } catch is CancellationError { count += 1 }

        let rotatedURL = root.appendingPathComponent("rotated.mov")
        let regular = (0..<24).map { CMTime(value: Int64($0), timescale: 24) }
        try await VideoFixtures.write(to: rotatedURL, times: regular, end: CMTime(value: 1, timescale: 1), rotated: true)
        let rotated = try await VideoSourceService.load(url: rotatedURL)
        require(rotated.metadata.displaySize == CGSize(width: 180, height: 320), "Rotation reflected in presentation size")
        let rotatedFrame = try await VideoSourceService.frame(source: rotated, at: CMTime(value: 1, timescale: 24))
        require(rotatedFrame.image.width == 180 && rotatedFrame.image.height == 320, "Rotation applied to decoded pixels")
        require(rotatedFrame.actualTime == CMTime(value: 1, timescale: 24), "24 fps rational PTS preserved")

        let noTagsURL = root.appendingPathComponent("untagged.mov")
        try await VideoFixtures.write(to: noTagsURL, times: regular, end: CMTime(value: 1, timescale: 1), colorTagged: false)
        let noTags = try await VideoSourceService.load(url: noTagsURL)
        // Apple can add inferred tags while encoding; inspect the real file rather
        // than asserting the writer kept tags absent.
        if noTags.metadata.colorPrimaries == nil || noTags.metadata.transferFunction == nil || noTags.metadata.yCbCrMatrix == nil {
            require(!noTags.metadata.supportsSDRInspection, "Missing color information is not verified SDR")
        }
        for codec in [AVVideoCodecType.hevc, .proRes422] {
            let codecURL = root.appendingPathComponent(codec == .hevc ? "hevc.mov" : "prores.mov")
            try await VideoFixtures.write(to: codecURL, times: regular, end: CMTime(value: 1, timescale: 1), codec: codec)
            let video = try await VideoSourceService.load(url: codecURL)
            let frame = try await VideoSourceService.frame(source: video, at: regular[7])
            require(frame.actualTime == regular[7], "Native HEVC / ProRes precise frame")
            require(video.metadata.supportsSDRInspection, "Native HEVC / ProRes color metadata")
        }
        let delayedURL = root.appendingPathComponent("delayed-start.mov")
        let delayedTimes = regular.map { $0 + CMTime(value: 1, timescale: 2) }
        try await VideoFixtures.write(to: delayedURL, times: delayedTimes, end: CMTime(value: 3, timescale: 2))
        let delayed = try await VideoSourceService.load(url: delayedURL)
        require(delayed.metadata.timeRange.start == CMTime(value: 1, timescale: 2), "Nonzero track start preserved")
        let firstDelayed = try await VideoSourceService.frame(source: delayed, at: delayed.metadata.timeRange.start)
        require(firstDelayed.actualTime == delayedTimes[0], "Nonzero first PTS preserved")
        do { _ = try await VideoSourceService.frame(source: delayed, at: .zero); fatalError("Before-track source time accepted") }
        catch VideoSourceError.outsideVideoRange { count += 1 }

        let editedURL = root.appendingPathComponent("edited.mov")
        try VideoFixtures.edit(to: editedURL, source: rotated, ranges: [
            (CMTimeRange(start: regular[6], duration: regular[6]), .zero),
            (CMTimeRange(start: regular[15], duration: regular[6]), CMTime(value: 1, timescale: 2))
        ])
        let edited = try await VideoSourceService.load(url: editedURL)
        let editFirst = try await VideoSourceService.frame(source: edited, at: .zero)
        require(editFirst.actualTime == .zero, "Trimmed media source maps to asset beginning")
        let editNext = try await VideoSourceService.adjacentSampleTime(source: edited, from: .zero, direction: 1)
        require(editNext == regular[1], "Trimmed media uses true mapped next PTS")
        do { _ = try await VideoSourceService.frame(source: edited, at: CMTime(value: 1, timescale: 3)); fatalError("An empty edit displayed stale pixels") }
        catch VideoSourceError.outsideVideoRange { count += 1 }
        let afterGap = try await VideoSourceService.adjacentSampleTime(source: edited, from: regular[5], direction: 1)
        require(afterGap == CMTime(value: 1, timescale: 2), "Stepping crosses gap to actual next sample")
        let beforeGap = try await VideoSourceService.adjacentSampleTime(source: edited, from: CMTime(value: 1, timescale: 2), direction: -1)
        require(beforeGap == regular[5], "Reverse step crosses gap to actual previous sample")
        let editSecond = try await VideoSourceService.frame(source: edited, at: CMTime(value: 1, timescale: 2))
        require(editSecond.actualTime == CMTime(value: 1, timescale: 2), "Post-gap frame PTS")
        let rationalURL = root.appendingPathComponent("rational.mov")
        let rationalTimes = (0..<60).map { CMTime(value: Int64($0) * 1001, timescale: 30_000) }
        try await VideoFixtures.write(to: rationalURL, times: rationalTimes, end: CMTime(value: 60_060, timescale: 30_000))
        let rational = try await VideoSourceService.load(url: rationalURL)
        for index in [0, 1, 27, 31, 59] {
            let frame = try await VideoSourceService.frame(source: rational, at: rationalTimes[index])
            require(frame.actualTime == rationalTimes[index], "29.97 rational PTS preserved across GOPs")
        }

        let referenceURL = root.appendingPathComponent("reference.mov")
        if FileManager.default.fileExists(atPath: referenceURL.path) { try FileManager.default.removeItem(at: referenceURL) }
        let movie = try AVMutableMovie(settingsFrom: nil, options: nil)
        try movie.insertTimeRange(source.metadata.timeRange, of: source.asset, at: .zero, copySampleData: false)
        try movie.writeHeader(to: referenceURL, fileType: .mov, options: .truncateDestinationToMovieHeaderOnly)
        do {
            let reference = try await VideoSourceService.load(url: referenceURL)
            _ = try await VideoSourceService.frame(source: reference, at: reference.metadata.timeRange.start)
            fatalError("External file reference was decoded despite forbidAll")
        } catch { count += 1 }

        try await checkPlayback(left: rotated, right: delayed)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: vfrURL.path)
        do { try VideoSourceService.validate(source: source); fatalError("Changed source accepted") }
        catch VideoSourceError.sourceChanged { count += 1 }
        do { _ = try await VideoSourceService.frame(source: source, at: .zero); fatalError("Changed source frame accepted") }
        catch VideoSourceError.sourceChanged { count += 1 }
        print("Video source checks passed: \(count) assertions (VFR, true PTS, bounds, rotation, color, errors, source revisions).")
    }
}
