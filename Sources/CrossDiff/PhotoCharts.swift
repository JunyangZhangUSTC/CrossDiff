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
