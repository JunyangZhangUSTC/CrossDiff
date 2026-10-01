import SwiftUI
import CoreGraphics
import CrossDiffCore

/// A source-time selection over the original per-channel envelope. Dragging never changes audio.
struct AudioWaveformChart: View {
    let source: AudioDecodedSource
    let selection: AudioRegion?
    let visibleRange: AudioRegion
    let correspondences: [AudioCorrespondence]
    let isLeft: Bool
    let theme: ComparisonTheme
    let select: (AudioRegion) -> Void
    @GestureState private var drag: AudioRegion?

    private var tint: Color { Color(nsColor: isLeft ? theme.accent : theme.differenceForeground(isRemoval: false)) }
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let channelHeight = size.height / CGFloat(max(1, source.waveform.count))
                for (channel, bins) in source.waveform.enumerated() {
                    let center = channelHeight * (CGFloat(channel) + 0.5)
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: center)); baseline.addLine(to: CGPoint(x: size.width, y: center))
                    context.stroke(baseline, with: .color(Color(nsColor: theme.separator)), lineWidth: 0.5)
                    guard !bins.isEmpty else { continue }
                    var envelope = Path(), rms = Path()
                    let columns = max(1, Int(size.width))
                    for x in 0..<columns {
                        let t0 = visibleRange.start + Double(x) / Double(columns) * visibleRange.duration
                        let t1 = visibleRange.start + Double(x + 1) / Double(columns) * visibleRange.duration
                        let lower = max(0, min(bins.count - 1, Int(t0 / source.duration * Double(bins.count))))
                        let upper = max(lower + 1, min(bins.count, Int(ceil(t1 / source.duration * Double(bins.count)))))
                        var minimum: Float = 0, maximum: Float = 0, level: Float = 0
                        for index in lower..<upper {
                            minimum = min(minimum, bins[index].minimum); maximum = max(maximum, bins[index].maximum)
                            level = max(level, bins[index].rms)
                        }
                        let amplitude = channelHeight * 0.43
                        envelope.move(to: CGPoint(x: CGFloat(x), y: center - CGFloat(min(1, maximum)) * amplitude))
                        envelope.addLine(to: CGPoint(x: CGFloat(x), y: center - CGFloat(max(-1, minimum)) * amplitude))
                        rms.move(to: CGPoint(x: CGFloat(x), y: center - CGFloat(min(1, level)) * amplitude))
                        rms.addLine(to: CGPoint(x: CGFloat(x), y: center + CGFloat(min(1, level)) * amplitude))
                    }
                    context.stroke(envelope, with: .color(tint.opacity(0.52)), lineWidth: 1)
                    context.stroke(rms, with: .color(tint.opacity(0.80)), lineWidth: 1)
                    if source.waveform.count > 1 {
                        context.draw(Text("\(channel + 1)").font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(nsColor: theme.secondaryText)), at: CGPoint(x: 8, y: center - channelHeight * 0.34))
                    }
                }
                for pair in correspondences where pair.state != .rejected {
                    let region = isLeft ? pair.left : pair.right
                    guard let rectangle = rect(region, size: size) else { continue }
                    context.fill(Path(CGRect(x: rectangle.minX, y: size.height - 4, width: max(2, rectangle.width), height: 3)), with: .color(tint))
                }
                if let chosen = drag ?? selection, let rectangle = rect(chosen, size: size) {
                    context.fill(Path(rectangle), with: .color(tint.opacity(0.10)))
                    context.stroke(Path(rectangle.insetBy(dx: 0.5, dy: 0.5)), with: .color(tint.opacity(0.8)), lineWidth: 1)
                    let edges = [chosen.start, chosen.end].filter { $0 >= visibleRange.start && $0 <= visibleRange.end }
                    for time in edges {
                        let x = (time - visibleRange.start) / visibleRange.duration * size.width
                        context.fill(Path(roundedRect: CGRect(x: x - 2, y: size.height / 2 - 10, width: 4, height: 20), cornerRadius: 2), with: .color(tint))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .updating($drag) { value, state, _ in state = region(value, width: geometry.size.width) }
                .onEnded { value in if let region = region(value, width: geometry.size.width) { select(region) } })
            .accessibilityLabel(L("\(isLeft ? "A" : "B") 音频波形，拖动选择片段", "\(isLeft ? "A" : "B") audio waveform. Drag to select a region."))
            .accessibilityValue(selection.map { "\(AudioChartFormat.time($0.start)) – \(AudioChartFormat.time($0.end))" } ?? L("全长", "Full duration"))
            .accessibilityIdentifier(isLeft ? "audio.waveform.left" : "audio.waveform.right")
        }.clipped()
    }
    private func region(_ value: DragGesture.Value, width: CGFloat) -> AudioRegion? {
        AudioWaveformSelectionGesture.region(startX: value.startLocation.x, currentX: value.location.x, width: width,
            visibleRange: visibleRange, selection: selection, duration: source.duration)
    }
    private func rect(_ region: AudioRegion, size: CGSize) -> CGRect? {
        let first = max(region.start, visibleRange.start), last = min(region.end, visibleRange.end)
        guard last > first else { return nil }
        return CGRect(x: (first - visibleRange.start) / visibleRange.duration * size.width, y: 0,
                      width: (last - first) / visibleRange.duration * size.width, height: size.height)
    }
}

