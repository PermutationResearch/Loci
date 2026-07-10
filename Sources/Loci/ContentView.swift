import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @Namespace private var referenceNamespace
    @State private var store: LibraryStore
    @State private var isFileDropTargeted = false
    @Environment(\.undoManager) private var undoManager

    init(store: LibraryStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        LociShell(store: store, namespace: referenceNamespace)
            .frame(minWidth: 1040, minHeight: 660)
            .background(LociColor.surface)
            .tint(.primary)
            .overlay {
                if isFileDropTargeted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(LociColor.border, style: StrokeStyle(lineWidth: 1.2, dash: [7, 5]))
                        .background(LociColor.surfaceRecessed, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .url, .plainText, .text], isTargeted: $isFileDropTargeted) { providers in
                importDroppedReferences(from: providers)
            }
            .overlay {
                FeedbackToast()
                ErrorToast()
            }
    }

    private func importDroppedReferences(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let textProviders = providers.filter {
            $0.canLoadObject(ofClass: NSString.self) || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard !fileProviders.isEmpty || !textProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.droppedFileURL(from: item) else { return }
                Task { @MainActor in
                    store.importFiles([url], undoManager: undoManager)
                }
            }
        }

        for provider in textProviders {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    guard let url = Self.droppedFileURL(from: item) else { return }
                    Task { @MainActor in
                        store.importWebsiteOrLink(url.absoluteString, undoManager: undoManager)
                    }
                }
            } else {
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let value = (object as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else { return }
                    Task { @MainActor in
                        store.importText(value)
                    }
                }
            }
        }
        return true
    }

    nonisolated private static func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }
}

struct LociShell: View {
    @Bindable var store: LibraryStore
    let namespace: Namespace.ID
    @Environment(\.undoManager) private var undoManager
    @State private var warmedModes: [ViewMode] = []
    @State private var didStartDemoAutoplay = false
    @State private var demoAutoplayObserver: NSObjectProtocol?
    @State private var isShowingCommandPalette = false

    var body: some View {
        workspace
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(AppMotion.instant, value: store.mode)
            .animation(AppMotion.toast, value: store.selectedItemIDs)
            .animation(AppMotion.hero, value: store.focusedItemID)
            .focusable()
            .onKeyPress(.leftArrow) {
                guard store.focusedItemID != nil else { return .ignored }
                withAnimation(AppMotion.smooth) {
                    _ = store.focusAdjacentVisibleItem(offset: -1)
                }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard store.focusedItemID != nil else { return .ignored }
                withAnimation(AppMotion.smooth) {
                    _ = store.focusAdjacentVisibleItem(offset: 1)
                }
                return .handled
            }
            .onDeleteCommand {
                store.sendSelectionToTrash(undoManager: undoManager)
            }
            .onExitCommand {
                if store.focusedItemID != nil {
                    store.requestFocusDismissal()
                } else {
                    store.selectedItemIDs.removeAll()
                    store.searchText = ""
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .lociShowCommandPalette)) { _ in
                withAnimation(AppMotion.quick) {
                    isShowingCommandPalette = true
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    store.warmCommonReferenceFilters()
                }
                startDemoAutoplayIfNeeded()
            }
    }

    private var workspace: some View {
        ZStack {
            LociColor.surface

            libraryWorkspace
            referenceChrome
            commandPaletteOverlay
        }
    }

    private var libraryWorkspace: some View {
        HStack(spacing: 0) {
            LociSidebar(store: store)
                .frame(width: 164)

            MainReferencePane(store: store, namespace: namespace)
        }
    }

    @ViewBuilder
    private var referenceChrome: some View {
        if showsReferenceChrome {
            LociTitle(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 22)

            BottomModeBar(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 20)

            UtilityCluster(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 18)
                .padding(.bottom, 21)
        }

        if showsReferenceChrome && !store.selectedItemIDs.isEmpty && store.selectedFilter != .trash {
            BatchActionBar(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 60)
                .transition(AppMotion.bottomToastTransition)
        }

        if showsReferenceChrome && store.mode == .grid {
            ZoomSlider(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 22)
                .padding(.trailing, 18)
        }
    }

    @ViewBuilder
    private var commandPaletteOverlay: some View {
        if isShowingCommandPalette {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture { isShowingCommandPalette = false }

            CommandPaletteView(store: store, isPresented: $isShowingCommandPalette)
                .frame(width: 560)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(30)
        }
    }

    private var showsReferenceChrome: Bool {
        guard store.focusedItemID == nil else {
            return false
        }

        switch store.selectedFilter {
        case .all, .inbox, .xBookmarks, .trash, .collection:
            return true
        case .files, .chat, .api, .graph, .timeline, .review, .capabilities, .patterns, .rules:
            return false
        }
    }

    private func startDemoAutoplayIfNeeded() {
        guard ProcessInfo.processInfo.environment["LOCI_DEMO_AUTOPLAY"] == "1",
              !didStartDemoAutoplay else {
            return
        }
        didStartDemoAutoplay = true

        store.removeGeneratedDemoLibraryIfPresent()
        applyDemoStep("reset")
        demoAutoplayObserver = NotificationCenter.default.addObserver(
            forName: .lociDemoStep,
            object: nil,
            queue: .main
        ) { notification in
            guard let step = notification.userInfo?["step"] as? String else { return }
            Task { @MainActor in
                applyDemoStep(step)
            }
        }
    }

    private func applyDemoStep(_ step: String) {
        switch step {
        case "reset":
            withAnimation(AppMotion.quick) {
                store.selectedFilter = .all
                store.mode = .grid
                store.gridZoom = 0.88
                store.searchText = ""
                store.clearFocus()
                store.clearSelection()
            }
        case "select":
            if let item = demoItem() {
                withAnimation(AppMotion.selection) {
                    store.select(item)
                }
            }
        case "focus":
            if let item = demoItem() {
                withAnimation(AppMotion.hero) {
                    store.focus(item)
                }
            }
        case "close":
            withAnimation(AppMotion.hero) {
                store.clearFocus()
            }
        case "canvas":
            withAnimation(AppMotion.smooth) {
                store.selectedFilter = realDemoFilter(preferredCollectionNames: ["Websites"])
                store.searchText = ""
                store.clearSelection()
                store.mode = .canvas
                store.canvasZoom = 1.04
                store.canvasPan = CGSize(width: -34, height: 18)
            }
        case "infinity":
            withAnimation(AppMotion.smooth) {
                store.selectedFilter = realDemoFilter(preferredCollectionNames: ["App icon", "Websites"])
                store.mode = .infinity
                store.infinityClustered = true
                store.infinityZoom = 0.64
                store.infinityPan = CGSize(width: 8, height: 0)
                store.groupZooms = Dictionary(uniqueKeysWithValues: ReferenceGroup.allCases.map { ($0, 1) })
                store.groupOffsets = Dictionary(uniqueKeysWithValues: ReferenceGroup.allCases.map { ($0, .zero) })
            }
        case "xsearch":
            withAnimation(AppMotion.smooth) {
                store.mode = .grid
                store.selectedFilter = .xBookmarks
                store.searchText = "icon"
                store.gridZoom = 0.96
            }
        default:
            break
        }
    }

