import AppKit
import SwiftUI

private func withDirectManipulation(_ updates: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        updates()
    }
}

struct ReferenceGridView: View {
    @Bindable var store: LibraryStore
    let namespace: Namespace.ID
    var isActive = true
    @Environment(\.undoManager) private var undoManager
    @State private var baseZoom: CGFloat = 1
    @State private var isShiftDown = false
    @State private var maxRenderedIndex: Int = 96
    @State private var renderGeneration = 0
    @State private var clickRipple: ReferenceClickRipple?
    @State private var pendingPreviewID: ReferenceItem.ID?
    private static let initialBatchSize = 144
    private static let batchSize = 360
    private static let previewOpenDelay: TimeInterval = 0.012

    var body: some View {
        GeometryReader { proxy in
            let visibleItems = isActive ? store.visibleItems : []
            let renderLimit = min(maxRenderedIndex, visibleItems.count)
            let renderedItems = Array(visibleItems.prefix(renderLimit))
            let panelInsets = gridPanelInsets(for: proxy.size)
            let contentWidth = max(260, proxy.size.width - panelInsets.leading - panelInsets.trailing)
            let placements = gridPlacements(for: renderedItems, in: contentWidth)
            let contentHeight = max(1, (placements.map(\.frame.maxY).max() ?? 0))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(gridBands(for: placements, contentHeight: contentHeight)) { band in
                        ZStack(alignment: .topLeading) {
                            LociColor.canvas.opacity(0.001)
                                .contentShape(Rectangle())
                                .frame(width: contentWidth, height: band.height)
                                .onTapGesture {
                                    dismissFocusedPreviewOrClearSelection()
                                }

                            ForEach(band.placements) { placement in
                                gridTile(for: placement, placements: placements, yOffset: band.minY)
                            }
                        }
                        .frame(width: contentWidth, height: band.height, alignment: .topLeading)
                    }
                }
                .frame(width: contentWidth, height: contentHeight, alignment: .top)
            }
            .background {
                LociColor.canvas
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissFocusedPreviewOrClearSelection()
                    }
            }
            .scrollIndicators(.hidden)
            .lociScrollFeel(.library)
            .padding(.top, panelInsets.top)
            .padding(.leading, panelInsets.leading)
            .padding(.trailing, panelInsets.trailing)
            .padding(.bottom, panelInsets.bottom)
            .overlay {
                MouseZoomCapture(
                    isEnabled: isActive && store.focusedItemID == nil,
                    onZoom: { delta, _ in
                        guard abs(delta) > 0.0005 else { return }
                        withDirectManipulation {
                            store.gridZoom = store.gridZoom * (1 + delta)
                            baseZoom = store.gridZoom
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LociColor.canvas)
        .animation(AppMotion.smooth, value: store.selectedFilter)
        .animation(AppMotion.smooth, value: store.activeSearchQuery)
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let newZoom = min(1.0, max(0.40, baseZoom * value.magnification))
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        store.gridZoom = newZoom
                    }
                }
                .onEnded { _ in
                    baseZoom = store.gridZoom
                }
        )
        .onAppear {
            baseZoom = store.gridZoom
            scheduleProgressiveGridRendering(for: store.visibleItems, reset: true)
        }
        .onChange(of: store.selectedFilter) { _, _ in
            scheduleProgressiveGridRendering(for: store.visibleItems, reset: true)
        }
        .onChange(of: store.activeSearchQuery) { _, _ in
            scheduleProgressiveGridRendering(for: store.visibleItems, reset: true)
        }
        .onChange(of: store.items.count) { _, _ in
            scheduleProgressiveGridRendering(for: store.visibleItems, reset: true)
        }
        .animation(nil, value: store.focusedItemID)
        .onModifierKeysChanged { _, newKeys in
            isShiftDown = newKeys.contains(.shift)
        }
        .onKeyPress(.leftArrow) { moveGridSelection(direction: .left) }
        .onKeyPress(.rightArrow) { moveGridSelection(direction: .right) }
        .onKeyPress(.upArrow) { moveGridSelection(direction: .up) }
        .onKeyPress(.downArrow) { moveGridSelection(direction: .down) }
        .onKeyPress(.space) {
            if store.focusedItemID != nil {
                store.requestFocusDismissal()
            } else if let selectedID = store.selectedItemIDs.first, let item = store.items.first(where: { $0.id == selectedID }) {
                withAnimation(AppMotion.hero) { store.focus(item) }
            }
            return .handled
        }
    }

    private func handleTap(for item: ReferenceItem) {
        guard store.focusedItemID == nil || store.focusIsDismissing else {
            pendingPreviewID = nil
            clickRipple = nil
            store.requestFocusDismissal()
            return
        }

        if isShiftDown {
            withAnimation(AppMotion.quick) {
                store.select(item, additive: true)
            }
            return
        }

        let previewID = item.id
        pendingPreviewID = previewID

        withAnimation(AppMotion.selection) {
            store.select(item)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewOpenDelay) {
            guard pendingPreviewID == previewID,
                  store.selectedItemIDs == [previewID],
                  store.focusedItemID != previewID else { return }

            pendingPreviewID = nil
            clickRipple = nil

            withAnimation(AppMotion.hero) {
                store.openPreview(item)
            }
        }
    }

    @ViewBuilder
    private func gridTile(
        for placement: ReferenceGridPlacement,
        placements: [ReferenceGridPlacement],
        yOffset: CGFloat
    ) -> some View {
        let item = placement.item
        let tileCenter = CGPoint(x: placement.frame.midX, y: placement.frame.midY)
        let isPreviewActive = store.focusedItemID != nil
        let isFocusedItem = store.focusedItemID == item.id
        let focusOffset = focusSpreadOffset(for: placement, in: placements)

        ReferenceGridTile(
            item: item,
            xBookmarkPayload: store.xBookmarkPayload(for: item),
            isSelected: !isPreviewActive && store.selectedItemIDs.contains(item.id),
            clickRippleStrength: isPreviewActive ? 0 : clickRippleStrength(for: item.id, ripple: clickRipple)
        )
        .focusMatchedGeometry(
            id: item.id,
            namespace: namespace,
            isSource: isActive && store.focusedItemID != item.id
        )
        .frame(width: placement.frame.width, height: placement.frame.height)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(
            RightClickSelectionMonitor {
                if !store.selectedItemIDs.contains(item.id) {
                    store.select(item)
                }
            }
        )
        .referenceContextMenu(item: item, store: store)
        .onDrag {
            let draggedIDs = store.selectedItemIDs.contains(item.id) && store.selectedItemIDs.count > 1
                ? store.selectedItemIDs
                : [item.id]
            let payload = draggedIDs.map(\.uuidString).joined(separator: "\n")
            return NSItemProvider(object: payload as NSString)
        }
        .highPriorityGesture(
            TapGesture().onEnded {
                guard store.focusedItemID == nil || store.focusIsDismissing else {
                    handleTap(for: item)
                    return
                }

                let anchors = placements.map { placement in
                    ReferenceRippleAnchor(
                        id: placement.item.id,
                        point: CGPoint(x: placement.frame.midX, y: placement.frame.midY)
                    )
                }
                startReferenceClickRipple(
                    $clickRipple,
                    at: tileCenter,
                    sourceID: item.id,
                    offsets: referenceClickRippleOffsets(
                        anchors: anchors,
                        origin: tileCenter,
                        magnitude: ReferenceClickRippleTuning.gridScatterMagnitude,
                        reach: ReferenceClickRippleTuning.gridReach
                    )
                )
                handleTap(for: item)
            }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { handleTap(for: item) }
        .position(x: placement.frame.midX, y: placement.frame.midY - yOffset)
        .offset(referenceClickRippleOffset(for: item.id, ripple: clickRipple))
        .offset(focusOffset)
        .opacity(isFocusedItem ? 0 : (isPreviewActive ? 0.58 : 1))
        .scaleEffect(isPreviewActive && !isFocusedItem ? 0.985 : 1)
        .animation(AppMotion.hero, value: store.focusedItemID)
        .zIndex(item.id == store.focusedItemID ? 8 : 0)
    }

    private func dismissFocusedPreviewOrClearSelection() {
        pendingPreviewID = nil
        clickRipple = nil

        if store.focusedItemID != nil {
            store.requestFocusDismissal()
        } else {
            withAnimation(AppMotion.quick) {
                store.clearSelection()
            }
        }
    }

    private func focusSpreadOffset(
        for placement: ReferenceGridPlacement,
        in placements: [ReferenceGridPlacement]
    ) -> CGSize {
        guard let focusedID = store.focusedItemID,
              focusedID != placement.item.id,
              let focusedPlacement = placements.first(where: { $0.item.id == focusedID }) else {
            return .zero
        }

        let dx = placement.frame.midX - focusedPlacement.frame.midX
        let dy = placement.frame.midY - focusedPlacement.frame.midY
        let distanceSquared = dx * dx + dy * dy
        guard distanceSquared > 1 else { return .zero }

        let distance = sqrt(distanceSquared)
        let reach: CGFloat = 440
        guard distance < reach else { return .zero }

        let normalizedDistance = min(1, distance / reach)
        let falloff = pow(max(0, 1 - normalizedDistance), 2.1)
        let push = 34 * falloff
        guard push > 0.35 else { return .zero }

        return CGSize(width: dx / distance * push, height: dy / distance * push)
    }

    private enum GridDirection { case left, right, up, down }

    private func moveGridSelection(direction: GridDirection) -> KeyPress.Result {
        let visible = store.visibleItems
        guard !visible.isEmpty else { return .ignored }

        if store.focusedItemID != nil {
            guard direction == .left || direction == .right else { return .handled }
            let offset = direction == .left ? -1 : 1
            withAnimation(AppMotion.smooth) {
                _ = store.focusAdjacentVisibleItem(offset: offset)
            }
            return .handled
        }

        guard let currentID = store.selectedItemIDs.first,
              let currentIndex = visible.firstIndex(where: { $0.id == currentID }) else {
            store.select(visible[0])
            return .handled
        }

        let progress = max(0, min(1, (store.gridZoom - 0.40) / 0.60))
        let spacing = 12 - progress * 2
        let targetUnitWidth = 115 + progress * 115
        let contentWidth = max(260, 900.0)
        let columns = min(12, max(3, Int((contentWidth + spacing) / (targetUnitWidth + spacing))))
        var nextIndex: Int
        switch direction {
        case .left: nextIndex = max(0, currentIndex - 1)
        case .right: nextIndex = min(visible.count - 1, currentIndex + 1)
        case .up: nextIndex = max(0, currentIndex - columns)
        case .down: nextIndex = min(visible.count - 1, currentIndex + columns)
        }
        store.select(visible[nextIndex])
        return .handled
    }

    private func gridPanelInsets(for size: CGSize) -> EdgeInsets {
        EdgeInsets(
            top: 72,
            leading: size.width > 900 ? 26 : 18,
            bottom: 74,
            trailing: size.width > 900 ? 28 : 18
        )
    }

    private func scheduleProgressiveGridRendering(for visibleItems: [ReferenceItem], reset: Bool) {
        renderGeneration += 1
        let generation = renderGeneration
        let total = visibleItems.count
        guard total > 0 else {
            maxRenderedIndex = 0
            return
        }

        let firstLimit = min(Self.initialBatchSize, total)
        if reset || maxRenderedIndex == 0 {
            maxRenderedIndex = firstLimit
            ReferenceThumbnail.warmImagesForFirstPaint(
                for: visibleItems.prefix(firstLimit),
                limit: 24,
                timeBudget: 0.045
            )
        } else {
            maxRenderedIndex = min(max(maxRenderedIndex, firstLimit), total)
        }

        ReferenceThumbnail.preloadImages(for: visibleItems.prefix(min(total, 56)))
        guard maxRenderedIndex < total else { return }

        let start = maxRenderedIndex
        let chunkCount = Int(ceil(Double(total - start) / Double(Self.batchSize)))
        guard chunkCount > 0 else { return }

        for chunk in 1...chunkCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8 * chunk)) {
                guard renderGeneration == generation else { return }
                let nextLimit = min(start + chunk * Self.batchSize, total)
                maxRenderedIndex = max(maxRenderedIndex, nextLimit)
            }
        }
    }

    private func gridPlacements(for items: [ReferenceItem], in width: CGFloat) -> [ReferenceGridPlacement] {
        let progress = max(0, min(1, (store.gridZoom - 0.40) / 0.60))
        let spacing = 14 - progress * 3
        let targetColumnWidth = 132 + progress * 126
        let rawColumnCount = Int((width + spacing) / (targetColumnWidth + spacing))
        let columnCount = min(8, max(width < 560 ? 2 : 3, rawColumnCount))
        let columnWidth = floor((width - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount))
        var columnHeights = Array(repeating: CGFloat.zero, count: columnCount)
        var placements: [ReferenceGridPlacement] = []

        for (index, item) in items.enumerated() {
            let aspectRatio = gridAspectRatio(for: item)
            let column = columnHeights.indices.min { first, second in
                columnHeights[first] < columnHeights[second]
            } ?? 0
            let height = gridHeight(for: item, aspectRatio: aspectRatio, width: columnWidth)
            let origin = CGPoint(
                x: CGFloat(column) * (columnWidth + spacing),
                y: columnHeights[column]
            )
            let frame = CGRect(origin: origin, size: CGSize(width: columnWidth, height: height))
            placements.append(ReferenceGridPlacement(item: item, index: index, column: column, frame: frame))
            columnHeights[column] = frame.maxY + spacing
        }

        return placements
    }

    private func gridBands(
        for placements: [ReferenceGridPlacement],
        contentHeight: CGFloat,
        bandHeight: CGFloat = 980
    ) -> [ReferenceGridBand] {
        let safeContentHeight = max(contentHeight, 1)
        let bandCount = max(1, Int(ceil(safeContentHeight / bandHeight)))
        var grouped = (0..<bandCount).map { index in
            ReferenceGridBand(
                index: index,
                minY: CGFloat(index) * bandHeight,
                height: min(bandHeight, safeContentHeight - CGFloat(index) * bandHeight),
                placements: []
            )
        }

        for placement in placements {
            let bandIndex = min(max(Int(placement.frame.midY / bandHeight), 0), bandCount - 1)
            grouped[bandIndex].placements.append(placement)
        }

        return grouped
    }

    private func bestColumn(forSpan span: Int, columnHeights: [CGFloat]) -> Int {
        let lastStart = columnHeights.count - span
        return (0...lastStart).min { first, second in
            let firstHeight = columnHeights[first..<(first + span)].max() ?? 0
            let secondHeight = columnHeights[second..<(second + span)].max() ?? 0
            if abs(firstHeight - secondHeight) < 0.5 {
                let firstLocalVariance = columnHeights[first..<(first + span)].reduce(CGFloat.zero) { partial, height in
                    partial + abs(height - firstHeight)
                }
                let secondLocalVariance = columnHeights[second..<(second + span)].reduce(CGFloat.zero) { partial, height in
                    partial + abs(height - secondHeight)
                }
                return firstLocalVariance < secondLocalVariance
            }
            return firstHeight < secondHeight
        } ?? 0
    }

    private func gridAspectRatio(for item: ReferenceItem) -> CGFloat {
        if let cachedAspectRatio = ReferenceThumbnail.cachedAspectRatio(for: item) {
            return cachedAspectRatio
        }
        return item.aspectRatio
    }

    private func gridSpan(for item: ReferenceItem, aspectRatio: CGFloat, index: Int, columnCount: Int) -> Int {
        if columnCount <= 3 { return 1 }

        let isWide = aspectRatio >= 1.22
        let isVeryWide = aspectRatio >= 1.75

        switch item.kind {
        case .phone:
            return isWide && columnCount > 7 ? 2 : 1
        case .website, .laptop:
            if columnCount >= 11 { return isVeryWide || index.isMultiple(of: 5) ? 4 : 3 }
            if columnCount >= 7 { return isWide ? 3 : 2 }
            return 2
        case .app:
            if isVeryWide && columnCount >= 11 { return 4 }
            if isWide && columnCount >= 8 { return 2 }
            return isWide ? 2 : 1
        case .product:
            if isVeryWide && columnCount >= 8 { return 3 }
            return isWide && columnCount >= 7 ? 2 : 1
        case .typography:
            if isVeryWide && columnCount >= 8 { return 3 }
            return isWide && columnCount >= 7 ? 2 : 1
        }
    }

    private func gridHeight(for item: ReferenceItem, aspectRatio: CGFloat, width: CGFloat) -> CGFloat {
        if item.isXBookmark {
            return width * 0.96
        }

        let naturalHeight = width / max(0.1, aspectRatio)

        switch item.kind {
        case .phone:
            return min(max(naturalHeight, width * 1.25), width * 2.08)
        case .website, .laptop:
            return min(max(naturalHeight, width * 0.46), width * 0.72)
        case .app:
            return min(max(naturalHeight, width * 0.52), width * 0.86)
        case .product:
            return min(max(naturalHeight, width * 0.58), width * 1.12)
        case .typography:
            return min(max(naturalHeight, width * 0.64), width * 1.18)
        }
    }

}

