import AppKit
import AVFoundation
import SwiftUI
import CrossDiffCore

/// Native video workbench: two source clocks, one transport, details on demand.
@MainActor
struct VideoComparisonView: View {
    let left: URL
    let right: URL
    @ObservedObject var model: VideoComparisonModel
    let execute: @Sendable ([PluginInput], [String: PluginJSONValue]) async throws -> PluginComparisonResult
    let executionID: String
    @ObservedObject private var appearance = AppAppearance.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showsAlignment = false
    @State private var showsInformation = false
    @State private var showsLoop = false
    @State private var showsSaveRegion = false
    @State private var selectingRegion = false
    @State private var offsetDraft = 0.0
    @State private var loopStartDraft = 0.0
    @State private var loopEndDraft = 1.0
    @State private var regionName = ""
    @State private var reloadID = UUID()
    private var theme: ComparisonTheme { appearance.colors }
    private var ready: Bool { model.hasSources && !model.isLoading }
    private var linkedBinding: Binding<Bool> { Binding(get: { model.isLinked }, set: { model.setLinked($0) }) }
    private var referenceDuration: Double { model.referenceSide == .left ? model.leftDuration : model.rightDuration }
    private var referenceTime: Double { model.referenceSide == .left ? model.leftTime : model.rightTime }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.isLoading {
                loading
            } else if model.hasSources {
                correspondenceNotice
                Divider()
                sourceHeaders
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                Divider()
                transport
                timelines
                footer
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(L("无法读取视频", "Unable to Read Video"), systemImage: "film")
                } description: { Text(localizedErrorDescription(error)) }
                actions: { Button(L("重新读取", "Reload")) { reload() } }
            } else {
                ContentUnavailableView(L("视频对比", "Video Compare"), systemImage: "film.stack")
            }
        }
        .foregroundStyle(Color(nsColor: theme.text))
        .background(Color(nsColor: theme.canvas))
        .task(id: "\(left.absoluteString)-\(right.absoluteString)-\(executionID)-\(reloadID)") {
            await model.load(left: left, right: right, execute: execute, executionID: executionID)
        }
        .onDisappear { model.stop(); model.cancel() }
        .onChange(of: model.isPlaying) { _, playing in if playing { selectingRegion = false } }
        .onChange(of: model.displayMode) { _, mode in if mode != .sideBySide { selectingRegion = false } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(L("视频", "Video"), systemImage: "film.stack")
                .font(.system(size: 13, weight: .medium)).fixedSize()
            Picker(L("比较方式", "Comparison Mode"), selection: $model.displayMode) {
                Text(L("并排", "Side by Side")).tag(VideoDisplayMode.sideBySide)
                Text(L("滑动", "Wipe")).tag(VideoDisplayMode.wipe)
                Text(L("差异", "Difference")).tag(VideoDisplayMode.difference)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 253)
                .id(settings.language).accessibilityIdentifier("video.mode")
            Spacer(minLength: 6)
            Button {
                model.stop()
                offsetDraft = model.offsetSeconds
                showsAlignment.toggle()
            } label: { Label(L("时间对齐…", "Time Alignment…"), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .fixedSize().accessibilityIdentifier("video.alignment")
                .popover(isPresented: $showsAlignment) { alignmentPopover }
            HStack(spacing: 0) {
                Button {
                    model.stop()
                    model.displayMode = .sideBySide
                    selectingRegion.toggle()
                } label: {
                    Image(systemName: "crop")
                        .foregroundStyle(Color(nsColor: selectingRegion ? theme.accent : theme.secondaryText))
                }
                .help(L("框选局部画面；仅改变查看范围", "Select a Frame Region; View Only"))
                .accessibilityLabel(L("框选局部画面", "Select a Frame Region"))
                .accessibilityIdentifier("video.selectRegion")
                Menu {
                    Toggle(L("联动框选区域", "Link Region Selections"), isOn: $model.regionLinked)
                    Button(L("恢复完整画面", "Show Whole Frames")) { model.resetROI(); selectingRegion = false }
                        .disabled(model.leftROI == nil && model.rightROI == nil)
                    Divider()
                    Button(L("保存当前区域…", "Save Current Regions…")) {
                        regionName = L("区域", "Region") + " \(model.savedRegions.count + 1)"
                        showsSaveRegion = true
                    }.disabled((model.leftROI == nil && model.rightROI == nil) || model.savedRegions.count >= 32)
                    ForEach(model.savedRegions, id: \.id) { region in
                        Button(region.name) { model.restoreRegion(region.id); selectingRegion = false }
                    }
                    if !model.savedRegions.isEmpty {
                        Menu(L("删除已存区域", "Delete Saved Region")) {
                            ForEach(model.savedRegions, id: \.id) { region in
                                Button(region.name, role: .destructive) { model.removeRegion(region.id) }
                            }
                        }
                    }
                } label: { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                    .help(L("局部查看选项", "Region Options"))
                    .accessibilityLabel(L("局部查看选项", "Region Options"))
            }.popover(isPresented: $showsSaveRegion) { saveRegionPopover }
            Button { showsInformation.toggle() } label: { Image(systemName: "info.circle") }
                .help(L("视频与分析信息", "Video & Inspection Information"))
                .accessibilityLabel(L("视频与分析信息", "Video & Inspection Information"))
                .accessibilityIdentifier("video.information")
                .popover(isPresented: $showsInformation) { informationPopover }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 14).frame(height: 44)
        .background(Color(nsColor: theme.chrome)).disabled(!ready)
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L("正在读取视频与首帧…", "Reading video and first frames…"))
                .font(.system(size: 12)).foregroundStyle(Color(nsColor: theme.secondaryText))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var correspondenceNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: selectingRegion ? "crop" : (model.isLinked ? "link" : "link.slash"))
                .foregroundStyle(Color(nsColor: theme.accent))
            Text(selectingRegion
                 ? L("在画面上拖动框选；只改变查看范围，不修改原视频。", "Drag on a frame to inspect a region. Source videos stay unchanged.")
                 : model.status)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 5)
            if selectingRegion {
                Button(L("完成", "Done")) { selectingRegion = false }.buttonStyle(.borderless)
            } else {
                Text(L("本地 · 只读", "Local · Read-only")).fixedSize()
            }
        }
        .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
        .padding(.horizontal, 16).frame(height: 26)
        .background(Color(nsColor: theme.accent).opacity(theme.isDark ? 0.07 : 0.025))
    }

    private var sourceHeaders: some View {
        HStack(spacing: 0) {
            sourceHeader(side: .left)
            Rectangle().fill(Color(nsColor: theme.separator)).frame(width: 1)
            sourceHeader(side: .right)
        }.frame(height: 34)
    }

    private func sourceHeader(side: VideoSide) -> some View {
        let isLeft = side == .left
        let name = isLeft ? model.leftName : model.rightName
        let time = isLeft ? model.leftTime : model.rightTime
        let actualTime = isLeft ? model.leftActualTime : model.rightActualTime
        return HStack(spacing: 8) {
            Text(isLeft ? "A" : "B").font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(nsColor: theme.accent))
                .frame(width: 20, height: 20)
                .background(Color(nsColor: theme.accent).opacity(0.085), in: RoundedRectangle(cornerRadius: 5))
            Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(VideoTimeLabel.string(model.isPlaying ? time : (actualTime ?? time)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize()
                .help(L("此视频的源时间；暂停时显示解码帧的实际时间。", "Source time of this video; paused frames show their decoded presentation time."))
        }.padding(.horizontal, 14).frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var stage: some View {
        if model.displayMode == .sideBySide {
            HStack(spacing: 1) {
                framePane(side: .left)
                framePane(side: .right)
            }.background(Color(nsColor: theme.separator))
        } else {
            comparisonCanvas
        }
    }

    private func framePane(side: VideoSide) -> some View {
        let isLeft = side == .left
        let image = isLeft ? model.leftImage : model.rightImage
        let roi = isLeft ? model.leftROI : model.rightROI
        let player = isLeft ? model.leftPlayer : model.rightPlayer
        let visibleImage = selectingRegion || model.isPlaying ? image : VideoRegionGeometry.crop(image, to: roi)
        let previewOnly = model.canShowPlaybackPreview && image == nil && !model.isSeeking && model.inspectionNotice != nil
        let waitingForFrame = !model.isPlaying && (model.isSeeking || (image == nil && model.inspectionNotice == nil))
        return GeometryReader { geometry in
            ZStack {
                VideoPlayerCanvas(player: player, image: visibleImage, playing: model.isPlaying || previewOnly,
                                  theme: theme, togglePlayback: { model.togglePlayback() }, step: { model.step($0) })
                if !model.isPlaying && image == nil && !waitingForFrame && !previewOnly {
                    VStack(spacing: 7) {
                        Image(systemName: "film").font(.system(size: 21)).opacity(0.5)
                        Text(L("此侧无对应画面", "No Corresponding Frame"))
                            .font(.system(size: 12))
                    }.foregroundStyle(Color(nsColor: theme.secondaryText)).allowsHitTesting(false)
                }
                if waitingForFrame {
                    ProgressView().controlSize(.small)
                        .padding(10).background(Color(nsColor: theme.canvas).opacity(0.92), in: RoundedRectangle(cornerRadius: 7))
                }
                if previewOnly {
                    VStack {
                        HStack { canvasBadge(L("播放预览 · 不用于精确差异", "Playback Preview · Not for Exact Comparison")); Spacer() }
                        Spacer()
                    }.padding(10).allowsHitTesting(false)
                }
                if selectingRegion, let image {
                    VideoRegionSelector(image: image, region: roi, theme: theme) { region in
                        model.setROI(region, side: side)
                    }
                }
                if !selectingRegion && !model.isPlaying && roi != nil {
                    VStack {
                        HStack {
                            Text(L("局部查看", "Region View"))
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Color(nsColor: theme.canvas).opacity(0.93), in: Capsule())
                            Spacer()
                            Button { model.setROI(nil, side: side) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                                .buttonStyle(.bordered).controlSize(.mini)
                                .help(L("恢复此侧完整画面", "Show This Whole Frame"))
                                .accessibilityLabel(L("恢复此侧完整画面", "Show This Whole Frame"))
                        }
                        Spacer()
                    }.padding(10)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }

    private var comparisonCanvas: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: theme.isDark ? NSColor(srgbRed: 0.065, green: 0.075, blue: 0.088, alpha: 1)
                                             : NSColor(srgbRed: 0.935, green: 0.941, blue: 0.950, alpha: 1))
                if model.displayMode == .difference {
                    if let difference = model.differenceImage {
                        Image(decorative: difference, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else if !model.isSeeking {
                        VStack(spacing: 9) {
                            Image(systemName: "square.dashed").font(.system(size: 24))
                            Text(model.inspectionNotice ?? L("当前帧无法生成差异图", "Difference Preview Unavailable"))
                                .font(.system(size: 12)).multilineTextAlignment(.center).frame(maxWidth: 360)
                        }.foregroundStyle(Color(nsColor: theme.secondaryText))
                    }
                } else if let first = VideoRegionGeometry.crop(model.leftImage, to: model.leftROI),
                          let second = VideoRegionGeometry.crop(model.rightImage, to: model.rightROI) {
                    Image(decorative: first, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    Image(decorative: second, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: geometry.size.width * (1 - model.wipeFraction))
                        }
                    wipeHandle(size: geometry.size)
                } else if !model.isSeeking {
                    Text(L("需要两侧都有对应帧", "Both Frames Are Required"))
                        .font(.system(size: 12)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                if model.isSeeking || (model.leftImage == nil && model.inspectionNotice == nil) {
                    ProgressView().controlSize(.small)
                        .padding(12).background(Color(nsColor: theme.canvas).opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                }
                VStack {
                    HStack {
                        if model.displayMode == .wipe { canvasBadge("A") }
                        Spacer()
                        canvasBadge(model.displayMode == .wipe ? "B" : L("暂停帧差异", "Paused Frame Difference"))
                    }
                    Spacer()
                }.padding(10).allowsHitTesting(false)
            }.coordinateSpace(name: "video-wipe-canvas").clipped()
        }
    }

    private func canvasBadge(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(nsColor: theme.canvas).opacity(0.92), in: Capsule())
    }

    private func wipeHandle(size: CGSize) -> some View {
        Color.clear.frame(width: 32, height: size.height)
            .overlay { Rectangle().fill(Color(nsColor: theme.canvas)).frame(width: 1) }
            .overlay {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(nsColor: theme.accent))
                    .frame(width: 28, height: 26)
                    .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: theme.separator), lineWidth: 1))
            }
            .position(x: size.width * model.wipeFraction, y: size.height / 2)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("video-wipe-canvas")).onChanged { value in
                model.wipeFraction = min(0.98, max(0.02, value.location.x / max(1, size.width)))
            })
            .accessibilityElement().accessibilityLabel(L("左右画面分界位置", "Frame Divider Position"))
            .accessibilityValue("\(Int(model.wipeFraction * 100))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.wipeFraction = min(0.98, model.wipeFraction + 0.05)
                case .decrement: model.wipeFraction = max(0.02, model.wipeFraction - 0.05)
                @unknown default: break
                }
            }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Toggle(isOn: linkedBinding) { Image(systemName: model.isLinked ? "link" : "link.slash") }
                .toggleStyle(.button)
                .help(L("联动浏览；关闭后可在两条时间线上独立定位。", "Linked Browsing; turn off to seek independently on each timeline."))
                .accessibilityLabel(L("联动浏览", "Linked Browsing")).accessibilityIdentifier("video.linkPlayback")
            Picker(L("逐帧基准", "Frame Reference"), selection: $model.referenceSide) {
                Text("A").tag(VideoSide.left)
                Text("B").tag(VideoSide.right)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 61).id(settings.language)
                .help(L("以选中视频的真实帧时间逐帧；循环范围也使用此侧的源时间。", "Step by this video's actual frame times. Loop ranges also use this side's source time."))
                .accessibilityIdentifier("video.referenceSide")
            Spacer(minLength: 4)
            Button { model.step(-1) } label: { Image(systemName: "backward.frame") }
                .help(L("上一帧 · 画面焦点下按 ←", "Previous Frame · ← with Frame Focus"))
                .accessibilityLabel(L("上一帧", "Previous Frame")).accessibilityIdentifier("video.previousFrame")
            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold)).frame(width: 23)
                    .foregroundStyle(Color(nsColor: theme.accent))
            }
                .help(model.isPlaying ? L("暂停 · 空格", "Pause · Space") : L("播放 · 空格；滑动与差异模式会返回并排播放。", "Play · Space; wipe and difference modes return to side-by-side playback."))
                .accessibilityLabel(model.isPlaying ? L("暂停", "Pause") : L("播放", "Play"))
                .accessibilityIdentifier("video.playPause")
            Button { model.step(1) } label: { Image(systemName: "forward.frame") }
                .help(L("下一帧 · 画面焦点下按 →", "Next Frame · → with Frame Focus"))
                .accessibilityLabel(L("下一帧", "Next Frame")).accessibilityIdentifier("video.nextFrame")
            if model.isSeeking { ProgressView().controlSize(.mini).frame(width: 14) }
            Spacer(minLength: 4)
            Button {
                loopStartDraft = model.loopStart
                loopEndDraft = model.loopEnd > model.loopStart ? model.loopEnd : min(referenceDuration, model.loopStart + 5)
                showsLoop.toggle()
            } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(Color(nsColor: model.loopEnabled ? theme.accent : theme.secondaryText))
            }.help(L("循环范围", "Loop Range")).accessibilityLabel(L("循环范围", "Loop Range"))
                .disabled(!model.isLinked)
                .help(L("启用联动后，循环查看两侧对应范围。", "Enable linked browsing to loop corresponding ranges on both sides."))
                .accessibilityIdentifier("video.loop").popover(isPresented: $showsLoop) { loopPopover }
            Picker(L("声音", "Audio"), selection: $model.audioSide) {
                Image(systemName: "speaker.slash").accessibilityLabel(L("静音", "Mute")).tag(VideoAudioSide.muted)
                Text("A").tag(VideoAudioSide.left)
                Text("B").tag(VideoAudioSide.right)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 99).id(settings.language)
                .help(L("选择唯一的试听音轨：静音、A 或 B。", "Choose one audio track: muted, A or B."))
                .accessibilityIdentifier("video.audioSide")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 16).frame(height: 44)
        .background(Color(nsColor: theme.chrome))
    }

    private var timelines: some View {
        VStack(spacing: 8) {
            VideoThumbnailTrack(name: "A", time: model.leftTime, duration: model.leftDuration,
                                thumbnails: model.leftThumbnails.map(\.image), selection: loopSelection(side: .left),
                                theme: theme) { model.seek(side: .left, seconds: $0) }
                .accessibilityIdentifier("video.leftTimeline")
            VideoThumbnailTrack(name: "B", time: model.rightTime, duration: model.rightDuration,
                                thumbnails: model.rightThumbnails.map(\.image), selection: loopSelection(side: .right),
                                theme: theme) { model.seek(side: .right, seconds: $0) }
                .accessibilityIdentifier("video.rightTimeline")
        }
        .padding(.horizontal, 16).padding(.top, 3).padding(.bottom, 9)
        .background(Color(nsColor: theme.chrome))
    }

    private func loopSelection(side: VideoSide) -> ClosedRange<Double>? {
        guard model.loopEnabled, model.loopEnd > model.loopStart else { return nil }
        if !model.isLinked && side != model.referenceSide { return nil }
        let offset: Double
        if side == model.referenceSide { offset = 0 }
        else { offset = side == .right ? model.offsetSeconds : -model.offsetSeconds }
        return (model.loopStart + offset)...(model.loopEnd + offset)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            if let error = model.error {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: true)))
                Text(localizedErrorDescription(error)).lineLimit(1).help(localizedErrorDescription(error))
            } else if let notice = model.inspectionNotice,
                      model.displayMode != .sideBySide || model.leftImage == nil || model.rightImage == nil {
                Text(notice).lineLimit(1).help(notice)
            } else if model.thumbnailsLoading {
                ProgressView().controlSize(.mini)
                Text(L("正在生成缩略图…", "Building thumbnails…"))
            } else {
                Text(L("点击时间线定位 · 点击画面后可用空格与方向键", "Seek on a timeline · Focus a frame for Space and arrow keys"))
                    .lineLimit(1)
            }
            Spacer(minLength: 5)
            if model.loopEnabled {
                Text("\(VideoTimeLabel.string(model.loopStart, milliseconds: false)) – \(VideoTimeLabel.string(model.loopEnd, milliseconds: false))")
                    .monospacedDigit().fixedSize()
            }
        }
        .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
        .padding(.horizontal, 16).frame(height: 24)
        .background(Color(nsColor: theme.chrome))
    }

    private var alignmentPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("时间对齐", "Time Alignment")).font(.headline)
            Text(L("分别定位到相同画面，再将当前两帧设为对应。固定偏移只用于浏览，不证明整片内容对应。", "Find the same moment on each side, then pair the current frames. A fixed offset guides browsing; it does not verify the whole video."))
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("A  " + VideoTimeLabel.string(model.leftTime))
                Spacer()
                Text("B  " + VideoTimeLabel.string(model.rightTime))
            }.font(.system(size: 11, design: .monospaced))
            Toggle(L("联动浏览", "Linked Browsing"), isOn: linkedBinding)
            Button {
                model.alignCurrentFrames()
                offsetDraft = model.offsetSeconds
                showsAlignment = false
            } label: { Label(L("将当前两帧设为对应", "Pair Current Frames"), systemImage: "link") }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("video.pairCurrentFrames")
                .disabled(model.leftImage == nil || model.rightImage == nil || model.isSeeking)
            Divider()
            HStack(spacing: 8) {
                Text(L("B 时间偏移", "B Time Offset"))
                Spacer()
                TextField("0.000", value: $offsetDraft, format: .number.precision(.fractionLength(3)))
                    .textFieldStyle(.roundedBorder).frame(width: 94).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("video.offsetField")
                Text(L("秒", "s")).foregroundStyle(Color(nsColor: theme.secondaryText))
                Button(L("应用", "Apply")) { model.setOffset(offsetDraft) }
                    .disabled(!offsetDraft.isFinite).accessibilityIdentifier("video.applyOffset")
            }
            Text(L("B 时间 = A 时间 + 偏移；正值读取 B 中更晚的位置。", "B time = A time + offset. Positive values read later in B."))
                .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { model.undo(); offsetDraft = model.offsetSeconds } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo).help(L("撤销对齐与选区调整", "Undo Alignment and Region Changes"))
                Button { model.redo(); offsetDraft = model.offsetSeconds } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo).help(L("重做对齐与选区调整", "Redo Alignment and Region Changes"))
                Spacer()
                Button(L("恢复同时间查看", "Reset to Same-Time View")) { model.resetAlignment(); offsetDraft = 0 }
            }
        }.padding(18).frame(width: 350).foregroundStyle(Color(nsColor: theme.text))
            .background(Color(nsColor: theme.chrome)).buttonStyle(.bordered).controlSize(.small)
    }

    private var loopPopover: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(L("循环查看范围", "Loop a Range")).font(.headline)
            Text(model.referenceSide == .left
                 ? L("使用 A 的源时间。仅影响查看，不剪裁视频。", "Uses A's source time. Changes viewing only, not the video.")
                 : L("使用 B 的源时间。仅影响查看，不剪裁视频。", "Uses B's source time. Changes viewing only, not the video."))
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize(horizontal: false, vertical: true)
            loopField(L("起点（秒）", "Start (s)"), value: $loopStartDraft) { loopStartDraft = referenceTime }
            loopField(L("终点（秒）", "End (s)"), value: $loopEndDraft) { loopEndDraft = referenceTime }
            HStack {
                Button(L("清除", "Clear")) { model.clearLoop(); showsLoop = false }
                Spacer()
                Button(L("循环此范围", "Loop This Range")) {
                    model.setLoop(start: loopStartDraft, end: loopEndDraft)
                    showsLoop = false
                }.buttonStyle(.borderedProminent)
                    .disabled(!loopStartDraft.isFinite || !loopEndDraft.isFinite || loopStartDraft < 0 || loopEndDraft <= loopStartDraft || loopEndDraft > referenceDuration)
            }
        }.padding(18).frame(width: 318).foregroundStyle(Color(nsColor: theme.text))
            .background(Color(nsColor: theme.chrome)).buttonStyle(.bordered).controlSize(.small)
    }

    private func loopField(_ label: String, value: Binding<Double>, current: @escaping () -> Void) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            TextField("0.000", value: value, format: .number.precision(.fractionLength(3)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            Button(L("当前位置", "Current"), action: current)
        }
    }

    private var saveRegionPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("保存区域配对", "Save Region Pair")).font(.headline)
            TextField(L("名称", "Name"), text: $regionName).textFieldStyle(.roundedBorder)
                .onSubmit { saveRegion() }
            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { showsSaveRegion = false }
                Button(L("保存", "Save")) { saveRegion() }.buttonStyle(.borderedProminent)
                    .disabled(regionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || regionName.utf8.count > 256 || model.savedRegions.count >= 32)
            }
        }.padding(18).frame(width: 285).foregroundStyle(Color(nsColor: theme.text))
            .background(Color(nsColor: theme.chrome))
    }

    private func saveRegion() {
        let name = regionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.saveRegion(name: name)
        showsSaveRegion = false
    }

    private var informationPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("视频信息", "Video Information")).font(.headline)
                Spacer()
                Button { reload(); showsInformation = false } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("重新读取视频", "Reload Videos")).accessibilityLabel(L("重新读取视频", "Reload Videos"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metadataSection(name: "A · " + model.leftName, items: model.leftMetadata)
                    Divider()
                    metadataSection(name: "B · " + model.rightName, items: model.rightMetadata)
                    Divider()
                    Text(L("滑动与差异使用暂停后的实际帧。播放返回并排浏览；不同帧率的视频以真实时间定位。", "Wipe and difference views inspect decoded paused frames. Playback returns to side-by-side browsing; videos with different frame rates use actual timestamps."))
                        .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                    if let notice = model.inspectionNotice {
                        Text(notice).font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                    }
                }.textSelection(.enabled)
            }.frame(maxHeight: 340)
        }.padding(18).frame(width: 362).foregroundStyle(Color(nsColor: theme.text))
            .background(Color(nsColor: theme.chrome))
    }

    private func reload() {
        model.cancel()
        reloadID = UUID()
    }

    private func metadataSection(name: String, items: [VideoInfoItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(2).truncationMode(.middle)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 14) {
                    Text(item.label).foregroundStyle(Color(nsColor: theme.secondaryText)).frame(width: 100, alignment: .leading)
                    Text(item.value).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 11))
            }
        }
    }
}