    private func realDemoFilter(preferredCollectionNames names: [String]) -> CollectionFilter {
        for name in names {
            if let collectionID = store.collections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.id {
                return .collection(collectionID)
            }
        }
        return .all
    }

    private func demoItem() -> ReferenceItem? {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
        return store.visibleItems.first { $0.websiteURL != nil && !$0.isXBookmark }
            ?? store.visibleItems.first { imageExtensions.contains($0.fileExtension) }
            ?? store.visibleItems.first { $0.isXBookmark }
            ?? store.visibleItems.dropFirst(1).first
            ?? store.visibleItems.first
    }
}

private extension Notification.Name {
    static let lociDemoStep = Notification.Name("LociDemoStep")
}

struct MainReferencePane: View {
    @Bindable var store: LibraryStore
    let namespace: Namespace.ID
    @Environment(\.undoManager) private var undoManager
    @State private var warmedModes: [ViewMode] = []

    var body: some View {
        ZStack {
            if shouldRenderMode(.grid) {
                ReferenceGridView(store: store, namespace: namespace, isActive: store.mode == .grid)
                    .opacity(store.mode == .grid ? 1 : 0)
                    .allowsHitTesting(store.mode == .grid)
                    .accessibilityHidden(store.mode != .grid)
                    .zIndex(store.mode == .grid ? 3 : 0)
                    .animation(nil, value: store.mode)
            }

            if shouldRenderMode(.canvas) {
                ReferenceCanvasView(store: store, namespace: namespace, isActive: store.mode == .canvas)
                    .opacity(store.mode == .canvas ? 1 : 0)
                    .allowsHitTesting(store.mode == .canvas)
                    .accessibilityHidden(store.mode != .canvas)
                    .zIndex(store.mode == .canvas ? 3 : 0)
                    .animation(nil, value: store.mode)
            }

            if shouldRenderMode(.infinity) {
                ReferenceInfinityView(store: store, namespace: namespace, isActive: store.mode == .infinity)
                    .opacity(store.mode == .infinity ? 1 : 0)
                    .allowsHitTesting(store.mode == .infinity)
                    .accessibilityHidden(store.mode != .infinity)
                    .zIndex(store.mode == .infinity ? 3 : 0)
                    .animation(nil, value: store.mode)
            }

            if store.selectedFilter == .api {
                VaultWorkspaceView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LociColor.surface)
                    .zIndex(12)
            }

            if store.selectedFilter == .files {
                FileSystemWorkspaceView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LociColor.surface)
                    .zIndex(12)
            }

            if store.selectedFilter == .graph {
                GraphExplorerView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LociColor.surface)
                    .zIndex(12)
            }

            if store.selectedFilter == .chat {
                ChatWorkspaceView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LociColor.surface)
                    .zIndex(12)
            }

            if store.selectedFilter == .review {
                ReviewQueueView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LociColor.surface)
                    .zIndex(12)
            }

            if store.selectedFilter == .capabilities {
                CapabilitiesView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LociColor.surface)
                    .zIndex(12)
            }

            if store.selectedFilter == .patterns {
                PatternLibraryView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LociColor.surface)
                    .zIndex(12)
            }

            if store.selectedFilter == .rules {
                AutoRulesView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LociColor.surface)
                    .zIndex(12)
            }

            if shouldShowEmptyReferenceState {
                ReferenceEmptyStateView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LociColor.surface)
                    .zIndex(14)
            }

            if let focusedItem = store.focusedItem {
                InlineFocusStage(item: focusedItem, store: store, namespace: namespace)
                    .transition(.asymmetric(
                        insertion: AppMotion.previewTransition.animation(AppMotion.hero),
                        removal: .identity
                    ))
                    .zIndex(20)
            }
        }
        .background(LociColor.surface)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                store.importPasteboard(undoManager: undoManager)
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
        }
        .clipped()
        .onAppear {
            warmMode(store.mode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                warmAllModes()
            }
        }
        .onChange(of: store.mode) { _, newMode in
            warmMode(newMode)
        }
    }

    private var shouldShowEmptyReferenceState: Bool {
        guard store.visibleItems.isEmpty, store.focusedItemID == nil else { return false }
        switch store.selectedFilter {
        case .all, .inbox, .xBookmarks, .trash, .collection:
            return true
        case .files, .chat, .api, .graph, .timeline, .review, .capabilities, .patterns, .rules:
            return false
        }
    }

    private func shouldRenderMode(_ mode: ViewMode) -> Bool {
        mode == store.mode || warmedModes.contains(mode)
    }

    private func warmMode(_ mode: ViewMode) {
        guard !warmedModes.contains(mode) else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            warmedModes.append(mode)
        }
    }

    private func warmAllModes() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            for mode in ViewMode.allCases where !warmedModes.contains(mode) {
                warmedModes.append(mode)
            }
        }
    }
}

struct ReferenceEmptyStateView: View {
    @Bindable var store: LibraryStore
    @Environment(\.undoManager) private var undoManager
    @State private var isShowingLinkImport = false
    @State private var linkDraft = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .lociFont(size: 28, weight: .semibold, relativeTo: .title)
                .foregroundStyle(LociColor.inkFaint)
                .frame(width: 56, height: 56)
                .background(LociColor.surfaceRecessed, in: Circle())

