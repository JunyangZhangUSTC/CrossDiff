import AppKit
import SwiftUI
import CrossDiffCore

@MainActor
struct PhotoComparisonView: View {
    let left: URL
    let right: URL
    @ObservedObject var model: PhotoComparisonModel
    let execute: @Sendable ([PluginInput]) async throws -> PluginComparisonResult
    let executionID: String
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @State private var showsProfessional = false
    @State private var section = Section.tone
    @State private var showsSaveRegion = false
    @State private var regionName = ""
    @State private var inspectSide: PhotoComparisonModel.Side?
    @State private var hoveredBin: Int?
    @State private var showsAnalysisHelp = false
    private var theme: ComparisonTheme { appearance.colors }
    private var selectedRegionName: String? {
        model.state.regions.first { $0.left == model.state.leftRegion && $0.right == model.state.rightRegion }?.name
    }
    private enum Section: String, CaseIterable {
        case tone, color, curves, information
        var title: String {
            switch self {
            case .tone: return L("影调", "Tone")
            case .color: return L("色彩 · HSL", "Color · HSL")
            case .curves: return L("处理曲线", "Recorded Curves")
            case .information: return L("拍摄与分析信息", "Image & Analysis")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if model.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L("正在读取照片与色彩信息…", "Reading photographs and color information…"))
                        .foregroundStyle(Color(nsColor: theme.secondaryText))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let leftImage = model.leftImage, let rightImage = model.rightImage {
                VSplitView {
                    HStack(spacing: 0) {
                        photograph(leftImage, url: left, side: .left, region: model.state.leftRegion)
                        Divider()
                        photograph(rightImage, url: right, side: .right, region: model.state.rightRegion)
                    }.frame(minHeight: 210, idealHeight: 360, maxHeight: .infinity)
                    analysisPanel.frame(minHeight: 250, idealHeight: 390, maxHeight: 500)
                }
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(L("无法读取照片", "Unable to Read Photographs"), systemImage: "photo.badge.exclamationmark")
                } description: { Text(localizedErrorDescription(error)) }
                actions: { Button(L("重试", "Try Again")) { reload() } }
            } else {
                ContentUnavailableView(L("摄影对比", "Photography Comparison"), systemImage: "camera.aperture")
            }
        }
        .foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
        .environment(\.colorScheme, appearance.isDark ? .dark : .light)
        .task(id: [left.absoluteString, right.absoluteString, executionID]) {
            await model.load(left: left, right: right, execute: execute, executionID: executionID)
        }
        .onDisappear { model.cancel() }
        .sheet(isPresented: Binding(get: { inspectSide != nil }, set: { if !$0 { inspectSide = nil } })) {
            if inspectSide == .left, let image = model.leftDisplayImage {
                PhotoPreviewInspector(image: image, name: left.lastPathComponent + " · " + previewTitle)
            } else if inspectSide == .right, let image = model.rightDisplayImage {
                PhotoPreviewInspector(image: image, name: right.lastPathComponent + " · " + previewTitle)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Label(L("摄影对比", "Photography"), systemImage: "camera.aperture")
                .font(.system(size: 13, weight: .medium))
            Rectangle().fill(Color(nsColor: theme.separator)).frame(width: 1, height: 16)
            Toggle(isOn: $model.state.linkedRegions) {
                Label(L("联动选区", "Link Regions"), systemImage: "link")
            }.toggleStyle(.button)
                .help(L("之后的框选将同步归一化位置；不会识别或配准相同物体。", "Future selections use the same normalized position on both images. This does not align matching objects."))
                .accessibilityIdentifier("photo.linkRegions")
            Button { model.resetRegions() } label: { Label(L("全图", "Whole Image"), systemImage: "viewfinder") }
                .disabled(model.state.leftRegion == .full && model.state.rightRegion == .full)
                .accessibilityIdentifier("photo.resetRegions")
            Menu {
                if model.state.regions.isEmpty {
                    Text(L("还没有保存的区域", "No Saved Regions"))
                }
                ForEach(model.state.regions) { pair in
                    Button(pair.name) { model.applyRegion(id: pair.id) }
                }
                if !model.state.regions.isEmpty {
                    Divider()
                    Menu(L("删除区域", "Delete Region")) {
                        ForEach(model.state.regions) { pair in
                            Button(pair.name, role: .destructive) { model.deleteRegion(id: pair.id) }
                        }
                    }
                }
            } label: { Label(selectedRegionName ?? L("已存区域", "Saved Regions"), systemImage: "rectangle.stack").lineLimit(1) }
                .frame(maxWidth: 132)
                .help(L("保存左右区域配对，随时切换", "Save pairs of regions and switch between them"))
                .accessibilityIdentifier("photo.savedRegions")
            Button {
                regionName = L("区域", "Region") + " \(model.state.regions.count + 1)"
                showsSaveRegion = true
            } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                .help(L("保存当前区域配对", "Save Current Region Pair"))
                .accessibilityLabel(L("保存区域", "Save Regions"))
                .accessibilityIdentifier("photo.saveRegions")
                .disabled(model.state.regions.count >= 32 || model.leftImage == nil)
                .popover(isPresented: $showsSaveRegion) { saveRegionPopover }
            Spacer(minLength: 0)
            Picker(L("照片预览", "Photo Preview"), selection: $model.state.previewChannel) {
                Text(L("预览：原图", "Preview: Original")).tag(PhotoPreviewChannel.original)
                Text(L("预览：红通道", "Preview: Red")).tag(PhotoPreviewChannel.red)
                Text(L("预览：绿通道", "Preview: Green")).tag(PhotoPreviewChannel.green)
                Text(L("预览：蓝通道", "Preview: Blue")).tag(PhotoPreviewChannel.blue)
            }.pickerStyle(.menu).labelsHidden().frame(width: 140)
                .id(settings.language.rawValue + (appearance.isDark ? "-dark" : "-light"))
                .help(L("同时查看两侧的单通道灰度预览；不改变原图或统计。", "View both photographs as one grayscale channel. Originals and statistics stay unchanged."))
                .disabled(model.leftImage == nil)
                .accessibilityIdentifier("photo.preview-channel")
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .help(L("重新读取照片与分析", "Reload Photographs and Analysis"))
                .accessibilityLabel(L("重新读取照片与分析", "Reload Photographs and Analysis"))
                .disabled(model.isLoading)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 16).frame(height: 44)
        .background(Color(nsColor: theme.chrome))
    }

