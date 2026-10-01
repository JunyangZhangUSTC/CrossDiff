import AppKit
import SwiftUI
import CrossDiffCore

/// Per-image alignment changes only bounded comparison previews, never the source files.
@MainActor
struct ImageComparisonView: View {
    let left: URL
    let right: URL
    @ObservedObject var model: ImageComparisonModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @State private var drag: ImageAlignmentDrag?
    @State private var cornerDrag: ImageCornerDrag?
    private var theme: ComparisonTheme { appearance.colors }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let preview = model.preview {
                imageAdjustments(preview)
                Divider()
                comparison(preview)
                Divider()
                previewInformation(preview)
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(L("无法打开图片", "Unable to Open Images"), systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(localizedErrorDescription(error))
                } actions: {
                    Button(L("重试", "Try Again")) {
                        Task { await model.load(left: left, right: right, force: true) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L("正在读取图片并计算差异…", "Loading images and calculating differences…"))
                        .foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .coordinateSpace(name: "image-alignment")
        .background(Color(nsColor: theme.canvas))
        .foregroundStyle(Color(nsColor: theme.text))
        .task(id: [left, right]) { await model.load(left: left, right: right) }
        .onDisappear {
            drag = nil
            cornerDrag = nil
            model.setInteracting(false)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Picker(L("比较方式", "Comparison Mode"), selection: $model.mode) {
                    ForEach(ImageComparisonMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(L("比较方式", "Comparison Mode"))
                .id(settings.language)
                .accessibilityIdentifier("image.mode")
                .frame(maxWidth: 440)
                Spacer(minLength: 8)
                Picker(L("视图缩放", "View Zoom"), selection: $model.zoom) {
                    ForEach(ImageComparisonZoom.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 205)
                .id(settings.language)
                .help(L("一起放大查看画布；要改变两图的相对大小，请使用各侧的大小滑块。", "Magnifies the entire canvas. Use each image’s Scale control to adjust its relative size."))
                Button {
                    Task { await model.load(left: left, right: right, force: true) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(L("重新读取图片，保留当前对齐参数", "Reload images and keep the current alignment"))
                    .accessibilityLabel(L("重新读取图片", "Reload Images"))
            }
            if model.mode != .sideBySide {
                HStack(spacing: 12) {
                    if model.mode == .overlay || model.mode == .wipe {
                        Text(model.mode == .overlay ? L("右图透明度", "Right Opacity") : L("分界位置", "Divider"))
                            .foregroundStyle(Color(nsColor: theme.secondaryText))
                        Slider(value: model.mode == .overlay ? $model.opacity : $model.wipePosition, in: 0...1)
                            .frame(maxWidth: 180)
                            .accessibilityLabel(model.mode == .overlay ? L("右图透明度", "Right Image Opacity") : L("左右图片分界位置", "Image Divider Position"))
                        Text((model.mode == .overlay ? model.opacity : model.wipePosition), format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    } else {
                        Toggle(L("仅比较重叠区域", "Compare Overlap Only"), isOn: $model.overlapOnly)
                            .accessibilityIdentifier("image.overlapOnly")
                            .help(L("适合裁剪图：只统计两张图共同覆盖的区域，透明像素也参与比较。", "Useful for crops: compares only the area covered by both images, including transparent pixels."))
                    }
                    Spacer(minLength: 12)
                    Label(L("拖动对齐", "Drag to Align"), systemImage: "hand.draw")
                        .foregroundStyle(Color(nsColor: theme.secondaryText))
                    Picker(L("拖动哪张图片", "Image to Move"), selection: $model.alignmentSide) {
                        ForEach(ImageComparisonSide.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 168)
                    .id(settings.language)
                    .accessibilityIdentifier("image.alignmentTarget")
                }
                .font(.system(size: 12))
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Color(nsColor: theme.chrome))
        .disabled(model.preview == nil)
    }

    private func imageAdjustments(_ preview: ImageComparisonPreview) -> some View {
        HStack(alignment: .top, spacing: 16) {
            adjustmentPanel(.left, url: left, image: preview.left)
            Rectangle().fill(Color(nsColor: theme.separator)).frame(width: 1)
            adjustmentPanel(.right, url: right, image: preview.right)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color(nsColor: theme.chrome))
    }

    private func adjustmentPanel(_ side: ImageComparisonSide, url: URL, image: ImageComparisonAsset) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "photo").foregroundStyle(Color(nsColor: theme.secondaryText))
                Text(side.title).font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .help(url.path)
                Spacer(minLength: 0)
                transformButton(side: side, identifier: "aspectLock",
                                symbol: model.aspectLocked(for: side) ? "lock.fill" : "lock.open",
                                title: model.aspectLocked(for: side) ? L("锁定长宽比", "Lock Aspect Ratio") : L("自由调整宽高", "Free Resize"),
                                active: model.aspectLocked(for: side)) {
                    model.toggleAspectLock(side: side)
                }
                transformButton(side: side, identifier: "flipHorizontal",
                                symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                title: L("水平翻转", "Flip Horizontally"),
                                active: model.transform(for: side).flipHorizontal) {
                    model.flipHorizontal(side: side)
                }
                transformButton(side: side, identifier: "flipVertical",
                                symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                title: L("垂直翻转", "Flip Vertically"),
                                active: model.transform(for: side).flipVertical) {
                    model.flipVertical(side: side)
                }
                Button { model.reset(side: side) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.transform(for: side).isIdentity && model.aspectLocked(for: side))
                    .help(side == .left ? L("重置左图的所有变换并锁定长宽比", "Reset All Left Image Transforms and Lock Aspect Ratio") : L("重置右图的所有变换并锁定长宽比", "Reset All Right Image Transforms and Lock Aspect Ratio"))
                    .accessibilityLabel(side == .left ? L("重置左图", "Reset Left Image") : L("重置右图", "Reset Right Image"))
                    .accessibilityIdentifier("image.\(side.rawValue).reset")
            }
            HStack(spacing: 8) {
                Text("\(image.originalWidth) × \(image.originalHeight) px")
                Spacer(minLength: 4)
                let transform = model.transform(for: side)
                if transform.offsetX != 0 || transform.offsetY != 0 {
                    Text("X \(ImageAdjustmentControl.formatted(transform.offsetX)) · Y \(ImageAdjustmentControl.formatted(transform.offsetY))")
                        .monospacedDigit()
                        .help(L("位置以解码后的预览像素计，向右、向下为正。", "Position is measured in decoded preview pixels; right and down are positive."))
                }
            }
            .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            if model.aspectLocked(for: side) {
                ImageAdjustmentControl(title: L("大小", "Scale"), symbol: "arrow.up.left.and.arrow.down.right",
                                       value: valueBinding(side, keyPath: \.scale, multiplier: 100),
                                       range: 10...400, suffix: "%", wraps: false,
                                       identifier: "image.\(side.rawValue).scale", sideTitle: side.title,
                                       onEditingChanged: model.setInteracting)
            } else {
                ImageAdjustmentControl(title: L("宽度", "Width"), symbol: "arrow.left.and.right",
                                       value: valueBinding(side, keyPath: \.scaleX, multiplier: 100),
                                       range: 10...400, suffix: "%", wraps: false,
                                       identifier: "image.\(side.rawValue).width", sideTitle: side.title,
                                       onEditingChanged: model.setInteracting)
                ImageAdjustmentControl(title: L("高度", "Height"), symbol: "arrow.up.and.down",
                                       value: valueBinding(side, keyPath: \.scaleY, multiplier: 100),
                                       range: 10...400, suffix: "%", wraps: false,
                                       identifier: "image.\(side.rawValue).height", sideTitle: side.title,
                                       onEditingChanged: model.setInteracting)
            }
            ImageAdjustmentControl(title: L("旋转", "Rotation"), symbol: "rotate.right",
                                   value: valueBinding(side, keyPath: \.rotationDegrees),
                                   range: -180...180, suffix: "°", wraps: true,
                                   identifier: "image.\(side.rawValue).rotation", sideTitle: side.title,
                                   onEditingChanged: model.setInteracting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transformButton(side: ImageComparisonSide, identifier: String, symbol: String,
                                 title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: active ? theme.accent : theme.secondaryText))
                .frame(width: 24, height: 24)
                .background(active ? Color(nsColor: theme.accent).opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel("\(side.title) · \(title)")
        .accessibilityValue(active ? L("开启", "On") : L("关闭", "Off"))
        .accessibilityIdentifier("image.\(side.rawValue).\(identifier)")
    }

    private func valueBinding(_ side: ImageComparisonSide, keyPath: WritableKeyPath<ImageComparisonTransform, Double>,
                              multiplier: Double = 1) -> Binding<Double> {
        Binding(get: { model.transform(for: side)[keyPath: keyPath] * multiplier }, set: { value in
            var transform = model.transform(for: side)
            transform[keyPath: keyPath] = value / multiplier
            model.setTransform(transform, for: side)
        })
    }

    private func comparison(_ preview: ImageComparisonPreview) -> some View {
        GeometryReader { geometry in
            let reference = cornerDrag?.reference ?? drag?.reference ?? ImageCanvasReference(preview, viewportSize: geometry.size)
            let gap: CGFloat = model.mode == .sideBySide ? 18 : 0
            let columns: CGFloat = model.mode == .sideBySide ? 2 : 1
            // Reserve space outside the raster so every corner has a full hit target.
            let width = max(1, (geometry.size.width - 32 - gap) / columns - 24)
            let height = max(1, geometry.size.height - 56)
            let fit = min(1, width / reference.pixelSize.width, height / reference.pixelSize.height)
            let scale = cornerDrag?.displayScale ?? drag?.displayScale ?? model.zoom.scale ?? fit
            let size = CGSize(width: reference.pixelSize.width * scale, height: reference.pixelSize.height * scale)
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: gap) {
                    if model.mode == .sideBySide {
                        imageCanvas(.left, preview: preview, reference: reference, size: size, scale: scale)
                        imageCanvas(.right, preview: preview, reference: reference, size: size, scale: scale)
                    } else {
                        combinedCanvas(preview, reference: reference, size: size, scale: scale)
                            .gesture(alignmentGesture(model.alignmentSide, reference: reference, scale: scale))
                            .accessibilityIdentifier("image.canvas.combined")
                            .overlay(alignment: .topLeading) {
                                selectionOverlay(model.alignmentSide, preview: preview, reference: reference, scale: scale)
                            }
                            .padding(12)
                    }
                }
                .padding(16)
                .frame(minWidth: reference.viewportSize.width, minHeight: reference.viewportSize.height)
            }
            .background(Color(nsColor: theme.canvas))
        }
    }

    private func imageCanvas(_ side: ImageComparisonSide, preview: ImageComparisonPreview,
                             reference: ImageCanvasReference, size: CGSize, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ImageComparisonCheckerboard(isDark: appearance.isDark)
            mappedImage(side == .left ? preview.left.image : preview.right.image,
                        preview: preview, reference: reference, scale: scale)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay(Rectangle().stroke(Color(nsColor: theme.separator), lineWidth: 1).allowsHitTesting(false))
        .contentShape(Rectangle())
        .gesture(alignmentGesture(side, reference: reference, scale: scale))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("拖动图片调整对齐位置", "Drag the image to adjust alignment"))
        .accessibilityIdentifier("image.canvas.\(side.rawValue)")
        .overlay(alignment: .topLeading) {
            selectionOverlay(side, preview: preview, reference: reference, scale: scale)
        }
        .padding(12)
    }

    /// Keep world coordinates stationary while a gesture changes the raster's bounds.
    /// Only the raster is replaced by the asynchronous renderer, never its on-screen scale.
    private func mappedImage(_ image: CGImage, preview: ImageComparisonPreview,
                             reference: ImageCanvasReference, scale: CGFloat) -> some View {
        let rasterScale = scale * reference.canvasScale / preview.canvasScale
        let origin = reference.point(preview.canvasOrigin, displayScale: scale)
        return Image(decorative: image, scale: 1)
            .resizable().interpolation(rasterScale > 1 ? .none : .high)
            .frame(width: CGFloat(preview.width) * rasterScale, height: CGFloat(preview.height) * rasterScale)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
    }

    private func combinedCanvas(_ preview: ImageComparisonPreview, reference: ImageCanvasReference,
                                size: CGSize, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ImageComparisonCheckerboard(isDark: appearance.isDark)
            if model.mode == .difference {
                mappedImage(preview.difference, preview: preview, reference: reference, scale: scale)
            } else if model.mode == .overlay {
                mappedImage(preview.left.image, preview: preview, reference: reference, scale: scale)
                mappedImage(preview.right.image, preview: preview, reference: reference, scale: scale).opacity(model.opacity)
            } else {
                mappedImage(preview.left.image, preview: preview, reference: reference, scale: scale)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .mask(alignment: .leading) { Rectangle().frame(width: size.width * model.wipePosition) }
                mappedImage(preview.right.image, preview: preview, reference: reference, scale: scale)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .mask(alignment: .trailing) { Rectangle().frame(width: size.width * (1 - model.wipePosition)) }
                Rectangle().fill(.white).frame(width: 2, height: size.height)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .offset(x: size.width * model.wipePosition - 1)
                    .allowsHitTesting(false)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 32)
                    .background(Color(nsColor: theme.accent), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.8), lineWidth: 1))
                    .offset(x: size.width * model.wipePosition - 14, y: max(0, size.height / 2 - 16))
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("image-wipe")).onChanged { value in
                        guard size.width > 0, cornerDrag == nil, drag == nil else { return }
                        model.wipePosition = min(1, max(0, value.location.x / size.width))
                    })
                    .accessibilityLabel(L("图片分界手柄", "Image Divider Handle"))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: "image-wipe")
        .overlay(Rectangle().stroke(Color(nsColor: theme.separator), lineWidth: 1).allowsHitTesting(false))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("图片对比画布", "Image Comparison Canvas"))
    }

    private func selectionOverlay(_ side: ImageComparisonSide, preview: ImageComparisonPreview,
                                  reference: ImageCanvasReference, scale: CGFloat) -> some View {
        let sourceSize = side == .left ? preview.leftSourceSize : preview.rightSourceSize
        let points = ImageTransformGeometry.corners(sourceSize: sourceSize, transform: model.transform(for: side))
            .map { reference.point($0, displayScale: scale) }
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.addLines(points)
                path.closeSubpath()
            }
            .stroke(Color(nsColor: theme.accent).opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .allowsHitTesting(false)
            ForEach(ImageTransformCorner.allCases) { corner in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(nsColor: theme.accent), lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .position(points[corner.rawValue])
                    .highPriorityGesture(cornerGesture(side, corner: corner, sourceSize: sourceSize,
                                                       reference: reference, scale: scale))
                    .help(model.aspectLocked(for: side) ? L("拖动角点等比例缩放；点击锁按钮可自由调整宽高。", "Drag to resize proportionally. Unlock to stretch width and height independently.") : L("拖动角点自由调整宽高，对角位置保持不变。", "Drag to stretch width and height; the opposite corner stays fixed."))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(side.title) · \(cornerTitle(corner))")
                    .accessibilityIdentifier("image.\(side.rawValue).corner.\(cornerIdentifier(corner))")
            }
        }
    }

    private func cornerIdentifier(_ corner: ImageTransformCorner) -> String {
        switch corner {
        case .topLeft: return "topLeft"
        case .topRight: return "topRight"
        case .bottomRight: return "bottomRight"
        case .bottomLeft: return "bottomLeft"
        }
    }

    private func cornerTitle(_ corner: ImageTransformCorner) -> String {
        switch corner {
        case .topLeft: return L("左上角缩放", "Resize Top Left Corner")
        case .topRight: return L("右上角缩放", "Resize Top Right Corner")
        case .bottomRight: return L("右下角缩放", "Resize Bottom Right Corner")
        case .bottomLeft: return L("左下角缩放", "Resize Bottom Left Corner")
        }
    }

    private func cornerGesture(_ side: ImageComparisonSide, corner: ImageTransformCorner, sourceSize: CGSize,
                               reference: ImageCanvasReference, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("image-alignment"))
            .onChanged { value in
                guard drag == nil else { return }
                if cornerDrag == nil {
                    cornerDrag = ImageCornerDrag(side: side, corner: corner, initial: model.transform(for: side),
                                                 sourceSize: sourceSize, lockAspectRatio: model.aspectLocked(for: side),
                                                 reference: reference, displayScale: scale)
                    model.setInteracting(true)
                }
                guard let gesture = cornerDrag else { return }
                let pixelsPerPoint = 1 / max(0.0001, gesture.displayScale * gesture.reference.canvasScale)
                let translation = CGSize(width: value.translation.width * pixelsPerPoint,
                                         height: value.translation.height * pixelsPerPoint)
                model.setTransform(ImageTransformGeometry.resize(initial: gesture.initial, sourceSize: gesture.sourceSize,
                                                                  corner: gesture.corner, translation: translation,
                                                                  lockAspectRatio: gesture.lockAspectRatio), for: gesture.side)
            }
            .onEnded { _ in
                cornerDrag = nil
                model.setInteracting(false)
            }
    }

    private func alignmentGesture(_ side: ImageComparisonSide, reference: ImageCanvasReference,
                                  scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("image-alignment"))
            .onChanged { value in
                guard cornerDrag == nil else { return }
                if drag == nil {
                    model.setInteracting(true)
                    drag = ImageAlignmentDrag(side: side, initial: model.transform(for: side),
                                              reference: reference, displayScale: scale)
                }
                guard let drag else { return }
                let pixelsPerPoint = 1 / max(0.0001, drag.displayScale * drag.reference.canvasScale)
                var transform = drag.initial
                transform.offsetX += Double(value.translation.width * pixelsPerPoint)
                transform.offsetY += Double(value.translation.height * pixelsPerPoint)
                model.setTransform(transform, for: drag.side)
            }
            .onEnded { _ in
                drag = nil
                model.setInteracting(false)
            }
    }

    private func previewInformation(_ preview: ImageComparisonPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if model.isRendering {
                    ProgressView().controlSize(.mini)
                    Text(L("正在更新比较…", "Updating comparison…"))
                } else if let error = model.error {
                    Label(localizedErrorDescription(error), systemImage: "exclamationmark.triangle")
                } else if model.mode == .difference {
                    if model.overlapOnly && preview.overlapPixels == 0 {
                        Label(L("两张图片尚未重叠，请拖动图片调整位置。", "The images do not overlap. Drag an image to align them."), systemImage: "rectangle.on.rectangle")
                    } else {
                        Text(L("差异 \(preview.differentPixels.formatted()) / \(preview.comparedPixels.formatted()) 像素", "Different pixels: \(preview.differentPixels.formatted()) / \(preview.comparedPixels.formatted())"))
                        Text("·")
                        Text(L("亮色为差异，深色为相同", "Bright means different; dark means identical"))
                    }
                } else {
                    Label(model.mode == .wipe ? L("拖动四角缩放、图片对齐，中间手柄移动分界线", "Drag corners to resize, images to align, or the center handle to move the divider") : L("拖动四角调整大小，拖动图片调整位置", "Drag corners to resize; drag images to align"), systemImage: "hand.draw")
                }
                Spacer(minLength: 4)
                Text(L("原文件不变", "Originals unchanged"))
            }
            if preview.isDownsampled || preview.isCanvasDownsampled {
                Text(L("比较基于最长边不超过 1600 像素的 sRGB 预览；缩放和旋转会重采样，细微像素差异不一定是内容修改。", "Comparison uses sRGB previews up to 1,600 pixels. Scaling and rotation resample pixels; small differences may not indicate edited content."))
            } else if model.mode == .difference {
                Text(L("比较包含透明度；缩放、旋转或压缩可能产生重采样差异。", "Comparison includes transparency; scaling, rotation, or compression may introduce resampling differences."))
            }
            if preview.hasMultipleFrames {
                Text(L("动画或多帧图片仅比较第一帧。", "Only the first frame of animated or multi-frame images is compared."))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(nsColor: theme.secondaryText))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(Color(nsColor: theme.chrome))
    }
}