private struct ReferenceGridPlacement: Identifiable {
    var item: ReferenceItem
    var index: Int
    var column: Int
    var frame: CGRect

    var id: ReferenceItem.ID { item.id }
}

private struct ReferenceGridBand: Identifiable {
    var index: Int
    var minY: CGFloat
    var height: CGFloat
    var placements: [ReferenceGridPlacement]

    var id: Int { index }
}

struct ReferenceCanvasView: View {
    @Bindable var store: LibraryStore
    let namespace: Namespace.ID
    var isActive = true
    @State private var dragStartPositions: [ReferenceItem.ID: CGSize] = [:]
    @State private var basePan: CGSize = .zero
    @State private var baseZoom: CGFloat = 1
    @State private var selectionStart: CGPoint?
    @State private var selectionEnd: CGPoint?
    @State private var activeCanvasDragIDs: Set<ReferenceItem.ID> = []
    @State private var liveCanvasDragTranslation: CGSize = .zero
    @State private var clickRipple: ReferenceClickRipple?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LociColor.canvas
                    .contentShape(Rectangle())
                    .gesture(canvasSelectionGesture(in: proxy.size))
                    .onTapGesture {
                        withAnimation(store.focusedItemID == nil ? AppMotion.quick : AppMotion.hero) {
                            store.clearFocus()
                            store.clearSelection()
                        }
                    }