    private var saveRegionPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("保存区域配对", "Save Region Pair")).font(.headline)
            TextField(L("名称，例如：天空", "Name, e.g. Sky"), text: $regionName)
                .textFieldStyle(.roundedBorder).onSubmit { saveRegion() }
            Text(L("同时保存左右区域。最多 32 组，随比较会话在本机保留。", "Saves both regions. Up to 32 pairs are retained locally with this comparison."))
                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { showsSaveRegion = false }
                Button(L("保存", "Save")) { saveRegion() }
                    .buttonStyle(.borderedProminent).disabled(!validRegionName)
            }
        }.padding(18).frame(width: 300)
    }
    private var validRegionName: Bool {
        let value = regionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.utf8.count <= 256
    }
    private func saveRegion() {
        guard validRegionName else { return }
        model.saveRegion(name: regionName); showsSaveRegion = false
    }

    private func photograph(_ image: PhotoDecodedImage, url: URL, side: PhotoComparisonModel.Side, region: PhotoRegion) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(side == .left ? "A" : "B").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: side == .left ? theme.photoLeft : theme.photoRight))
                Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(previewTitle).font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(Color(nsColor: theme.secondaryText)).help(previewTitle)
                Text(region == .full ? L("全图", "Whole Image") : L("选区", "Region") + " · " + String(format: "%.1f%%", region.width * region.height * 100))
                    .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize()
                Button { inspectSide = side } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help(L("放大查看预览", "Inspect Preview"))
                    .accessibilityLabel(L("放大查看预览", "Inspect Preview"))
                    .disabled(model.isPreviewing || (side == .left ? model.leftDisplayImage : model.rightDisplayImage) == nil)
            }.padding(.horizontal, 14).frame(height: 36)
            PhotoRegionView(image: displayedImage(image, side: side), region: region) { model.selectRegion($0, side: side) }
                .overlay(alignment: .topTrailing) {
                    if model.isPreviewing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(L("更新预览…", "Updating preview…")).font(.system(size: 10))
                        }.padding(8).background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 6))
                            .padding(12).allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier(side == .left ? "photo.left.region" : "photo.right.region")
            HStack {
                Text("\(image.pixelWidth) × \(image.pixelHeight)").monospacedDigit()
                Spacer()
                Text(L("在照片上拖动，框选比较区域", "Drag on the photograph to compare a region"))
            }.font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                .padding(.horizontal, 14).frame(height: 26)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayedImage(_ image: PhotoDecodedImage, side: PhotoComparisonModel.Side) -> CGImage {
        (side == .left ? model.leftDisplayImage : model.rightDisplayImage) ?? image.preview
    }

    private var previewTitle: String {
        let title: String
        switch model.state.previewChannel {
        case .original: title = L("原图", "Original")
        case .red: title = L("红通道灰度", "Red Channel Grayscale")
        case .green: title = L("绿通道灰度", "Green Channel Grayscale")
        case .blue: title = L("蓝通道灰度", "Blue Channel Grayscale")
        }
        return title + (model.highlightedRange == nil ? "" : L(" · 区间高亮", " · Range Highlight"))
    }

    private var analysisPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(L("分析", "Analysis"), systemImage: "chart.xyaxis.line").font(.system(size: 12, weight: .medium))
                if model.isAnalyzing { ProgressView().controlSize(.mini) }
                if model.resultStatus == .partial {
                    Label(L("部分结果", "Partial Result"), systemImage: "exclamationmark.circle")
                        .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                if showsProfessional {
                    Picker(L("分析项目", "Analysis Section"), selection: $section) {
                        ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460).id(settings.language)
                }
                Spacer(minLength: 0)
                if model.highlightedRange != nil {
                    Button { model.clearHighlight() } label: {
                        Label(L("清除高亮", "Clear Highlight"), systemImage: "xmark.circle")
                    }.buttonStyle(.borderless).font(.system(size: 11))
                        .accessibilityIdentifier("photo.clear-highlight")
                }
                Button { showsAnalysisHelp.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("分析说明", "About This Analysis"))
                    .popover(isPresented: $showsAnalysisHelp) { analysisHelp }
                Button {
                    showsProfessional.toggle()
                    if !showsProfessional { section = .tone }
                } label: {
                    Label(showsProfessional ? L("收起专业图表", "Hide Details") : L("专业图表", "More Analysis"),
                          systemImage: showsProfessional ? "chevron.up" : "chevron.down")
                }.buttonStyle(.borderless).font(.system(size: 11))
                    .accessibilityIdentifier("photo.professional")
            }.padding(.horizontal, 16).frame(height: 38)
            Divider()
            if section == .tone { toneControls }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.previewError {
                        Label(localizedErrorDescription(error), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                    }
                    if let error = model.error {
                        Label(localizedErrorDescription(error), systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText))
                        Button(L("重试分析", "Retry Analysis")) { reload() }
                    } else if let first = model.leftStatistics, let second = model.rightStatistics {
                        switch section {
                        case .tone: tone(first, second)
                        case .color: color(first, second)
                        case .curves: curves
                        case .information: information(first, second)
                        }
                        if section == .tone {
                            analysisCaption(first, second)
                        }
                    } else {
                        HStack { Spacer(); Text(L("正在计算选区分布…", "Calculating region distributions…")); Spacer() }
                            .font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText)).padding(.vertical, 32)
                    }
                }.padding(.horizontal, 18).padding(.vertical, 14)
            }
        }.background(Color(nsColor: theme.canvas))
    }

    private var toneControls: some View {
        HStack(spacing: 12) {
            Picker(L("图表通道", "Chart Channel"), selection: $model.state.histogramChannel) {
                Text(L("明度 L*", "Lightness L*")).tag(PhotoHistogramChannel.perceptualLightness)
                Text("RGB").tag(PhotoHistogramChannel.rgb)
                Text("R").tag(PhotoHistogramChannel.red)
                Text("G").tag(PhotoHistogramChannel.green)
                Text("B").tag(PhotoHistogramChannel.blue)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 325).id(settings.language)
                .accessibilityIdentifier("photo.histogram-channel")
            Spacer(minLength: 0)
            Picker(L("图表布局", "Chart Layout"), selection: $model.state.histogramLayout) {
                Text(L("分开", "Separate")).tag(PhotoHistogramLayout.separated)
                Text(L("叠加", "Overlay")).tag(PhotoHistogramLayout.overlay)
                Text(L("分布差", "Difference")).tag(PhotoHistogramLayout.difference)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 236).id(settings.language)
                .accessibilityIdentifier("photo.histogram-layout")
        }.controlSize(.small).padding(.horizontal, 18).frame(height: 40)
            .background(Color(nsColor: theme.chrome))
            .onChange(of: model.state.histogramChannel) { _, _ in hoveredBin = nil }
    }

    private var analysisHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("读懂这组对比", "Reading This Comparison")).font(.headline)
            Text(L("两侧按各自有效像素数归一化，并共用刻度。悬停查看双方数值，拖选数值范围，在照片中定位对应像素。", "Both sides use the fraction of their own valid pixels and share a scale. Hover to compare values; drag across a range to locate matching pixels in the photographs."))
            Text(L("明度 L* 是 CIELAB 感知明度，范围 0–100。摘要来自分箱统计，分位值为估计；它不是拍摄曝光或相机动态范围。HSL 明度仍在专业色彩分析中提供。", "Lightness L* is CIELAB perceptual lightness, from 0 to 100. Summaries use binned statistics and estimated percentiles, not exposure or camera dynamic range. HSL lightness remains available under Color analysis."))
            Text(L("分析采用统一 sRGB SDR 范围。高亮仅用于观察，不改变选区或统计。不同主体和构图会影响分布；RAW 使用 Apple 默认显影，端点不代表传感器过曝。", "Analysis uses a common sRGB SDR range. Highlighting does not change regions or statistics. Subjects and composition affect distributions. RAW uses Apple's default rendering; endpoints do not establish sensor clipping."))
            Text(L("预览最长边 2048 像素，统计选区最长边 4096 像素，分别采样。细小内容的屏幕高亮可能与统计占比略有差别。", "Preview images are sampled to a maximum edge of 2048 pixels; region statistics use up to 4096. Fine details in the highlighted preview may differ slightly from the measured fractions."))
        }.font(.system(size: 12)).foregroundStyle(Color(nsColor: theme.text)).padding(20).frame(width: 370)
    }

    private func tone(_ first: PhotoStatistics, _ second: PhotoStatistics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            toneSummary(first, second)
            Divider()
            if model.state.histogramChannel == .rgb {
                HStack(alignment: .top, spacing: 16) {
                    ForEach([PhotoHistogramChannel.red, .green, .blue], id: \.self) { channel in
                        pairedChart(channel, first, second).frame(maxWidth: .infinity)
                    }
                }
            } else {
                pairedChart(model.state.histogramChannel, first, second)
            }
            if let selected = model.highlightedRange {
                HStack(spacing: 8) {
                    Image(systemName: "viewfinder")
                    Text(highlightTitle(selected))
                    Spacer(minLength: 0)
                    Text(L("左", "Left") + " " + String(format: "%.1f%%", first.fraction(in: selected) * 100))
                        .foregroundStyle(Color(nsColor: theme.photoLeft))
                    Text(L("右", "Right") + " " + String(format: "%.1f%%", second.fraction(in: selected) * 100))
                        .foregroundStyle(Color(nsColor: theme.photoRight))
                }.font(.system(size: 11)).monospacedDigit().padding(.vertical, 3)
            }

        }
    }

    private func toneSummary(_ first: PhotoStatistics, _ second: PhotoStatistics) -> some View {
            HStack(alignment: .top, spacing: 22) {
                summaryColumn(L("明度中位值", "Median Lightness"),
                    left: first.percentile(0.5, channel: .perceptualLightness).map { $0 * 100 },
                    right: second.percentile(0.5, channel: .perceptualLightness).map { $0 * 100 }, suffix: "L*",
                    help: L("一半像素低于此明度；由 256 个分箱估算，不是曝光值。", "Half the pixels fall below this lightness. Estimated from 256 bins, not an exposure value."))
                summaryColumn(L("明暗跨度", "Tonal Spread"), left: tonalSpread(first), right: tonalSpread(second), suffix: "L*",
                    help: L("P90 − P10：中间 80% 像素的感知明度跨度，不是相机动态范围。", "P90 − P10: perceptual lightness span of the middle 80% of pixels, not camera dynamic range."))
                let low = PhotoHistogramRange(channel: .perceptualLightness, lowerBin: 0, upperBin: 50)
                summaryColumn(L("低明度占比", "Low-lightness Share"),
                    left: first.fraction(in: low) * 100, right: second.fraction(in: low) * 100, suffix: "%",
                    help: L("L* < 约 20 的像素占比；不是欠曝判定。差值单位为百分点。", "Fraction of pixels at L* ≲ 20; not an underexposure diagnosis. Differences use percentage points."))
                let high = PhotoHistogramRange(channel: .perceptualLightness, lowerBin: 205, upperBin: 255)
                summaryColumn(L("高明度占比", "High-lightness Share"),
                    left: first.fraction(in: high) * 100, right: second.fraction(in: high) * 100, suffix: "%",
                    help: L("L* ≥ 约 80 的像素占比。明亮内容不等于过曝；差值单位为百分点。", "Fraction of pixels at L* ≳ 80. Bright content is not necessarily overexposed; the difference is in percentage points."))
            }
    }

    private func pairedChart(_ channel: PhotoHistogramChannel, _ first: PhotoStatistics, _ second: PhotoStatistics) -> some View {
        PhotoComparisonHistogram(title: channelTitle(channel), channel: channel,
            left: first.values(for: channel), right: second.values(for: channel), layout: model.state.histogramLayout,
            hoveredBin: $hoveredBin, selection: $model.highlightedRange)
    }

    private func highlightTitle(_ selected: PhotoHistogramRange) -> String {
        let lower = Double(selected.lowerBin) * 100.0 / 256.0
        let upper = Double(selected.upperBin + 1) * 100.0 / 256.0
        let range = String(format: "%.1f–%.1f", lower, upper)
        let unit = selected.channel == .perceptualLightness ? " L*" : "%"
        return L("高亮", "Highlight") + " · " + channelTitle(selected.channel) + " " + range + unit
    }

    private func channelTitle(_ channel: PhotoHistogramChannel) -> String {
        switch channel {
        case .perceptualLightness: return L("感知明度 · Lab L*", "Perceptual Lightness · Lab L*")
        case .rgb: return L("RGB 总览", "RGB Overview")
        case .red: return L("红通道 · R", "Red Channel · R")
        case .green: return L("绿通道 · G", "Green Channel · G")
        case .blue: return L("蓝通道 · B", "Blue Channel · B")
        }
    }

    private func tonalSpread(_ value: PhotoStatistics) -> Double? {
        guard let low = value.percentile(0.1, channel: .perceptualLightness),
              let high = value.percentile(0.9, channel: .perceptualLightness) else { return nil }
        return (high - low) * 100
    }

    private func summaryColumn(_ title: String, left: Double?, right: Double?, suffix: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            HStack(spacing: 9) {
                Text(left.map { String(format: "%.1f", $0) } ?? "—").foregroundStyle(Color(nsColor: theme.photoLeft))
                Text("→").foregroundStyle(Color(nsColor: theme.secondaryText))
                Text(right.map { String(format: "%.1f", $0) } ?? "—").foregroundStyle(Color(nsColor: theme.photoRight))
                Text(suffix).font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            }.font(.system(size: 14, weight: .medium)).monospacedDigit()
            if let left, let right {
                Text("Δ " + String(format: "%+.1f", right - left) + (suffix == "%" ? L(" 个百分点", " pp") : " L*"))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(Color(nsColor: theme.secondaryText))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).help(help)
    }

    private func analysisCaption(_ first: PhotoStatistics, _ second: PhotoStatistics) -> some View {
        HStack(spacing: 8) {
            Text(L("共同刻度 · sRGB SDR · 只读", "Shared scale · sRGB SDR · Read-only"))
            Spacer(minLength: 0)
            Text(first.sampled || second.sampled
                 ? L("采样统计 · 高亮为预览", "Sampled statistics · Preview highlights")
                 : L("选区统计 · 高亮为预览", "Region statistics · Preview highlights"))
        }.font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
    }

    private func color(_ first: PhotoStatistics, _ second: PhotoStatistics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 28) {
                colorCharts(first, hueMaximum: maximum(first.hue, second.hue), saturationMaximum: maximum(first.saturation, second.saturation))
                Rectangle().fill(Color(nsColor: theme.separator)).frame(width: 1)
                colorCharts(second, hueMaximum: maximum(first.hue, second.hue), saturationMaximum: maximum(first.saturation, second.saturation))
            }
            Text(L("HSL 描述当前像素的色相、饱和度和明度，不是修图软件中的调整滑块。饱和度低于 2% 的像素单独统计，色相分布不包含这些近中性色。", "HSL describes current pixel hue, saturation, and lightness, not editor adjustment sliders. Pixels below 2% saturation are counted separately and excluded from the hue distribution."))
                .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
        }
    }
    private func colorCharts(_ value: PhotoStatistics, hueMaximum: Double, saturationMaximum: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 20) {
                PhotoHistogram(title: L("色相 · H", "Hue · H"), series: [.init(values: value.hue, color: Color(nsColor: theme.accent))],
                               sharedMaximum: hueMaximum, lowerLabel: "0°", upperLabel: "360°")
                PhotoHistogram(title: L("饱和度 · S", "Saturation · S"), series: [.init(values: value.saturation, color: Color(nsColor: theme.accent))], sharedMaximum: saturationMaximum)
            }
            PhotoHistogram(title: L("明度 · HSL L", "Lightness · HSL L"),
                series: [.init(values: value.lightness, color: Color(nsColor: theme.accent))],
                sharedMaximum: maximum(model.leftStatistics?.lightness ?? [], model.rightStatistics?.lightness ?? []))
            Text(L("中性色占比", "Neutral Pixels") + "  " + String(format: "%.1f%%", value.neutralFraction * 100))
                .font(.system(size: 11)).monospacedDigit()
        }.frame(maxWidth: .infinity)
    }

    private var curves: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 28) {
                curveColumn(model.leftCurves, side: .left, path: model.state.leftXMPPath)
                Rectangle().fill(Color(nsColor: theme.separator)).frame(width: 1)
                curveColumn(model.rightCurves, side: .right, path: model.state.rightXMPPath)
            }
            Text(L("只显示文件或所选 XMP 中记录的控制点。连线仅为示意，不复现原软件的插值或显影效果。缺失记录不推测。", "Shows control points recorded in the image or selected XMP. Connecting lines are illustrative, not the original editor’s interpolation or rendering. Missing records are never inferred."))
                .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            ForEach(Array(model.curveWarnings.enumerated()), id: \.offset) { _, warning in
                Label(localizedErrorDescription(warning), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
        }
    }
    private func curveColumn(_ values: [PhotoRecordedCurve], side: PhotoComparisonModel.Side, path: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(L("选择 XMP…", "Choose XMP…")) { model.selectXMP(side: side) }
                    .controlSize(.small)
                if let path {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption).lineLimit(1)
                    Button { model.clearXMP(side: side) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help(L("移除旁路记录", "Remove Sidecar"))
                }
            }
            if values.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2)
                    Text(L("未记录处理曲线", "No Recorded Processing Curves")).font(.system(size: 12, weight: .medium))
                    Text(L("可选择照片对应的 XMP 文件", "You can select this photograph’s XMP file")).font(.caption)
                }.foregroundStyle(Color(nsColor: theme.secondaryText))
                    .frame(maxWidth: .infinity).padding(.vertical, 26)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(values) { PhotoRecordedCurveChart(curve: $0) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func information(_ first: PhotoStatistics, _ second: PhotoStatistics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text(L("文件记录", "File Records")).frame(width: 148, alignment: .leading)
                Text(L("A · 左侧", "A · Left")).foregroundStyle(Color(nsColor: theme.photoLeft))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("B · 右侧", "B · Right")).foregroundStyle(Color(nsColor: theme.photoRight))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8)
            VStack(spacing: 2) {
                ForEach(metadataFields, id: \.0) { field in
                    metadataComparisonRow(field.0, label: field.1,
                        left: metadataValue(field.0, image: model.leftImage),
                        right: metadataValue(field.0, image: model.rightImage))
                }
            }
            Text(L("圆点标记不同项；缺失值显示“未记录”。拍摄参数来自文件，不根据画面推测。", "Dots mark differences; absent values say “Not recorded”. Capture settings come from the file, never from estimates of the picture."))
                .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            Divider()
            Text(L("分析条件", "Analysis Conditions")).font(.system(size: 12, weight: .medium))
            VStack(spacing: 2) {
                metadataComparisonRow("analysisSpace", label: L("分析色彩空间", "Analysis Space"), left: first.analysisSpace, right: second.analysisSpace)
                metadataComparisonRow("sampleSize", label: L("分析尺寸", "Sample Dimensions"),
                    left: "\(first.sampleWidth) × \(first.sampleHeight)", right: "\(second.sampleWidth) × \(second.sampleHeight)")
                metadataComparisonRow("sampleCount", label: L("有效像素", "Valid Pixels"), left: "\(first.analyzedPixels)", right: "\(second.analyzedPixels)")
                metadataComparisonRow("sampled", label: L("采样", "Sampling"),
                    left: first.sampled ? L("有界采样", "Bounded Sampling") : L("选区全部像素", "All Region Pixels"),
                    right: second.sampled ? L("有界采样", "Bounded Sampling") : L("选区全部像素", "All Region Pixels"))
            }
            ForEach(Array((model.leftImage?.diagnostics ?? []).enumerated()), id: \.offset) { _, diagnostic in
                Text(L("左侧：", "Left: ") + diagnostic.localized).font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            ForEach(Array((model.rightImage?.diagnostics ?? []).enumerated()), id: \.offset) { _, diagnostic in
                Text(L("右侧：", "Right: ") + diagnostic.localized).font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            Divider()
            Text(L("插件分析 · HSL", "Plugin Analysis · HSL")).font(.system(size: 12, weight: .medium))
            ForEach(Array(model.findings.enumerated()), id: \.offset) { _, finding in
                Text(finding.localized).font(.system(size: 11))
            }
            ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Label(diagnostic.localized, systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
        }
    }

    private var metadataFields: [(String, String)] {
        [("cameraMake", L("厂商", "Manufacturer")), ("camera", L("相机", "Camera")),
         ("lens", L("镜头", "Lens")), ("shutter", L("快门", "Shutter")),
         ("aperture", L("光圈", "Aperture")), ("iso", "ISO"),
         ("exposureBias", L("曝光补偿", "Exposure Bias")), ("focalLength", L("焦距", "Focal Length")),
         ("whiteBalance", L("白平衡模式", "White Balance")), ("dimensions", L("像素尺寸", "Pixel Dimensions")),
         ("profile", L("颜色配置", "Color Profile")), ("depth", L("源文件位深", "Source Bit Depth"))]
    }

    private func metadataValue(_ id: String, image: PhotoDecodedImage?) -> String? {
        guard let value = image?.metadata.first(where: { $0.id == id })?.value else { return nil }
        if id == "whiteBalance" {
            if value == "0" { return L("自动", "Auto") }
            if value == "1" { return L("手动", "Manual") }
        }
        return value
    }

    private func metadataComparisonRow(_ id: String, label: String, left: String?, right: String?) -> some View {
        let differs = left != right
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            HStack(spacing: 5) {
                Text(label)
                if differs { Circle().fill(Color(nsColor: theme.accent)).frame(width: 4, height: 4) }
            }.foregroundStyle(Color(nsColor: theme.secondaryText)).frame(width: 148, alignment: .leading)
            Text(left ?? L("未记录", "Not recorded")).textSelection(.enabled)
                .foregroundStyle(Color(nsColor: left == nil ? theme.secondaryText : (differs ? theme.photoLeft : theme.text)))
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("photo.metadata.\(id).left")
            Text(right ?? L("未记录", "Not recorded")).textSelection(.enabled)
                .foregroundStyle(Color(nsColor: right == nil ? theme.secondaryText : (differs ? theme.photoRight : theme.text)))
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("photo.metadata.\(id).right")
        }.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 7)
            .background(Color(nsColor: theme.accent).opacity(differs ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 4))
    }
    private func maximum(_ arrays: [Double]...) -> Double { arrays.flatMap { $0 }.max() ?? 0 }
    private func reload() {
        model.invalidateSources()
        Task { await model.load(left: left, right: right, execute: execute, executionID: executionID) }
    }
}
