import SwiftUI
import CrossDiffCore

@MainActor
struct AudioComparisonView: View {
    let left: URL
    let right: URL
    @ObservedObject var model: AudioComparisonModel
    let execute: @Sendable ([PluginInput], [String: PluginJSONValue]) async throws -> PluginComparisonResult
    let executionID: String
    @ObservedObject private var appearance = AppAppearance.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @State private var spectrogram = false
    @State private var showsParameters = false
    @State private var showsSpectrum = false
    @State private var showsSave = false
    @State private var regionName = ""
    @State private var leftViewport: AudioRegion?
    @State private var rightViewport: AudioRegion?
    @State private var reloadID = UUID()
    private var theme: ComparisonTheme { appearance.colors }
    private var matches: [AudioCorrespondence] { model.comparison?.correspondences ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L("正在读取音频与生成波形…", "Reading audio and building waveforms…"))
                        .foregroundStyle(Color(nsColor: theme.secondaryText))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let first = model.leftSource, let second = model.rightSource {
                ScrollView {
                    VStack(spacing: 12) {
                        track(first, side: .left)
                        track(second, side: .right)
                        if showsSpectrum { spectrumPanel }
                        correspondencePanel
                        if let error = model.error {
                            Label(localizedErrorDescription(error), systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: true)))
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }.padding(16)
                }
                Divider()
                AudioTransportBar(model: model, playback: model.playback, theme: theme)
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(L("无法读取音频", "Unable to Read Audio"), systemImage: "waveform.badge.exclamationmark")
                } description: { Text(localizedErrorDescription(error)) }
                actions: { Button(L("重新读取", "Reload")) { reload() } }
            } else {
                ContentUnavailableView(L("音频对比", "Audio Compare"), systemImage: "waveform")
            }
        }
        .foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
        .task(id: "\(left.absoluteString)-\(right.absoluteString)-\(executionID)-\(reloadID)") {
            await model.load(left: left, right: right, execute: execute, executionID: executionID)
        }
        .onDisappear { model.stop(); model.cancel() }
        .onChange(of: model.state.leftRegion) { _, region in
            if let region, let viewport = leftViewport,
               region.start < viewport.start || region.end > viewport.end { leftViewport = region }
        }
        .onChange(of: model.state.rightRegion) { _, region in
            if let region, let viewport = rightViewport,
               region.start < viewport.start || region.end > viewport.end { rightViewport = region }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(L("音频", "Audio"), systemImage: "waveform").font(.system(size: 13, weight: .medium))
            Picker(L("显示方式", "Display"), selection: $spectrogram) {
                Text(L("波形", "Waveform")).tag(false)
                Text(L("时频图", "Spectrogram")).tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 182)
                .accessibilityIdentifier("audio.showSpectrogram").id(appSettings.language)
            Button { model.runMatching() } label: {
                Label(L("查找对应片段", "Find Matches"), systemImage: "point.3.connected.trianglepath.dotted")
            }.accessibilityIdentifier("audio.findMatches").disabled(model.isLoading || model.isMatching || model.leftSource == nil)
            if model.isMatching {
                ProgressView().controlSize(.small)
                Button { model.cancelMatching() } label: { Image(systemName: "xmark") }
                    .help(L("取消匹配", "Cancel Matching")).accessibilityLabel(L("取消匹配", "Cancel Matching"))
            }
            Spacer(minLength: 4)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help(L("撤销音频调整", "Undo Audio Adjustment")).accessibilityIdentifier("audio.undo")
                .accessibilityLabel(L("撤销音频调整", "Undo Audio Adjustment"))
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help(L("重做音频调整", "Redo Audio Adjustment")).accessibilityIdentifier("audio.redo")
                .accessibilityLabel(L("重做音频调整", "Redo Audio Adjustment"))
            Button { showsParameters.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help(L("分析参数", "Analysis Settings")).accessibilityLabel(L("分析参数", "Analysis Settings"))
                .accessibilityIdentifier("audio.parameters").popover(isPresented: $showsParameters) { parameters }
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .help(L("重新读取音频", "Reload Audio")).accessibilityLabel(L("重新读取音频", "Reload Audio"))
                .disabled(model.isLoading).accessibilityIdentifier("audio.reload")
        }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 16).frame(height: 46)
            .background(Color(nsColor: theme.chrome))
    }

    private func track(_ source: AudioDecodedSource, side: AudioComparisonSide) -> some View {
        let isLeft = side == .left
        let selection = isLeft ? model.state.leftRegion : model.state.rightRegion
        let viewport = (isLeft ? leftViewport : rightViewport)?.clipped(to: source.duration)
            ?? AudioRegion(start: 0, end: source.duration)
        let spectrum = isLeft ? model.leftSpectrum : model.rightSpectrum
        let accent = Color(nsColor: isLeft ? theme.accent : theme.differenceForeground(isRemoval: false))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(isLeft ? "A" : "B").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent).frame(width: 26, height: 26).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.metadata.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text("\(source.metadata.format.uppercased()) · \(String(format: "%.1f kHz", source.sampleRate / 1000)) · \(source.channelCount) \(L("声道", "ch"))")
                        .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                Spacer()
                Text(AudioChartFormat.time(source.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(nsColor: theme.secondaryText))
                Button {
                    if isLeft { leftViewport = selection } else { rightViewport = selection }
                } label: { Image(systemName: "plus.magnifyingglass") }
                    .help(L("放大选区，仅改变视图", "Zoom to Selection; View Only")).disabled(selection == nil || spectrogram)
                Button {
                    if isLeft { leftViewport = nil } else { rightViewport = nil }
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(L("显示全长", "Show Full Duration")).disabled(spectrogram)
            }.buttonStyle(.borderless).controlSize(.small)
            Group {
                if spectrogram {
                    if let spectrum {
                        AudioSpectrogramChart(analysis: spectrum, settings: model.state.settings, theme: theme).frame(height: 144)
                        AudioTimeRuler(region: spectrum.region, theme: theme).padding(.leading, 59)
                        HStack {
                            Text(L("声道功率平均 · 显示桶峰值", "Channel power mean · Display-bin peaks") +
                                 String(format: " · ≤ %.1f kHz", min(spectrum.sourceNyquist, 24000) / 1000))
                            Spacer()
                            Text("\(Int(model.state.settings.minimumDB)) … \(Int(model.state.settings.maximumDB)) dBFS")
                        }.font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                        if spectrum.isPartial {
                            Text(L("仅分析上方标注范围；缩小或移动选区可查看其他片段。", "Only the labeled range is analyzed. Select a smaller or different region to inspect more."))
                                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                        }
                    } else if model.isAnalyzing {
                        ProgressView(L("正在计算 STFT…", "Computing STFT…")).frame(maxWidth: .infinity).frame(height: 164)
                    } else {
                        Text(L("频谱分析未完成，请重新读取或调整选区。", "Spectrum analysis is unavailable. Reload or adjust the region."))
                            .font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText)).frame(maxWidth: .infinity).frame(height: 164)
                    }
                } else {
                    AudioWaveformChart(source: source, selection: selection, visibleRange: viewport,
                                       correspondences: matches, isLeft: isLeft, theme: theme) { model.selectRegion($0, side: side) }
                        .frame(height: 116)
                        .overlay { AudioPlayheadOverlay(playback: model.playback, side: side, region: viewport, color: accent) }
                    AudioTimeRuler(region: viewport, theme: theme)
                }
            }
            regionFields(source, side: side, selection: selection)
        }.padding(14).background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: theme.separator).opacity(0.8), lineWidth: 0.7))
    }

    private func regionFields(_ source: AudioDecodedSource, side: AudioComparisonSide, selection: AudioRegion?) -> some View {
        let chosen = selection ?? AudioRegion(start: 0, end: source.duration)
        return HStack(spacing: 8) {
            Text(L("选区", "Region")).foregroundStyle(Color(nsColor: theme.secondaryText))
            regionField(chosen.start, source: source, side: side, isStart: true)
            Text("–").foregroundStyle(Color(nsColor: theme.secondaryText))
            regionField(chosen.end, source: source, side: side, isStart: false)
            Text("s").foregroundStyle(Color(nsColor: theme.secondaryText))
            Text(String(format: "%.2f s", chosen.duration)).foregroundStyle(Color(nsColor: theme.secondaryText)).padding(.leading, 4)
            Spacer()
            Button { model.play(side: side) } label: { Label(L("试听", "Listen"), systemImage: "play.fill") }
                .accessibilityIdentifier(side == .left ? "audio.play.left" : "audio.play.right")
                .help(L("播放当前选区；A 保持原始声音，B 应用下方试听参数。", "Play this region. A stays original; B uses the audition settings below."))
        }.font(.system(size: 11)).textFieldStyle(.roundedBorder).buttonStyle(.bordered).controlSize(.small)
    }

    private func regionField(_ value: Double, source: AudioDecodedSource, side: AudioComparisonSide, isStart: Bool) -> some View {
        TextField(isStart ? L("起点", "Start") : L("终点", "End"), value: Binding(get: { value }, set: { newValue in
            var selected = (side == .left ? model.state.leftRegion : model.state.rightRegion) ?? AudioRegion(start: 0, end: source.duration)
            if isStart { selected.start = newValue } else { selected.end = newValue }
            guard selected.validated(duration: source.duration) else { return }
            model.selectRegion(selected, side: side)
        }), format: .number.precision(.fractionLength(0...3)))
            .font(.system(size: 11, design: .monospaced)).frame(width: 76)
            .accessibilityIdentifier("audio.region.\(side.rawValue).\(isStart ? "start" : "end")")
    }

    private var correspondencePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(L("片段对应", "Corresponding Regions"), systemImage: "link").font(.system(size: 12, weight: .medium))
                Text("\(matches.count)").font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color(nsColor: theme.chrome), in: Capsule())
                Spacer()
                Toggle(L("联动选区", "Link Regions"), isOn: $model.state.linkedRegions).toggleStyle(.checkbox)
                    .help(L("按相同源时间联动后续选择，不代表自动匹配。", "Link future selections by source time; this is not automatic matching."))
                Menu {
                    if model.state.regions.isEmpty { Text(L("尚未保存区域", "No Saved Regions")) }
                    ForEach(model.state.regions) { pair in Button(pair.name) { model.applyRegion(id: pair.id) } }
                    if !model.state.regions.isEmpty {
                        Divider()
                        Menu(L("删除区域", "Delete Region")) {
                            ForEach(model.state.regions) { pair in Button(pair.name, role: .destructive) { model.deleteRegion(id: pair.id) } }
                        }
                    }
                } label: { Label(L("已存区域", "Saved Regions"), systemImage: "rectangle.stack") }
                Button {
                    regionName = L("片段", "Passage") + " \(model.state.regions.count + 1)"; showsSave = true
                } label: { Image(systemName: "plus") }
                    .help(L("保存当前区域对", "Save Region Pair")).accessibilityLabel(L("保存当前区域对", "Save Region Pair"))
                    .accessibilityIdentifier("audio.saveRegions").disabled(model.state.regions.count >= 32)
                    .popover(isPresented: $showsSave) { savePopover }
                Button { model.resetRegions(); leftViewport = nil; rightViewport = nil } label: { Image(systemName: "arrow.counterclockwise") }
                    .help(L("重置选区", "Reset Regions")).accessibilityLabel(L("重置选区", "Reset Regions"))
                    .accessibilityIdentifier("audio.resetRegions")
            }.font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
            if model.isMatching {
                HStack { ProgressView().controlSize(.small); Text(L("正在本机寻找共同片段…", "Finding shared passages on your Mac…")) }
                    .font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText))
            } else if matches.isEmpty {
                Text(model.comparison?.analysisState == .idle || model.comparison == nil
                     ? L("拖动波形选择片段，或点击“查找对应片段”自动定位。", "Drag across a waveform to select a passage, or choose Find Matches.")
                     : L("未找到可靠对应。可以手动选择两侧片段继续比较。", "No reliable matches found. Select regions manually to continue comparing."))
                    .font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText))
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, pair in
                        Button { model.selectCorrespondence(pair) } label: {
                            HStack(spacing: 12) {
                                Text(String(format: "%02d", index + 1)).foregroundStyle(Color(nsColor: theme.secondaryText)).frame(width: 24)
                                Text("A  \(AudioChartFormat.time(pair.left.start)) – \(AudioChartFormat.time(pair.left.end))")
                                    .foregroundStyle(Color(nsColor: theme.accent))
                                Image(systemName: "arrow.left.arrow.right").foregroundStyle(Color(nsColor: theme.secondaryText))
                                Text("B  \(AudioChartFormat.time(pair.right.start)) – \(AudioChartFormat.time(pair.right.end))")
                                    .foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: false)))
                                Spacer()
                                Text(L("候选对应", "Candidate")).font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                            }.font(.system(size: 11, design: .monospaced)).padding(9)
                                .background(Color(nsColor: theme.chrome), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("audio.match.\(index)")
                    }
                }
            }
            if let result = model.comparison {
                Text(result.summary.localized).font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                ForEach(Array(result.diagnostics.enumerated()), id: \.offset) { _, value in
                    Text(value.localized).font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
            }
            Text(L("自动匹配适用于未变速、未变调的同源录音；候选需要试听确认，未匹配不代表删除。", "Automatic matching targets same-source recordings at unchanged speed and pitch. Audition candidates to verify them; unmatched does not mean deleted."))
                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
        }.padding(14).background(Color(nsColor: theme.chrome).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var spectrumPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("选区平均频谱", "Average Region Spectrum")).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("A").foregroundStyle(Color(nsColor: theme.accent))
                Text("B").foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: false)))
                Text("\(Int(model.state.settings.minimumDB)) … \(Int(model.state.settings.maximumDB)) dBFS").foregroundStyle(Color(nsColor: theme.secondaryText))
            }.font(.system(size: 10, design: .monospaced))
            AudioAverageSpectrumChart(left: model.leftSpectrum, right: model.rightSpectrum, settings: model.state.settings, theme: theme)
                .frame(height: 110)
            HStack {
                Text(model.state.settings.frequencyScale == .logarithmic ? "20 Hz" : "0 Hz"); Spacer()
                Text(String(format: "%.1f kHz", min(model.leftSpectrum?.sourceNyquist ?? 24000, model.rightSpectrum?.sourceNyquist ?? 24000, 24000) / 1000))
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(nsColor: theme.secondaryText))
            Text(L("先在线性功率域平均，再转换为 dB。只比较图谱实际分析范围。", "Averaged in linear power before converting to dB. Uses only the analyzed regions."))
                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            HStack {
                spectrumRange(model.leftSpectrum, label: "A")
                Spacer()
                spectrumRange(model.rightSpectrum, label: "B")
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(nsColor: theme.secondaryText))
        }.padding(14).background(Color(nsColor: theme.chrome).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func spectrumRange(_ analysis: AudioSpectrumAnalysis?, label: String) -> Text {
        guard let analysis else { return Text(label + " · " + L("尚未分析", "Not analyzed")) }
        let range = "\(label)  \(AudioChartFormat.time(analysis.region.start)) – \(AudioChartFormat.time(analysis.region.end))"
        return Text(range + (analysis.isPartial ? " · " + L("部分选区", "Partial region") : ""))
    }

    private var parameters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("音频分析", "Audio Analysis")).font(.headline)
            Text(L("两侧共用参数与刻度；仅改变分析和显示。", "Both sources share parameters and scales. These affect analysis and display only."))
                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize(horizontal: false, vertical: true)
            Picker(L("FFT 窗长", "FFT Window"), selection: Binding(get: { model.state.settings.fftSize }, set: { value in
                var state = model.state; state.settings.fftSize = value
                state.settings.hopSize = min(state.settings.hopSize, value); model.state = state
            })) { ForEach([256, 512, 1024, 2048, 4096, 8192, 16384], id: \.self) { Text("\($0) · Hann").tag($0) } }
            Picker(L("步长", "Hop Size"), selection: $model.state.settings.hopSize) {
                ForEach(Array(Set([64, 128, 256, 512, 1024, 2048, 4096, model.state.settings.hopSize])).filter { $0 <= model.state.settings.fftSize }.sorted(), id: \.self) { Text("\($0)").tag($0) }
            }
            Picker(L("频率轴", "Frequency Axis"), selection: $model.state.settings.frequencyScale) {
                Text(L("对数", "Logarithmic")).tag(AudioFrequencyScale.logarithmic)
                Text(L("线性", "Linear")).tag(AudioFrequencyScale.linear)
            }.id(appSettings.language)
            Picker(L("显示范围", "Display Range"), selection: $model.state.settings.minimumDB) {
                ForEach(Array(Set([-60.0, -80, -100, -120, model.state.settings.minimumDB])).sorted(by: >), id: \.self) { value in
                    Text("\(Int(value)) … \(Int(model.state.settings.maximumDB)) dBFS").tag(value)
                }
            }
            Toggle(L("显示选区平均频谱", "Show Average Region Spectrum"), isOn: $showsSpectrum)
                .accessibilityIdentifier("audio.averageSpectrum")
            Button(L("清理音频临时文件", "Clear Audio Temporary Files")) { model.clearTemporaryFiles() }
                .disabled(model.isClearingCache).accessibilityIdentifier("audio.clearCache")
            if let message = model.cacheMessage { Text(message).font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText)) }
            Text(L("48 kHz 分析副本 · 最高 24 kHz\n每次最多分析选区前 30 秒；高密度参数会进一步限制范围。高于原始采样率一半的区域不作分析。", "48 kHz analysis copy · up to 24 kHz\nAnalyzes up to the first 30 seconds of a region; dense settings may reduce this range. Frequencies above the source Nyquist limit are not analyzed."))
                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize(horizontal: false, vertical: true)
            HStack { Button(L("恢复默认", "Restore Defaults")) { model.state.settings = .init() }; Spacer(); Button(L("完成", "Done")) { showsParameters = false } }
        }.padding(20).frame(width: 340).foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
    }
    private var savePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("保存区域对", "Save Region Pair")).font(.headline)
            TextField(L("区域名称", "Region Name"), text: $regionName).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("audio.regionName")
            Text(L("同时保存两侧选区与 B 的试听参数，仅保存在本机会话。", "Saves both regions and B's audition settings in this local session."))
                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            HStack {
                Spacer(); Button(L("取消", "Cancel")) { showsSave = false }
                Button(L("保存", "Save")) { model.saveRegion(name: regionName); showsSave = false }
                    .disabled(regionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || regionName.utf8.count > 256)
                    .accessibilityIdentifier("audio.confirmSave").buttonStyle(.borderedProminent)
            }
        }.padding(18).frame(width: 290)
    }
    private func reload() { model.invalidateSources(); reloadID = UUID(); leftViewport = nil; rightViewport = nil }
}