                if isActive {
                    ForEach(visibleCanvasItems(in: proxy.size)) { item in
                        let itemSize = canvasSize(for: item)
                        let itemPoint = canvasPoint(for: item, in: proxy.size)
                        ReferenceTile(
                            item: item,
                            xBookmarkPayload: store.xBookmarkPayload(for: item),
                            isSelected: store.focusedItemID == nil && store.selectedItemIDs.contains(item.id),
                            showsTitle: false,
                            namespace: namespace,
                            clickRippleStrength: store.focusedItemID == nil ? clickRippleStrength(for: item.id, ripple: clickRipple) : 0
                        )
                        .focusMatchedGeometry(
                            id: item.id,
                            namespace: namespace,
                            isSource: isActive && store.focusedItemID != item.id
                        )
                        .frame(width: itemSize.width, height: itemSize.height)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .background(
                            RightClickSelectionMonitor {
                                if !store.selectedItemIDs.contains(item.id) {
                                    store.select(item)
                                }
                            }
                        )
                        .referenceContextMenu(item: item, store: store)
                        .highPriorityGesture(itemInteractionGesture(for: item, in: proxy.size))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { openCanvasItem(item) }
                        .position(itemPoint)
                        .offset(referenceClickRippleOffset(for: item.id, ripple: clickRipple))
                        .opacity(store.focusedItemID == item.id ? 0 : 1)
                        .zIndex(store.selectedItemIDs.contains(item.id) || activeCanvasDragIDs.contains(item.id) ? 6 : 0)
                        .transaction { transaction in
                            if activeCanvasDragIDs.contains(item.id) {
                                transaction.animation = nil
                            }
                        }
                    }

                    if let selectionRect {
                        Rectangle()
                            .fill(Color.black.opacity(0.040))
                            .overlay {
                                Rectangle()
                                    .stroke(Color.black.opacity(0.16), lineWidth: 1)
                            }
                            .frame(width: selectionRect.width, height: selectionRect.height)
                            .position(x: selectionRect.midX, y: selectionRect.midY)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(canvasMagnificationGesture(in: proxy.size))
            .overlay {
                MouseZoomCapture(
                    isEnabled: isActive && store.focusedItemID == nil,
                    onZoom: { delta, location in
                        guard abs(delta) > 0.0005 else { return }
                        withDirectManipulation {
                            if let location {
                                zoomCanvas(at: location, by: delta, in: proxy.size)
                            } else {
                                store.adjustGlobalZoom(by: delta)
                            }
                        }
                    },
                    onPan: { delta in
                        panCanvas(by: delta)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
        .onAppear {
            basePan = store.canvasPan
            baseZoom = store.canvasZoom
        }
    }

    private var selectionRect: CGRect? {
        guard let selectionStart, let selectionEnd else { return nil }
        return CGRect(
            x: min(selectionStart.x, selectionEnd.x),
            y: min(selectionStart.y, selectionEnd.y),
            width: abs(selectionEnd.x - selectionStart.x),
            height: abs(selectionEnd.y - selectionStart.y)
        )
    }

    private func canvasWidth(for item: ReferenceItem) -> CGFloat {
        switch item.kind {
        case .phone:
            58
        case .typography:
            84
        case .app, .product:
            94
        case .website, .laptop:
            124
        }
    }

    private func canvasSize(for item: ReferenceItem) -> CGSize {
        let width = canvasWidth(for: item) * store.zoom
        return CGSize(width: width, height: width / max(0.1, item.aspectRatio))
    }

    private func zoomCanvas(at location: CGPoint, by delta: CGFloat, in size: CGSize) {
        let before = max(0.01, store.zoom)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let localAnchor = CGPoint(
            x: (location.x - center.x - store.canvasPan.width) / before,
            y: (location.y - center.y - store.canvasPan.height) / before
        )

        store.adjustGlobalZoom(by: delta)

        store.canvasPan = CGSize(
            width: location.x - center.x - localAnchor.x * store.zoom,
            height: location.y - center.y - localAnchor.y * store.zoom
        )
        baseZoom = store.canvasZoom
        basePan = store.canvasPan
    }

    private func panCanvas(by delta: CGSize) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            store.canvasPan = CGSize(
                width: store.canvasPan.width + delta.width,
                height: store.canvasPan.height + delta.height
            )
        }
        basePan = store.canvasPan
    }

    private func canvasPoint(for item: ReferenceItem, in size: CGSize) -> CGPoint {
        let liveOffset = canvasLiveDragOffset(for: item)
        return CGPoint(
            x: size.width / 2 + store.canvasPan.width + item.canvasPosition.width * store.zoom + liveOffset.width,
            y: size.height / 2 + store.canvasPan.height + item.canvasPosition.height * store.zoom + liveOffset.height
        )
    }

    private func canvasRect(for item: ReferenceItem, in size: CGSize) -> CGRect {
        let itemSize = canvasSize(for: item)
        let point = canvasPoint(for: item, in: size)
        return CGRect(
            x: point.x - itemSize.width / 2,
            y: point.y - itemSize.height / 2,
            width: itemSize.width,
            height: itemSize.height
        )
    }

    /// Keep a generous screen-space margin so fast pans and zooms remain
    /// visually continuous while offscreen tiles avoid image/view work.
    private func visibleCanvasItems(in size: CGSize) -> [ReferenceItem] {
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -180, dy: -180)
        return store.visibleItems.filter { item in
            store.focusedItemID == item.id
                || activeCanvasDragIDs.contains(item.id)
                || viewport.intersects(canvasRect(for: item, in: size))
        }
    }

    private func itemInteractionGesture(for item: ReferenceItem, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragStartPositions.isEmpty {
                    let activeIDs = store.selectedItemIDs.contains(item.id) && !store.selectedItemIDs.isEmpty
                        ? store.selectedItemIDs
                        : [item.id]

                    activeCanvasDragIDs = activeIDs
                    for id in activeIDs {
                        if let found = store.items.first(where: { $0.id == id }) {
                            dragStartPositions[id] = found.canvasPosition
                        }
                    }
                }

                guard isRealCanvasDrag(value.translation) else { return }

                if !store.selectedItemIDs.contains(item.id) {
                    store.select(item)
                }

                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    liveCanvasDragTranslation = value.translation
                }
            }
            .onEnded { value in
                if isRealCanvasDrag(value.translation) {
                    commitCanvasDrag(translation: value.translation)
                } else {
                    openCanvasItem(item)
                    clearCanvasDragState()
                }
            }
    }

    private func isRealCanvasDrag(_ translation: CGSize) -> Bool {
        abs(translation.width) > 3 || abs(translation.height) > 3
    }

    private func openCanvasItem(_ item: ReferenceItem) {
        clickRipple = nil

        withAnimation(AppMotion.hero) {
            if store.focusedItemID == item.id {
                store.clearFocus()
            } else {
                store.focus(item)
            }
        }
    }

    private func commitCanvasDrag(translation: CGSize) {
        let zoom = max(0.01, store.zoom)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            for id in activeCanvasDragIDs {
                guard let start = dragStartPositions[id] else { continue }
                store.updateCanvasPosition(
                    for: id,
                    to: CGSize(
                        width: start.width + translation.width / zoom,
                        height: start.height + translation.height / zoom
                    )
                )
            }
            clearCanvasDragState()
        }
    }

    private func clearCanvasDragState() {
        activeCanvasDragIDs.removeAll()
        liveCanvasDragTranslation = .zero
        dragStartPositions.removeAll()
    }

    private func canvasLiveDragOffset(for item: ReferenceItem) -> CGSize {
        activeCanvasDragIDs.contains(item.id) ? liveCanvasDragTranslation : .zero
    }

    private func canvasRippleAnchors(in size: CGSize) -> [ReferenceRippleAnchor] {
        store.visibleItems.map { item in
            ReferenceRippleAnchor(id: item.id, point: canvasPoint(for: item, in: size))
        }
    }

    private func canvasSelectionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .local)
            .onChanged { value in
                if selectionStart == nil {
                    selectionStart = value.startLocation
                    store.clearFocus()
                }
                selectionEnd = value.location

                guard let selectionRect else { return }
                let ids = Set(
                    store.visibleItems.compactMap { item in
                        selectionRect.intersects(canvasRect(for: item, in: size)) ? item.id : nil
                    }
                )
                store.selectItems(with: ids)
            }
            .onEnded { _ in
                selectionStart = nil
                selectionEnd = nil
            }
    }

    private func canvasMagnificationGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                withDirectManipulation {
                    let nextZoom = min(2.05, max(0.42, baseZoom * value.magnification))
                    let ratio = nextZoom / max(0.01, baseZoom)
                    store.canvasZoom = nextZoom
                    store.canvasPan = CGSize(
                        width: basePan.width * ratio,
                        height: basePan.height * ratio
                    )
                }
            }
            .onEnded { _ in
                baseZoom = store.canvasZoom
                basePan = store.canvasPan
            }
    }
}