private enum VideoRegionGeometry {
    static func crop(_ image: CGImage?, to region: VideoROI?) -> CGImage? {
        guard let image, let region else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = CGRect(x: region.x * Double(image.width), y: region.y * Double(image.height),
                          width: region.width * Double(image.width), height: region.height * Double(image.height))
            .integral.intersection(bounds)
        guard !rect.isEmpty else { return image }
        return image.cropping(to: rect) ?? image
    }

    static func fittedRect(image: CGImage, size: CGSize) -> CGRect {
        let scale = min(size.width / CGFloat(max(image.width, 1)), size.height / CGFloat(max(image.height, 1)))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

@MainActor
private struct VideoRegionSelector: View {
    let image: CGImage
    let region: VideoROI?
    let theme: ComparisonTheme
    let select: (VideoROI) -> Void
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let fitted = VideoRegionGeometry.fittedRect(image: image, size: geometry.size)
            let box = selectionBox(in: fitted)
            ZStack(alignment: .topLeading) {
                Color.clear
                if let box {
                    Rectangle().fill(Color(nsColor: theme.accent).opacity(0.12))
                        .overlay(Rectangle().strokeBorder(Color(nsColor: theme.navigationOutline), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                        .frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    guard fitted.contains(value.startLocation) else { return }
                    if dragStart == nil { dragStart = clamped(value.startLocation, to: fitted) }
                    dragEnd = clamped(value.location, to: fitted)
                }
                .onEnded { _ in
                    if dragStart != nil, let box = selectionBox(in: fitted), box.width >= 8, box.height >= 8,
                       fitted.width > 0, fitted.height > 0 {
                        select(VideoROI(x: (box.minX - fitted.minX) / fitted.width,
                                        y: (box.minY - fitted.minY) / fitted.height,
                                        width: box.width / fitted.width, height: box.height / fitted.height))
                    }
                    dragStart = nil; dragEnd = nil
                })
            .accessibilityLabel(L("框选暂停画面的区域", "Select a Region of the Paused Frame"))
        }
    }

    private func selectionBox(in fitted: CGRect) -> CGRect? {
        if let start = dragStart, let end = dragEnd {
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
        guard let region else { return nil }
        return CGRect(x: fitted.minX + region.x * fitted.width, y: fitted.minY + region.y * fitted.height,
                      width: region.width * fitted.width, height: region.height * fitted.height)
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(rect.maxX, max(rect.minX, point.x)), y: min(rect.maxY, max(rect.minY, point.y)))
    }
}