private struct ImageAlignmentDrag {
    let side: ImageComparisonSide
    let initial: ImageComparisonTransform
    let reference: ImageCanvasReference
    let displayScale: CGFloat
}

/// A gesture freezes this reference so fitting and raster bounds cannot move its anchor.
private struct ImageCanvasReference {
    let origin: CGPoint
    let pixelSize: CGSize
    let canvasScale: CGFloat
    let viewportSize: CGSize

    init(_ preview: ImageComparisonPreview, viewportSize: CGSize) {
        origin = preview.canvasOrigin
        pixelSize = CGSize(width: preview.width, height: preview.height)
        canvasScale = preview.canvasScale
        self.viewportSize = viewportSize
    }

    func point(_ world: CGPoint, displayScale: CGFloat) -> CGPoint {
        CGPoint(x: (world.x - origin.x) * canvasScale * displayScale,
                y: (world.y - origin.y) * canvasScale * displayScale)
    }
}

private struct ImageCornerDrag {
    let side: ImageComparisonSide
    let corner: ImageTransformCorner
    let initial: ImageComparisonTransform
    let sourceSize: CGSize
    let lockAspectRatio: Bool
    let reference: ImageCanvasReference
    let displayScale: CGFloat
}

@MainActor
private struct ImageAdjustmentControl: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    let wraps: Bool
    let identifier: String
    let sideTitle: String
    let onEditingChanged: (Bool) -> Void
    @ObservedObject private var appearance = AppAppearance.shared
    @State private var draft = ""
    @State private var hasEdits = false
    @FocusState private var isFocused: Bool
    private var theme: ComparisonTheme { appearance.colors }

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                .frame(width: 76, alignment: .leading)
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .accessibilityLabel("\(sideTitle) \(title)")
                .accessibilityIdentifier(identifier + ".slider")
            HStack(spacing: 3) {
                TextField("", text: Binding(get: { draft }, set: { draft = $0; hasEdits = true }))
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onSubmit { commit(); isFocused = false }
                    .accessibilityLabel("\(sideTitle) \(title) \(suffix)")
                    .accessibilityIdentifier(identifier + ".field")
                Text(suffix).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            .font(.system(size: 11).monospacedDigit())
            .padding(.horizontal, 7).frame(width: 75, height: 25)
            .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: isFocused ? theme.accent : theme.separator), lineWidth: 1))
            .help(wraps ? L("输入角度后按回车；正值顺时针，支持小数。", "Press Return to apply degrees. Positive values rotate clockwise; decimals are supported.") : L("输入 10–400% 后按回车，或拖动滑块。", "Enter 10–400% and press Return, or drag the slider."))
        }
        .onAppear { draft = Self.formatted(value) }
        // Sliders and reset buttons can keep the native text field focused.
        // Reflect their value immediately so a later blur cannot restore a stale draft.
        .onChange(of: value) { _, newValue in
            draft = Self.formatted(newValue)
            hasEdits = false
        }
        .onChange(of: isFocused) { _, focused in if !focused { commit() } }
    }

    private func commit() {
        // Focusing or leaving a display-rounded value must not alter precise alignment.
        guard hasEdits else { return }
        hasEdits = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: suffix, with: "").replacingOccurrences(of: ",", with: ".")
        if let number = Double(text), number.isFinite {
            if wraps {
                var angle = number.truncatingRemainder(dividingBy: 360)
                if angle > 180 { angle -= 360 }
                if angle < -180 { angle += 360 }
                value = angle
            } else { value = min(range.upperBound, max(range.lowerBound, number)) }
        }
        draft = Self.formatted(value)
    }

    static func formatted(_ number: Double) -> String {
        var result = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), number)
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result == "-0" ? "0" : result
    }
}

private struct ImageComparisonCheckerboard: View {
    let isDark: Bool

    private static let lightTile = tile(light: 0.96, dark: 0.90)
    private static let darkTile = tile(light: 0.20, dark: 0.24)

    private static func tile(light: Double, dark: Double) -> Image {
        Image(size: CGSize(width: 24, height: 24), opaque: true) { context in
            context.fill(Path(CGRect(x: 0, y: 0, width: 24, height: 24)), with: .color(Color(white: light)))
            for origin in [CGPoint.zero, CGPoint(x: 12, y: 12)] {
                context.fill(Path(CGRect(origin: origin, size: CGSize(width: 12, height: 12))), with: .color(Color(white: dark)))
            }
        }
    }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .tiledImage(isDark ? Self.darkTile : Self.lightTile))
        }
        .accessibilityHidden(true)
    }
}
