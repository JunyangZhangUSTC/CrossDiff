import AppKit
import AVFoundation
import SwiftUI
import CrossDiffCore

/// One native surface owns keyboard focus; playback keys never monitor the whole app.
@MainActor
struct VideoPlayerCanvas: NSViewRepresentable {
    let player: AVPlayer?
    let image: CGImage?
    let playing: Bool
    let theme: ComparisonTheme
    let togglePlayback: () -> Void
    let step: (Int) -> Void

    func makeNSView(context: Context) -> VideoPlayerSurface {
        let view = VideoPlayerSurface()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: VideoPlayerSurface, context: Context) {
        view.configure(player: player, image: image, playing: playing, theme: theme,
                       togglePlayback: togglePlayback, step: step)
    }

    static func dismantleNSView(_ view: VideoPlayerSurface, coordinator: ()) {
        view.releasePlayer()
    }
}

@MainActor
final class VideoPlayerSurface: NSView {
    private let playerLayer = AVPlayerLayer()
    private let frameLayer = CALayer()
    private var playAction: (() -> Void)?
    private var stepAction: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.magnificationFilter = .linear
        frameLayer.minificationFilter = .trilinear
        layer?.addSublayer(playerLayer)
        layer?.addSublayer(frameLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(player: AVPlayer?, image: CGImage?, playing: Bool, theme: ComparisonTheme,
                   togglePlayback: @escaping () -> Void, step: @escaping (Int) -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playerLayer.player !== player { playerLayer.player = player }
        playerLayer.isHidden = !playing
        frameLayer.isHidden = playing
        frameLayer.contents = image
        layer?.backgroundColor = (theme.isDark ? NSColor(srgbRed: 0.065, green: 0.075, blue: 0.088, alpha: 1)
                                  : NSColor(srgbRed: 0.935, green: 0.941, blue: 0.950, alpha: 1)).cgColor
        CATransaction.commit()
        playAction = togglePlayback
        stepAction = step
        setAccessibilityLabel(L("视频画面", "Video Frame"))
        setAccessibilityHelp(L("点击画面后，空格播放或暂停，左右方向键逐帧。", "Click the frame, then use Space to play or pause and the arrow keys to step."))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        frameLayer.frame = bounds
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 49: playAction?()
        case 123: stepAction?(-1)
        case 124: stepAction?(1)
        default: super.keyDown(with: event)
        }
    }

    func releasePlayer() {
        playerLayer.player = nil
        frameLayer.contents = nil
        playAction = nil
        stepAction = nil
    }
}

/// A bounded, source-time thumbnail track. The two tracks keep their own durations.
@MainActor
struct VideoThumbnailTrack: View {
    let name: String
    let time: Double
    let duration: Double
    let thumbnails: [CGImage]
    let selection: ClosedRange<Double>?
    let theme: ComparisonTheme
    let seek: (Double) -> Void
    @State private var draggingTime: Double?

    private var fraction: Double { min(1, max(0, (draggingTime ?? time) / max(duration, 0.001))) }

    var body: some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(nsColor: theme.secondaryText)).frame(width: 16)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: theme.separator).opacity(0.5))
                    if !thumbnails.isEmpty {
                        HStack(spacing: 1) {
                            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: max(0, (geometry.size.width - CGFloat(thumbnails.count - 1)) / CGFloat(thumbnails.count)), height: geometry.size.height)
                                    .clipped()
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 4)).opacity(theme.isDark ? 0.74 : 0.83)
                    }
                    if let selection, duration > 0 {
                        let start = min(1, max(0, selection.lowerBound / duration))
                        let end = min(1, max(start, selection.upperBound / duration))
                        Rectangle().fill(Color(nsColor: theme.accent).opacity(0.2))
                            .frame(width: max(0, geometry.size.width * (end - start)))
                            .overlay(Rectangle().strokeBorder(Color(nsColor: theme.navigationOutline), lineWidth: 1))
                            .offset(x: geometry.size.width * start)
                    }
                    Rectangle().fill(Color(nsColor: theme.accent)).frame(width: 2)
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: theme.accent))
                                .frame(width: 7, height: 6).offset(y: -2)
                        }
                        .offset(x: min(max(0, geometry.size.width - 2), geometry.size.width * fraction))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        draggingTime = min(1, max(0, value.location.x / max(1, geometry.size.width))) * duration
                    }
                    .onEnded { value in
                        let target = min(1, max(0, value.location.x / max(1, geometry.size.width))) * duration
                        draggingTime = nil
                        seek(target)
                    })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("\(name) 视频时间线", "\(name) Video Timeline"))
                .accessibilityValue(VideoTimeLabel.string(draggingTime ?? time))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: seek(min(duration, time + 1))
                    case .decrement: seek(max(0, time - 1))
                    @unknown default: break
                    }
                }
            }.frame(height: 29)
            Text(VideoTimeLabel.string(duration, milliseconds: false))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(nsColor: theme.secondaryText)).frame(width: 48, alignment: .trailing)
        }
    }
}

enum VideoTimeLabel {
    static func string(_ seconds: Double, milliseconds: Bool = true) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(min(seconds * 1_000, Double(Int.max / 2)).rounded(.down))
        let hours = total / 3_600_000, minutes = (total / 60_000) % 60, secs = (total / 1_000) % 60
        let base = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                             : String(format: "%02d:%02d", minutes, secs)
        return milliseconds ? base + String(format: ".%03d", total % 1_000) : base
    }
}
