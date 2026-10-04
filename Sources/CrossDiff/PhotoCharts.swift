import SwiftUI
import CrossDiffCore

struct PhotoHistogram: View {
    struct Series { let values: [Double]; let color: Color }
    let title: String
    let series: [Series]
    let sharedMaximum: Double
    var lowerLabel = "0"
    var upperLabel = "1"
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ComparisonTheme { ComparisonTheme(isDark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                Text(String(format: "%.1f%%", sharedMaximum * 100))
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(Color(nsColor: theme.secondaryText))
                    .help(L("纵轴顶部：单个分箱的有效像素占比", "Top of vertical axis: fraction of valid pixels in a bin"))
            }
            Canvas { context, size in
                let baseline = size.height - 1
                var grid = Path()
                for fraction in [0.0, 0.5, 1.0] {
                    let y = baseline * fraction
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(Color(nsColor: theme.separator).opacity(0.65)), lineWidth: 0.5)
                guard sharedMaximum > 0, sharedMaximum.isFinite else { return }
                for item in series where item.values.count > 1 {
                    var line = Path()
                    for (index, value) in item.values.enumerated() {
                        let point = CGPoint(x: Double(index) / Double(item.values.count - 1) * size.width,
                                            y: baseline - min(1, max(0, value / sharedMaximum)) * baseline)
                        if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                    }
                    var area = line
                    area.addLine(to: CGPoint(x: size.width, y: baseline))
                    area.addLine(to: CGPoint(x: 0, y: baseline)); area.closeSubpath()
                    context.fill(area, with: .color(item.color.opacity(0.11)))
                    context.stroke(line, with: .color(item.color.opacity(0.9)), lineWidth: 1.2)
                }
            }
            .frame(height: 68)
            .accessibilityLabel(title)
            HStack { Text(lowerLabel); Spacer(); Text(upperLabel) }
                .font(.system(size: 9).monospacedDigit()).foregroundStyle(Color(nsColor: theme.secondaryText))
        }
    }
}


/// Compares two distributions already normalized by their own valid-pixel counts.
/// A bin always denotes the same value on both sides, including in separated mode.
struct PhotoComparisonHistogram: View {
    let title: String
    let channel: PhotoHistogramChannel
    let left: [Double]
    let right: [Double]
    let layout: PhotoHistogramLayout
    @Binding var hoveredBin: Int?
    @Binding var selection: PhotoHistogramRange?
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false
    @State private var pointerInside = false