struct ReferenceInfinityView: View {
    @Bindable var store: LibraryStore
    let namespace: Namespace.ID
    var isActive = true
    @State private var baseZoom: CGFloat = 1
    @State private var basePan: CGSize = .zero
    @State private var selectionStart: CGPoint?
    @State private var selectionEnd: CGPoint?
    @State private var dragStartGroupOffsets: [ReferenceGroup: CGSize] = [:]
    @State private var dragStartInfinityPositions: [ReferenceItem.ID: CGPoint] = [:]
    @State private var expandedInfinityGroup: ReferenceGroup?
    @State private var expandedClusterFocusOffsets: [ReferenceGroup: CGSize] = [:]
    @State private var clickRipple: ReferenceClickRipple?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LociColor.canvas

                InfinitySpaceBackground(zoom: store.zoom, pan: store.infinityPan)
                    .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(selectionGesture(in: proxy.size))
                    .onTapGesture {
                        withAnimation(store.focusedItemID == nil ? AppMotion.quick : AppMotion.hero) {
                            store.clearFocus()
                            store.selectItems(with: [])
                            closeExpandedCluster()
                        }
                    }

                if isActive, store.infinityClustered && store.focusedItemID == nil {
                    ForEach(ReferenceGroup.allCases) { group in
                        InfinityClusterSurface(group: group, bounds: clusterSurfaceBounds(for: group, in: proxy.size))
                            .allowsHitTesting(false)
                    }

                    ForEach(ReferenceGroup.allCases) { group in
                        ClusterLabel(
                            group: group,
                            zoom: store.zoomScale(for: group) * (expandedInfinityGroup == group ? 1.08 : 1)
                        )
                        .contentShape(Capsule())
                        .position(clusterLabelPosition(for: group, in: proxy.size))
                        .gesture(clusterDragGesture(for: group))
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    withAnimation(AppMotion.quick) {
                                        openCluster(group, in: proxy.size)
                                    }
                                }
                            )
                    }
                }

                if isActive {
                    ForEach(visibleInfinityItems(in: proxy.size)) { item in
                        let itemPosition = infinityPosition(for: item, in: proxy.size)
                        let itemSize = infinitySize(for: item)
                        ReferenceTile(
                            item: item,
                            xBookmarkPayload: store.xBookmarkPayload(for: item),
                            isSelected: store.focusedItemID == nil && store.selectedItemIDs.contains(item.id),
                            showsTitle: false,
                            namespace: namespace,
                            clickRippleStrength: store.focusedItemID == nil ? clickRippleStrength(for: item.id, ripple: clickRipple) : 0
                        )
                            .focusMatchedGeometry(
                                id: item.id,
                                namespace: namespace,
                                isSource: isActive && store.focusedItemID != item.id
                            )
                            .frame(width: itemSize.width, height: itemSize.height)
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .referenceContextMenu(item: item, store: store)
                            .simultaneousGesture(itemDragGesture(for: item))
                            .highPriorityGesture(
                                TapGesture().onEnded {
                                    withAnimation(AppMotion.hero) {
                                        focusInfinityItem(item)
                                    }
                                }
                            )
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {
                                withAnimation(AppMotion.hero) {
                                    focusInfinityItem(item)
                                }
                            }
                            .position(itemPosition)
                            .offset(referenceClickRippleOffset(for: item.id, ripple: clickRipple))
                            .opacity(store.focusedItemID == item.id ? 0 : infinityOpacity(for: item))
                            .zIndex(store.selectedItemIDs.contains(item.id) || store.focusedItemID == item.id ? 8 : 1)
                    }
                }

                if isActive, let selectionRect {
                    Rectangle()
                        .fill(Color.black.opacity(0.045))
                        .overlay {
                            Rectangle()
                                .stroke(Color.black.opacity(0.16), lineWidth: 1)
                        }
                        .frame(width: selectionRect.width, height: selectionRect.height)
                        .position(x: selectionRect.midX, y: selectionRect.midY)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(infinityMagnificationGesture())
            .overlay {
                MouseZoomCapture(
                    isEnabled: isActive && store.focusedItemID == nil,
                    onZoom: { delta, location in
                        guard abs(delta) > 0.0005 else { return }
                        withDirectManipulation {
                            if let location {
                                zoomWholeInfinity(at: location, by: delta, in: proxy.size)
                            } else {
                                store.adjustGlobalZoom(by: delta)
                                baseZoom = store.infinityZoom
                            }
                        }
                    },
                    onPan: { delta in
                        panInfinity(by: delta)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LociColor.canvas)
        .clipped()
        .onAppear {
            baseZoom = store.infinityZoom
            basePan = store.infinityPan
        }
        .onChange(of: store.infinityClustered) { _, _ in
            closeExpandedCluster()
        }
    }

    private var selectionRect: CGRect? {
        guard let selectionStart, let selectionEnd else { return nil }
        return CGRect(
            x: min(selectionStart.x, selectionEnd.x),
            y: min(selectionStart.y, selectionEnd.y),
            width: abs(selectionEnd.x - selectionStart.x),
            height: abs(selectionEnd.y - selectionStart.y)
        )
    }

    private func focusInfinityItem(_ item: ReferenceItem) {
        if expandedInfinityGroup != nil, expandedInfinityGroup != item.group {
            expandedInfinityGroup = item.group
        }

        if store.focusedItemID == item.id {
            store.clearFocus()
        } else {
            expandedInfinityGroup = item.group
            store.focus(item)
        }
    }

    private func closeExpandedCluster() {
        expandedInfinityGroup = nil
        expandedClusterFocusOffsets.removeAll()
        for group in ReferenceGroup.allCases {
            store.groupZooms[group] = max(0.92, min(store.zoomScale(for: group), 1.05))
        }
    }

    private func infinityOpacity(for item: ReferenceItem) -> Double {
        guard let expandedInfinityGroup, store.focusedItemID == nil else { return 1 }
        return item.group == expandedInfinityGroup ? 1 : 0.42
    }

    private func selectionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .local)
            .onChanged { value in
                if selectionStart == nil {
                    selectionStart = value.startLocation
                    store.clearFocus()
                    expandedInfinityGroup = nil
                    expandedClusterFocusOffsets.removeAll()
                }

                selectionEnd = value.location
                guard let selectionRect else { return }

                let ids = Set(
                    store.visibleItems.compactMap { item in
                        selectionRect.intersects(itemRect(for: item, in: size)) ? item.id : nil
                    }
                )
                store.selectItems(with: ids)
            }
            .onEnded { _ in
                selectionStart = nil
                selectionEnd = nil
            }
    }

    private func itemDragGesture(for item: ReferenceItem) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                if store.infinityClustered {
                    let groups = selectedGroups(defaultingTo: item.group, activeItemID: item.id)
                    if dragStartGroupOffsets.isEmpty {
                        for group in groups {
                            dragStartGroupOffsets[group] = store.clusterOffset(for: group)
                        }
                        if !store.selectedItemIDs.contains(item.id) {
                            store.select(item)
                        }
                    }
                    for group in groups {
                        let start = dragStartGroupOffsets[group] ?? store.clusterOffset(for: group)
                        store.setClusterOffset(
                            CGSize(
                                width: start.width + value.translation.width / max(0.01, store.zoom),
                                height: start.height + value.translation.height / max(0.01, store.zoom)
                            ),
                            for: group
                        )
                    }
                } else {
                    let ids = selectedItemIDs(defaultingTo: item.id)
                    if dragStartInfinityPositions.isEmpty {
                        for id in ids {
                            if let found = store.items.first(where: { $0.id == id }) {
                                dragStartInfinityPositions[id] = found.infinityPosition
                            }
                        }
                        if !store.selectedItemIDs.contains(item.id) {
                            store.select(item)
                        }
                    }
                    for id in ids {
                        guard let start = dragStartInfinityPositions[id] else { continue }
                        store.updateInfinityPosition(
                            for: id,
                            to: CGPoint(
                                x: start.x + value.translation.width / max(0.01, store.zoom),
                                y: start.y + value.translation.height / max(0.01, store.zoom)
                            )
                        )
                    }
                }
            }
            .onEnded { _ in
                dragStartGroupOffsets.removeAll()
                dragStartInfinityPositions.removeAll()
            }
    }

    private func clusterDragGesture(for group: ReferenceGroup) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                let start = dragStartGroupOffsets[group] ?? store.clusterOffset(for: group)
                dragStartGroupOffsets[group] = start
                store.setClusterOffset(
                    CGSize(
                        width: start.width + value.translation.width / max(0.01, store.zoom),
                        height: start.height + value.translation.height / max(0.01, store.zoom)
                    ),
                    for: group
                )
            }
            .onEnded { _ in
                dragStartGroupOffsets[group] = nil
            }
    }

    private func selectedGroups(defaultingTo group: ReferenceGroup, activeItemID: ReferenceItem.ID) -> Set<ReferenceGroup> {
        guard store.selectedItemIDs.contains(activeItemID) else { return [group] }
        let groups = Set(store.visibleItems.compactMap { item in
            store.selectedItemIDs.contains(item.id) ? item.group : nil
        })
        return groups.isEmpty ? [group] : groups
    }

    private func selectedItemIDs(defaultingTo id: ReferenceItem.ID) -> Set<ReferenceItem.ID> {
        store.selectedItemIDs.isEmpty ? [id] : store.selectedItemIDs
    }

    private func itemRect(for item: ReferenceItem, in size: CGSize) -> CGRect {
        let position = infinityPosition(for: item, in: size)
        let itemSize = infinitySize(for: item)
        return CGRect(
            x: position.x - itemSize.width / 2,
            y: position.y - itemSize.height / 2,
            width: itemSize.width,
            height: itemSize.height
        )
    }

    /// Infinity positions are already resolved in screen space, so culling is
    /// a cheap rectangle test. Overscan keeps cluster expansion and inertial
    /// navigation from revealing an empty edge between render passes.
    private func visibleInfinityItems(in size: CGSize) -> [ReferenceItem] {
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -220, dy: -220)
        return store.visibleItems.filter { item in
            store.focusedItemID == item.id
                || dragStartInfinityPositions[item.id] != nil
                || viewport.intersects(itemRect(for: item, in: size))
        }
    }

    private func infinityRippleAnchors(in size: CGSize) -> [ReferenceRippleAnchor] {
        store.visibleItems.map { item in
            ReferenceRippleAnchor(id: item.id, point: infinityPosition(for: item, in: size))
        }
    }

    private func infinityPosition(for item: ReferenceItem, in size: CGSize) -> CGPoint {
        if store.infinityClustered {
            let local = clusterLocalPosition(for: item)
            let center = clusterCenter(for: item.group, in: size)
            let scale = infinityScale(for: item)
            return CGPoint(
                x: center.x + local.x * scale,
                y: center.y + local.y * scale
            )
        }

        return CGPoint(
            x: size.width / 2 + store.infinityPan.width + item.infinityPosition.x * store.zoom,
            y: size.height / 2 + store.infinityPan.height + item.infinityPosition.y * store.zoom
        )
    }

    private func clusterLocalPosition(for item: ReferenceItem) -> CGPoint {
        let peers = store.visibleItems.filter { $0.group == item.group }
        let index = peers.firstIndex(where: { $0.id == item.id }) ?? 0
        let columns = switch item.group {
        case .file, .website:
            9
        case .memory, .link:
            8
        }
        let rows = max(1, Int(ceil(Double(peers.count) / Double(columns))))
        let column = index % columns
        let row = index / columns
        let rowOffset = row.isMultiple(of: 2) ? CGFloat.zero : 15
        let jitterX = CGFloat((abs(item.fileName.hashValue) % 9) - 4)
        let jitterY = CGFloat((abs(item.title.hashValue) % 7) - 3)
        return CGPoint(
            x: (CGFloat(column) - CGFloat(columns - 1) / 2) * 58 + rowOffset + jitterX,
            y: (CGFloat(row) - CGFloat(rows - 1) / 2) * 48 + jitterY
        )
    }

    private func clusterCenter(for group: ReferenceGroup, in size: CGSize) -> CGPoint {
        let base = clusterBaseCenter(for: group, in: size)
        let offset = store.clusterOffset(for: group)
        let focusOffset = expandedClusterFocusOffsets[group] ?? .zero
        return CGPoint(
            x: base.x + offset.width * store.zoom + focusOffset.width,
            y: base.y + offset.height * store.zoom + focusOffset.height
        )
    }

    private func clusterBaseCenter(for group: ReferenceGroup, in size: CGSize) -> CGPoint {
        let worldCenter = clusterWorldCenter(for: group)
        return CGPoint(
            x: size.width / 2 + store.infinityPan.width + worldCenter.x * store.zoom,
            y: size.height / 2 + store.infinityPan.height + worldCenter.y * store.zoom
        )
    }

    private func clusterWorldCenter(for group: ReferenceGroup) -> CGPoint {
        switch group {
        case .file:
            CGPoint(x: -430, y: -285)
        case .memory:
            CGPoint(x: -430, y: 285)
        case .link:
            CGPoint(x: 430, y: 285)
        case .website:
            CGPoint(x: 430, y: -285)
        }
    }

    private func openCluster(_ group: ReferenceGroup, in size: CGSize) {
        store.clearFocus()
        store.selectItems(with: [])
        expandedInfinityGroup = group
        expandedClusterFocusOffsets.removeAll()

        let currentCenter = clusterCenter(for: group, in: size)
        let target = CGPoint(x: size.width * 0.50, y: size.height * 0.50)
        for otherGroup in ReferenceGroup.allCases where otherGroup != group {
            store.groupZooms[otherGroup] = min(store.zoomScale(for: otherGroup), 0.86)
        }
        store.groupZooms[group] = max(store.zoomScale(for: group), 1.62)
        expandedClusterFocusOffsets[group] = CGSize(
            width: target.x - currentCenter.x,
            height: target.y - currentCenter.y
        )
    }

    private func clusterLabelPosition(for group: ReferenceGroup, in size: CGSize) -> CGPoint {
        let bounds = clusterSurfaceBounds(for: group, in: size)
        return CGPoint(x: bounds.minX + 58, y: bounds.minY + 16)
    }

    private func clusterSurfaceBounds(for group: ReferenceGroup, in size: CGSize) -> CGRect {
        let center = clusterCenter(for: group, in: size)
        let contentBounds = clusterBounds(for: group, in: size)
            .insetBy(dx: -34, dy: -32)
        let minimum = CGRect(
            x: center.x - size.width * 0.215,
            y: center.y - size.height * 0.185,
            width: size.width * 0.43,
            height: size.height * 0.37
        )
        return contentBounds.union(minimum)
    }

    private func nearestCluster(to location: CGPoint, in size: CGSize) -> ReferenceGroup {
        if let expandedInfinityGroup,
           clusterSurfaceBounds(for: expandedInfinityGroup, in: size)
            .insetBy(dx: -28, dy: -28)
            .contains(location) {
            return expandedInfinityGroup
        }

        if let directHit = clusterHitGroup(at: location, in: size) {
            return directHit
        }

        let containingSurfaces = ReferenceGroup.allCases.filter { group in
            clusterSurfaceBounds(for: group, in: size)
                .insetBy(dx: -18, dy: -18)
                .contains(location)
        }

        if let containingSurface = containingSurfaces.min(by: {
            distanceSquared(from: location, to: clusterCenter(for: $0, in: size))
                < distanceSquared(from: location, to: clusterCenter(for: $1, in: size))
        }) {
            return containingSurface
        }

        return ReferenceGroup.allCases.min { first, second in
            distanceSquared(from: location, to: clusterCenter(for: first, in: size))
                < distanceSquared(from: location, to: clusterCenter(for: second, in: size))
        } ?? .file
    }

    private func clusterHitGroup(at location: CGPoint, in size: CGSize) -> ReferenceGroup? {
        let directItemHits = store.visibleItems.filter { item in
            itemRect(for: item, in: size)
                .insetBy(dx: -10, dy: -10)
                .contains(location)
        }

        if let closestItem = directItemHits.min(by: {
            distanceSquared(from: location, to: infinityPosition(for: $0, in: size))
                < distanceSquared(from: location, to: infinityPosition(for: $1, in: size))
        }) {
            return closestItem.group
        }

        let containingClusters = ReferenceGroup.allCases.filter { group in
            clusterBounds(for: group, in: size)
                .insetBy(dx: -24, dy: -24)
                .contains(location)
        }

        guard !containingClusters.isEmpty else { return nil }

        return containingClusters.min { first, second in
            nearestItemDistanceSquared(in: first, from: location, size: size)
                < nearestItemDistanceSquared(in: second, from: location, size: size)
        }
    }

    private func clusterBounds(for group: ReferenceGroup, in size: CGSize) -> CGRect {
        let rects = store.visibleItems
            .filter { $0.group == group }
            .map { itemRect(for: $0, in: size) }

        guard var bounds = rects.first else {
            let center = clusterCenter(for: group, in: size)
            return CGRect(x: center.x - 56, y: center.y - 28, width: 112, height: 56)
        }

        for rect in rects.dropFirst() {
            bounds = bounds.union(rect)
        }

        return bounds
    }

    private func nearestItemDistanceSquared(in group: ReferenceGroup, from location: CGPoint, size: CGSize) -> CGFloat {
        store.visibleItems
            .filter { $0.group == group }
            .map { distanceSquared(from: location, to: infinityPosition(for: $0, in: size)) }
            .min() ?? distanceSquared(from: location, to: clusterCenter(for: group, in: size))
    }

    private func zoomNearestCluster(at location: CGPoint, by delta: CGFloat, in size: CGSize) {
        guard store.infinityClustered else {
            zoomWholeInfinity(at: location, by: delta, in: size)
            return
        }

        let group = nearestCluster(to: location, in: size)
        let base = clusterBaseCenter(for: group, in: size)
        let oldScale = max(0.01, store.zoom * store.zoomScale(for: group))
        let oldOffset = store.clusterOffset(for: group)
        let focusOffset = expandedClusterFocusOffsets[group] ?? .zero
        let oldCenter = CGPoint(
            x: base.x + oldOffset.width * store.zoom + focusOffset.width,
            y: base.y + oldOffset.height * store.zoom + focusOffset.height
        )
        let localAnchor = CGPoint(
            x: (location.x - oldCenter.x) / oldScale,
            y: (location.y - oldCenter.y) / oldScale
        )

        store.adjustZoom(for: group, by: delta)

        let newScale = max(0.01, store.zoom * store.zoomScale(for: group))
        let desiredCenter = CGPoint(
            x: location.x - localAnchor.x * newScale,
            y: location.y - localAnchor.y * newScale
        )
        if expandedClusterFocusOffsets[group] != nil {
            expandedClusterFocusOffsets[group] = CGSize(
                width: desiredCenter.x - base.x - oldOffset.width * store.zoom,
                height: desiredCenter.y - base.y - oldOffset.height * store.zoom
            )
        } else {
            let nextOffset = CGSize(
                width: (desiredCenter.x - base.x) / max(0.01, store.zoom),
                height: (desiredCenter.y - base.y) / max(0.01, store.zoom)
            )
            store.setClusterOffset(nextOffset, for: group)
        }
    }

    private func zoomWholeInfinity(at location: CGPoint, by delta: CGFloat, in size: CGSize) {
        let before = max(0.01, store.zoom)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let localAnchor = CGPoint(
            x: (location.x - center.x - store.infinityPan.width) / before,
            y: (location.y - center.y - store.infinityPan.height) / before
        )

        store.adjustGlobalZoom(by: delta)

        store.infinityPan = CGSize(
            width: location.x - center.x - localAnchor.x * store.zoom,
            height: location.y - center.y - localAnchor.y * store.zoom
        )
        baseZoom = store.infinityZoom
        basePan = store.infinityPan
    }

    private func panInfinity(by delta: CGSize) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            store.infinityPan = CGSize(
                width: store.infinityPan.width + delta.width,
                height: store.infinityPan.height + delta.height
            )
        }
        basePan = store.infinityPan
    }

    private func infinityMagnificationGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                withDirectManipulation {
                    let nextZoom = min(2.80, max(0.24, baseZoom * value.magnification))
                    let ratio = nextZoom / max(0.01, baseZoom)
                    store.infinityZoom = nextZoom
                    store.infinityPan = CGSize(
                        width: basePan.width * ratio,
                        height: basePan.height * ratio
                    )
                }
            }
            .onEnded { _ in
                baseZoom = store.infinityZoom
                basePan = store.infinityPan
            }
    }

    private func distanceSquared(from first: CGPoint, to second: CGPoint) -> CGFloat {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return dx * dx + dy * dy
    }

    private func infinityScale(for item: ReferenceItem) -> CGFloat {
        if store.infinityClustered {
            store.zoom * store.zoomScale(for: item.group)
        } else {
            store.zoom
        }
    }

    private func infinityWidth(for item: ReferenceItem) -> CGFloat {
        switch item.kind {
        case .phone:
            46
        case .website, .laptop:
            96
        case .typography:
            72
        case .app, .product:
            78
        }
    }

    private func infinitySize(for item: ReferenceItem) -> CGSize {
        let width = infinityWidth(for: item) * infinityScale(for: item)
        return CGSize(width: width, height: width / max(0.1, item.aspectRatio))
    }

}