            VStack(spacing: 5) {
                Text(title)
                    .font(LociFont.title)
                    .foregroundStyle(LociColor.ink)
                Text(subtitle)
                    .font(LociFont.caption)
                    .foregroundStyle(LociColor.inkTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                emptyStateButton("folder.badge.plus", "Import") {
                    openFileImporter()
                }
                emptyStateButton("link.badge.plus", "Link") {
                    linkDraft = ""
                    isShowingLinkImport = true
                }
                emptyStateButton("doc.on.clipboard", "Paste") {
                    store.importPasteboard(undoManager: undoManager)
                }
                emptyStateButton("bookmark", "X Sync") {
                    NSApp.sendAction(Selector(("openSettings")), to: nil, from: nil)
                }
            }
        }
        .padding(.horizontal, 28)
        .sheet(isPresented: $isShowingLinkImport) {
            ImportTextSheet(
                title: "Add Link",
                placeholder: "https://example.com",
                text: $linkDraft
            ) {
                store.importWebsiteOrLink(linkDraft, undoManager: undoManager)
                linkDraft = ""
            }
        }
    }

    private var title: String {
        switch store.selectedFilter {
        case .xBookmarks:
            "No X bookmarks yet"
        case .inbox:
            "Inbox is clear"
        case .trash:
            "Trash is empty"
        default:
            "Build your reference library"
        }
    }

    private var subtitle: String {
        switch store.selectedFilter {
        case .xBookmarks:
            "Connect X in Settings, then sync saved posts into this view."
        case .inbox:
            "New manual imports will land here first."
        case .trash:
            "Deleted references will appear here before permanent removal."
        default:
            "Drop files, paste links, or sync X bookmarks."
        }
    }

    private var symbol: String {
        switch store.selectedFilter {
        case .xBookmarks:
            "bookmark.square"
        case .inbox:
            "tray"
        case .trash:
            "trash"
        default:
            "square.grid.3x3"
        }
    }

    private func emptyStateButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(LociFont.caption)
                .foregroundStyle(LociColor.ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(LociColor.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(LociColor.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func openFileImporter() {
        let panel = NSOpenPanel()
        panel.title = "Import to \(AppBrand.name)"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            store.importFiles(panel.urls, undoManager: undoManager)
        }
    }
}

struct InlineFocusStage: View {
    var item: ReferenceItem
    @Bindable var store: LibraryStore
    let namespace: Namespace.ID

    @State private var pageIndex = 0
    @State private var showsDetails = false
    @State private var previewVisible = false
    @State private var chromeVisible = false
    @State private var isDismissing = false

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg"
    ]

    private var isImage: Bool {
        Self.imageExtensions.contains(item.fileExtension)
    }

    private var isWebsite: Bool {
        item.kind == .website || item.fileExtension == "webloc" || item.websiteURL != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = focusStageLayout(for: proxy.size)

            ZStack {
                Color.black.opacity(isDismissing ? 0.16 : (chromeVisible ? 0.46 : 0.28))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissFocus()
                    }
                    .animation(AppMotion.chromeReveal, value: chromeVisible)

                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(LociFont.headline)
                                .foregroundStyle(.white.opacity(0.88))
                                .lineLimit(1)
                            Text(item.fileName)
                                .font(LociFont.caption)
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            withAnimation(AppMotion.quick) {
                                showsDetails.toggle()
                            }
                        } label: {
                            Image(systemName: showsDetails ? "info.circle.fill" : "info.circle")
                                .font(LociFont.headline)
                                .foregroundStyle(.white.opacity(showsDetails ? 0.92 : 0.72))
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(showsDetails ? 0.16 : 0.10), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(showsDetails ? "Hide details" : "Show details")
                        .accessibilityLabel(showsDetails ? "Hide details" : "Show info")

                        Button {
                            dismissFocus()
                        } label: {
                            Image(systemName: "xmark")
                                .font(LociFont.headline)
                                .foregroundStyle(.white.opacity(0.72))
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.10), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Close")
                        .accessibilityLabel("Close")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                    .frame(height: layout.headerHeight, alignment: .top)
                    .opacity(chromeVisible ? 1 : 0)
                    .offset(y: chromeVisible ? 0 : -6)
                    .allowsHitTesting(chromeVisible)
                    .animation(AppMotion.chromeReveal, value: chromeVisible)

                    // The preview and inspector use separate layout lanes so metadata never covers the file.
                    ZStack {
                        previewContent
                            .frame(width: layout.previewWidth, height: layout.previewHeight)
                            .scaleEffect(previewScale)
                            .opacity(previewOpacity)
                            .transition(.opacity)
                            .animation(AppMotion.hero, value: previewVisible)
                            .animation(AppMotion.closeHero, value: isDismissing)
                    }
                    .frame(width: proxy.size.width, height: layout.previewLaneHeight)
                    .clipped()

                    if showsDetails {
                        FocusMetadataPanel(
                            item: item,
                            collectionName: item.collectionID.flatMap { id in
                                store.collections.first(where: { $0.id == id })?.name
                            } ?? "Inbox"
                        )
                        .frame(width: layout.inspectorWidth, height: layout.inspectorHeight)
                        .padding(.horizontal, 24)
                        .padding(.top, layout.inspectorTopSpacing)
                        .padding(.bottom, layout.bottomPadding)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Color.clear
                            .frame(height: layout.bottomPadding)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(AppMotion.quick, value: showsDetails)

                HStack {
                    focusNavigationButton(systemName: "chevron.left", offset: -1)
                    Spacer()
                    focusNavigationButton(systemName: "chevron.right", offset: 1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, max(24, proxy.size.width * 0.045))
                .opacity(chromeVisible ? 1 : 0)
                .scaleEffect(chromeVisible ? 1 : 0.96)
                .allowsHitTesting(chromeVisible)
                .animation(AppMotion.chromeReveal, value: chromeVisible)

            }
            .accessibilityAction(.escape) {
                dismissFocus()
            }
        }
        .id(item.id)
        .allowsHitTesting(!isDismissing)
        .task(id: item.id) {
            isDismissing = false
            previewVisible = false
            chromeVisible = false
            withAnimation(AppMotion.hero) {
                previewVisible = true
            }
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(AppMotion.chromeReveal) {
                chromeVisible = true
            }
        }
        .onChange(of: item.id) { _, _ in
            pageIndex = 0
            showsDetails = false
        }
        .onChange(of: store.focusDismissalRequestID) { _, _ in
            dismissFocus()
        }
    }

    private func dismissFocus() {
        guard !isDismissing else { return }
        store.focusIsDismissing = true

        withAnimation(AppMotion.closeHero) {
            isDismissing = true
            chromeVisible = false
            showsDetails = false
            previewVisible = false
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 105_000_000)
            guard isDismissing else { return }
            withAnimation(AppMotion.closeHero) {
                store.clearFocus()
            }
        }
    }

    private var previewScale: CGFloat {
        if previewVisible {
            return 1
        }
        return isDismissing ? 0.97 : 0.945
    }

    private var previewOpacity: Double {
        if previewVisible {
            return 1
        }
        return isDismissing ? 0.26 : 0.96
    }

    private struct FocusStageLayout {
        var headerHeight: CGFloat
        var previewLaneHeight: CGFloat
        var previewWidth: CGFloat
        var previewHeight: CGFloat
        var inspectorWidth: CGFloat
        var inspectorHeight: CGFloat
        var inspectorTopSpacing: CGFloat
        var bottomPadding: CGFloat
    }

    @ViewBuilder
    private var previewContent: some View {
        if isImage {
            CleanImagePreview(item: item, store: store)
        } else if isWebsite {
            CleanWebsitePreview(item: item, store: store)
        } else {
            ExtendDocumentViewer(
                item: item,
                originalURL: store.originalFileURL(for: item),
                pageIndex: $pageIndex
            )
        }
    }

    private func focusStageLayout(for size: CGSize) -> FocusStageLayout {
        let headerHeight: CGFloat = 66
        let bottomPadding: CGFloat = showsDetails ? 14 : 20
        let inspectorTopSpacing: CGFloat = showsDetails ? 12 : 0
        let inspectorHeight: CGFloat = showsDetails ? min(max(size.height * 0.10, 68), 82) : 0
        let reservedHeight = headerHeight + inspectorTopSpacing + inspectorHeight + bottomPadding
        let previewLaneHeight = max(160, size.height - reservedHeight)
        let previewWidth = min(size.width * 0.88, 1160)
        let previewHeight = min(previewLaneHeight, size.height * (showsDetails ? 0.66 : 0.82))
        let inspectorWidth = min(max(720, size.width - 72), 1120)

        return FocusStageLayout(
            headerHeight: headerHeight,
            previewLaneHeight: previewLaneHeight,
            previewWidth: previewWidth,
            previewHeight: previewHeight,
            inspectorWidth: inspectorWidth,
            inspectorHeight: inspectorHeight,
            inspectorTopSpacing: inspectorTopSpacing,
            bottomPadding: bottomPadding
        )
    }

    private func focusNavigationButton(systemName: String, offset: Int) -> some View {
        Button {
            withAnimation(AppMotion.smooth) {
                _ = store.focusAdjacentVisibleItem(offset: offset)
            }
        } label: {
            Image(systemName: systemName)
                .lociFont(size: 17, weight: .semibold, relativeTo: .headline)
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 38, height: 44)
                .background(Color.white.opacity(0.12), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(offset < 0 ? "Previous document" : "Next document")
        .accessibilityLabel(offset < 0 ? "Previous document" : "Next document")
        .disabled(store.visibleItems.count < 2)
        .opacity(store.visibleItems.count < 2 ? 0 : 1)
    }
}

