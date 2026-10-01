import AppKit
import SwiftUI
import CrossDiffCore

/// Selection geometry is in oriented-image coordinates, independent of the
/// letterboxing and the preview resolution used by the window.
struct PhotoRegionView: View {
    let image: CGImage
    let region: PhotoRegion
    let select: (PhotoRegion) -> Void
    @State private var draft: PhotoRegion?
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ComparisonTheme { ComparisonTheme(isDark: colorScheme == .dark) }

    var body: some View {
        GeometryReader { geometry in
            let imageRect = fittedRect(in: geometry.size)
            let shown = draft ?? region
            ZStack(alignment: .topLeading) {
                Color(nsColor: theme.isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.91, alpha: 1))
                Image(decorative: image, scale: 1)
                    .resizable().interpolation(.high)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                if shown != .full {
                    let rect = displayRect(shown, in: imageRect)
                    Path { path in path.addRect(imageRect); path.addRect(rect) }
                        .fill(.black.opacity(0.24), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    Rectangle().stroke(.black.opacity(0.55), lineWidth: 3)
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                    Rectangle().stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    guard imageRect.contains(value.startLocation) else { return }
                    draft = selection(from: value.startLocation, to: value.location, in: imageRect)
                }
                .onEnded { _ in
                    if let draft, draft.isValid { select(draft) }
                    draft = nil
                })
            .accessibilityLabel(L("拖动框选分析区域", "Drag to select an analysis region"))
            .accessibilityValue(shown == .full ? L("全图", "Whole Image") : L("已选择局部区域", "Region Selected"))
        }.clipped()
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let scale = min(max(0, size.width - 24) / CGFloat(image.width), max(0, size.height - 24) / CGFloat(image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
    private func displayRect(_ region: PhotoRegion, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + region.x * rect.width, y: rect.minY + region.y * rect.height,
               width: region.width * rect.width, height: region.height * rect.height)
    }
    private func selection(from start: CGPoint, to end: CGPoint, in rect: CGRect) -> PhotoRegion? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = min(rect.maxX, max(rect.minX, end.x)), y = min(rect.maxY, max(rect.minY, end.y))
        let width = abs(x - start.x), height = abs(y - start.y)
        guard width >= 2, height >= 2 else { return nil }
        return PhotoRegion(x: (min(start.x, x) - rect.minX) / rect.width,
                           y: (min(start.y, y) - rect.minY) / rect.height,
                           width: width / rect.width, height: height / rect.height)
    }
}

struct PhotoPreviewInspector: View {
    let image: CGImage
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale = 1.0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).font(.headline).lineLimit(1)
                Spacer()
                Button { scale = max(0.25, scale / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help(L("缩小预览", "Zoom Out"))
                Text(String(format: "%.0f%%", scale * 100)).monospacedDigit().frame(width: 48)
                Button { scale = min(4, scale * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help(L("放大预览", "Zoom In"))
                Button(L("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    .padding(16)
            }.background(Color(white: 0.16))
            Text(L("显示的是解码预览；百分比相对于预览像素，不代表原始照片的 100% 细节。", "This is the decoded preview. Zoom is relative to preview pixels, not 100% original-image detail."))
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(width: 880, height: 600)
    }
}