    private let plotHeight: CGFloat = 112
    private let axisWidth: CGFloat = 43
    private var theme: ComparisonTheme { ComparisonTheme(isDark: colorScheme == .dark) }
    private var leftColor: Color { Color(nsColor: theme.photoLeft) }
    private var rightColor: Color { Color(nsColor: theme.photoRight) }
    private var secondaryColor: Color { Color(nsColor: theme.secondaryText) }
    private var activeSelection: PhotoHistogramRange? {
        guard let selection, selection.isValid, selection.channel == channel else { return nil }
        return selection
    }
    private var commonMaximum: Double {
        axisMaximum((left + right).filter { $0.isFinite && $0 > 0 }.max() ?? 0)
    }
    private var differenceMaximum: Double {
        axisMaximum((0..<256).map { abs(difference(at: $0)) }.max() ?? 0)
    }
    private var horizontalTitle: String {
        channel == .perceptualLightness ? L("感知明度 L*", "Perceptual lightness L*") : L("sRGB 通道强度 · %", "sRGB channel intensity · %")
    }
    private var verticalTitle: String {
        layout == .difference
            ? L("有效像素占比差 · 百分点（右 − 左）", "Valid-pixel fraction difference · pp (right − left)")
            : L("有效像素占比 · %", "Fraction of valid pixels · %")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            HStack(spacing: 16) {
                if layout == .difference {
                    legend("A > B", color: leftColor, dashed: false)
                        .help(L("负值：该分箱左侧 A 的像素占比更高；右减左，单位为百分点。", "Negative: left A has a larger pixel fraction in this bin. Right minus left, in percentage points."))
                        .accessibilityLabel(L("负值，左侧 A 占比高于右侧 B，单位为百分点", "Negative, left A has a larger fraction than right B, in percentage points"))
                    legend("B > A", color: rightColor, dashed: false)
                        .help(L("正值：该分箱右侧 B 的像素占比更高；右减左，单位为百分点。", "Positive: right B has a larger pixel fraction in this bin. Right minus left, in percentage points."))
                        .accessibilityLabel(L("正值，右侧 B 占比高于左侧 A，单位为百分点", "Positive, right B has a larger fraction than left A, in percentage points"))
                } else {
                    legend(L("A · 左", "A · Left"), color: leftColor, dashed: false)
                    legend(L("B · 右", "B · Right"), color: rightColor, dashed: true)
                }
            }
            Text(verticalTitle).font(.system(size: 10)).foregroundStyle(secondaryColor)
            if layout == .separated {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        plot(.left).frame(minWidth: 158)
                        plot(.right).frame(minWidth: 158)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        plot(.left)
                        plot(.right)
                    }
                }
            } else {
                plot(layout == .difference ? .difference : .overlay)
            }
            Text(readout)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(secondaryColor)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .help(L("范围采用 [下界, 上界) 表示：包含下界、不含上界；最后一箱包含 100。边界显示至一位小数。", "Ranges use [lower, upper): the lower bound is included and the upper bound is excluded, except the last bin includes 100. Displayed bounds are rounded to one decimal place."))
                .accessibilityLabel(readout)
                .accessibilityIdentifier("photo.histogram.\(channel.rawValue).readout")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { hoveredBin = nil; isDragging = false; pointerInside = false }
    }

    private enum Plot: String {
        case overlay, left, right, difference
    }

    private func legend(_ label: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 5))
                path.addLine(to: CGPoint(x: 22, y: 5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, dash: dashed ? [4, 3] : []))
            .frame(width: 22, height: 10)
            .accessibilityHidden(true)
            Text(label).font(.system(size: 10, weight: .medium))
        }
    }

    private func plot(_ kind: Plot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if kind == .left || kind == .right {
                Text(kind == .left ? L("A · 左", "A · Left") : L("B · 右", "B · Right"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(kind == .left ? leftColor : rightColor)
                    .padding(.leading, axisWidth + 5)
            }
            HStack(alignment: .top, spacing: 5) {
                verticalLabels(difference: kind == .difference)
                GeometryReader { geometry in
                    Canvas { context, size in
                        drawPlot(context: context, size: size, kind: kind)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            pointerInside = true
                            if !isDragging { hoveredBin = bin(at: location.x, width: geometry.size.width) }
                        case .ended:
                            pointerInside = false
                            if !isDragging { hoveredBin = nil }
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let start = bin(at: value.startLocation.x, width: geometry.size.width)
                            let end = bin(at: value.location.x, width: geometry.size.width)
                            hoveredBin = end
                            select(lower: min(start, end), upper: max(start, end))
                        }
                        .onEnded { value in
                            let start = bin(at: value.startLocation.x, width: geometry.size.width)
                            let end = bin(at: value.location.x, width: geometry.size.width)
                            select(lower: min(start, end), upper: max(start, end))
                            isDragging = false
                            hoveredBin = pointerInside ? end : nil
                        })
                    .contextMenu {
                        Button(L("高亮低值区间 · 约 0–10%", "Highlight low range · about 0–10%")) { select(lower: 0, upper: 25) }
                        Button(L("高亮高值区间 · 约 90–100%", "Highlight high range · about 90–100%")) { select(lower: 230, upper: 255) }
                        Divider()
                        Button(L("清除区间高亮", "Clear Range Highlight")) { selection = nil }
                            .disabled(selection == nil)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title + ", " + plotDescription(kind))
                    .accessibilityValue(readout)
                    .accessibilityHint(L("横轴从 0 到 100。分箱包含下界、不含上界，最后一箱包含 100。拖动选择区间，或使用低值、高值和清除区间动作。", "The horizontal axis runs from 0 to 100. Bins include the lower bound and exclude the upper bound, except that the last bin includes 100. Drag to select a range, or use the low range, high range, and clear range actions."))
                    .accessibilityAction(named: Text(L("高亮低值区间", "Highlight Low Range"))) { select(lower: 0, upper: 25) }
                    .accessibilityAction(named: Text(L("高亮高值区间", "Highlight High Range"))) { select(lower: 230, upper: 255) }
                    .accessibilityAction(named: Text(L("清除区间高亮", "Clear Range Highlight"))) { selection = nil }
                    .accessibilityIdentifier("photo.histogram.\(channel.rawValue).\(kind.rawValue)")
                }
                .frame(height: plotHeight)
            }
            HStack(spacing: 0) {
                Text("0")
                Spacer(minLength: 0)
                Text("50")
                Spacer(minLength: 0)
                Text("100")
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(secondaryColor)
            .padding(.leading, axisWidth + 5)
            Text(horizontalTitle)
                .font(.system(size: 10)).foregroundStyle(secondaryColor)
                .frame(maxWidth: .infinity)
                .padding(.leading, axisWidth + 5)
        }
    }

    private func verticalLabels(difference: Bool) -> some View {
        let maximum = difference ? differenceMaximum : commonMaximum
        return VStack(alignment: .trailing, spacing: 0) {
            Text(axisLabel(maximum, signed: difference))
            Spacer(minLength: 0)
            Text(difference ? "0" : axisLabel(maximum / 2))
            Spacer(minLength: 0)
            Text(difference ? axisLabel(-maximum) : "0")
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(secondaryColor)
        .frame(width: axisWidth, height: plotHeight, alignment: .trailing)
    }

    private func drawPlot(context: GraphicsContext, size: CGSize, kind: Plot) {
        guard size.width > 0, size.height > 0 else { return }
        let isDifference = kind == .difference
        let maximum = isDifference ? differenceMaximum : commonMaximum
        let baseline = isDifference ? size.height / 2 : size.height
        var grid = Path()
        for fraction in [0.0, 0.5, 1.0] {
            let y = size.height * fraction
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        grid.move(to: .zero)
        grid.addLine(to: CGPoint(x: 0, y: size.height))
        context.stroke(grid, with: .color(Color(nsColor: theme.separator)), lineWidth: 0.7)
        if let activeSelection {
            let lower = Double(activeSelection.lowerBin) / 256 * size.width
            let upper = Double(activeSelection.upperBin + 1) / 256 * size.width
            let rect = CGRect(x: lower, y: 0, width: max(1, upper - lower), height: size.height)
            context.fill(Path(rect), with: .color(Color(nsColor: theme.selectionBackground).opacity(0.65)))
            context.stroke(Path(rect), with: .color(Color(nsColor: theme.navigationOutline).opacity(0.8)), lineWidth: 0.8)
        }
        if isDifference {
            let line = path(values: (0..<256).map { difference(at: $0) }, size: size, maximum: maximum, difference: true)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: baseline))
            area.addLine(to: CGPoint(x: 0, y: baseline))
            area.closeSubpath()
            for positive in [true, false] {
                var clipped = context
                let rect = CGRect(x: 0, y: positive ? 0 : baseline, width: size.width, height: size.height / 2)
                clipped.clip(to: Path(rect))
                let color = positive ? rightColor : leftColor
                clipped.fill(area, with: .color(color.opacity(0.12)))
                clipped.stroke(line, with: .color(color), lineWidth: 1.5)
            }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: baseline))
            zero.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(zero, with: .color(secondaryColor.opacity(0.7)), lineWidth: 0.8)
        } else {
            if kind != .right { drawDistribution(left, color: leftColor, dashed: false, context: context, size: size, maximum: maximum) }
            if kind != .left { drawDistribution(right, color: rightColor, dashed: true, context: context, size: size, maximum: maximum) }
        }
        if let hoveredBin, (0..<256).contains(hoveredBin) {
            let x = (Double(hoveredBin) + 0.5) / 256 * size.width
            var guide = Path()
            guide.move(to: CGPoint(x: x, y: 0))
            guide.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(guide, with: .color(secondaryColor.opacity(0.8)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
            if isDifference {
                let value = difference(at: hoveredBin)
                drawPoint(x: x, y: baseline - value / maximum * baseline, color: value >= 0 ? rightColor : leftColor, context: context)
            } else {
                if kind != .right { drawPoint(x: x, y: size.height * (1 - value(left, at: hoveredBin) / maximum), color: leftColor, context: context) }
                if kind != .left { drawPoint(x: x, y: size.height * (1 - value(right, at: hoveredBin) / maximum), color: rightColor, context: context) }
            }
        }
    }

    private func drawDistribution(_ values: [Double], color: Color, dashed: Bool, context: GraphicsContext, size: CGSize, maximum: Double) {
        let line = path(values: values, size: size, maximum: maximum, difference: false)
        var area = line
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .color(color.opacity(0.08)))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : []))
    }

    private func path(values: [Double], size: CGSize, maximum: Double, difference: Bool) -> Path {
        var result = Path()
        for index in 0..<256 {
            let sample = values.indices.contains(index) && values[index].isFinite ? values[index] : 0
            let y = difference ? size.height / 2 * (1 - sample / maximum) : size.height * (1 - max(0, sample) / maximum)
            let point = CGPoint(x: (Double(index) + 0.5) / 256 * size.width, y: min(size.height, max(0, y)))
            if index == 0 { result.move(to: point) } else { result.addLine(to: point) }
        }
        return result
    }

    private func drawPoint(x: CGFloat, y: CGFloat, color: Color, context: GraphicsContext) {
        context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)), with: .color(color))
    }

    private func value(_ values: [Double], at index: Int) -> Double {
        guard values.indices.contains(index), values[index].isFinite else { return 0 }
        return max(0, values[index])
    }
    private func difference(at index: Int) -> Double { value(right, at: index) - value(left, at: index) }
    private func bin(at x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, x.isFinite else { return 0 }
        return min(255, Int((min(1, max(0, x / width)) * 256).rounded(.down)))
    }
    private func select(lower: Int, upper: Int) {
        guard selection?.channel != channel || selection?.lowerBin != lower || selection?.upperBin != upper else { return }
        selection = PhotoHistogramRange(channel: channel, lowerBin: lower, upperBin: upper)
    }
    private func axisMaximum(_ observed: Double) -> Double {
        // Keep an actual fraction scale even when both distributions are empty or identical.
        guard observed > 0, observed.isFinite else { return 0.001 }
        let magnitude = pow(10, floor(log10(observed)))
        let normalized = observed / magnitude
        let step = [1.0, 2.0, 5.0, 10.0].first { $0 >= normalized } ?? 10
        return min(1, step * magnitude)
    }
    private func axisLabel(_ fraction: Double, signed: Bool = false) -> String {
        let percent = fraction * 100
        if abs(percent) >= 1 { return String(format: signed ? "%+.1f" : "%.1f", percent) }
        return String(format: signed ? "%+.2f" : "%.2f", percent)
    }
    private func plotDescription(_ kind: Plot) -> String {
        switch kind {
        case .left: return L("A 左侧分布", "A left distribution")
        case .right: return L("B 右侧分布", "B right distribution")
        case .overlay: return L("左右叠加分布", "Left and right overlaid distributions")
        case .difference: return L("右减左占比差，单位百分点", "Right minus left fractions, in percentage points")
        }
    }
    private func percentages(left: Double, right: Double) -> String {
        "A " + String(format: "%.2f%%", left * 100) + "   B " + String(format: "%.2f%%", right * 100)
            + "   Δ " + String(format: "%+.2f", (right - left) * 100) + " " + L("百分点", "pp")
    }
    private func rangeLabel(lower: Int, upper: Int) -> String {
        // Bins are [lower/256, (upper+1)/256); the final bin also includes 1.
        let bounds = String(format: "[%.1f, %.1f", Double(lower) / 256 * 100, Double(upper + 1) / 256 * 100)
        return bounds + (upper == 255 ? "]" : ")") + (channel == .perceptualLightness ? " L*" : "%")
    }
    private var readout: String {
        if let hoveredBin, (0..<256).contains(hoveredBin) {
            return L("分箱", "Bin") + " " + rangeLabel(lower: hoveredBin, upper: hoveredBin)
                + "  ·  " + percentages(left: value(left, at: hoveredBin), right: value(right, at: hoveredBin))
        }
        if let activeSelection {
            let lower = max(0, min(255, activeSelection.lowerBin))
            let upper = max(lower, min(255, activeSelection.upperBin))
            let first = (lower...upper).reduce(0.0) { $0 + value(left, at: $1) }
            let second = (lower...upper).reduce(0.0) { $0 + value(right, at: $1) }
            return L("已选区间", "Selected range") + " " + rangeLabel(lower: lower, upper: upper)
                + "  ·  " + percentages(left: first, right: second)
        }
        return L("悬停查看同一分箱的左右占比与差值；拖动高亮区间。", "Hover to compare both fractions and their difference in one bin; drag to highlight a range.")
    }
}