private struct FocusMetadataPanel: View {
    var item: ReferenceItem
    var collectionName: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: item.kindSymbol)
                    .font(LociFont.headline)
                    .foregroundStyle(LociColor.inkSecondary)
                    .frame(width: 32, height: 32)
                    .background(LociColor.surfaceSelected, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.kind.rawValue.capitalized)
                        .font(LociFont.headline)
                        .foregroundStyle(LociColor.ink)
                        .lineLimit(1)
                    Text(headerSubtitle)
                        .font(LociFont.caption)
                        .foregroundStyle(LociColor.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 176, alignment: .leading)

            Rectangle()
                .fill(LociColor.hairline)
                .frame(width: 1, height: 38)

            FocusMetadataCell(label: "Title", value: item.title)
                .layoutPriority(4)
            FocusMetadataCell(label: "File", value: item.fileName)
                .layoutPriority(3)
            FocusMetadataCell(label: "Type", value: fileTypeLabel)
                .frame(width: 72, alignment: .leading)
            FocusMetadataCell(label: "Source", value: sourceLabel)
                .frame(width: 88, alignment: .leading)
            FocusMetadataCell(label: "Space", value: collectionName)
                .frame(width: 116, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(LociColor.surfaceRecessed, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LociColor.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private var fileTypeLabel: String {
        let ext = item.fileExtension.uppercased()
        return ext.isEmpty ? item.kind.rawValue.capitalized : ext
    }

    private var sourceLabel: String {
        if item.isXBookmark { return "X Bookmark" }
        if item.websiteURL != nil { return "Website" }
        if item.subtitle == "Quick Note" { return "Note" }
        return item.group.rawValue
    }

    private var headerSubtitle: String {
        let subtitle = item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subtitle.isEmpty,
              !subtitle.hasPrefix("http://"),
              !subtitle.hasPrefix("https://"),
              subtitle != item.fileName else {
            return collectionName
        }
        return subtitle
    }
}

private struct FocusMetadataCell: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(LociFont.caption)
                .foregroundStyle(LociColor.inkFaint)
                .lineLimit(1)
            Text(value)
                .font(LociFont.caption)
                .foregroundStyle(LociColor.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

private struct FocusMetadataRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(LociFont.caption)
                .foregroundStyle(LociColor.inkTertiary)
                .frame(width: 48, alignment: .leading)

            Text(value)
                .font(LociFont.body)
                .foregroundStyle(LociColor.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }
}

private struct FocusMetadataDivider: View {
    var body: some View {
        Rectangle()
            .fill(LociColor.hairline)
            .frame(height: 1)
            .padding(.leading, 60)
    }
}

private struct CleanImagePreview: View {
    var item: ReferenceItem
    @Bindable var store: LibraryStore
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                GeometryReader { proxy in
                    let fittedSize = Self.fittedSize(for: image.size, in: proxy.size)

                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(LociColor.hairline, lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            } else {
                ReferenceThumbnail(item: item, xBookmarkPayload: store.xBookmarkPayload(for: item))
                    .aspectRatio(item.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(LociColor.hairline, lineWidth: 1)
                    }
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                            .padding(10)
                            .background(Color.white.opacity(0.92), in: Circle())
                    }
                    .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            guard let url = store.originalFileURL(for: item) else { return }
            image = await Self.loadImage(from: url)
        }
        .onDisappear {
            image = nil
        }
    }

    @MainActor
    private static func loadImage(from url: URL) async -> NSImage? {
        await LociImageLoader.downsampledImage(from: url, maxPixelSize: 2400)
    }

    private static func fittedSize(for imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        let imageWidth = max(imageSize.width, 1)
        let imageHeight = max(imageSize.height, 1)
        let widthScale = containerSize.width / imageWidth
        let heightScale = containerSize.height / imageHeight
        let scale = min(widthScale, heightScale)
        return CGSize(width: imageWidth * scale, height: imageHeight * scale)
    }
}

private struct CleanWebsitePreview: View {
    var item: ReferenceItem
    @Bindable var store: LibraryStore
    @State private var isLoading = true

    var body: some View {
        Group {
            if let url = item.websiteURL {
                ZStack {
                    WebsitePreviewWebView(url: url, isLoading: $isLoading)

                    if isLoading {
                        WebsiteLoadingOverlay(url: url)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: isLoading)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "safari")
                        .lociFont(size: 32, weight: .semibold, relativeTo: .title)
                        .foregroundStyle(LociColor.inkFaint)
                    Text(item.title)
                        .font(LociFont.body)
                        .foregroundStyle(LociColor.inkTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LociColor.hairline, lineWidth: 1)
        }
    }
}

private struct WebsitePreviewWebView: NSViewRepresentable {
    var url: URL
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = LociWebSession.configuration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = LociWebSession.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.load(LociWebSession.request(for: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            isLoading = true
            webView.load(LociWebSession.request(for: url))
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool

        init(isLoading: Binding<Bool>) {
            _isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }
    }
}

private struct WebsiteLoadingOverlay: View {
    var url: URL
    @State private var spin = false

    private var host: String {
        url.host(percentEncoded: false) ?? url.absoluteString
    }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(LociColor.hairline, lineWidth: 3)
                    .frame(width: 40, height: 40)

                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(
                        LociColor.inkTertiary,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: 40, height: 40)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            }

            VStack(spacing: 6) {
                Text("Loading")
                    .font(LociFont.caption)
                    .foregroundStyle(LociColor.inkFaint)

                Text(host)
                    .font(LociFont.headline)
                    .foregroundStyle(LociColor.inkSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LociColor.surface)
        .onAppear {
            if !AppMotion.reduceMotion {
                spin = true
            }
        }
    }
}


struct LociTitle: View {
    @Bindable var store: LibraryStore