/// Pure source-time mapping shared by the actual drag gesture and workflow checks.
/// Hit testing uses the original selection, so an edge never turns into a new brush midway through a drag.
enum AudioWaveformSelectionGesture {
    static func region(startX: Double, currentX: Double, width: Double, visibleRange: AudioRegion,
                       selection: AudioRegion?, duration: Double) -> AudioRegion? {
        guard width.isFinite, width > 0, startX.isFinite, currentX.isFinite,
              visibleRange.validated(duration: duration) else { return nil }
        func time(_ x: Double) -> Double { max(0, min(duration, visibleRange.start + x / width * visibleRange.duration)) }
        func location(_ seconds: Double) -> Double { (seconds - visibleRange.start) / visibleRange.duration * width }
        if let selection, selection.validated(duration: duration) {
            let first = location(selection.start), last = location(selection.end)
            let firstDistance = abs(startX - first), lastDistance = abs(startX - last)
            let hitsFirst = first >= 0 && first <= width && firstDistance <= 8
            let hitsLast = last >= 0 && last <= width && lastDistance <= 8
            let minimum = min(0.01, selection.duration)
            if hitsFirst, !hitsLast || firstDistance <= lastDistance {
                return AudioRegion(start: min(time(currentX), selection.end - minimum), end: selection.end)
            }
            if hitsLast {
                return AudioRegion(start: selection.start, end: max(time(currentX), selection.start + minimum))
            }
            if startX > first, startX < last {
                let delta = (currentX - startX) / width * visibleRange.duration
                let start = max(0, min(duration - selection.duration, selection.start + delta))
                return AudioRegion(start: start, end: start + selection.duration)
            }
        }
        let first = time(max(0, min(width, startX))), last = time(max(0, min(width, currentX)))
        let selected = AudioRegion(start: min(first, last), end: max(first, last))
        return selected.duration >= min(0.01, duration) ? selected : nil
    }
}

struct AudioTimeRuler: View {
    let region: AudioRegion
    let theme: ComparisonTheme
    var body: some View {
        HStack {
            Text(AudioChartFormat.time(region.start)); Spacer()
            Text(AudioChartFormat.time(region.start + region.duration / 2)); Spacer()
            Text(AudioChartFormat.time(region.end))
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(nsColor: theme.secondaryText))
    }
}

enum AudioChartFormat {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        return String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

struct AudioSpectrogramChart: View {
    let analysis: AudioSpectrumAnalysis
    let settings: AudioAnalysisSettings
    let theme: ComparisonTheme
    @State private var image: CGImage?
    private var key: String { "\(analysis.id)-\(settings.frequencyScale.rawValue)-\(settings.minimumDB)-\(settings.maximumDB)" }
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing) {
                Text(String(format: "%.1f kHz", analysis.sampleRate / 2000))
                Spacer(); Text(settings.frequencyScale == .logarithmic ? "20 Hz" : "0 Hz")
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Color(nsColor: theme.secondaryText)).frame(width: 51)
            GeometryReader { geometry in
                let width = min(1400, max(1, Int(ceil(geometry.size.width))))
                let height = min(512, max(1, Int(ceil(geometry.size.height))))
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().interpolation(.none) }
                    else { Rectangle().fill(Color(nsColor: theme.chrome)).overlay { ProgressView().controlSize(.small) } }
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .task(id: "\(key)-\(width)-\(height)") {
                        image = nil
                        let worker = Task.detached(priority: .userInitiated) {
                            AudioChartRendering.spectrogram(analysis, settings: settings, width: width, height: height)
                        }
                        let rendered = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                        guard !Task.isCancelled else { return }
                        image = rendered
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("STFT 时频图，范围 \(AudioChartFormat.time(analysis.region.start)) 至 \(AudioChartFormat.time(analysis.region.end))", "STFT spectrogram, \(AudioChartFormat.time(analysis.region.start)) to \(AudioChartFormat.time(analysis.region.end))"))
    }
}