private struct InfinitySpaceBackground: View {
    var zoom: CGFloat
    var pan: CGSize

    var body: some View {
        Canvas { context, size in
            let worldSpacing: CGFloat = 172
            let spacing = min(164, max(44, worldSpacing * max(0.32, zoom)))
            let dotRadius = min(1.15, max(0.55, 0.70 + zoom * 0.12))
            let offsetX = normalizedRemainder(pan.width, spacing)
            let offsetY = normalizedRemainder(pan.height, spacing)

            var dots = Path()
            var x = offsetX - spacing
            while x <= size.width + spacing {
                var y = offsetY - spacing
                while y <= size.height + spacing {
                    dots.addEllipse(in: CGRect(
                        x: x - dotRadius,
                        y: y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    ))
                    y += spacing
                }
                x += spacing
            }
            context.fill(dots, with: .color(Color.black.opacity(0.028)))

            let origin = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
            if origin.x > -32, origin.x < size.width + 32 {
                var verticalAxis = Path()
                verticalAxis.move(to: CGPoint(x: origin.x, y: 0))
                verticalAxis.addLine(to: CGPoint(x: origin.x, y: size.height))
                context.stroke(verticalAxis, with: .color(Color.black.opacity(0.026)), lineWidth: 1)
            }
            if origin.y > -32, origin.y < size.height + 32 {
                var horizontalAxis = Path()
                horizontalAxis.move(to: CGPoint(x: 0, y: origin.y))
                horizontalAxis.addLine(to: CGPoint(x: size.width, y: origin.y))
                context.stroke(horizontalAxis, with: .color(Color.black.opacity(0.026)), lineWidth: 1)
            }
        }
    }