    private var title: String {
        switch store.selectedFilter {
        case .all: "LOCI LIBRARY"
        case .inbox: "INBOX"
        case .xBookmarks: "X BOOKMARKS"
        case .files: "FILES"
        case .trash: "TRASH"
        case .chat: "ASK LOCI"
        case .api: "CREATIVE MEMORY"
        case .graph: "GRAPH"
        case .timeline: "TIMELINE"
        case .review: "REVIEW"
        case .capabilities: "CAPABILITIES"
        case .patterns: "PATTERNS"
        case .rules: "RULES"
        case .collection(let id):
            store.collections.first(where: { $0.id == id })?.name.uppercased() ?? "COLLECTION"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            if let thread {
                Text("CREATIVE THREAD")
                    .font(LociFont.label)
                    .foregroundStyle(LociColor.inkSecondary)
                    .tracking(0.3)
                Text(thread.name)
                    .font(LociFont.headline)
                    .foregroundStyle(LociColor.ink)
                if !thread.brief.isEmpty {
                    Text(thread.brief)
                        .font(LociFont.caption)
                        .foregroundStyle(LociColor.inkTertiary)
                        .lineLimit(1)
                        .frame(maxWidth: 360)
                } else {
                    Text("Add a brief from the Space menu")
                        .font(LociFont.caption)
                        .foregroundStyle(LociColor.inkFaint)
                }
            } else {
                Text(title)
                    .font(LociFont.label)
                    .foregroundStyle(LociColor.inkSecondary)
                    .tracking(0.3)
                Text("\(store.visibleItems.count.formatted()) ITEMS")
                    .font(LociFont.label)
                    .foregroundStyle(LociColor.inkFaint)
                    .tracking(0.2)
            }
        }
        .allowsHitTesting(false)
    }

    private var thread: ReferenceCollection? {
        guard case .collection(let id) = store.selectedFilter else { return nil }
        return store.collections.first(where: { $0.id == id })
    }
}

struct LociSidebar: View {
    @Bindable var store: LibraryStore
    @Environment(\.undoManager) private var undoManager
    @State private var collectionToRename: ReferenceCollection?
    @State private var renameDraft = ""
    @State private var collectionToEditBrief: ReferenceCollection?
    @State private var briefDraft = ""
    @AppStorage("LociAdvancedSidebarExpanded") private var isStudioExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library")
                .sidebarSectionLabel()
                .padding(.top, 14)

            SidebarGroup {
                LociSidebarRow(
                    title: "All",
                    symbol: "circle.grid.2x2.fill",
                    count: store.count(for: .all).formatted(),
                    isSelected: store.selectedFilter == .all
                ) {
                    selectFilter(.all)
                }
                LociSidebarRow(
                    title: "Inbox",
                    symbol: "tray.fill",
                    count: store.count(for: .inbox).formatted(),
                    isSelected: store.selectedFilter == .inbox
                ) {
                    selectFilter(.inbox)
                }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    moveDroppedReferences(from: providers, to: nil)
                }
            }

            Text("Spaces")
                .sidebarSectionLabel()
                .padding(.top, 12)

            SidebarGroup {
                ForEach(store.collections) { collection in
                    LociSidebarRow(
                        title: collection.name,
                        symbol: collection.symbol,
                        count: store.count(for: .collection(collection.id)).formatted(),
                        isSelected: store.selectedFilter == .collection(collection.id)
                    ) {
                        selectFilter(.collection(collection.id))
                    }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        moveDroppedReferences(from: providers, to: collection.id)
                    }
                    .contextMenu {
                        Button {
                            beginRename(collection)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }

                        Button {
                            beginEditingBrief(collection)
                        } label: {
                            Label("Edit Creative Brief", systemImage: "text.quote")
                        }

                        Button {
                            store.deleteCollection(id: collection.id, undoManager: undoManager)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Divider()

                        Button {
                            store.mergeCollection(id: collection.id, direction: .up)
                        } label: {
                            Label("Merge Up", systemImage: "arrow.up")
                        }
                        .disabled(!store.canMergeCollection(id: collection.id, direction: .up))

                        Button {
                            store.mergeCollection(id: collection.id, direction: .down)
                        } label: {
                            Label("Merge Down", systemImage: "arrow.down")
                        }
                        .disabled(!store.canMergeCollection(id: collection.id, direction: .down))
                    }
                }
            }

            SidebarGroup {
                LociSidebarRow(
                    title: "Ask Loci",
                    symbol: "sparkles",
                    count: "",
                    isSelected: store.selectedFilter == .chat
                ) {
                    selectFilter(.chat)
                }

                LociSidebarRow(
                    title: "Rediscover",
                    symbol: "clock.arrow.circlepath",
                    count: reviewDueCount,
                    isSelected: store.selectedFilter == .review,
                    countStyle: .attention
                ) {
                    _ = ReviewScheduler.autoEnqueueForgottenReferences()
                    selectFilter(.review)
                }
            }
            .padding(.top, 12)

            Spacer()