private enum AudioChartRendering {
    static func spectrogram(_ analysis: AudioSpectrumAnalysis, settings: AudioAnalysisSettings, width: Int, height: Int) -> CGImage? {
        guard analysis.columns > 0, analysis.bins > 1 else { return nil }
        let maximumFrequency = analysis.sampleRate / 2
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        // Reduce display cells by maxima, preserving brief transients and narrow peaks.
        // Source-time ranges remain separate from FFT window/hop and display resolution.
        var timeColumns: [Range<Int>] = []
        var firstColumn = 0
        for x in 0..<width {
            let start = analysis.region.start + Double(x) / Double(width) * analysis.region.duration
            let end = analysis.region.start + Double(x + 1) / Double(width) * analysis.region.duration
            while firstColumn < analysis.columns && analysis.columnRegions[firstColumn].end <= start { firstColumn += 1 }
            var endColumn = firstColumn
            while endColumn < analysis.columns && analysis.columnRegions[endColumn].start < end { endColumn += 1 }
            timeColumns.append(firstColumn..<endColumn)
        }
        // A shared dark-to-blue-to-cyan-to-warm scale; both inputs use identical dB bounds.
        let stops: [(Double, Double, Double)] = [(12, 21, 37), (32, 66, 111), (47, 133, 155), (125, 201, 192), (249, 224, 150)]
        for y in 0..<height {
            if Task.isCancelled { return nil }
            func frequency(_ position: Double) -> Double {
                settings.frequencyScale == .logarithmic ? 20 * pow(maximumFrequency / 20, position) : maximumFrequency * position
            }
            let lowerFrequency = frequency(Double(height - 1 - y) / Double(height))
            let upperFrequency = min(analysis.sourceNyquist, frequency(Double(height - y) / Double(height)))
            let lowerBin = max(0, min(analysis.bins - 1, Int(lowerFrequency / analysis.sampleRate * Double(analysis.fftSize))))
            let upperBin = max(lowerBin + 1, min(analysis.bins, Int(ceil(upperFrequency / analysis.sampleRate * Double(analysis.fftSize))) + 1))
            for x in 0..<width {
                if lowerFrequency > analysis.sourceNyquist || timeColumns[x].isEmpty {
                    let index = (y * width + x) * 4
                    pixels[index] = 77; pixels[index + 1] = 82; pixels[index + 2] = 90
                    continue
                }
                var level = -Float.infinity
                for column in timeColumns[x] {
                    for bin in lowerBin..<upperBin { level = max(level, analysis.decibels[column * analysis.bins + bin]) }
                }
                let db = Double(level)
                let fraction = max(0, min(1, (db - settings.minimumDB) / (settings.maximumDB - settings.minimumDB))) * 4
                let lower = min(3, Int(fraction)), mix = fraction - Double(lower)
                let first = stops[lower], second = stops[lower + 1], index = (y * width + x) * 4
                pixels[index] = UInt8(first.0 + (second.0 - first.0) * mix)
                pixels[index + 1] = UInt8(first.1 + (second.1 - first.1) * mix)
                pixels[index + 2] = UInt8(first.2 + (second.2 - first.2) * mix)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct AudioAverageSpectrumChart: View {
    let left: AudioSpectrumAnalysis?
    let right: AudioSpectrumAnalysis?
    let settings: AudioAnalysisSettings
    let theme: ComparisonTheme
    var body: some View {
        Canvas { context, size in
            for fraction in [0.0, 0.5, 1.0] {
                let y = fraction * size.height
                var grid = Path(); grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(Color(nsColor: theme.separator)), lineWidth: 0.5)
            }
            for (analysis, color) in [(left, theme.accent), (right, theme.differenceForeground(isRemoval: false))] {
                guard let analysis else { continue }
                var path = Path(), started = false
                let maximum = min(left?.sourceNyquist ?? 24000, right?.sourceNyquist ?? 24000, 24000)
                for x in 0..<max(1, Int(size.width)) {
                    let fraction = Double(x) / max(1, size.width - 1)
                    let hz = settings.frequencyScale == .logarithmic ? 20 * pow(maximum / 20, fraction) : maximum * fraction
                    let nextFraction = min(1, Double(x + 1) / max(1, size.width - 1))
                    let nextHz = settings.frequencyScale == .logarithmic ? 20 * pow(maximum / 20, nextFraction) : maximum * nextFraction
                    let bin = min(analysis.bins - 1, max(0, Int(hz / analysis.sampleRate * Double(analysis.fftSize))))
                    let endBin = max(bin + 1, min(analysis.bins, Int(ceil(nextHz / analysis.sampleRate * Double(analysis.fftSize))) + 1))
                    let db = Double(analysis.averageDecibels[bin..<endBin].max() ?? -180)
                    let y = (1 - max(0, min(1, (db - settings.minimumDB) / (settings.maximumDB - settings.minimumDB)))) * size.height
                    if started { path.addLine(to: CGPoint(x: Double(x), y: y)) }
                    else { path.move(to: CGPoint(x: Double(x), y: y)); started = true }
                }
                context.stroke(path, with: .color(Color(nsColor: color)), lineWidth: 1.4)
            }
        }.clipped().accessibilityLabel(L("选区平均频谱，蓝色 A，绿色 B，共用刻度", "Average region spectrum. Blue A, green B, shared scale."))
    }
}
