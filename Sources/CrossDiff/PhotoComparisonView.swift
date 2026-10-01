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
                    analysisPanel.frame(minHeight: 215, idealHeight: 270, maxHeight: 440)
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
        .task(id: [left.absoluteString, right.absoluteString, executionID]) {
            await model.load(left: left, right: right, execute: execute, executionID: executionID)
        }
        .onDisappear { model.cancel() }
        .sheet(isPresented: Binding(get: { inspectSide != nil }, set: { if !$0 { inspectSide = nil } })) {
            if inspectSide == .left, let image = model.leftImage {
                PhotoPreviewInspector(image: image.preview, name: left.lastPathComponent)
            } else if let image = model.rightImage {
                PhotoPreviewInspector(image: image.preview, name: right.lastPathComponent)
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
                .frame(maxWidth: 160)
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
            Text(L("只读", "Read-only")).font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
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
                Image(systemName: "photo").foregroundStyle(Color(nsColor: theme.secondaryText))
                Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(region == .full ? L("全图", "Whole Image") : L("选区", "Region") + " · " + String(format: "%.1f%%", region.width * region.height * 100))
                    .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize()
                Button { inspectSide = side } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help(L("放大查看预览", "Inspect Preview"))
                    .accessibilityLabel(L("放大查看预览", "Inspect Preview"))
            }.padding(.horizontal, 14).frame(height: 36)
            PhotoRegionView(image: image.preview, region: region) { model.selectRegion($0, side: side) }
                .accessibilityIdentifier(side == .left ? "photo.left.region" : "photo.right.region")
            HStack {
                Text("\(image.pixelWidth) × \(image.pixelHeight)").monospacedDigit()
                Spacer()
                Text(L("在照片上拖动，框选比较区域", "Drag on the photograph to compare a region"))
            }.font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                .padding(.horizontal, 14).frame(height: 26)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                } else {
                    Text(L("相同刻度 · 有效像素占比", "Shared scale · Fraction of valid pixels"))
                        .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                Spacer(minLength: 0)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                            findings
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                Text(L("明度为 HSL L，不是曝光值；成片分布不能还原原作者的调色参数。", "Lightness is HSL L, not exposure. Image distributions do not recover the creator’s editing settings."))
                            }.font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                            if first.sampled || second.sampled {
                                Text(L("当前结果经过有界采样；分析尺寸见“拍摄与分析信息”。", "These results use bounded sampling. See Image & Analysis for sample dimensions."))
                                    .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                            }
                        }
                    } else {
                        HStack { Spacer(); Text(L("正在计算选区分布…", "Calculating region distributions…")); Spacer() }
                            .font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText)).padding(.vertical, 32)
                    }
                }.padding(.horizontal, 18).padding(.vertical, 14)
            }
        }.background(Color(nsColor: theme.canvas))
    }

    private var findings: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(model.findings.prefix(3).enumerated()), id: \.offset) { _, finding in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(Color(nsColor: theme.accent)).frame(width: 4, height: 4)
                    Text(finding.localized).font(.system(size: 11)).textSelection(.enabled)
                }
            }
        }
    }

    private func tone(_ first: PhotoStatistics, _ second: PhotoStatistics) -> some View {
        let rgbMax = maximum(first.red, first.green, first.blue, second.red, second.green, second.blue)
        let lightMax = maximum(first.lightness, second.lightness)
        return HStack(alignment: .top, spacing: 28) {
            toneCharts(first, rgbMaximum: rgbMax, lightMaximum: lightMax)
            Rectangle().fill(Color(nsColor: theme.separator)).frame(width: 1)
            toneCharts(second, rgbMaximum: rgbMax, lightMaximum: lightMax)
        }
    }
    private func toneCharts(_ value: PhotoStatistics, rgbMaximum: Double, lightMaximum: Double) -> some View {
        HStack(alignment: .top, spacing: 20) {
            PhotoHistogram(title: L("RGB 分布", "RGB Distribution"), series: [
                .init(values: value.red, color: Color(red: 0.85, green: 0.31, blue: 0.33)),
                .init(values: value.green, color: Color(red: 0.25, green: 0.65, blue: 0.43)),
                .init(values: value.blue, color: Color(red: 0.32, green: 0.53, blue: 0.88))], sharedMaximum: rgbMaximum)
            PhotoHistogram(title: L("明度分布 · HSL L", "Lightness · HSL L"),
                           series: [.init(values: value.lightness, color: Color(nsColor: theme.accent))], sharedMaximum: lightMaximum)
        }.frame(maxWidth: .infinity)
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
            HStack(alignment: .top, spacing: 28) {
                informationColumn(model.leftImage, statistics: first)
                Rectangle().fill(Color(nsColor: theme.separator)).frame(width: 1)
                informationColumn(model.rightImage, statistics: second)
            }
            Divider()
            ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Label(diagnostic.localized, systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            ForEach(Array(model.findings.dropFirst(3).enumerated()), id: \.offset) { _, finding in
                Text(finding.localized).font(.system(size: 11))
            }
        }
    }
    private func informationColumn(_ image: PhotoDecodedImage?, statistics: PhotoStatistics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            informationRow(L("分析色彩空间", "Analysis Color Space"), statistics.analysisSpace)
            informationRow(L("分析尺寸", "Analysis Dimensions"), "\(statistics.sampleWidth) × \(statistics.sampleHeight)")
            informationRow(L("有效像素", "Valid Pixels"), "\(statistics.analyzedPixels)")
            informationRow(L("采样", "Sampling"), statistics.sampled ? L("有界采样", "Bounded Sampling") : L("所选区域完整像素", "Full Selected Region"))
            Divider()
            if let image {
                ForEach(image.metadata) { informationRow($0.label.localized, $0.value) }
                ForEach(Array(image.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Label(diagnostic.localized, systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
            }
            Text(L("未显示的拍摄参数可能未记录。画面统计不能确定快门、色温或曝光调整值。", "Omitted capture settings may not be recorded. Pixel statistics cannot determine shutter speed, color temperature, or exposure adjustments."))
                .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func informationRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(Color(nsColor: theme.secondaryText)).frame(width: 105, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
    }
    private func maximum(_ arrays: [Double]...) -> Double { arrays.flatMap { $0 }.max() ?? 0 }
    private func reload() {
        model.invalidateSources()
        Task { await model.load(left: left, right: right, execute: execute, executionID: executionID) }
    }
}