struct PhotoRecordedCurveChart: View {
    let curve: PhotoRecordedCurve
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ComparisonTheme { ComparisonTheme(isDark: colorScheme == .dark) }
    private var color: Color {
        switch curve.name {
        case "Red": return .red
        case "Green": return .green
        case "Blue": return .blue
        default: return Color(nsColor: theme.accent)
        }
    }
    private var title: String {
        switch curve.name {
        case "Red": return L("红通道", "Red")
        case "Green": return L("绿通道", "Green")
        case "Blue": return L("蓝通道", "Blue")
        default: return curve.name
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium))
            Canvas { context, size in
                var diagonal = Path()
                diagonal.move(to: CGPoint(x: 0, y: size.height))
                diagonal.addLine(to: CGPoint(x: size.width, y: 0))
                context.stroke(diagonal, with: .color(Color(nsColor: theme.separator)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var path = Path()
                for (index, point) in curve.points.enumerated() {
                    let position = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                    context.fill(Path(ellipseIn: CGRect(x: position.x - 2.5, y: position.y - 2.5, width: 5, height: 5)), with: .color(color))
                }
                context.stroke(path, with: .color(color), lineWidth: 1.4)
            }
            .frame(height: 110).padding(5)
            .background(Color(nsColor: theme.chrome), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: theme.separator), lineWidth: 0.5))
            Text(curve.source).font(.system(size: 9)).foregroundStyle(Color(nsColor: theme.secondaryText)).lineLimit(2)
        }
    }
}