@MainActor
private struct AudioPlayheadOverlay: View {
    @ObservedObject var playback: AudioPlaybackController
    let side: AudioComparisonSide
    let region: AudioRegion
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            if playback.activeSide == side, playback.playhead >= region.start, playback.playhead <= region.end,
               playback.isPlaying || playback.playhead > region.start {
                Rectangle().fill(color).frame(width: 1.5)
                    .offset(x: (playback.playhead - region.start) / region.duration * geometry.size.width)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

@MainActor
private struct AudioTransportBar: View {
    @ObservedObject var model: AudioComparisonModel
    @ObservedObject var playback: AudioPlaybackController
    let theme: ComparisonTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    if playback.isPlaying { playback.pause() } else { model.play(side: playback.activeSide) }
                } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 16) }
                    .accessibilityLabel(playback.isPlaying ? L("暂停", "Pause") : L("播放", "Play"))
                Button { model.stop() } label: { Image(systemName: "stop.fill") }.accessibilityLabel(L("停止", "Stop"))
                HStack(spacing: 0) {
                    Button("A") { model.play(side: .left) }
                    Button("B") { model.play(side: .right) }
                }.help(L("切换试听源", "Switch Audition Source"))
                Text(AudioChartFormat.time(playback.playhead)).font(.system(size: 11, design: .monospaced)).frame(width: 75)
                Toggle(isOn: $playback.looping) { Image(systemName: "repeat") }.toggleStyle(.button)
                    .help(L("循环选区", "Loop Region")).accessibilityLabel(L("循环选区", "Loop Region"))
                Spacer()
                Text(L("原始音量 · 只读试听", "Original gain · Read-only audition")).font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            HStack(spacing: 10) {
                Text(L("B 试听", "B audition")).font(.system(size: 11, weight: .medium))
                Text(L("速度", "Rate")).font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                Slider(value: $model.state.rate, in: 0.25...4).frame(minWidth: 60, maxWidth: 130)
                    .accessibilityLabel(L("B 试听速度，保持音高", "B audition rate, preserving pitch"))
                TextField("×", value: $model.state.rate, format: .number.precision(.fractionLength(2))).frame(width: 53)
                    .accessibilityIdentifier("audio.rate")
                Text("×").font(.caption)
                Text(L("音高", "Pitch")).font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                Slider(value: $model.state.pitchSemitones, in: -24...24, step: 0.1).frame(minWidth: 60, maxWidth: 130)
                    .accessibilityLabel(L("B 试听音高，半音", "B audition pitch, semitones"))
                TextField(L("半音", "st"), value: $model.state.pitchSemitones, format: .number.precision(.fractionLength(1))).frame(width: 48)
                    .accessibilityIdentifier("audio.pitch")
                Text(L("半音", "st")).font(.caption)
                Spacer(minLength: 4)
                Button(L("匹配时长", "Match Duration")) {
                    guard let left = model.leftSource, let right = model.rightSource else { return }
                    let a = model.state.leftRegion?.duration ?? left.duration, b = model.state.rightRegion?.duration ?? right.duration
                    model.state.rate = max(0.25, min(4, b / a))
                }.help(L("按当前选区时长设置 B 的试听速度；保持音高。", "Set B's audition rate from the selected durations, preserving pitch."))
                Button { var state = model.state; state.rate = 1; state.pitchSemitones = 0; model.state = state } label: { Image(systemName: "arrow.counterclockwise") }
                    .help(L("恢复原始试听", "Reset Audition")).accessibilityLabel(L("恢复原始试听", "Reset Audition"))
            }.textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            if let error = playback.error {
                Text(localizedErrorDescription(error)).font(.caption).foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: true)))
            }
        }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 18).padding(.vertical, 10)
            .background(Color(nsColor: theme.chrome))
    }
}
