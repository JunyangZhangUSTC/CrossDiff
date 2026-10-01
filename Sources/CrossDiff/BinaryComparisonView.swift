import AppKit
import SwiftUI
import CrossDiffCore

@MainActor
struct BinaryComparisonView: View {
    let left: URL
    let right: URL
    @ObservedObject var model: BinaryComparisonModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @StateObject private var selection = BinaryHexSelection()
    @State private var address = ""
    @State private var addressSide = BinaryDataSide.left
    @State private var addressError: String?
    @State private var choseRowWidth = false
    @State private var reloadGeneration = 0
    @State private var startedReloadGeneration = 0
    private var theme: ComparisonTheme { appearance.colors }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                controls
                Divider()
                fileHeaders
                Divider()
                if model.isLoading {
                    VStack(spacing: 14) {
                        ProgressView(value: model.progress).frame(width: 220)
                        Text(L("正在比较文件字节…", "Comparing File Bytes…"))
                            .font(.system(size: 13, weight: .medium))
                        Text(model.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color(nsColor: theme.secondaryText))
                        Button(L("取消", "Cancel")) { model.cancel() }
                            .accessibilityIdentifier("binary.cancel")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.error {
                    ContentUnavailableView {
                        Label(L("无法比较二进制文件", "Unable to Compare Binary Files"), systemImage: "doc.badge.ellipsis")
                    } description: {
                        Text(localizedErrorDescription(error))
                    } actions: {
                        Button(L("重新读取", "Reload Files"), action: reload)
                    }
                } else if model.result != nil {
                    NativeHexView(page: model.page, layout: model.layout, selectedSpanIndex: model.selectedSpanIndex,
                                  requestedRow: model.requestedRow, navigationID: model.navigationID,
                                  theme: theme, selection: selection, requestRows: model.requestRows)
                } else {
                    ContentUnavailableView {
                        Label(model.isCancelled ? L("比较已取消", "Comparison Canceled") : L("二进制比较", "Binary Comparison"), systemImage: "number.square")
                    } actions: {
                        Button(L("开始比较", "Compare Files"), action: reload)
                    }
                }
                Divider()
                statusBar
            }
            .background(Color(nsColor: theme.canvas))
            .foregroundStyle(Color(nsColor: theme.text))
            .onAppear { adaptColumns(width: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in adaptColumns(width: width) }
        }
        .task(id: [left.absoluteString, right.absoluteString, String(reloadGeneration)]) {
            let force = reloadGeneration != startedReloadGeneration
            startedReloadGeneration = reloadGeneration
            await model.load(left: left, right: right, force: force)
        }
        .onChange(of: model.result == nil) { _, noResult in
            if noResult { selection.set(nil) }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Label(L("十六进制", "Hexadecimal"), systemImage: "number.square")
                .font(.system(size: 13, weight: .medium)).fixedSize()
            Text(L("只读", "Read Only"))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Color(nsColor: theme.secondaryText))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color(nsColor: theme.canvas), in: Capsule())
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                Text(L("每行", "Bytes/Row")).font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize()
                Picker(L("每行字节数", "Bytes per Row"), selection: Binding(get: { model.bytesPerRow }, set: {
                    choseRowWidth = true; model.bytesPerRow = $0
                })) {
                    Text("8").tag(8)
                    Text("16").tag(16)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 84)
                .accessibilityIdentifier("binary.columns")
            }
            HStack(spacing: 7) {
                Menu {
                    Button(L("左侧文件", "Left File")) { addressSide = .left; addressError = nil }
                    Button(L("右侧文件", "Right File")) { addressSide = .right; addressError = nil }
                } label: {
                    Text(addressSide == .left ? L("左侧", "Left") : L("右侧", "Right"))
                        .font(.system(size: 12)).foregroundStyle(Color(nsColor: theme.text))
                }
                .menuStyle(.borderlessButton).frame(width: 56)
                .accessibilityLabel(L("地址所属文件", "File for Address"))
                .accessibilityIdentifier("binary.addressSide")
                TextField(L("地址：0x20 或 32", "Address: 0x20 or 32"), text: $address)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: addressError == nil ? theme.separator : theme.differenceForeground(isRemoval: true)), lineWidth: 0.7))
                    .frame(width: 168)
                    .onSubmit(jump)
                    .onChange(of: address) { _, _ in addressError = nil }
                    .accessibilityLabel(L("字节地址（十六进制或十进制）", "Byte Address in Hexadecimal or Decimal"))
                    .accessibilityIdentifier("binary.address")
                Button(action: jump) { Image(systemName: "arrow.turn.down.right") }
                    .buttonStyle(.borderless).disabled(model.result == nil)
                    .help(L("跳转到字节地址", "Go to Byte Address"))
                    .accessibilityLabel(L("跳转到字节地址", "Go to Byte Address"))
                    .accessibilityIdentifier("binary.jump")
            }
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(model.isLoading)
                .help(L("重新读取并比较", "Reload and Compare"))
                .accessibilityLabel(L("重新读取二进制文件", "Reload Binary Files"))
                .accessibilityIdentifier("binary.reload")
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Color(nsColor: theme.chrome))
    }

    private var fileHeaders: some View {
        HStack(spacing: 0) {
            fileHeader(left, size: model.result?.leftSize, side: .left)
            Rectangle().fill(Color(nsColor: theme.separator)).frame(width: 1)
            fileHeader(right, size: model.result?.rightSize, side: .right)
            Color.clear.frame(width: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
        }
        .frame(height: 48)
        .background(Color(nsColor: theme.chrome))
    }
    private func fileHeader(_ url: URL, size: Int64?, side: BinaryDataSide) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "doc").foregroundStyle(Color(nsColor: theme.secondaryText))
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).help(url.path)
                Text(side == .left ? L("左侧文件", "Left File") : L("右侧文件", "Right File"))
                    .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            Spacer(minLength: 4)
            if let size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .binary))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Color(nsColor: theme.secondaryText))
                    .help(L("\(size) 字节", "\(size) bytes"))
            }
        }
        .padding(.horizontal, 16).frame(maxWidth: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let addressError {
                Label(addressError, systemImage: "exclamationmark.circle")
                    .foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: true)))
            } else if model.error == nil, model.result != nil, let selected = selection.value {
                Text(L("\(selected.side == .left ? "左侧" : "右侧") · 0x\(String(selected.range.lowerBound, radix: 16, uppercase: true)) · \(selected.bytes.count) 字节",
                       "\(selected.side == .left ? "Left" : "Right") · 0x\(String(selected.range.lowerBound, radix: 16, uppercase: true)) · \(selected.bytes.count) bytes"))
                    .monospacedDigit()
                Button { selection.copyHex() } label: { Label(L("复制十六进制", "Copy Hex"), systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("binary.copyHex")
            } else {
                Text(L("拖动选择字节 · ⌘C 复制十六进制", "Drag to Select Bytes · ⌘C to Copy Hex"))
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            Spacer(minLength: 4)
            if model.result?.alignmentIsApproximate == true {
                Label(L("部分粗对齐", "Some Coarse Alignment"), systemImage: "info.circle")
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
                    .help(L("复杂区域使用整块差异，插入与删除的对应位置可能不精确；这些区域不会标为相同。", "Complex regions use block-level differences. Insert/delete correspondence may be approximate; those regions are not marked as equal."))
            }
            if model.result != nil {
                if model.changeIndices.isEmpty {
                    Label(L("内容一致", "Identical Contents"), systemImage: "checkmark.circle")
                        .foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: false)))
                } else {
                    Text(L("\(model.changeIndices.count) 处差异 · 当前 \(model.selectedChange + 1)",
                           "\(model.changeIndices.count) changes · \(model.selectedChange + 1) selected"))
                        .monospacedDigit()
                }
            }
            Button { model.navigate(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(!model.canNavigate)
                .help(L("上一处差异", "Previous Difference"))
                .accessibilityLabel(L("上一处二进制差异", "Previous Binary Difference"))
                .accessibilityIdentifier("binary.previousDifference")
            Button { model.navigate(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(!model.canNavigate)
                .help(L("下一处差异", "Next Difference"))
                .accessibilityLabel(L("下一处二进制差异", "Next Binary Difference"))
                .accessibilityIdentifier("binary.nextDifference")
        }
        .font(.system(size: 11)).lineLimit(1)
        .padding(.horizontal, 16).frame(height: 34)
        .background(Color(nsColor: theme.chrome))
    }

    private func adaptColumns(width: CGFloat) {
        guard !choseRowWidth else { return }
        model.bytesPerRow = width < BinaryHexCanvas.minimumWidth(columns: 16) + 20 ? 8 : 16
    }
    private func jump() {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let radix = raw.lowercased().hasPrefix("0x") ? 16 : 10
        let digits = radix == 16 ? String(raw.dropFirst(2)) : raw
        guard let offset = Int64(digits, radix: radix), offset >= 0 else {
            addressError = L("请输入十进制地址或 0x 开头的十六进制地址", "Enter a decimal address or hexadecimal with a 0x prefix")
            return
        }
        guard let result = model.result else { return }
        let size = addressSide == .left ? result.leftSize : result.rightSize
        guard offset < size else {
            addressError = size == 0 ? L("此侧文件为空", "This File Is Empty") :
                L("地址超出范围，最大为 0x\(String(size - 1, radix: 16, uppercase: true))", "Address is out of range; maximum is 0x\(String(size - 1, radix: 16, uppercase: true))")
            return
        }
        addressError = nil; selection.set(nil)
        model.jump(to: offset, side: addressSide)
    }
    private func reload() {
        selection.set(nil); addressError = nil
        reloadGeneration += 1
    }
}