            Button {
                store.addCollection(undoManager: undoManager)
            } label: {
                Label("New Creative Thread", systemImage: "plus")
                    .font(LociFont.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LociColor.ink)
            .padding(.leading, 18)
            .padding(.bottom, 6)

            Button {
                VaultExporter.showExportPanel()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "square.and.arrow.up")
                    .font(LociFont.label)
                Text("Export Library")
                    .font(LociFont.caption)
            }
        }
            .buttonStyle(.plain)
            .foregroundStyle(LociColor.inkTertiary)
            .padding(.leading, 18)
            .padding(.bottom, 12)

            Rectangle()
                .fill(LociColor.hairline)
                .frame(height: 1)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            StudioSidebarSection(
                isExpanded: $isStudioExpanded,
                isActive: isStudioFilterSelected
            ) {
                LociSidebarRow(
                    title: "X Bookmarks",
                    symbol: "bookmark.square.fill",
                    count: store.count(for: .xBookmarks).formatted(),
                    isSelected: store.selectedFilter == .xBookmarks
                ) {
                    selectFilter(.xBookmarks)
                }

                LociSidebarRow(
                    title: "Files",
                    symbol: "folder.fill",
                    count: store.count(for: .files).formatted(),
                    isSelected: store.selectedFilter == .files
                ) {
                    selectFilter(.files)
                }

                LociSidebarRow(
                    title: "Graph",
                    symbol: "point.3.connected.trianglepath.dotted",
                    count: store.graphNodeCount.formatted(),
                    isSelected: store.selectedFilter == .graph
                ) {
                    selectFilter(.graph)
                }

                LociSidebarRow(
                    title: "Auto Rules",
                    symbol: "gearshape.2",
                    count: "",
                    isSelected: store.selectedFilter == .rules
                ) {
                    selectFilter(.rules)
                }

                LociSidebarRow(
                    title: "Patterns",
                    symbol: "wand.and.stars",
                    count: PromptLibrary.patterns.count.formatted(),
                    isSelected: store.selectedFilter == .patterns
                ) {
                    selectFilter(.patterns)
                }

                LociSidebarRow(
                    title: "Feature Map",
                    symbol: "sparkle.magnifyingglass",
                    count: "10",
                    isSelected: store.selectedFilter == .capabilities
                ) {
                    selectFilter(.capabilities)
                }

                LociSidebarRow(
                    title: "Local API",
                    symbol: "curlybraces.square",
                    count: "",
                    isSelected: store.selectedFilter == .api
                ) {
                    selectFilter(.api)
                }

                LociSidebarRow(
                    title: "Trash",
                    symbol: "trash.fill",
                    count: store.count(for: .trash).formatted(),
                    isSelected: store.selectedFilter == .trash
                ) {
                    selectFilter(.trash)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        store.emptyTrash()
                    } label: {
                        Label("Empty Trash", systemImage: "trash.slash")
                    }
                    .disabled(store.count(for: .trash) == 0)
                }
            }
            .padding(.bottom, 18)
        }
        .background(LociColor.surface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(LociColor.surfaceRecessed)
                .frame(width: 1)
        }
        .alert("Rename Collection", isPresented: renameAlertBinding) {
            TextField("Collection name", text: $renameDraft)
            Button("Cancel", role: .cancel) {
                collectionToRename = nil
                renameDraft = ""
            }
            Button("Rename") {
                if let collectionToRename {
                    store.renameCollection(id: collectionToRename.id, to: renameDraft, undoManager: undoManager)
                }
                collectionToRename = nil
                renameDraft = ""
            }
        } message: {
            Text("Choose a new name for this collection.")
        }
        .sheet(item: $collectionToEditBrief) { collection in
            CreativeThreadBriefSheet(
                threadName: collection.name,
                brief: $briefDraft,
                onSave: { store.updateCollectionBrief(id: collection.id, to: briefDraft) }
            )
        }
    }

    private var isStudioFilterSelected: Bool {
        switch store.selectedFilter {
        case .api, .graph, .capabilities, .patterns, .rules, .xBookmarks, .files, .trash:
            true
        case .all, .inbox, .chat, .timeline, .review, .collection:
            false
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { collectionToRename != nil },
            set: { isPresented in
                if !isPresented {
                    collectionToRename = nil
                    renameDraft = ""
                }
            }
        )
    }

    private func beginRename(_ collection: ReferenceCollection) {
        collectionToRename = collection
        renameDraft = collection.name
    }

    private func beginEditingBrief(_ collection: ReferenceCollection) {
        briefDraft = collection.brief
        collectionToEditBrief = collection
    }

    private func selectFilter(_ filter: CollectionFilter) {
        if case .collection(let id) = filter {
            store.activeThreadID = id
        }
        if filter == .chat {
            UserDefaults.standard.set(true, forKey: "LociNotebookInspectorVisible")
        }
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            store.selectedFilter = filter
        }
    }

    private func moveDroppedReferences(from providers: [NSItemProvider], to collectionID: UUID?) -> Bool {
        let textProviders = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !textProviders.isEmpty else { return false }

        for provider in textProviders {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                let ids = Self.referenceIDs(from: object as? String)
                guard !ids.isEmpty else { return }

                Task { @MainActor in
                    store.moveReferences(ids, to: collectionID, undoManager: undoManager)
                    store.selectedItemIDs = ids
                }
            }
        }
        return true
    }

    nonisolated private static func referenceIDs(from payload: String?) -> Set<ReferenceItem.ID> {
        guard let payload else { return [] }
        return Set(
            payload
                .split(whereSeparator: \.isWhitespace)
                .compactMap { UUID(uuidString: String($0)) }
        )
    }

    private var reviewDueCount: String {
        let due = ReviewScheduler.stats().due
        return due > 0 ? due.formatted() : ""
    }

}

struct StudioSidebarSection<Content: View>: View {
    @Binding var isExpanded: Bool
    var isActive: Bool
    @ViewBuilder var content: Content

    private var isContentVisible: Bool {
        isExpanded || isActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(AppMotion.quick) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(LociColor.inkFaint)
                        .rotationEffect(.degrees(isContentVisible ? 90 : 0))
                        .frame(width: 12)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Advanced")
                            .font(LociFont.label)
                            .foregroundStyle(LociColor.ink)
                        Text("Sources, connections, automation")
                            .font(LociFont.caption)
                            .foregroundStyle(LociColor.inkFaint)
                    }

                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? LociColor.surfaceSelected : Color.clear)
                }
            }
            .buttonStyle(.plain)

            if isContentVisible {
                VStack(spacing: 1) {
                    content
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
    }
}

struct SidebarGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 1) {
            content
        }
        .padding(.horizontal, 12)
    }
}

enum LociSidebarCountStyle {
    case standard
    case attention
}

struct LociSidebarRow: View {
    var title: String
    var symbol: String
    var count: String
    var isSelected: Bool
    var countStyle: LociSidebarCountStyle = .standard
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(LociFont.label)
                    .foregroundStyle(isSelected ? LociColor.ink : (isHovered ? LociColor.inkSecondary : LociColor.inkTertiary))
                    .frame(width: 14)
                Text(title)
                    .font(isSelected ? LociFont.headline : LociFont.caption)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !count.isEmpty {
                    Text(count)
                        .font(LociFont.badge)
                        .monospacedDigit()
                        .foregroundStyle(countForeground)
                }
            }
            .foregroundStyle(isSelected ? LociColor.ink : LociColor.inkSecondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowFill)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AppMotion.hover, value: isHovered)
        .animation(AppMotion.quick, value: isSelected)
    }

    private var rowFill: Color {
        if isSelected {
            return LociColor.surfaceSelected
        }
        if isHovered {
            return LociColor.surfaceRecessed
        }
        return Color.clear
    }

    private var countForeground: Color {
        switch countStyle {
        case .standard:
            isSelected ? LociColor.inkSecondary : LociColor.inkFaint
        case .attention:
            isSelected ? Color.orange.opacity(0.96) : Color.orange.opacity(0.86)
        }
    }
}

private extension View {
    func sidebarSectionLabel() -> some View {
        self
            .font(LociFont.label)
            .foregroundStyle(LociColor.inkSecondary)
            .padding(.bottom, 6)
            .padding(.leading, 20)
    }
}

struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.32))
            Circle().fill(Color(red: 1.0, green: 0.77, blue: 0.22))
            Circle().fill(Color(red: 0.22, green: 0.80, blue: 0.32))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(.black.opacity(0.12), lineWidth: 1)
                .frame(width: 10, height: 10)
                .padding(.leading, 4)
        }
        .frame(width: 56, height: 10)
    }
}