    private func normalizedRemainder(_ value: CGFloat, _ divisor: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

struct ClusterLabel: View {
    var group: ReferenceGroup
    var zoom: CGFloat

    var body: some View {
        Label(group.rawValue, systemImage: group.symbol)
            .lociFont(size: 9.5, weight: .semibold, relativeTo: .caption2)
            .foregroundStyle(.black.opacity(0.28 + min(0.12, (zoom - 1) * 0.08)))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.black.opacity(0.045), lineWidth: 0.6)
            }
            .allowsHitTesting(true)
    }
}

struct InfinityClusterSurface: View {
    var group: ReferenceGroup
    var bounds: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(surfaceColor)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.035), lineWidth: 0.7)
            }
            .frame(width: bounds.width, height: bounds.height)
            .position(x: bounds.midX, y: bounds.midY)
    }

    private var surfaceColor: Color {
        switch group {
        case .file:
            Color(red: 0.965, green: 0.972, blue: 0.982).opacity(0.62)
        case .memory:
            Color(red: 0.982, green: 0.970, blue: 0.948).opacity(0.60)
        case .link:
            Color(red: 0.970, green: 0.980, blue: 0.962).opacity(0.58)
        case .website:
            Color(red: 0.982, green: 0.962, blue: 0.958).opacity(0.58)
        }
    }
}

