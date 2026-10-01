import AppKit
import Combine
import CrossDiffCore

enum ImageComparisonSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? L("左图", "Left Image") : L("右图", "Right Image") }
}

enum ImageComparisonMode: String, CaseIterable, Identifiable {
    case sideBySide, overlay, wipe, difference
    var id: Self { self }
    var title: String {
        switch self {
        case .sideBySide: return L("并排", "Side by Side")
        case .overlay: return L("叠加", "Overlay")
        case .wipe: return L("滑动对比", "Wipe")
        case .difference: return L("像素差异", "Pixel Difference")
        }
    }
}

enum ImageComparisonZoom: String, CaseIterable, Identifiable {
    case fit = "fit", half = "50%", actual = "100%", double = "200%", quadruple = "400%"
    var id: Self { self }
    var title: String { self == .fit ? L("适应窗口", "Fit to Window") : rawValue }
    var scale: CGFloat? {
        switch self {
        case .fit: return nil
        case .half: return 0.5
        case .actual: return 1
        case .double: return 2
        case .quadruple: return 4
        }
    }
}

/// Owned by the comparison tab. Alignment never enters source files or text sessions.
@MainActor
final class ImageComparisonModel: ObservableObject {
    @Published private(set) var preview: ImageComparisonPreview?
    @Published private(set) var error: Error?
    @Published private(set) var isRendering = false
    @Published var mode = ImageComparisonMode.sideBySide
    @Published var zoom = ImageComparisonZoom.fit
    @Published var opacity = 0.5
    @Published var wipePosition = 0.5
    @Published var alignmentSide = ImageComparisonSide.right
    @Published var leftAspectLocked = true
    @Published var rightAspectLocked = true
    @Published var overlapOnly = false { didSet { if overlapOnly != oldValue { render() } } }
    @Published var leftTransform = ImageComparisonTransform.identity {
        didSet { if leftTransform != oldValue { render() } }
    }
    @Published var rightTransform = ImageComparisonTransform.identity {
        didSet { if rightTransform != oldValue { render() } }
    }
    private(set) var renderedLeftTransform = ImageComparisonTransform.identity
    private(set) var renderedRightTransform = ImageComparisonTransform.identity
    private(set) var renderedOverlapOnly = false
    private(set) var isInteracting = false
    private var sources: ImageComparisonSources?
    private var loadedPair: [URL]?
    private var loadID = UUID()
    private var renderID = UUID()
    private var renderTask: Task<Void, Never>?
    private var interactiveRenderInFlight = false

    deinit { renderTask?.cancel() }

    func transform(for side: ImageComparisonSide) -> ImageComparisonTransform {
        side == .left ? leftTransform : rightTransform
    }

    func setTransform(_ transform: ImageComparisonTransform, for side: ImageComparisonSide) {
        if side == .left { leftTransform = transform.normalized }
        else { rightTransform = transform.normalized }
    }

    func aspectLocked(for side: ImageComparisonSide) -> Bool {
        side == .left ? leftAspectLocked : rightAspectLocked
    }

    func toggleAspectLock(side: ImageComparisonSide) {
        if side == .left { leftAspectLocked.toggle() }
        else { rightAspectLocked.toggle() }
    }

    func flipHorizontal(side: ImageComparisonSide) {
        var transform = transform(for: side)
        transform.flipHorizontal.toggle()
        setTransform(transform, for: side)
    }

    func flipVertical(side: ImageComparisonSide) {
        var transform = transform(for: side)
        transform.flipVertical.toggle()
        setTransform(transform, for: side)
    }

    func reset(side: ImageComparisonSide) {
        if side == .left { leftAspectLocked = true }
        else { rightAspectLocked = true }
        setTransform(.identity, for: side)
    }

    func setInteracting(_ value: Bool) {
        guard isInteracting != value else { return }
        isInteracting = value
        // Finishing a gesture immediately requests the final parameters.
        if !value { render() }
    }

    func load(left: URL, right: URL, force: Bool = false) async {
        let pair = [left, right]
        if !force, loadedPair == pair, sources != nil { return }
        let request = UUID()
        loadID = request
        renderID = UUID()
        renderTask?.cancel()
        interactiveRenderInFlight = false
        sources = nil
        preview = nil
        error = nil
        isRendering = false
        if loadedPair != pair {
            leftTransform = .identity
            rightTransform = .identity
            leftAspectLocked = true
            rightAspectLocked = true
        }
        loadedPair = nil
        let worker = Task.detached(priority: .userInitiated) {
            try ImageComparisonDecoder.load(left: left, right: right)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, loadID == request else { return }
            sources = result
            loadedPair = pair
            render()
        } catch is CancellationError {
            // Closing or changing a pair must not publish an obsolete decode.
        } catch {
            guard !Task.isCancelled, loadID == request else { return }
            self.error = error
        }
    }

    private func render() {
        // During a continuous gesture, finish one preview then render the latest
        // parameters. Cancelling on every mouse event can starve slower machines.
        if isInteracting && interactiveRenderInFlight { return }
        renderID = UUID()
        renderTask?.cancel()
        interactiveRenderInFlight = false
        guard let sources else { return }
        let request = renderID
        let left = leftTransform.normalized, right = rightTransform.normalized
        let overlap = overlapOnly
        interactiveRenderInFlight = isInteracting
        isRendering = true
        error = nil
        renderTask = Task { [weak self] in
            // Coalesce changes made in the same UI event without waiting for a gesture to end.
            await Task.yield()
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try ImageComparisonRenderer.render(sources: sources, leftTransform: left,
                                                   rightTransform: right, overlapOnly: overlap)
            }
            do {
                let value = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, self.renderID == request else { return }
                self.renderedLeftTransform = left
                self.renderedRightTransform = right
                self.renderedOverlapOnly = overlap
                self.preview = value
                self.interactiveRenderInFlight = false
                if self.isInteracting && (self.leftTransform.normalized != left ||
                    self.rightTransform.normalized != right || self.overlapOnly != overlap) {
                    self.render()
                } else {
                    self.isRendering = false
                }
            } catch is CancellationError {
                // A later change owns the busy indicator and comparison result.
            } catch {
                guard !Task.isCancelled, let self, self.renderID == request else { return }
                self.interactiveRenderInFlight = false
                self.error = error
                self.isRendering = false
            }
        }
    }
}