struct BottomModeBar: View {
    @Bindable var store: LibraryStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases) { mode in
                Button {
                    withAnimation(AppMotion.instant) {
                        store.mode = mode
                    }
                } label: {
                    Text(mode.rawValue)
                        .font(store.mode == mode ? LociFont.label : LociFont.caption)
                        .foregroundStyle(store.mode == mode ? LociColor.ink : LociColor.inkTertiary)
                        .frame(width: 52)
                        .frame(minHeight: 24)
                        .contentShape(Capsule())
                        .background {
                            Capsule()
                                .fill(store.mode == mode ? LociColor.surface : Color.clear)
                                .shadow(color: .black.opacity(store.mode == mode ? 0.12 : 0), radius: 4, y: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(LociColor.surface, in: Capsule())
        .overlay {
            Capsule()
                .stroke(LociColor.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    }
}

struct UtilityCluster: View {
    @Bindable var store: LibraryStore
    @Environment(\.undoManager) private var undoManager
    @State private var isShowingURLImport = false
    @State private var isShowingNoteImport = false
    @State private var importURLDraft = ""
    @State private var noteDraft = ""
    @State private var isConfirmingPermanentDelete = false

    private var searchBinding: Binding<String> {
        Binding(
            get: { store.searchText },
            set: { store.searchText = LibraryStore.sanitizedSearchInput($0) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            LibrarySearchField(
                text: searchBinding,
                hasQuery: !store.normalizedSearchText.isEmpty,
                onSubmit: { store.normalizeSearchText() },
                onClear: { store.searchText = "" }
            )

            Menu {
                Button {
                    importURLDraft = ""
                    isShowingURLImport = true
                } label: {
                    Label("Website or Link...", systemImage: "link.badge.plus")
                }

                Button {
                    openFileImporter()
                } label: {
                    Label("Files or Folder...", systemImage: "folder.badge.plus")
                }

                Button {
                    store.importPasteboard(undoManager: undoManager)
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }

                Button {
                    noteDraft = ""
                    isShowingNoteImport = true
                } label: {
                    Label("Quick Note...", systemImage: "note.text.badge.plus")
                }

                Divider()

                Button {
                    store.importScreenshot(undoManager: undoManager)
                } label: {
                    Label("Screenshot Full Screen", systemImage: "camera.fill")
                }
            } label: {
                Image(systemName: "plus")
                    .font(LociFont.label)
                    .foregroundStyle(LociColor.inkTertiary)
                    .frame(width: 28, height: 28)
                    .background(LociColor.surface, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(LociColor.hairline, lineWidth: 1)
                    }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)

            SmallUtilityButton(symbol: "gearshape") {
                NSApp.sendAction(Selector(("openSettings")), to: nil, from: nil)
            }
            .help("Settings")
            .accessibilityLabel("Settings")

            if store.mode == .infinity {
                SmallUtilityButton(symbol: store.infinityClustered ? "rectangle.3.group.fill" : "rectangle.3.group") {
                    withAnimation(AppMotion.quick) {
                        store.infinityClustered.toggle()
                        store.clearFocus()
                    }
                }
            }
            if store.mode == .canvas {
                SmallUtilityButton(symbol: "arrow.counterclockwise") {
                    withAnimation(AppMotion.quick) {
                        store.resetCanvasLayout()
                    }
                }
            }

            if store.selectedFilter != .trash {
                SmallUtilityButton(symbol: "trash") {
                    store.sendSelectionToTrash(undoManager: undoManager)
                }
                .disabled(store.selectedItemIDs.isEmpty)
                .accessibilityLabel("Move to Trash")
            } else {
                SmallUtilityButton(symbol: "trash.slash") {
                    isConfirmingPermanentDelete = true
                }
                .disabled(store.selectedItemIDs.isEmpty)
                .accessibilityLabel("Delete Permanently")
            }
        }
        .confirmationDialog(
            "Permanently delete \(store.selectedItemIDs.count) item\(store.selectedItemIDs.count == 1 ? "" : "s")?",
            isPresented: $isConfirmingPermanentDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                store.deleteSelectedFromTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The items are removed from your library. Their files are moved to the system Trash.")
        }
        .sheet(isPresented: $isShowingURLImport) {
            ImportTextSheet(
                title: "Add Link",
                placeholder: "https://example.com",
                text: $importURLDraft
            ) {
                store.importWebsiteOrLink(importURLDraft, undoManager: undoManager)
                importURLDraft = ""
            }
        }
        .sheet(isPresented: $isShowingNoteImport) {
            ImportTextSheet(
                title: "Quick Note",
                placeholder: "Write or paste a note...",
                text: $noteDraft,
                isMultiline: true
            ) {
                store.importNote(noteDraft, undoManager: undoManager)
                noteDraft = ""
            }
        }
    }

    private func openFileImporter() {
        let panel = NSOpenPanel()
        panel.title = "Import to \(AppBrand.name)"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            store.importFiles(panel.urls, undoManager: undoManager)
        }
    }

}

struct LibrarySearchField: View {
    @Binding var text: String
    var hasQuery: Bool
    var onSubmit: () -> Void
    var onClear: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(LociFont.label)
                .foregroundStyle(isFocused ? LociColor.inkTertiary : LociColor.inkFaint)
                .frame(width: 13)

            TextField(
                "",
                text: $text,
                prompt: Text("Search")
                    .foregroundStyle(LociColor.inkFaint)
            )
            .textFieldStyle(.plain)
            .font(LociFont.body)
            .foregroundStyle(LociColor.ink)
            .tint(LociColor.inkSecondary)
            .focused($isFocused)
            .lineLimit(1)
            .onSubmit(onSubmit)

            if hasQuery {
                Button {
                    withAnimation(AppMotion.quick) {
                        onClear()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(LociFont.label)
                        .foregroundStyle(LociColor.inkTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.86).combined(with: .opacity))
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, hasQuery ? 6 : 10)
        .frame(width: 188)
        .frame(minHeight: 30)
        .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(isFocused ? LociColor.border : LociColor.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(isFocused ? 0.12 : 0.08), radius: isFocused ? 10 : 6, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture {
            isFocused = true
        }
        .onExitCommand {
            if hasQuery {
                onClear()
            } else {
                isFocused = false
            }
        }
        .animation(AppMotion.quick, value: isFocused)
        .animation(AppMotion.quick, value: hasQuery)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search library")
        .help("Search library")
    }
}

struct ImportTextSheet: View {
    var title: String
    var placeholder: String
    @Binding var text: String
    var isMultiline = false
    var onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(LociFont.title)
                .foregroundStyle(LociColor.ink)

            if isMultiline {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(LociFont.body)
                            .foregroundStyle(LociColor.inkFaint)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $text)
                        .font(LociFont.body)
                        .foregroundColor(LociColor.ink)
                        .tint(.black)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(width: 360, height: 150)
                        .background(Color.clear)
                }
                .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(LociColor.border, lineWidth: 0.8)
                }
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(LociColor.inkFaint))
                    .textFieldStyle(.plain)
                    .font(LociFont.body)
                    .foregroundColor(LociColor.ink)
                    .tint(.black)
                    .frame(width: 360)
                    .frame(minHeight: 32)
                    .padding(.horizontal, 10)
                    .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(LociColor.border, lineWidth: 0.8)
                    }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(LociColor.inkSecondary)
                .font(LociFont.body)
                .keyboardShortcut(.cancelAction)

                Button("Import") {
                    onImport()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(LociColor.ink)
                .foregroundStyle(.white)
                .font(LociFont.body)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .background(LociColor.surfaceRecessed)
        .colorScheme(.light)
    }
}

struct ZoomSlider: View {
    @Bindable var store: LibraryStore
    @State private var isDragging = false

    private var percent: Int {
        Int(round(store.zoom * 100))
    }

    private var range: ClosedRange<CGFloat> { 0.40...1.0 }

    var body: some View {
        HStack(spacing: 9) {
            Button {
                stepZoom(by: -0.08)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(LociFont.label)
                    .foregroundStyle(LociColor.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom out")

            GeometryReader { geometry in
                let trackWidth = geometry.size.width
                let knobSize: CGFloat = 14
                let knobOffset = max(0, min(trackWidth - knobSize, (trackWidth - knobSize) * (store.zoom - range.lowerBound) / (range.upperBound - range.lowerBound)))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.black.opacity(0.10))
                        .frame(height: 4)

                    Capsule()
                        .fill(.black.opacity(0.44))
                        .frame(width: max(4, knobOffset + knobSize / 2), height: 4)

                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .overlay(Circle().stroke(.black.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(isDragging ? 0.20 : 0.12), radius: isDragging ? 5 : 3, y: isDragging ? 2 : 1)
                        .scaleEffect(isDragging ? 1.12 : 1)
                        .animation(AppMotion.quick, value: isDragging)
                        .offset(x: knobOffset)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let ratio = max(0, min(1, value.location.x / trackWidth))
                            withAnimation(.interactiveSpring(response: 0.12, dampingFraction: 0.72)) {
                                store.zoom = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                    )
            }
            .frame(width: 82, height: 20)

            Button {
                stepZoom(by: 0.08)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(LociFont.label)
                    .foregroundStyle(LociColor.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom in")

            Text("\(percent)%")
                .font(LociFont.badge)
                .monospacedDigit()
                .foregroundStyle(LociColor.inkSecondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(LociColor.surface, in: Capsule())
        .overlay(
            Capsule()
                .stroke(LociColor.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        .colorScheme(.light)
        .accessibilityElement()
        .accessibilityLabel("Zoom")
        .accessibilityValue("\(percent) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                stepZoom(by: 0.08)
            case .decrement:
                stepZoom(by: -0.08)
            @unknown default:
                break
            }
        }
    }

    private func stepZoom(by delta: CGFloat) {
        withAnimation(AppMotion.quick) {
            store.zoom = min(range.upperBound, max(range.lowerBound, store.zoom + delta))
        }
    }
}

struct SmallUtilityButton: View {
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(LociFont.label)
                .foregroundStyle(LociColor.inkTertiary)
                .frame(width: 28, height: 28)
                .background(LociColor.surface, in: Circle())
                .overlay {
                    Circle()
                        .stroke(LociColor.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

struct BatchActionBar: View {
    @Bindable var store: LibraryStore
    @State private var showTagSheet = false
    @State private var tagDraft = ""
    @State private var showCollectionPicker = false
    @Environment(\.undoManager) private var undoManager

    private var selectedCount: Int { store.selectedItemIDs.count }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(selectedCount) selected")
                .font(LociFont.headline)
                .foregroundStyle(LociColor.inkSecondary)

            Divider().frame(height: 16)

            BatchActionChip(symbol: "tag", title: "Tag") {
                showTagSheet = true
            }

            BatchActionChip(symbol: "folder", title: "Move") {
                showCollectionPicker = true
            }

            BatchActionChip(symbol: "brain.head.profile", title: "Review") {
                let ids = Array(store.selectedItemIDs)
                _ = BatchOperations.batchAddToReview(items: ids)
                store.selectedItemIDs.removeAll()
            }

            BatchActionChip(symbol: "trash", title: "Trash") {
                store.sendSelectionToTrash(undoManager: undoManager)
            }

            Button {
                store.selectedItemIDs.removeAll()
            } label: {
                Image(systemName: "xmark")
                    .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                    .foregroundStyle(LociColor.inkFaint)
                    .frame(width: 22, height: 22)
                    .background(LociColor.surfaceRecessed, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear selection")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LociColor.surface, in: Capsule())
        .overlay(Capsule().stroke(LociColor.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .sheet(isPresented: $showTagSheet) {
            ImportTextSheet(title: "Batch Tag", placeholder: "tag name", text: $tagDraft) {
                let ids = Array(store.selectedItemIDs)
                _ = BatchOperations.batchTag(items: ids, tagName: tagDraft)
                store.selectedItemIDs.removeAll()
                tagDraft = ""
                showTagSheet = false
            }
        }
        .sheet(isPresented: $showCollectionPicker) {
            CollectionPickerSheet(store: store) { collectionID in
                let ids = Array(store.selectedItemIDs)
                _ = BatchOperations.batchMoveToCollection(items: ids, collectionID: collectionID)
                store.selectedItemIDs.removeAll()
                showCollectionPicker = false
            }
        }
    }
}

private struct BatchActionChip: View {
    var symbol: String
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .lociFont(size: 9, weight: .semibold, relativeTo: .caption2)
                Text(title)
                    .font(LociFont.caption)
            }
            .foregroundStyle(LociColor.inkSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(LociColor.surfaceRecessed, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct CollectionPickerSheet: View {
    @Bindable var store: LibraryStore
    var onSelect: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Move to Collection")
                .font(LociFont.title)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    Button {
                        onSelect(nil)
                    } label: {
                        CollectionPickerRow(
                            symbol: "tray",
                            title: "Inbox",
                            isSelected: isCurrentDestination(nil)
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(store.collections) { collection in
                        Button {
                            onSelect(collection.id)
                        } label: {
                            CollectionPickerRow(
                                symbol: collection.symbol,
                                title: collection.name,
                                isSelected: isCurrentDestination(collection.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .font(LociFont.body)
                .foregroundStyle(LociColor.inkTertiary)
                .padding(.vertical, 10)
        }
        .frame(width: 300, height: 340)
    }

    private var selectedDestinations: Set<UUID?> {
        let selectedIDs = store.selectedItemIDs
        return Set(store.items.filter { selectedIDs.contains($0.id) }.map(\.collectionID))
    }

    private func isCurrentDestination(_ collectionID: UUID?) -> Bool {
        let destinations = selectedDestinations
        guard destinations.count == 1 else { return false }
        return destinations.first! == collectionID
    }
}

private struct CollectionPickerRow: View {
    var symbol: String
    var title: String
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(LociFont.caption)
                .frame(width: 14)

            Text(title)
                .font(isSelected ? LociFont.headline : LociFont.body)

            Spacer(minLength: 0)

            Image(systemName: "checkmark.circle.fill")
                .font(LociFont.headline)
                .foregroundStyle(Color(red: 0.04, green: 0.62, blue: 0.30))
                .scaleEffect(isSelected ? 1 : 0.76)
                .opacity(isSelected ? 1 : 0)
                .animation(AppMotion.snappy, value: isSelected)
        }
        .foregroundStyle(isSelected ? LociColor.ink : LociColor.inkSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? LociColor.surfaceSelected : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
}