private struct ReferenceRippleAnchor {
    let id: ReferenceItem.ID
    let point: CGPoint
}

private struct ReferenceClickRipple {
    let id: UUID
    let sourceID: ReferenceItem.ID
    let offsets: [ReferenceItem.ID: CGSize]
    var strength: CGFloat
}

private enum ReferenceClickRippleTuning {
    static let gridScatterMagnitude: CGFloat = 12
    static let gridReach: CGFloat = 220
    static let canvasScatterMagnitude: CGFloat = 12
    static let canvasReach: CGFloat = 190
    static let infinityScatterMagnitude: CGFloat = 13
    static let infinityReach: CGFloat = 210
    static let falloffPower: CGFloat = 3.15
    static let sourcePulseScale: CGFloat = 0.006
    static let settleDelay: TimeInterval = 0.045
    static let cleanupDelay: TimeInterval = 0.20
    static let scatterOut = Animation.spring(response: 0.085, dampingFraction: 0.90)
    static let settleBack = Animation.spring(response: 0.14, dampingFraction: 0.97)
}

private func startReferenceClickRipple(
    _ ripple: Binding<ReferenceClickRipple?>,
    at origin: CGPoint,
    sourceID: ReferenceItem.ID,
    offsets: [ReferenceItem.ID: CGSize]
) {
    guard !AppMotion.reduceMotion else { return }

    let token = UUID()
    ripple.wrappedValue = ReferenceClickRipple(id: token, sourceID: sourceID, offsets: offsets, strength: 0)

    withAnimation(ReferenceClickRippleTuning.scatterOut) {
        ripple.wrappedValue = ReferenceClickRipple(id: token, sourceID: sourceID, offsets: offsets, strength: 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + ReferenceClickRippleTuning.settleDelay) {
        guard ripple.wrappedValue?.id == token else { return }
        withAnimation(ReferenceClickRippleTuning.settleBack) {
            ripple.wrappedValue = ReferenceClickRipple(id: token, sourceID: sourceID, offsets: offsets, strength: 0)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + ReferenceClickRippleTuning.cleanupDelay) {
        guard ripple.wrappedValue?.id == token else { return }
        ripple.wrappedValue = nil
    }
}

private func referenceClickRippleOffsets(
    anchors: [ReferenceRippleAnchor],
    origin: CGPoint,
    magnitude: CGFloat,
    reach: CGFloat
) -> [ReferenceItem.ID: CGSize] {
    var offsets: [ReferenceItem.ID: CGSize] = [:]
    offsets.reserveCapacity(min(anchors.count, 18))

    for anchor in anchors {
        let dx = anchor.point.x - origin.x
        let dy = anchor.point.y - origin.y
        let distanceSquared = dx * dx + dy * dy
        guard distanceSquared > 1, distanceSquared < reach * reach else { continue }

        let distance = sqrt(distanceSquared)
        let normalizedDistance = min(1, distance / reach)
        let falloff = pow(max(0, 1 - normalizedDistance), ReferenceClickRippleTuning.falloffPower)
        let push = magnitude * falloff
        guard push > 0.25 else { continue }

        offsets[anchor.id] = CGSize(width: dx / distance * push, height: dy / distance * push)
    }

    return offsets
}

private func referenceClickRippleOffset(for itemID: ReferenceItem.ID, ripple: ReferenceClickRipple?) -> CGSize {
    guard let ripple, ripple.strength > 0, let offset = ripple.offsets[itemID] else { return .zero }
    return CGSize(width: offset.width * ripple.strength, height: offset.height * ripple.strength)
}

private func clickRippleStrength(for itemID: ReferenceItem.ID, ripple: ReferenceClickRipple?) -> CGFloat {
    guard ripple?.sourceID == itemID else { return 0 }
    return ripple?.strength ?? 0
}

struct ReferenceGridTile: View {
    var item: ReferenceItem
    var xBookmarkPayload: XBookmarkPayloadSummary? = nil
    var isSelected: Bool
    var clickRippleStrength: CGFloat = 0
    @State private var isHovering = false
    private let selectionBlue = LociColor.accent

    var body: some View {
        ReferenceThumbnail(item: item, xBookmarkPayload: xBookmarkPayload)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LociColor.surface.opacity(0.96))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? selectionBlue : LociColor.hairline.opacity(isHovering ? 0.85 : 0.45),
                        lineWidth: isSelected ? 2.2 : 0.6
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .lociFont(size: 16, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(selectionBlue)
                        .background(LociColor.surface, in: Circle())
                        .padding(7)
                        .transition(.scale(scale: 0.72).combined(with: .opacity))
                }
            }
            .shadow(
                color: isSelected ? selectionBlue.opacity(0.18) : .black.opacity(isHovering ? 0.075 : 0.050),
                radius: isSelected ? 10 : (isHovering ? 7 : 4),
                x: 0,
                y: isSelected ? 4 : (isHovering ? 3 : 2)
            )
            .scaleEffect((isSelected ? 1.012 : (isHovering ? 1.006 : 1)) + ReferenceClickRippleTuning.sourcePulseScale * clickRippleStrength)
            .animation(AppMotion.hover, value: isHovering)
            .animation(AppMotion.snappy, value: isSelected)
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.title), \(item.subtitle)")
    }
}

struct ReferenceTile: View {
    var item: ReferenceItem
    var xBookmarkPayload: XBookmarkPayloadSummary? = nil
    var isSelected: Bool
    var showsTitle: Bool
    let namespace: Namespace.ID
    var clickRippleStrength: CGFloat = 0
    @State private var isHovering = false
    private let selectionBlue = LociColor.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ReferenceThumbnail(item: item, xBookmarkPayload: xBookmarkPayload)
                .aspectRatio(item.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isSelected ? selectionBlue : LociColor.hairline.opacity(isHovering ? 0.9 : 0.55),
                            lineWidth: isSelected ? 2.1 : 0.7
                        )
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .lociFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                            .foregroundStyle(selectionBlue)
                            .background(LociColor.surface, in: Circle())
                            .padding(4)
                            .transition(.scale(scale: 0.72).combined(with: .opacity))
                    }
                }
                .shadow(
                    color: .black.opacity(isSelected ? 0.14 : 0.065),
                    radius: isHovering ? 9 : 4,
                    y: isHovering ? 5 : 2
                )

            if showsTitle {
                Text(item.title)
                    .lociFont(size: 8.5, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .scaleEffect((isSelected ? 1.014 : (isHovering ? 1.018 : 1)) + ReferenceClickRippleTuning.sourcePulseScale * clickRippleStrength)
        .animation(AppMotion.hover, value: isHovering)
        .animation(AppMotion.snappy, value: isSelected)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.subtitle)")
    }
}

private struct ReferenceContextMenuModifier: ViewModifier {
    let item: ReferenceItem
    @Bindable var store: LibraryStore
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                withAnimation(AppMotion.hero) {
                    if store.focusedItemID == item.id {
                        store.clearFocus()
                    } else {
                        store.focus(item)
                    }
                }
            } label: {
                Label(store.focusedItemID == item.id ? "Close Preview" : "Open Preview", systemImage: "arrow.up.left.and.arrow.down.right")
            }

            Button {
                store.select(item)
            } label: {
                Label("Select Only This", systemImage: "checkmark.circle")
            }

            Button {
                store.select(item, additive: true)
            } label: {
                Label(store.selectedItemIDs.contains(item.id) ? "Remove from Selection" : "Add to Selection", systemImage: "checklist")
            }

            if store.mode == .canvas && store.selectedItemIDs.contains(item.id) && store.selectedItemIDs.count > 1 {
                Button {
                    withAnimation(AppMotion.quick) {
                        store.rearrangeSelectedCanvasItems()
                    }
                } label: {
                    Label("Rearrange Selected", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }

            Divider()

            if item.subtitle.hasPrefix("http://") || item.subtitle.hasPrefix("https://") {
                Button {
                    if let url = URL(string: item.subtitle) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Link in Browser", systemImage: "safari")
                }

                Button {
                    copyToPasteboard(item.subtitle)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
            }

            Button {
                copyToPasteboard(item.title)
            } label: {
                Label("Copy Title", systemImage: "textformat")
            }

            Button {
                copyToPasteboard(item.fileName)
            } label: {
                Label("Copy File Name", systemImage: "doc.on.doc")
            }

            if let originalURL = originalFileURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([originalURL])
                } label: {
                    Label("Reveal Original in Finder", systemImage: "finder")
                }
            }

            Button {
                store.importPasteboard(undoManager: undoManager)
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }

            Divider()

            Menu {
                Button {
                    let idsToMove: Set<ReferenceItem.ID> = store.selectedItemIDs.contains(item.id) && store.selectedItemIDs.count > 1
                        ? store.selectedItemIDs
                        : [item.id]
                    store.moveReferences(idsToMove, to: nil, undoManager: undoManager)
                } label: {
                    Label("No Collection", systemImage: "tray")
                }
                .disabled(item.collectionID == nil)

                ForEach(store.collections) { collection in
                    Button {
                        let idsToMove: Set<ReferenceItem.ID> = store.selectedItemIDs.contains(item.id) && store.selectedItemIDs.count > 1
                            ? store.selectedItemIDs
                            : [item.id]
                        store.moveReferences(idsToMove, to: collection.id, undoManager: undoManager)
                    } label: {
                        Label(collection.name, systemImage: collection.symbol)
                    }
                    .disabled(item.collectionID == collection.id)
                }
            } label: {
                let count = store.selectedItemIDs.contains(item.id) && store.selectedItemIDs.count > 1 ? store.selectedItemIDs.count : 1
                Label(count > 1 ? "Move \(count) to Collection" : "Move to Collection", systemImage: "folder")
            }

            Button {
                store.duplicateReference(id: item.id, undoManager: undoManager)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            if item.group == .file || item.kind == .product {
                Menu {
                    ForEach(VariationType.allCases, id: \.self) { type in
                        Button {
                            store.generateVariation(of: type, for: item, undoManager: undoManager)
                        } label: {
                            Label(type.rawValue, systemImage: type.symbol)
                        }
                    }
                } label: {
                    Label("Generate Variation", systemImage: "wand.and.stars")
                }
            }

            Divider()

            if item.isTrashed {
                Button {
                    store.restoreReference(id: item.id, undoManager: undoManager)
                } label: {
                    Label("Restore from Trash", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    store.trashReference(id: item.id, undoManager: undoManager)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
    }

    private var originalFileURL: URL? {
        guard let store = LociPersistentStore.shared else { return nil }
        let candidates = [
            item.fileName,
            "webloc_\(item.id.uuidString.lowercased()).webloc"
        ]
        return candidates
            .map { store.originalsURL.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private extension View {
    func focusMatchedGeometry(id: ReferenceItem.ID, namespace: Namespace.ID, isSource: Bool) -> some View {
        matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
    }

    func referenceContextMenu(item: ReferenceItem, store: LibraryStore) -> some View {
        modifier(ReferenceContextMenuModifier(item: item, store: store))
    }
}

private struct RightClickSelectionMonitor: NSViewRepresentable {
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickSelectionView {
        let view = RightClickSelectionView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: RightClickSelectionView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    static func dismantleNSView(_ nsView: RightClickSelectionView, coordinator: ()) {
        nsView.teardown()
    }
}

private final class RightClickSelectionView: NSView {
    var onRightClick: (() -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitor()
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, self.window === event.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) {
                self.onRightClick?()
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    func teardown() {
        removeMonitor()
        onRightClick = nil
    }

}

struct MouseZoomCapture: NSViewRepresentable {
    var isEnabled = true
    var onZoom: (CGFloat, CGPoint?) -> Void
    var onPan: ((CGSize) -> Void)? = nil

    func makeNSView(context: Context) -> ZoomCatcherView {
        let view = ZoomCatcherView()
        view.isEnabled = isEnabled
        view.onZoom = onZoom
        view.onPan = onPan
        return view
    }

    func updateNSView(_ nsView: ZoomCatcherView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onZoom = onZoom
        nsView.onPan = onPan
    }

    static func dismantleNSView(_ nsView: ZoomCatcherView, coordinator: ()) {
        nsView.teardown()
    }
}

    final class ZoomCatcherView: NSView {
        var isEnabled = true
        var onZoom: ((CGFloat, CGPoint?) -> Void)?
        var onPan: ((CGSize) -> Void)?
    nonisolated(unsafe) private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        guard window != nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event)
        }
    }

    func teardown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        onZoom = nil
        onPan = nil
    }

    override func scrollWheel(with event: NSEvent) {
        _ = handleScroll(event)
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard let window else { return event }
        guard isEnabled else { return event }
        let appKitLocation = convert(event.locationInWindow, from: nil)
        guard bounds.contains(appKitLocation), window.isKeyWindow else { return event }

        let location = CGPoint(
            x: appKitLocation.x,
            y: bounds.height - appKitLocation.y
        )

        let scrollX = event.scrollingDeltaX == 0 ? event.deltaX : event.scrollingDeltaX
        let scrollY = event.scrollingDeltaY == 0 ? event.deltaY : event.scrollingDeltaY
        let shouldZoom = event.modifierFlags.intersection([.command, .option]).isEmpty == false
        guard shouldZoom else {
            guard let onPan else { return event }
            let panDelta = normalizedPanDelta(
                x: scrollX,
                y: scrollY,
                isPrecise: event.hasPreciseScrollingDeltas,
                isMomentum: event.momentumPhase != []
            )
            guard abs(panDelta.width) > 0.05 || abs(panDelta.height) > 0.05 else { return nil }
            onPan(panDelta)
            return nil
        }

        let normalized = normalizedZoomDelta(
            scrollY,
            isPrecise: event.hasPreciseScrollingDeltas,
            isMomentum: event.momentumPhase != []
        )
        onZoom?(normalized, location)
        return nil
    }

    private func normalizedPanDelta(x: CGFloat, y: CGFloat, isPrecise: Bool, isMomentum: Bool) -> CGSize {
        let multiplier: CGFloat = isPrecise ? 0.62 : 6.5
        let momentumDamping: CGFloat = isMomentum ? 0.78 : 1.0
        let maxStep: CGFloat = isPrecise ? 38 : 60

        return CGSize(
            width: clamp(-x * multiplier * momentumDamping, -maxStep, maxStep),
            height: clamp(y * multiplier * momentumDamping, -maxStep, maxStep)
        )
    }

    private func normalizedZoomDelta(_ y: CGFloat, isPrecise: Bool, isMomentum: Bool) -> CGFloat {
        let sensitivity: CGFloat = isPrecise ? 0.00118 : 0.0125
        let momentumDamping: CGFloat = isMomentum ? 0.74 : 1.0
        let rawStep = clamp(y * sensitivity * momentumDamping, -0.036, 0.036)
        return exp(rawStep) - 1
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(upper, max(lower, value))
    }

}
