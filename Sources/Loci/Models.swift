import AppKit
import Foundation
import Observation
import QuickLookThumbnailing
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case grid = "Library"
    case canvas = "Board"
    case infinity = "Explore"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .grid:
            "square.grid.3x3.fill"
        case .canvas:
            "rectangle.connected.to.line.below"
        case .infinity:
            "infinity"
        }
    }
}

enum CollectionFilter: Hashable {
    case all
    case inbox
    case xBookmarks
    case files
    case trash
    case chat
    case api
    case graph
    case timeline
    case review
    case capabilities
    case patterns
    case rules
    case collection(UUID)
}

private extension CollectionFilter {
    var telemetryName: String {
        switch self {
        case .all: "all"
        case .inbox: "inbox"
        case .xBookmarks: "x_bookmarks"
        case .files: "files"
        case .trash: "trash"
        case .chat: "chat"
        case .api: "api"
        case .graph: "graph"
        case .timeline: "timeline"
        case .review: "review"
        case .capabilities: "capabilities"
        case .patterns: "patterns"
        case .rules: "rules"
        case .collection: "collection"
        }
    }
}

enum CollectionMergeDirection {
    case up
    case down
}

private struct VisibleItemsCacheKey: Hashable {
    var filter: CollectionFilter
    var searchText: String
    var generation: UInt64
}

enum VisualKind: String, CaseIterable {
    case phone
    case laptop
    case website
    case app
    case product
    case typography
}

enum ReferenceGroup: String, CaseIterable, Identifiable, Hashable {
    case file = "Files"
    case memory = "Memory"
    case link = "Links"
    case website = "Websites"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .file:
            "doc.fill"
        case .memory:
            "sparkles"
        case .link:
            "link"
        case .website:
            "safari.fill"
        }
    }
}

enum ReferenceTheme: String, CaseIterable {
    case aurora
    case graphite
    case citrus
    case marine
    case studio
    case signal
    case dusk
    case paper

    var colors: [Color] {
        switch self {
        case .aurora:
            [Color(red: 0.82, green: 0.94, blue: 1.0), Color(red: 0.22, green: 0.68, blue: 0.94), .white]
        case .graphite:
            [Color(white: 0.04), Color(white: 0.18), Color(white: 0.70)]
        case .citrus:
            [Color(red: 1.0, green: 0.94, blue: 0.78), Color(red: 0.96, green: 0.60, blue: 0.34), .white]
        case .marine:
            [Color(red: 0.84, green: 0.91, blue: 1.0), Color(red: 0.18, green: 0.44, blue: 0.95), .white]
        case .studio:
            [Color(red: 1.0, green: 0.86, blue: 0.93), Color(red: 0.92, green: 0.34, blue: 0.60), .white]
        case .signal:
            [Color(red: 1.0, green: 0.88, blue: 0.84), Color(red: 0.88, green: 0.22, blue: 0.12), Color(white: 0.10)]
        case .dusk:
            [Color(white: 0.07), Color(red: 0.18, green: 0.20, blue: 0.38), Color(red: 0.55, green: 0.62, blue: 0.92)]
        case .paper:
            [.white, Color(white: 0.88), Color(red: 0.78, green: 0.73, blue: 0.64)]
        }
    }
}

struct ReferenceCollection: Identifiable, Hashable {
    let id: UUID
    var name: String
    var symbol: String
    var tint: Color
    /// The human intent that turns a collection of references into a creative thread.
    var brief: String = ""
}

struct ReferenceItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var subtitle: String
    var fileName: String
    var kind: VisualKind
    var group: ReferenceGroup
    var theme: ReferenceTheme
    var aspectRatio: CGFloat
    var collectionID: UUID?
    var isInbox: Bool
    var isTrashed: Bool
    var thumbnailPath: String?
    var canvasPosition: CGSize
    var infinityPosition: CGPoint

    var websiteURL: URL? {
        guard kind == .website || subtitle.hasPrefix("http://") || subtitle.hasPrefix("https://") else {
            return nil
        }

        let value = subtitle.hasPrefix("http://") || subtitle.hasPrefix("https://")
            ? subtitle
            : "https://\(subtitle)"
        return URL(string: value)
    }

    var kindSymbol: String {
        switch kind {
        case .phone:
            "iphone"
        case .laptop:
            "laptopcomputer"
        case .website:
            "safari"
        case .app:
            "app.dashed"
        case .product:
            "cube"
        case .typography:
            "textformat"
        }
    }

    var fileExtension: String {
        fileName.split(separator: ".").last.map { String($0).lowercased() } ?? ""
    }

    var isManagedDocument: Bool {
        if group == .file || kind == .typography || subtitle == "Quick Note" {
            return true
        }
        let documentExtensions: Set<String> = [
            "pdf", "doc", "docx", "pages", "key", "ppt", "pptx", "xls", "xlsx",
            "csv", "txt", "md", "rtf", "png", "jpg", "jpeg", "gif", "webp", "heic",
            "svg", "zip", "json"
        ]
        return documentExtensions.contains(fileExtension)
    }
}

/// Serial queue for all markdown-vault file work so it never blocks the UI
/// and individual jobs never race each other on disk.
private let vaultWriteQueue = DispatchQueue(label: "loci.vault-writes", qos: .utility)

@MainActor
@Observable
final class LibraryStore {
    var mode: ViewMode = .grid {
        didSet {
            guard oldValue != mode else { return }
            LociTelemetry.record(.modeChanged, properties: ["mode": mode.rawValue])
        }
    }
    var selectedFilter: CollectionFilter = .all {
        didSet {
            guard oldValue != selectedFilter else { return }
            LociTelemetry.record(.filterChanged, properties: ["filter": selectedFilter.telemetryName])
        }
    }
    var selectedItemIDs: Set<ReferenceItem.ID> = []
    var focusedItemID: ReferenceItem.ID? {
        didSet {
            if focusedItemID != oldValue {
                focusIsDismissing = false
            }
        }
    }
    var focusIsDismissing = false
    var focusDismissalRequestID = 0
    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleSearchApplication()
        }
    }
    /// Normalized query that actually drives filtering; trails `searchText` by a
    /// short debounce so typing does not run FTS + grid diffing per keystroke.
    private(set) var activeSearchQuery = ""
    var normalizedSearchText: String {
        Self.normalizedSearchQuery(searchText)
    }
    var gridZoom: CGFloat = 0.92
    var canvasZoom: CGFloat = 0.96
    var infinityZoom: CGFloat = 0.64
    var groupZooms: [ReferenceGroup: CGFloat] = Dictionary(
        uniqueKeysWithValues: ReferenceGroup.allCases.map { ($0, 1) }
    )
    var groupOffsets: [ReferenceGroup: CGSize] = Dictionary(
        uniqueKeysWithValues: ReferenceGroup.allCases.map { ($0, .zero) }
    )
    var canvasPan: CGSize = .zero
    var infinityPan: CGSize = .zero
    var infinityClustered = true
    var importJobResults: [ImportCoordinator.ImportJobResult] = []
    var isAPILibraryVisible = false
    var notebookActiveItemID: ReferenceItem.ID?
    /// The last Space selected by the user; Ask Loci uses it as a Creative Thread scope.
    var activeThreadID: ReferenceCollection.ID?

    var collections: [ReferenceCollection]
    var items: [ReferenceItem]
    var vaultSnapshot: MarkdownVaultSnapshot
    var importJobs: [ImportJobRecord]
    var storageStats: PersistentStoreStats
    var xBookmarkPayloadsByReferenceID: [ReferenceItem.ID: XBookmarkPayloadSummary]

    private let persistence: LociPersistentStore?
    @ObservationIgnored nonisolated(unsafe) private var vaultWriteWorkItem: DispatchWorkItem?
    private var pendingVaultItems: Set<ReferenceItem.ID> = []
    @ObservationIgnored nonisolated(unsafe) private var importResultsTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var statsRefreshWorkItem: DispatchWorkItem?
    @ObservationIgnored nonisolated(unsafe) private var searchDebounceWorkItem: DispatchWorkItem?
    /// Rolling result of the vault-work chain; only touched on `vaultWriteQueue`.
    @ObservationIgnored nonisolated(unsafe) private var queuedVaultSnapshot: MarkdownVaultSnapshot?
    private var cachedVisibleItems: [VisibleItemsCacheKey: [ReferenceItem]] = [:]
    private var cachedCounts: [CollectionFilter: Int] = [:]
    private var countsGeneration: UInt64 = 0
    private var mutationCounter: UInt64 = 0
    private var needsDeferredVaultBootstrap = false

    init(
        collections: [ReferenceCollection],
        items: [ReferenceItem],
        persistence: LociPersistentStore? = nil,
        deferVaultBootstrap: Bool = false
    ) {
        self.collections = collections
        var hydratedItems = items
        let xPayloads = persistence?.loadXBookmarkPayloadsByReferenceID() ?? [:]
        Self.hydrateXBookmarkTitles(in: &hydratedItems, xPayloads: xPayloads, persistence: persistence)
        self.items = hydratedItems
        self.persistence = persistence
        self.xBookmarkPayloadsByReferenceID = xPayloads
        self.importJobs = persistence?.loadSnapshot().importJobs ?? []
        self.storageStats = persistence?.stats() ?? .empty
        self.needsDeferredVaultBootstrap = deferVaultBootstrap
        self.vaultSnapshot = deferVaultBootstrap
            ? MarkdownVault.lightweightSnapshot(collections: collections, items: hydratedItems)
            : MarkdownVault.bootstrap(
                collections: collections,
                items: hydratedItems,
                xPayloadsByReferenceID: xPayloads
            )
        if let persistence {
            Task { await ImportCoordinator.shared.setPersistence(persistence) }
        }
        startImportResultObservation()
        startReactiveObservation()
    }

    deinit {
        importResultsTask?.cancel()
        vaultWriteWorkItem?.cancel()
        statsRefreshWorkItem?.cancel()
    }

    private func startReactiveObservation() {
        TableObserver.shared.startObserving { [weak self] changes in
            self?.reloadFromDatabase(changes: changes)
        }
    }

    private func reloadFromDatabase(changes: LociDatabaseChanges) {
        guard let persistence else { return }

        if changes.collectionsChanged {
            collections = persistence.loadCollectionsSnapshot()
        }
        if changes.importJobsChanged {
            importJobs = persistence.loadRecentImportJobs()
        }
        if changes.xPayloadsChanged {
            xBookmarkPayloadsByReferenceID = persistence.loadXBookmarkPayloadsByReferenceID()
        }

        if !changes.referenceIDs.isEmpty {
            var itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            for id in changes.referenceIDs {
                itemsByID[id] = persistence.loadReference(id: id)
            }
            var updatedItems = items.compactMap { itemsByID.removeValue(forKey: $0.id) }
            updatedItems.append(contentsOf: itemsByID.values.sorted { $0.title < $1.title })
            Self.hydrateXBookmarkTitles(
                in: &updatedItems,
                xPayloads: xBookmarkPayloadsByReferenceID,
                persistence: persistence
            )
            items = updatedItems
            invalidateVisibleItems()
        } else if changes.xPayloadsChanged {
            var updatedItems = items
            Self.hydrateXBookmarkTitles(
                in: &updatedItems,
                xPayloads: xBookmarkPayloadsByReferenceID,
                persistence: persistence
            )
            if updatedItems != items {
                items = updatedItems
                invalidateVisibleItems()
            }
        }
        storageStats = persistence.stats()
    }

    private static func hydrateXBookmarkTitles(
        in items: inout [ReferenceItem],
        xPayloads: [UUID: XBookmarkPayloadSummary],
        persistence: LociPersistentStore?
    ) {
        guard let persistence, !xPayloads.isEmpty else { return }

        for index in items.indices {
            guard items[index].isXBookmark,
                  let payload = xPayloads[items[index].id] else { continue }
            let author = payload.note ?? payload.title
            let text = payload.selectedText ?? payload.articleMarkdown
            let enrichedTitle = XBookmarkDisplay.title(author: author, text: text, fallback: items[index].title)
            guard enrichedTitle != items[index].title else { continue }

            items[index].title = enrichedTitle
            items[index].aspectRatio = min(items[index].aspectRatio, 0.92)
            persistence.upsert(reference: items[index], recordsHistory: false)
        }
    }

    private func startImportResultObservation() {
        importResultsTask?.cancel()
        importResultsTask = Task { @MainActor [weak self] in
            let updates = await ImportCoordinator.shared.resultUpdates()
            for await results in updates {
                guard let self, !Task.isCancelled else { return }
                importJobResults = results
                for result in results {
                    if let referenceID = result.referenceID, let thumbnailPath = result.thumbnailPath {
                        applyThumbnailPath(thumbnailPath, to: referenceID)
                    }
                }
                refreshStorageDiagnostics()
            }
        }
    }

    var vaultRootURL: URL {
        vaultSnapshot.rootURL
    }

    var graphNodeCount: Int {
        vaultSnapshot.graph.nodes.count
    }

    var graphEdgeCount: Int {
        vaultSnapshot.graph.edges.count
    }

    func refreshVault() {
        needsDeferredVaultBootstrap = false
        let collections = self.collections
        let items = self.items
        let payloads = currentXBookmarkPayloadsByReferenceID()
        performVaultWork { _ in
            MarkdownVault.bootstrap(
                collections: collections,
                items: items,
                xPayloadsByReferenceID: payloads
            )
        }
    }

    /// Runs vault file work on the serial background queue and publishes the
    /// resulting snapshot back on the main actor. Jobs chain: each receives the
    /// previous job's snapshot so ordering and content stay coherent.
    private func performVaultWork(_ work: @escaping @Sendable (MarkdownVaultSnapshot) -> MarkdownVaultSnapshot) {
        let base = vaultSnapshot
        vaultWriteQueue.async { [weak self] in
            guard let self else { return }
            let input = self.queuedVaultSnapshot ?? base
            let result = work(input)
            self.queuedVaultSnapshot = result
            Task { @MainActor [weak self] in
                self?.vaultSnapshot = result
            }
        }
    }

    func finishDeferredStartupWork() {
        guard needsDeferredVaultBootstrap else { return }
        refreshVault()
    }

    @discardableResult
    func enqueueRecompileAllReferences() -> Int {
        guard let persistence else { return 0 }
        let activeItems = items.filter { !$0.isTrashed }
        var queued = 0
        for item in activeItems {
            let payload = recompilePayload(for: item)
            persistence.enqueueImportJob(source: .extract, payload: payload, status: .queued, referenceID: item.id)
            queued += 1
        }
        refreshStorageDiagnostics()
        Task { await ImportCoordinator.shared.enqueueProcess() }
        return queued
    }

    private func recompilePayload(for item: ReferenceItem) -> String {
        if let url = originalFileURL(for: item) {
            return url.path
        }
        if let websiteURL = item.websiteURL {
            return websiteURL.absoluteString
        }
        return item.subtitle.isEmpty ? item.fileName : item.subtitle
    }

    func writeReferenceMarkdown(_ item: ReferenceItem) {
        scheduleVaultWrite(for: item)
    }

    func removeReferenceMarkdown(_ item: ReferenceItem) {
        let payloads = currentXBookmarkPayloadsByReferenceID()
        performVaultWork { snapshot in
            MarkdownVault.removeReference(
                item,
                existing: snapshot,
                xPayloadsByReferenceID: payloads
            )
        }
    }

    func rebuildVaultGraph() {
        let items = self.items
        let collections = self.collections
        let payloads = currentXBookmarkPayloadsByReferenceID()
        performVaultWork { snapshot in
            MarkdownVault.rebuildGraph(
                existing: snapshot,
                items: items,
                collections: collections,
                xPayloadsByReferenceID: payloads
            )
        }
    }

    private func currentXBookmarkPayloadsByReferenceID() -> [UUID: XBookmarkPayloadSummary] {
        xBookmarkPayloadsByReferenceID
    }

    func xBookmarkPayload(for item: ReferenceItem) -> XBookmarkPayloadSummary? {
        xBookmarkPayloadsByReferenceID[item.id]
    }

    private func scheduleVaultWrite(for item: ReferenceItem) {
        pendingVaultItems.insert(item.id)
        vaultWriteWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let idsToWrite = self.pendingVaultItems
            self.pendingVaultItems.removeAll()
            let itemsToWrite = idsToWrite.compactMap { id in
                self.items.first(where: { $0.id == id })
            }
            guard !itemsToWrite.isEmpty else { return }
            let collections = self.collections
            let payloads = self.currentXBookmarkPayloadsByReferenceID()
            self.performVaultWork { snapshot in
                var result = snapshot
                for item in itemsToWrite {
                    result = MarkdownVault.writeReference(
                        item,
                        collections: collections,
                        slugsByID: result.documentSlugsByID,
                        rootURL: result.rootURL,
                        existing: result,
                        xPayloadsByReferenceID: payloads
                    )
                }
                return result
            }
        }
        vaultWriteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func refreshStorageDiagnostics() {
        guard isAPILibraryVisible else { return }
        statsRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let persistence else { return }
            let snapshot = persistence.loadSnapshot()
            let stats = persistence.stats()
            Task { @MainActor [weak self] in
                self?.importJobs = snapshot.importJobs
                self?.storageStats = stats
            }
        }
        statsRefreshWorkItem = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    var zoom: CGFloat {
        get {
            switch mode {
            case .grid:
                gridZoom
            case .canvas:
                canvasZoom
            case .infinity:
                infinityZoom
            }
        }
        set {
            switch mode {
            case .grid:
                gridZoom = min(1.0, max(0.40, newValue))
            case .canvas:
                canvasZoom = min(2.05, max(0.42, newValue))
            case .infinity:
                infinityZoom = min(2.80, max(0.24, newValue))
            }
        }
    }

    var visibleItems: [ReferenceItem] {
        let query = activeSearchQuery
        let cacheKey = VisibleItemsCacheKey(
            filter: selectedFilter,
            searchText: query,
            generation: mutationCounter
        )
        if let cached = cachedVisibleItems[cacheKey] {
            return cached
        }

        let result = makeVisibleItems(filter: selectedFilter, searchText: query)
        cachedVisibleItems[cacheKey] = result
        return result
    }

    func warmCommonReferenceFilters() {
        let filters: [CollectionFilter] = [.all, .inbox, .xBookmarks, .trash] + collections.map { .collection($0.id) }
        let query = activeSearchQuery
        for filter in filters {
            let cacheKey = VisibleItemsCacheKey(filter: filter, searchText: query, generation: mutationCounter)
            guard cachedVisibleItems[cacheKey] == nil else { continue }
            cachedVisibleItems[cacheKey] = makeVisibleItems(filter: filter, searchText: query)
        }
    }

    nonisolated static func sanitizedSearchInput(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.last?.isWhitespace == true, !collapsed.isEmpty else {
            return collapsed
        }
        return "\(collapsed) "
    }

    nonisolated static func normalizedSearchQuery(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func normalizeSearchText() {
        searchText = normalizedSearchText
        applySearchQueryNow()
    }

    private func scheduleSearchApplication() {
        searchDebounceWorkItem?.cancel()
        let normalized = normalizedSearchText
        guard normalized != activeSearchQuery else { return }
        // Clearing the field should feel instant; only debounce while typing.
        if normalized.isEmpty {
            activeSearchQuery = ""
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applySearchQueryNow()
        }
        searchDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func applySearchQueryNow() {
        searchDebounceWorkItem?.cancel()
        searchDebounceWorkItem = nil
        let normalized = normalizedSearchText
        if normalized != activeSearchQuery {
            activeSearchQuery = normalized
        }
    }

    private func makeVisibleItems(filter: CollectionFilter, searchText: String) -> [ReferenceItem] {
        let filtered = items.filter { item in
            switch filter {
            case .all, .graph:
                !item.isTrashed
            case .inbox:
                item.isInbox && !item.isTrashed
            case .xBookmarks:
                item.isXBookmark && !item.isTrashed
            case .files:
                item.isManagedDocument && !item.isTrashed
            case .trash:
                item.isTrashed
            case .chat:
                item.isManagedDocument && !item.isTrashed
            case .api:
                item.kind == .website && !item.isTrashed
            case .collection(let id):
                item.collectionID == id && !item.isTrashed
            case .timeline, .review, .capabilities, .patterns, .rules:
                !item.isTrashed
            }
        }

        let tokens = Self.searchTokens(from: searchText)
        if !tokens.isEmpty, let persistence, let ftsIDs = persistence.ftsSearch(searchText) {
            let idSet = Set(ftsIDs)
            return filtered.filter { idSet.contains($0.id) }
        } else if !tokens.isEmpty {
            return filtered.filter {
                Self.item($0, matchesAllSearchTokens: tokens)
            }
        } else {
            return filtered
        }
    }

    nonisolated private static func searchTokens(from query: String) -> [String] {
        normalizedSearchQuery(query)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
    }

    nonisolated private static func item(_ item: ReferenceItem, matchesAllSearchTokens tokens: [String]) -> Bool {
        let searchableFields = [item.title, item.subtitle, item.fileName]
        return tokens.allSatisfy { token in
            searchableFields.contains { field in
                field.localizedStandardContains(token)
            }
        }
    }

    private func invalidateVisibleItems() {
        cachedVisibleItems.removeAll(keepingCapacity: true)
        cachedCounts = [:]
        countsGeneration = 0
        mutationCounter &+= 1
    }

    var focusedItem: ReferenceItem? {
        guard let focusedItemID else { return nil }
        return items.first(where: { $0.id == focusedItemID })
    }

    func count(for filter: CollectionFilter) -> Int {
        if countsGeneration == mutationCounter, let cached = cachedCounts[filter] {
            return cached
        }
        if countsGeneration != mutationCounter {
            cachedCounts.removeAll()
            countsGeneration = mutationCounter
        }

        let result: Int
        switch filter {
        case .all, .graph:
            result = items.filter { !$0.isTrashed }.count
        case .inbox:
            result = items.filter { $0.isInbox && !$0.isTrashed }.count
        case .xBookmarks:
            result = items.filter { $0.isXBookmark && !$0.isTrashed }.count
        case .files:
            result = items.filter { $0.isManagedDocument && !$0.isTrashed }.count
        case .trash:
            result = items.filter(\.isTrashed).count
        case .chat:
            result = items.filter { $0.isManagedDocument && !$0.isTrashed }.count
        case .api:
            result = items.filter { $0.kind == .website && !$0.isTrashed }.count
        case .collection(let id):
            result = items.filter { $0.collectionID == id && !$0.isTrashed }.count
        case .timeline:
            result = items.filter { !$0.isTrashed }.count
        case .review:
            result = ReviewScheduler.dueItems().count
        case .capabilities:
            result = LociCapability.all.count
        case .patterns:
            result = PromptLibrary.patterns.count
        case .rules:
            result = AutoRulesEngine.allRules().count
        }
        cachedCounts[filter] = result
        return result
    }

    func select(_ item: ReferenceItem, additive: Bool = false) {
        if additive {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
        } else {
            selectedItemIDs = [item.id]
        }
    }

    func focus(_ item: ReferenceItem) {
        selectedItemIDs = [item.id]
        focusedItemID = item.id
    }

    func openPreview(_ item: ReferenceItem) {
        selectedItemIDs = [item.id]
        focusedItemID = item.id
    }

    func requestFocusDismissal() {
        guard focusedItemID != nil else { return }
        focusIsDismissing = true
        focusDismissalRequestID += 1
    }

    func openInNotebook(_ item: ReferenceItem) {
        notebookActiveItemID = item.id
        selectedItemIDs = [item.id]
        selectedFilter = .chat
        focusedItemID = nil
    }

    func clearNotebookDocument() {
        notebookActiveItemID = nil
    }

    @discardableResult
    func focusAdjacentVisibleItem(offset: Int) -> Bool {
        let visible = visibleItems
        guard visible.count > 1,
              let currentFocusedItemID = focusedItemID,
              let currentIndex = visible.firstIndex(where: { $0.id == currentFocusedItemID }) else {
            return false
        }

        let nextIndex = (currentIndex + offset + visible.count) % visible.count
        selectedItemIDs.removeAll()
        self.focusedItemID = visible[nextIndex].id
        return true
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
    }

    func clearFocus() {
        focusedItemID = nil
    }

    func copySelectionToPasteboard(_ pasteboard: NSPasteboard = .general) {
        let ids = selectedItemIDs.isEmpty
            ? Set(focusedItemID.map { [$0] } ?? [])
            : selectedItemIDs
        let selectedItems = items.filter { ids.contains($0.id) && !$0.isTrashed }
        guard !selectedItems.isEmpty else { return }

        let urls = selectedItems.compactMap { originalFileURL(for: $0) }
        let text = selectedItems.map { item in
            item.websiteURL?.absoluteString ?? originalFileURL(for: item)?.path ?? item.title
        }.joined(separator: "\n")

        pasteboard.clearContents()
        if !urls.isEmpty {
            pasteboard.writeObjects(urls as [NSURL])
        }
        if !text.isEmpty {
            pasteboard.setString(text, forType: .string)
        }
    }

    func originalFileURL(for item: ReferenceItem) -> URL? {
        guard let store = LociPersistentStore.shared else { return nil }

        if let managedPath = MarkdownVault.managedOriginalPath(for: item),
           FileManager.default.fileExists(atPath: managedPath.path) {
            return managedPath
        }

        let candidates = [
            item.fileName,
            "webloc_\(item.id.uuidString.lowercased()).webloc"
        ]
        return candidates
            .map { store.originalsURL.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func removeReferenceFromLibrary(id: ReferenceItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        selectedItemIDs.remove(id)
        if focusedItemID == id {
            focusedItemID = nil
        }
        invalidateVisibleItems()
        persistence?.batchDeleteReferences(ids: [id])
        refreshStorageDiagnostics()
        removeReferenceMarkdown(item)
    }

    func zoomScale(for group: ReferenceGroup) -> CGFloat {
        groupZooms[group] ?? 1
    }

    func adjustGlobalZoom(by delta: CGFloat) {
        zoom = zoom * (1 + delta)
    }

    func adjustZoom(for group: ReferenceGroup, by delta: CGFloat) {
        let nextZoom = min(3.20, max(0.36, zoomScale(for: group) * (1 + delta)))
        groupZooms[group] = nextZoom
    }

    func clusterOffset(for group: ReferenceGroup) -> CGSize {
        groupOffsets[group] ?? .zero
    }

    func setClusterOffset(_ offset: CGSize, for group: ReferenceGroup) {
        groupOffsets[group] = offset
    }

    func selectItems(with ids: Set<ReferenceItem.ID>) {
        selectedItemIDs = ids
        if let focusedItemID, !ids.contains(focusedItemID) {
            self.focusedItemID = nil
        }
    }

    func importScreenshot(undoManager: UndoManager? = nil) {
        Task {
            do {
                let screenshotURL = try await ScreenshotCapture.captureScreen()
                await MainActor.run {
                    importFiles([screenshotURL], undoManager: undoManager)
                }
            } catch {
                await MainActor.run {
                    ErrorPresenter.shared.show(.importFailed("Screenshot capture: \(error.localizedDescription)"))
                }
            }
        }
    }

    func importScreenshotRegion(_ rect: CGRect, undoManager: UndoManager? = nil) {
        Task {
            do {
                let screenshotURL = try await ScreenshotCapture.captureRegion(rect)
                await MainActor.run {
                    importFiles([screenshotURL], undoManager: undoManager)
                }
            } catch {
                await MainActor.run {
                    ErrorPresenter.shared.show(.importFailed("Screenshot capture: \(error.localizedDescription)"))
                }
            }
        }
    }

    func generateVariation(of type: VariationType, for item: ReferenceItem, undoManager: UndoManager? = nil) {
        Task {
            guard let result = await VariationGenerator.generateVariation(type, for: item, persistence: persistence) else { return }
            await MainActor.run {
                VariationGenerator.importVariation(result, into: self, undoManager: undoManager)
            }
        }
    }

    func importWebsiteOrLink(_ rawValue: String, undoManager: UndoManager? = nil) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalized = normalizedURLString(trimmed)
        guard URL(string: normalized) != nil,
              normalized.contains(".") || normalized.contains("://") else {
            ErrorPresenter.shared.show(.importFailed("\"\(trimmed.prefix(60))\" is not a valid link"))
            return
        }
        let title = URL(string: normalized)?.host(percentEncoded: false) ?? trimmed
        let fileName = safeFileName(from: title, fallback: "website") + ".webloc"
        addImportedReference(
            title: title.replacingOccurrences(of: "www.", with: ""),
            subtitle: normalized,
            fileName: fileName,
            kind: .website,
            group: .website,
            aspectRatio: 1.48,
            source: .url,
            payload: normalized,
            undoManager: undoManager
        )
        LociTelemetry.recordImport(source: .url, count: 1)
        FeedbackPresenter.shared.success("Added to Inbox", detail: title.replacingOccurrences(of: "www.", with: ""))
    }

    func importFiles(_ urls: [URL], undoManager: UndoManager? = nil) {
        let fileURLs = expandedImportFileURLs(from: urls)
        guard !fileURLs.isEmpty else { return }

        for url in fileURLs {
            let kind = visualKind(for: url)
            let group: ReferenceGroup = kind == .website ? .website : .file
            let managedURL = persistence?.importFileToOriginals(from: url)
            let fileName = managedURL?.lastPathComponent ?? url.lastPathComponent
            let importAspectRatio = imageAspectRatio(for: managedURL ?? url) ?? aspectRatio(forImported: kind)
            let itemID = addImportedReference(
                title: url.deletingPathExtension().lastPathComponent,
                subtitle: url.deletingLastPathComponent().lastPathComponent,
                fileName: fileName,
                kind: kind,
                group: group,
                aspectRatio: importAspectRatio,
                source: .file,
                payload: managedURL?.path ?? url.path,
                undoManager: undoManager
            )
            if let managedURL {
                attachThumbnail(for: itemID, from: managedURL)
            }
        }
        FeedbackPresenter.shared.success(
            fileURLs.count == 1 ? "Added to Inbox" : "Added \(fileURLs.count) items",
            detail: fileURLs.count == 1 ? fileURLs[0].lastPathComponent : "Ready in Inbox"
        )
        LociTelemetry.recordImport(source: .file, count: fileURLs.count)
    }

    func importPasteboard(_ pasteboard: NSPasteboard = .general, undoManager: UndoManager? = nil) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            importFiles(urls, undoManager: undoManager)
            return
        }

        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return
        }

        if looksLikeURL(text) {
            importWebsiteOrLink(text, undoManager: undoManager)
        } else {
            importNote(text, undoManager: undoManager)
        }
    }

    func importText(_ text: String, undoManager: UndoManager? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if looksLikeURL(trimmed) {
            importWebsiteOrLink(trimmed, undoManager: undoManager)
        } else {
            importNote(trimmed, undoManager: undoManager)
        }
    }

    func importNote(_ text: String, undoManager: UndoManager? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let firstLine = trimmed.components(separatedBy: .newlines).first ?? "Note"
        addImportedReference(
            title: String(firstLine.prefix(48)),
            subtitle: "Quick Note",
            fileName: safeFileName(from: firstLine, fallback: "note") + ".md",
            kind: .typography,
            group: .memory,
            aspectRatio: 0.82,
            source: .clipboard,
            payload: trimmed,
            undoManager: undoManager
        )
        LociTelemetry.recordImport(source: .clipboard, count: 1)
        FeedbackPresenter.shared.success("Added to Inbox", detail: "Quick Note")
    }

    func removeGeneratedDemoLibraryIfPresent() {
        guard let index = collections.firstIndex(where: { $0.name == "Demo Library" }) else {
            return
        }

        let collection = collections[index]
        let generatedTitles: Set<String> = [
            "Apple Human Interface Guidelines",
            "Linear product motion",
            "Raycast command palette",
            "Mobbin mobile flow references",
            "Figma community systems",
            "Saved X thread: visual research",
            "Design system audit checklist",
            "Reference capture workflow"
        ]
        let generatedSubtitles: Set<String> = [
            "https://developer.apple.com/design/human-interface-guidelines",
            "https://linear.app",
            "https://raycast.com",
            "https://mobbin.com",
            "https://www.figma.com/community",
            "https://x.com/design/status/1789200000000000000"
        ]
        let collectionItems = items.filter { $0.collectionID == collection.id }
        let generatedItems = collectionItems.filter {
            generatedTitles.contains($0.title) || generatedSubtitles.contains($0.subtitle)
        }
        let generatedIDs = Set(generatedItems.map(\.id))
        if !collectionItems.isEmpty && generatedItems.isEmpty {
            return
        }

        if !generatedIDs.isEmpty {
            persistence?.batchDeleteReferences(ids: generatedIDs)
            for item in generatedItems {
                deleteFilesForReference(item)
                removeReferenceMarkdown(item)
            }
            items.removeAll { generatedIDs.contains($0.id) }
            selectedItemIDs.subtract(generatedIDs)
            if let focusedItemID, generatedIDs.contains(focusedItemID) {
                self.focusedItemID = nil
            }
        }

        let hasUserItems = collectionItems.contains { !generatedIDs.contains($0.id) }
        if !hasUserItems {
            collections.remove(at: index)
            persistence?.softDeleteCollection(id: collection.id)
            if selectedFilter == .collection(collection.id) {
                selectedFilter = .all
            }
        }
        invalidateVisibleItems()
        refreshStorageDiagnostics()
        rebuildVaultGraph()
    }

    @discardableResult
    func upsertXBookmarkReferences(_ candidates: [XBookmarkImportCandidate]) -> XBookmarkImportSummary {
        guard !candidates.isEmpty else {
            return XBookmarkImportSummary(imported: 0, updated: 0, touchedIDs: [])
        }

        var imported = 0
        var updated = 0
        var touchedIDs: [ReferenceItem.ID] = []
        var queuedThumbnailWork = false
        var existingIDsByURL: [String: ReferenceItem.ID] = [:]
        var existingIndexByID: [ReferenceItem.ID: Int] = [:]
        var insertedItems: [ReferenceItem] = []
        var insertedURLs = Set<String>()

        for (index, item) in items.enumerated() where !item.isTrashed {
            existingIDsByURL[item.subtitle] = item.id
            existingIndexByID[item.id] = index
        }

        for candidate in candidates {
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? "X Bookmark" : title
            let payloadString = candidate.payloadString
            let shouldFetchPreview = candidate.hasMediaPreview

            if let existingID = existingIDsByURL[candidate.url],
               let index = existingIndexByID[existingID] {
                items[index].title = displayTitle
                items[index].subtitle = candidate.url
                items[index].kind = .website
                items[index].group = .link
                items[index].isInbox = true
                items[index].aspectRatio = min(items[index].aspectRatio, 0.92)
                xBookmarkPayloadsByReferenceID[existingID] = XBookmarkPayloadSummary(candidate.payload)
                if let persistence {
                    persistence.upsert(reference: items[index])
                    persistence.enqueueImportJob(
                        source: .browserExtension,
                        payload: payloadString,
                        status: shouldFetchPreview ? .queued : .succeeded,
                        referenceID: existingID
                    )
                    MarkdownVault.writeRawSourcePackage(for: items[index], source: .browserExtension, payload: payloadString)
                    writeReferenceMarkdown(items[index])
                    TagHierarchy.addTag("x-bookmarked", to: existingID)
                }
                touchedIDs.append(existingID)
                queuedThumbnailWork = queuedThumbnailWork || shouldFetchPreview
                updated += 1
                continue
            }

            guard insertedURLs.insert(candidate.url).inserted else {
                continue
            }
            let insertOffset = insertedItems.count
            let item = ReferenceItem(
                id: UUID(),
                title: displayTitle,
                subtitle: candidate.url,
                fileName: safeFileName(from: URL(string: candidate.url)?.host(percentEncoded: false) ?? displayTitle, fallback: "x-post") + ".webloc",
                kind: .website,
                group: .link,
                theme: themeForImport(displayTitle),
                aspectRatio: 0.92,
                collectionID: nil,
                isInbox: true,
                isTrashed: false,
                canvasPosition: nextImportCanvasPosition(for: .link, additionalOffset: insertOffset),
                infinityPosition: nextImportInfinityPosition(for: .link, additionalOffset: insertOffset)
            )

            var managedOriginalURL: URL?
            if let weblocURL = persistence?.createWeblocFile(for: candidate.url, itemID: item.id) {
                managedOriginalURL = persistence?.importFileToOriginals(from: weblocURL)
            }

            insertedItems.append(item)
            xBookmarkPayloadsByReferenceID[item.id] = XBookmarkPayloadSummary(candidate.payload)
            if let persistence {
                MarkdownVault.writeRawSourcePackage(
                    for: item,
                    source: .browserExtension,
                    payload: payloadString,
                    managedOriginalURL: managedOriginalURL
                )
                persistence.upsert(reference: item)
                persistence.enqueueImportJob(
                    source: .browserExtension,
                    payload: payloadString,
                    status: shouldFetchPreview ? .queued : .succeeded,
                    referenceID: item.id
                )
                writeReferenceMarkdown(item)
                TagHierarchy.addTag("x-bookmarked", to: item.id)
            }
            touchedIDs.append(item.id)
            queuedThumbnailWork = queuedThumbnailWork || shouldFetchPreview
            imported += 1
        }

        if !insertedItems.isEmpty {
            items.insert(contentsOf: insertedItems.reversed(), at: 0)
        }

        if !touchedIDs.isEmpty {
            selectedFilter = .xBookmarks
            selectedItemIDs = [touchedIDs[0]]
            focusedItemID = nil
            invalidateVisibleItems()
            refreshStorageDiagnostics()
            if queuedThumbnailWork {
                Task { await ImportCoordinator.shared.enqueueProcess() }
            }
        }

        return XBookmarkImportSummary(imported: imported, updated: updated, touchedIDs: touchedIDs)
    }

    func importExtensionReference(_ payload: BrowserExtensionReferencePayload) {
        let normalizedURL = payload.url.map(normalizedURLString)
        let host = normalizedURL.flatMap { URL(string: $0)?.host(percentEncoded: false) }
        let note = payload.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedText = payload.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = [title, selectedText, host]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .first ?? "Saved Reference"

        guard let normalizedURL, URL(string: normalizedURL) != nil else {
            importNote([displayTitle, note].compactMap { $0 }.joined(separator: "\n\n"))
            return
        }

        let isXPost = URL(string: normalizedURL)?.isXFamilyURL == true
        let importedTitle = isXPost
            ? XBookmarkDisplay.title(author: title, text: selectedText, fallback: displayTitle)
            : displayTitle
        let group: ReferenceGroup = isXPost ? .link : .website
        let fileName = safeFileName(from: host ?? importedTitle, fallback: isXPost ? "x-post" : "website") + ".webloc"
        let payloadEnvelope = BrowserExtensionReferencePayload(
            url: normalizedURL,
            title: importedTitle,
            note: note,
            selectedText: selectedText,
            pageHTML: payload.pageHTML,
            articleMarkdown: payload.articleMarkdown,
            transcriptText: payload.transcriptText,
            imageURLs: payload.imageURLs,
            autoTags: payload.autoTags,
            source: payload.source,
            faviconURL: payload.faviconURL,
            ogImageURL: payload.ogImageURL,
            alsoBookmarkOnX: payload.alsoBookmarkOnX
        )

        let importedID = addImportedReference(
            title: importedTitle,
            subtitle: normalizedURL,
            fileName: fileName,
            kind: .website,
            group: group,
            aspectRatio: isXPost ? 0.92 : 1.48,
            source: .browserExtension,
            payload: (try? String(data: JSONEncoder().encode(payloadEnvelope), encoding: .utf8)) ?? normalizedURL
        )
        LociTelemetry.recordImport(source: .browserExtension, count: 1)

        if isXPost {
            xBookmarkPayloadsByReferenceID[importedID] = XBookmarkPayloadSummary(payloadEnvelope)
        }
        if payload.alsoBookmarkOnX == true, isXPost {
            syncXBookmark(url: normalizedURL)
        }
    }

    private func syncXBookmark(url: String) {
        let bookmarkTag = "x-bookmarked"
        if let lastItem = items.first(where: { $0.subtitle == url && !$0.isTrashed }) {
            Task { @MainActor in
                TagHierarchy.addTag(bookmarkTag, to: lastItem.id)
            }
        }
    }

    func updateImportedReference(
        id: ReferenceItem.ID,
        title: String,
        subtitle: String,
        source: ImportSourceKind,
        payload: String,
        markInbox: Bool = false
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            items[index].title = trimmedTitle
        }
        items[index].subtitle = subtitle
        if markInbox {
            items[index].isInbox = true
            selectedFilter = .inbox
        }
        invalidateVisibleItems()
        persistence?.upsert(reference: items[index])
        MarkdownVault.writeRawSourcePackage(for: items[index], source: source, payload: payload)
        writeReferenceMarkdown(items[index])
        if source == .browserExtension, let persistence {
            persistence.enqueueImportJob(source: source, payload: payload, status: .queued, referenceID: id)
            Task { await ImportCoordinator.shared.enqueueProcess() }
        }
    }

    @discardableResult
    func addImportedReference(
        title: String,
        subtitle: String,
        fileName: String,
        kind: VisualKind,
        group: ReferenceGroup,
        aspectRatio: CGFloat,
        source: ImportSourceKind,
        payload: String,
        undoManager: UndoManager? = nil
    ) -> ReferenceItem.ID {
        let item = ReferenceItem(
            id: UUID(),
            title: title.isEmpty ? "Untitled Reference" : title,
            subtitle: subtitle,
            fileName: fileName,
            kind: kind,
            group: group,
            theme: themeForImport(title),
            aspectRatio: aspectRatio,
            collectionID: nil,
            isInbox: true,
            isTrashed: false,
            canvasPosition: nextImportCanvasPosition(for: group),
            infinityPosition: nextImportInfinityPosition(for: group)
        )

        var managedOriginalURL: URL?
        if (source == .url || source == .browserExtension), let persistence {
            let webURL = source == .browserExtension ? (try? JSONDecoder().decode(BrowserExtensionReferencePayload.self, from: Data(payload.utf8)))?.url ?? payload : payload
            let weblocURL = persistence.createWeblocFile(for: webURL, itemID: item.id)
            if let weblocURL {
                managedOriginalURL = persistence.importFileToOriginals(from: weblocURL)
            }
        } else if source == .file {
            let fileURL = URL(fileURLWithPath: payload)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                managedOriginalURL = fileURL
            }
        }

        MarkdownVault.writeRawSourcePackage(for: item, source: source, payload: payload, managedOriginalURL: managedOriginalURL)
        items.insert(item, at: 0)
        selectedFilter = .inbox
        selectedItemIDs = [item.id]
        focusedItemID = nil
        invalidateVisibleItems()
        if let persistence {
            persistence.upsert(reference: item)
            persistence.enqueueImportJob(source: source, payload: payload, status: .queued, referenceID: item.id)
            persistence.enqueueImportJob(source: .extract, payload: payload, status: .queued, referenceID: item.id)
        }
        refreshStorageDiagnostics()
        Task { await ImportCoordinator.shared.enqueueProcess() }
        Task { @MainActor in
            AutoRulesEngine.runRulesForImport(itemID: item.id, source: source, payload: payload)
        }
        Task { @MainActor [weak self, item] in
            self?.writeReferenceMarkdown(item)
        }
        let capturedID = item.id
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.removeReferenceFromLibrary(id: capturedID)
            }
        }
        undoManager?.setActionName("Import Reference")
        return item.id
    }

    private func attachThumbnail(for itemID: ReferenceItem.ID, from fileURL: URL) {
        Task { [weak self] in
            guard let self else { return }
            let downsampledPNGData = await LociImageLoader.pngData(from: fileURL, maxPixelSize: 720)
            let thumbnailPNGData: Data?
            if let downsampledPNGData {
                thumbnailPNGData = downsampledPNGData
            } else {
                thumbnailPNGData = await Self.quickLookThumbnailPNGData(for: fileURL)
            }
            guard let pngData = thumbnailPNGData else { return }
            let persistence = self.persistence
            await MainActor.run {
                if let thumbURL = persistence?.writeThumbnailPNGData(pngData, for: itemID) {
                    self.applyThumbnailPath(thumbURL.lastPathComponent, to: itemID)
                    persistence?.updateReferenceThumbnail(id: itemID, thumbPath: thumbURL.lastPathComponent)
                }
            }
        }
    }

    private func applyThumbnailPath(_ path: String, to itemID: ReferenceItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].thumbnailPath = path
        invalidateVisibleItems()
    }

    nonisolated static func quickLookThumbnailPNGData(for fileURL: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 720, height: 720),
            scale: await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 },
            representationTypes: .all
        )

        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let representation else {
                    continuation.resume(returning: nil)
                    return
                }
                let bitmap = NSBitmapImageRep(cgImage: representation.cgImage)
                continuation.resume(returning: bitmap.representation(using: .png, properties: [:]))
            }
        }
    }

    private func normalizedURLString(_ value: String) -> String {
        if value.contains("://") {
            return value
        }
        return "https://\(value)"
    }

    private func looksLikeURL(_ text: String) -> Bool {
        text.contains("://") || (text.contains(".") && !text.contains(" "))
    }

    private func expandedImportFileURLs(from urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return [url]
            }
            guard isDirectory.boolValue else { return [url] }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []
            return children.filter { child in
                (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
    }

    private func visualKind(for url: URL) -> VisualKind {
        switch url.pathExtension.lowercased() {
        case "url", "webloc", "html", "htm":
            .website
        case "app":
            .app
        case "txt", "md", "rtf", "pdf":
            .typography
        case "heic", "jpg", "jpeg", "png", "gif", "webp", "tiff":
            .product
        default:
            .laptop
        }
    }

    private func aspectRatio(forImported kind: VisualKind) -> CGFloat {
        switch kind {
        case .phone:
            0.56
        case .laptop, .website:
            1.52
        case .app, .product:
            1.0
        case .typography:
            0.76
        }
    }

    private func imageAspectRatio(for url: URL) -> CGFloat? {
        LociImageLoader.imageAspectRatio(from: url)
    }

    private func themeForImport(_ text: String) -> ReferenceTheme {
        let themes = ReferenceTheme.allCases
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return themes[Int(hash % UInt64(themes.count))]
    }

    private func safeFileName(from text: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let folded = text.lowercased().map { character -> Character in
            character.unicodeScalars.allSatisfy { allowed.contains($0) } ? character : "-"
        }
        let collapsed = String(folded).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? fallback : String(collapsed.prefix(56))
    }

    private func nextImportCanvasPosition(for group: ReferenceGroup, additionalOffset: Int = 0) -> CGSize {
        let count = items.filter { $0.group == group && !$0.isTrashed }.count + additionalOffset
        let base: CGSize = switch group {
        case .file:
            CGSize(width: -250, height: -120)
        case .memory:
            CGSize(width: -220, height: 130)
        case .link:
            CGSize(width: 220, height: 130)
        case .website:
            CGSize(width: 235, height: -120)
        }
        return CGSize(
            width: base.width + CGFloat(count % 7) * 34,
            height: base.height + CGFloat(count / 7) * 42
        )
    }

    private func nextImportInfinityPosition(for group: ReferenceGroup, additionalOffset: Int = 0) -> CGPoint {
        let count = items.filter { $0.group == group && !$0.isTrashed }.count + additionalOffset
        let angle = CGFloat(count) * 0.62
        let radius = CGFloat(80 + (count % 12) * 16)
        return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    func updateCanvasPosition(for id: ReferenceItem.ID, to position: CGSize) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].canvasPosition = position
        invalidateVisibleItems()
        persistence?.upsert(reference: items[index], recordsHistory: false, refreshFTS: false)
        refreshStorageDiagnostics()
    }

    func rearrangeSelectedCanvasItems() {
        let selectedIDs = selectedItemIDs
        let selectedIndexes = items.indices
            .filter { selectedIDs.contains(items[$0].id) && !items[$0].isTrashed }
            .sorted { lhs, rhs in
                if abs(items[lhs].canvasPosition.height - items[rhs].canvasPosition.height) > 1 {
                    return items[lhs].canvasPosition.height < items[rhs].canvasPosition.height
                }
                return items[lhs].canvasPosition.width < items[rhs].canvasPosition.width
            }
        guard selectedIndexes.count > 1 else { return }

        let center = selectedIndexes.reduce(CGSize.zero) { partial, index in
            CGSize(
                width: partial.width + items[index].canvasPosition.width,
                height: partial.height + items[index].canvasPosition.height
            )
        }
        let averageCenter = CGSize(
            width: center.width / CGFloat(selectedIndexes.count),
            height: center.height / CGFloat(selectedIndexes.count)
        )
        let columns = max(2, Int(ceil(sqrt(Double(selectedIndexes.count)))))
        let rows = Int(ceil(Double(selectedIndexes.count) / Double(columns)))
        let spacing = CGSize(width: 168, height: 128)

        for (offset, index) in selectedIndexes.enumerated() {
            let column = offset % columns
            let row = offset / columns
            let x = (CGFloat(column) - CGFloat(columns - 1) / 2) * spacing.width
            let y = (CGFloat(row) - CGFloat(rows - 1) / 2) * spacing.height
            items[index].canvasPosition = CGSize(
                width: averageCenter.width + x,
                height: averageCenter.height + y
            )
            persistence?.upsert(reference: items[index], recordsHistory: false, refreshFTS: false)
        }

        invalidateVisibleItems()
        refreshStorageDiagnostics()
    }

    func resetCanvasLayout() {
        canvasZoom = 0.96
        canvasPan = .zero
        selectedItemIDs.removeAll()
        focusedItemID = nil

        var groupCounts: [ReferenceGroup: Int] = [:]
        for index in items.indices {
            guard !items[index].isTrashed else { continue }
            let group = items[index].group
            let localIndex = groupCounts[group, default: 0]
            groupCounts[group] = localIndex + 1
            items[index].canvasPosition = resetCanvasPosition(for: group, localIndex: localIndex)
            persistence?.upsert(reference: items[index], recordsHistory: false, refreshFTS: false)
        }

        refreshStorageDiagnostics()
    }

    private func resetCanvasPosition(for group: ReferenceGroup, localIndex: Int) -> CGSize {
        let base: CGSize = switch group {
        case .file:
            CGSize(width: -230, height: -118)
        case .website:
            CGSize(width: 230, height: -112)
        case .memory:
            CGSize(width: -210, height: 132)
        case .link:
            CGSize(width: 220, height: 138)
        }
        let columns = switch group {
        case .file, .website:
            7
        case .memory, .link:
            6
        }
        let column = localIndex % columns
        let row = localIndex / columns
        let rowOffset = row.isMultiple(of: 2) ? CGFloat.zero : 18
        let jitterX = CGFloat((localIndex * 13) % 11 - 5)
        let jitterY = CGFloat((localIndex * 17) % 9 - 4)
        return CGSize(
            width: base.width + (CGFloat(column) - CGFloat(columns - 1) / 2) * 72 + rowOffset + jitterX,
            height: base.height + CGFloat(row) * 68 + jitterY
        )
    }

    func updateInfinityPosition(for id: ReferenceItem.ID, to position: CGPoint) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].infinityPosition = position
        invalidateVisibleItems()
        persistence?.upsert(reference: items[index], recordsHistory: false, refreshFTS: false)
        refreshStorageDiagnostics()
    }

    func addCollection(undoManager: UndoManager? = nil) {
        let collection = ReferenceCollection(
            id: UUID(),
            name: "Untitled Thread \(collections.count + 1)",
            symbol: "sparkles",
            tint: .gray
        )
        collections.append(collection)
        persistence?.upsert(collection: collection)
        selectedFilter = .collection(collection.id)
        selectedItemIDs.removeAll()
        refreshStorageDiagnostics()
        rebuildVaultGraph()
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.deleteCollection(id: collection.id, undoManager: nil)
            }
        }
        undoManager?.setActionName("Add Collection")
    }

    func renameCollection(id: UUID, to name: String, undoManager: UndoManager? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = collections.firstIndex(where: { $0.id == id }) else { return }
        let previousName = collections[index].name
        collections[index].name = trimmed
        persistence?.upsert(collection: collections[index])
        refreshStorageDiagnostics()
        rebuildVaultGraph()
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.renameCollection(id: id, to: previousName, undoManager: nil)
            }
        }
        undoManager?.setActionName("Rename Collection")
    }

    func updateCollectionBrief(id: UUID, to brief: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        persistence?.upsert(collection: collections[index])
        rebuildVaultGraph()
    }

    func mergeCollection(id: UUID, direction: CollectionMergeDirection) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = index - 1
        case .down:
            targetIndex = index + 1
        }
        guard collections.indices.contains(targetIndex) else { return }

        let targetID = collections[targetIndex].id
        for itemIndex in items.indices where items[itemIndex].collectionID == id {
            items[itemIndex].collectionID = targetID
            persistence?.upsert(reference: items[itemIndex])
        }
        persistence?.softDeleteCollection(id: id)
        collections.remove(at: index)
        if selectedFilter == .collection(id) {
            selectedFilter = .collection(targetID)
        }
        selectedItemIDs.removeAll()
        refreshStorageDiagnostics()
        rebuildVaultGraph()
    }

    func canMergeCollection(id: UUID, direction: CollectionMergeDirection) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return false }
        switch direction {
        case .up:
            return index > 0
        case .down:
            return index < collections.count - 1
        }
    }

    func moveReference(id: ReferenceItem.ID, to collectionID: UUID?, undoManager: UndoManager? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let previousCollectionID = items[index].collectionID
        let previousIsInbox = items[index].isInbox
        items[index].collectionID = collectionID
        items[index].isInbox = collectionID == nil
        invalidateVisibleItems()
        persistence?.upsert(reference: items[index])
        refreshStorageDiagnostics()
        rebuildVaultGraph()
        FeedbackPresenter.shared.success("Moved reference", detail: collectionDisplayName(for: collectionID))
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.moveReference(id: id, to: previousCollectionID, undoManager: nil)
                if let restoreIndex = target.items.firstIndex(where: { $0.id == id }) {
                    target.items[restoreIndex].isInbox = previousIsInbox
                    target.persistence?.upsert(reference: target.items[restoreIndex])
                    target.invalidateVisibleItems()
                }
            }
        }
        undoManager?.setActionName("Move Reference")
    }

    func moveReferences(_ ids: Set<ReferenceItem.ID>, to collectionID: UUID?, undoManager: UndoManager? = nil) {
        let previousStates = ids.compactMap { id -> (ReferenceItem.ID, UUID?, Bool)? in
            guard let item = items.first(where: { $0.id == id }) else { return nil }
            return (id, item.collectionID, item.isInbox)
        }
        guard !previousStates.isEmpty else { return }
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            items[index].collectionID = collectionID
            items[index].isInbox = collectionID == nil
            persistence?.upsert(reference: items[index])
        }
        invalidateVisibleItems()
        refreshStorageDiagnostics()
        rebuildVaultGraph()
        FeedbackPresenter.shared.success(
            previousStates.count == 1 ? "Moved reference" : "Moved \(previousStates.count) references",
            detail: collectionDisplayName(for: collectionID)
        )
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                for (id, collectionID, isInbox) in previousStates {
                    guard let index = target.items.firstIndex(where: { $0.id == id }) else { continue }
                    target.items[index].collectionID = collectionID
                    target.items[index].isInbox = isInbox
                    target.persistence?.upsert(reference: target.items[index])
                }
                target.invalidateVisibleItems()
                target.refreshStorageDiagnostics()
                target.rebuildVaultGraph()
            }
        }
        undoManager?.setActionName("Move References")
    }

    private func collectionDisplayName(for collectionID: UUID?) -> String {
        guard let collectionID else { return "Inbox" }
        return collections.first(where: { $0.id == collectionID })?.name ?? "Collection"
    }

    func duplicateReference(id: ReferenceItem.ID, undoManager: UndoManager? = nil) {
        guard let source = items.first(where: { $0.id == id }) else { return }
        var duplicate = source
        duplicate = ReferenceItem(
            id: UUID(),
            title: "\(source.title) Copy",
            subtitle: source.subtitle,
            fileName: source.fileName,
            kind: source.kind,
            group: source.group,
            theme: source.theme,
            aspectRatio: source.aspectRatio,
            collectionID: source.collectionID,
            isInbox: source.isInbox,
            isTrashed: false,
            thumbnailPath: source.thumbnailPath,
            canvasPosition: CGSize(width: source.canvasPosition.width + 26, height: source.canvasPosition.height + 26),
            infinityPosition: CGPoint(x: source.infinityPosition.x + 34, y: source.infinityPosition.y + 34)
        )
        items.insert(duplicate, at: 0)
        invalidateVisibleItems()
        persistence?.upsert(reference: duplicate)
        selectedItemIDs = [duplicate.id]
        focusedItemID = nil
        refreshStorageDiagnostics()
        writeReferenceMarkdown(duplicate)
        let capturedID = duplicate.id
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.removeReferenceFromLibrary(id: capturedID)
            }
        }
        undoManager?.setActionName("Duplicate Reference")
    }

    func trashReference(id: ReferenceItem.ID, undoManager: UndoManager? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trashedItem = items[index]
        let capturedID = id

        undoManager?.registerUndo(withTarget: self) { _ in
            Task { @MainActor in
                self.restoreReference(id: capturedID, undoManager: nil)
            }
        }
        undoManager?.setActionName("Trash Reference")

        items[index].isTrashed = true
        invalidateVisibleItems()
        persistence?.batchTrashReferences(ids: [id])
        selectedItemIDs.remove(id)
        if focusedItemID == id {
            focusedItemID = nil
        }
        refreshStorageDiagnostics()
        removeReferenceMarkdown(trashedItem)
    }

    func restoreReference(id: ReferenceItem.ID, undoManager: UndoManager? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let capturedID = id

        undoManager?.registerUndo(withTarget: self) { _ in
            Task { @MainActor in
                self.trashReference(id: capturedID, undoManager: nil)
            }
        }
        undoManager?.setActionName("Restore Reference")

        items[index].isTrashed = false
        items[index].isInbox = true
        invalidateVisibleItems()
        persistence?.upsert(reference: items[index])
        selectedItemIDs = [id]
        selectedFilter = .inbox
        refreshStorageDiagnostics()
        writeReferenceMarkdown(items[index])
    }

    func sendSelectionToTrash(undoManager: UndoManager? = nil) {
        let trashedIDs = selectedItemIDs
        var trashedItems: [ReferenceItem] = []
        for id in selectedItemIDs {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            items[index].isTrashed = true
            trashedItems.append(items[index])
        }
        invalidateVisibleItems()

        undoManager?.registerUndo(withTarget: self) { _ in
            Task { @MainActor in
                for item in trashedItems {
                    self.restoreReference(id: item.id, undoManager: nil)
                }
            }
        }
        undoManager?.setActionName("Trash Selection")

        if let persistence {
            persistence.batchTrashReferences(ids: trashedIDs)
        }
        if let focusedItemID, trashedIDs.contains(focusedItemID) {
            self.focusedItemID = nil
        }
        selectedItemIDs.removeAll()
        refreshStorageDiagnostics()
        Task { @MainActor [weak self, trashedItems] in
            for item in trashedItems {
                self?.removeReferenceMarkdown(item)
            }
        }
    }

    func emptyTrash() {
        let trashedItems = items.filter(\.isTrashed)
        guard !trashedItems.isEmpty else { return }
        let trashedIDs = Set(trashedItems.map(\.id))

        if let persistence {
            persistence.batchDeleteReferences(ids: trashedIDs)
        }

        for item in trashedItems {
            deleteFilesForReference(item)
            removeReferenceMarkdown(item)
        }

        items.removeAll { $0.isTrashed }
        selectedItemIDs.removeAll()
        if let focusedItemID, trashedIDs.contains(focusedItemID) {
            self.focusedItemID = nil
        }
        invalidateVisibleItems()
        refreshStorageDiagnostics()
        rebuildVaultGraph()
    }

    func deleteSelectedFromTrash() {
        let selectedTrashed = selectedItemIDs.filter { id in
            items.first(where: { $0.id == id })?.isTrashed == true
        }
        guard !selectedTrashed.isEmpty else { return }

        if let persistence {
            persistence.batchDeleteReferences(ids: selectedTrashed)
        }

        for id in selectedTrashed {
            if let item = items.first(where: { $0.id == id }) {
                deleteFilesForReference(item)
                removeReferenceMarkdown(item)
            }
        }

        items.removeAll { selectedTrashed.contains($0.id) }
        selectedItemIDs.removeAll()
        if let focusedItemID, selectedTrashed.contains(focusedItemID) {
            self.focusedItemID = nil
        }
        invalidateVisibleItems()
        refreshStorageDiagnostics()
        rebuildVaultGraph()
    }

    private func deleteFilesForReference(_ item: ReferenceItem) {
        guard let store = LociPersistentStore.shared else { return }
        let candidates = [
            item.fileName,
            "webloc_\(item.id.uuidString.lowercased()).webloc"
        ]
        for name in candidates {
            let url = store.originalsURL.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func deleteCollection(id: UUID, undoManager: UndoManager? = nil) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        let deletedCollection = collections[index]
        let affectedItems = items.filter { $0.collectionID == id }

        undoManager?.registerUndo(withTarget: self) { _ in
            Task { @MainActor in
                self.addCollectionRestored(deletedCollection, items: affectedItems)
            }
        }
        undoManager?.setActionName("Delete Collection")

        for itemIndex in items.indices where items[itemIndex].collectionID == id {
            items[itemIndex].collectionID = nil
            persistence?.upsert(reference: items[itemIndex])
        }
        invalidateVisibleItems()
        persistence?.softDeleteCollection(id: id)
        collections.remove(at: index)
        if selectedFilter == .collection(id) {
            selectedFilter = .all
        }
        selectedItemIDs.removeAll()
        refreshStorageDiagnostics()
        rebuildVaultGraph()
    }

    private func addCollectionRestored(_ collection: ReferenceCollection, items: [ReferenceItem]) {
        collections.append(collection)
        persistence?.upsert(collection: collection)
        for item in items {
            if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[index].collectionID = collection.id
                persistence?.upsert(reference: self.items[index])
            }
        }
        invalidateVisibleItems()
        refreshStorageDiagnostics()
        rebuildVaultGraph()
    }

    static func load() -> LibraryStore {
        guard let persistence = LociPersistentStore.shared else {
            return LibraryStore(collections: [], items: [])
        }

        persistence.removeGeneratedDemoDataIfNeeded()
        let snapshot = persistence.loadSnapshot()
        return LibraryStore(
            collections: snapshot.collections,
            items: snapshot.references,
            persistence: persistence,
            deferVaultBootstrap: true
        )
    }

}
actor ImportCoordinator {
    static let shared = ImportCoordinator()

    private weak var persistence: LociPersistentStore?
    private var isProcessing = false
    private var pendingTrigger = false
    private var autonomousAgentTask: Task<Void, Never>?
    private var recentResults: [ImportJobResult] = []
    private var resultObservers: [UUID: AsyncStream<[ImportJobResult]>.Continuation] = [:]

    struct ImportJobResult: Identifiable, Hashable, Sendable {
        let id: UUID
        let source: ImportSourceKind
        let status: ImportJobStatus
        let title: String
        let referenceID: ReferenceItem.ID?
        let thumbnailPath: String?
        let timestamp: Date
    }

    func setPersistence(_ store: LociPersistentStore) {
        self.persistence = store
    }

    func getRecentResults() -> [ImportJobResult] {
        recentResults
    }

    func resultUpdates() -> AsyncStream<[ImportJobResult]> {
        let id = UUID()
        return AsyncStream { continuation in
            resultObservers[id] = continuation
            continuation.yield(recentResults)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeResultObserver(id) }
            }
        }
    }

    private func removeResultObserver(_ id: UUID) {
        resultObservers[id] = nil
    }

    private func record(_ result: ImportJobResult) {
        recentResults.insert(result, at: 0)
        if recentResults.count > 20 { recentResults.removeLast() }
        for observer in resultObservers.values {
            observer.yield(recentResults)
        }
    }

    func enqueueProcess() {
        guard !isProcessing else { pendingTrigger = true; return }
        isProcessing = true
        Task { await process() }
    }

    func startAutonomousAgent(intervalSeconds: UInt64 = 5) {
        guard autonomousAgentTask == nil else { return }
        autonomousAgentTask = Task {
            while !Task.isCancelled {
                enqueueProcess()
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }
        }
    }

    func stopAutonomousAgent() {
        autonomousAgentTask?.cancel()
        autonomousAgentTask = nil
    }

    private func process() async {
        defer { isProcessing = false }

        while true {
            guard let persistence else {
                if pendingTrigger { pendingTrigger = false; continue }
                break
            }
            let job = await MainActor.run { persistence.nextQueuedJob() }
            guard let job else {
                if pendingTrigger { pendingTrigger = false; continue }
                break
            }

            await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .running) }

            switch job.source {
            case .file:
                await processFileJob(job)
            case .url, .browserExtension:
                await processURLJob(job)
            case .extract:
                await processExtractJob(job)
            case .wikiCompile:
                await processWikiCompileJob(job)
            default:
                await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .failed, errorMessage: "Unsupported source") }
            }

            if pendingTrigger { pendingTrigger = false }
        }
    }

    private func processFileJob(_ job: ImportJobRecord) async {
        guard let persistence else { return }
        let fileURL = URL(fileURLWithPath: job.payload)
        let refID = job.referenceID

        var generatedThumbnailPath: String?
        if let refID, let pngData = await LociImageLoader.pngData(from: fileURL, maxPixelSize: 600) {
            generatedThumbnailPath = await MainActor.run { () -> String? in
                if let thumbURL = persistence.writeThumbnailPNGData(pngData, for: refID) {
                    let path = thumbURL.lastPathComponent
                    persistence.updateReferenceThumbnail(id: refID, thumbPath: path)
                    return path
                }
                return nil
            }
        }

        if generatedThumbnailPath == nil, let refID, let pngData = await LibraryStore.quickLookThumbnailPNGData(for: fileURL) {
            generatedThumbnailPath = await MainActor.run { () -> String? in
                if let thumbURL = persistence.writeThumbnailPNGData(pngData, for: refID) {
                    let path = thumbURL.lastPathComponent
                    persistence.updateReferenceThumbnail(id: refID, thumbPath: path)
                    return path
                }
                return nil
            }
        }

        await MainActor.run {
            persistence.updateImportJobStatus(id: job.id, status: .succeeded)
        }
        let result = ImportJobResult(
            id: job.id,
            source: job.source,
            status: .succeeded,
            title: job.payload,
            referenceID: refID,
            thumbnailPath: generatedThumbnailPath,
            timestamp: Date()
        )
        record(result)
    }

    private func processExtractJob(_ job: ImportJobRecord) async {
        guard let persistence else { return }
        guard let refID = job.referenceID else {
            await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .failed, errorMessage: "Missing referenceID") }
            return
        }
        guard let item = await MainActor.run(body: { persistence.loadReference(id: refID) }) else {
            await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .failed, errorMessage: "Missing reference") }
            return
        }

        let originalSource = originalSourceKind(from: job.payload) ?? itemSourceKindFallback(for: item)
        let result = await WikiCompiler.extract(item: item, source: originalSource, payload: job.payload)

        if DocumentPreviewConverter.isOfficeDocument(extension: item.fileExtension) {
            let sourceURL = await MainActor.run { persistence.originalsURL.appendingPathComponent(item.fileName) }
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                _ = await DocumentPreviewConverter.pdfPreviewURL(for: item, sourceURL: sourceURL)
            }
        }

        await MainActor.run {
            persistence.updateImportJobStatus(id: job.id, status: .succeeded)
            persistence.enqueueImportJob(source: .wikiCompile, payload: job.payload, status: .queued, referenceID: refID)
        }
        record(ImportJobResult(
            id: job.id,
            source: job.source,
            status: .succeeded,
            title: result.title,
            referenceID: refID,
            thumbnailPath: nil,
            timestamp: Date()
        ))
    }

    private func processWikiCompileJob(_ job: ImportJobRecord) async {
        guard let persistence else { return }
        guard let refID = job.referenceID else {
            await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .failed, errorMessage: "Missing referenceID") }
            return
        }
        guard let item = await MainActor.run(body: { persistence.loadReference(id: refID) }) else {
            await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .failed, errorMessage: "Missing reference") }
            return
        }

        let originalSource = originalSourceKind(from: job.payload) ?? itemSourceKindFallback(for: item)
        let result = await WikiCompiler.compile(item: item, source: originalSource, payload: job.payload)

        await MainActor.run {
            persistence.updateImportJobStatus(id: job.id, status: .succeeded)
        }
        record(ImportJobResult(
            id: job.id,
            source: job.source,
            status: .succeeded,
            title: "\(result.title): \(result.summary)",
            referenceID: refID,
            thumbnailPath: nil,
            timestamp: Date()
        ))
    }

    private func originalSourceKind(from payload: String) -> ImportSourceKind? {
        guard let data = payload.data(using: .utf8),
              let extensionPayload = try? JSONDecoder().decode(BrowserExtensionReferencePayload.self, from: data),
              extensionPayload.url != nil else {
            return nil
        }
        return .browserExtension
    }

    private func itemSourceKindFallback(for item: ReferenceItem) -> ImportSourceKind {
        item.group == .file ? .file : .url
    }

    private func writePreviewThumbnail(_ data: Data, for refID: ReferenceItem.ID, persistence: LociPersistentStore) async -> String? {
        await MainActor.run { () -> String? in
            if let thumbURL = persistence.writeThumbnailPNGData(data, for: refID) {
                let path = thumbURL.lastPathComponent
                persistence.updateReferenceThumbnail(id: refID, thumbPath: path)
                return path
            }
            return nil
        }
    }

    private func finishURLJob(
        _ job: ImportJobRecord,
        title: String,
        referenceID: ReferenceItem.ID,
        thumbnailPath: String?,
        persistence: LociPersistentStore
    ) async {
        await MainActor.run {
            persistence.updateImportJobStatus(id: job.id, status: .succeeded)
        }
        let result = ImportJobResult(
            id: job.id,
            source: job.source,
            status: .succeeded,
            title: title,
            referenceID: referenceID,
            thumbnailPath: thumbnailPath,
            timestamp: Date()
        )
        record(result)
    }

    private func processURLJob(_ job: ImportJobRecord) async {
        guard let persistence else { return }
        guard let refID = job.referenceID else {
            await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .failed, errorMessage: "Missing referenceID") }
            return
        }
        let payloadURLString: String
        var extensionPayload: BrowserExtensionReferencePayload?
        if job.source == .browserExtension,
           let data = job.payload.data(using: .utf8),
           let decodedPayload = try? JSONDecoder().decode(BrowserExtensionReferencePayload.self, from: data),
           let extensionURL = decodedPayload.url {
            extensionPayload = decodedPayload
            payloadURLString = extensionURL
        } else {
            payloadURLString = job.payload
        }

        guard let url = URL(string: payloadURLString) else {
            await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .failed, errorMessage: "Invalid URL") }
            return
        }

        if url.isXFamilyURL {
            var generatedThumbnailPath: String?
            let mediaOnlyResponse = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            if let imageURL = await websitePreviewImageURL(for: url, data: Data(), response: mediaOnlyResponse, extensionPayload: extensionPayload),
               let imageData = await fetchPreviewImageData(from: imageURL) {
                generatedThumbnailPath = await writePreviewThumbnail(imageData, for: refID, persistence: persistence)
            }
            await finishURLJob(
                job,
                title: url.host() ?? payloadURLString,
                referenceID: refID,
                thumbnailPath: generatedThumbnailPath,
                persistence: persistence
            )
            return
        }

        let snapshotTask: Task<Data?, Never>? = url.isXFamilyURL
            ? nil
            : Task { @MainActor in
                await WebsiteSnapshotRenderer.snapshotPNGData(for: url)
            }

        let maxDownloadBytes: Int64 = 50 * 1_024 * 1_024
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 3
        if let (_, headResponse) = try? await URLSession.shared.data(for: headRequest),
           let httpResponse = headResponse as? HTTPURLResponse,
           let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let bytes = Int64(contentLength), bytes > maxDownloadBytes {
            snapshotTask?.cancel()
            await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .failed, errorMessage: "File too large (\(bytes) bytes)") }
            return
        }

        guard let (data, response) = try? await URLSession.shared.data(from: url) else {
            snapshotTask?.cancel()
            await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .failed, errorMessage: "Download failed") }
            return
        }

        let ext = url.pathExtension.isEmpty ? (response.mimeType == "text/html" ? "html" : "dat") : url.pathExtension
        let fileName = "\(UUID().uuidString.lowercased()).\(ext)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: tempURL)

        let managedURL = await MainActor.run { persistence.importFileToOriginals(from: tempURL) }
        try? FileManager.default.removeItem(at: tempURL)
        guard let managedURL else {
            snapshotTask?.cancel()
            await MainActor.run { persistence.updateImportJobStatus(id: job.id, status: .failed, errorMessage: "File copy failed") }
            return
        }

        var generatedThumbnailPath: String?
        if let imageURL = await websitePreviewImageURL(for: url, data: data, response: response, extensionPayload: extensionPayload),
           let imageData = await fetchPreviewImageData(from: imageURL) {
            snapshotTask?.cancel()
            generatedThumbnailPath = await MainActor.run { () -> String? in
                if let thumbURL = persistence.writeThumbnailPNGData(imageData, for: refID) {
                    let path = thumbURL.lastPathComponent
                    persistence.updateReferenceThumbnail(id: refID, thumbPath: path)
                    return path
                }
                return nil
            }
        }

        if generatedThumbnailPath == nil,
           let snapshotTask,
           let snapshotData = await snapshotTask.value {
            generatedThumbnailPath = await MainActor.run { () -> String? in
                if let thumbURL = persistence.writeThumbnailPNGData(snapshotData, for: refID) {
                    let path = thumbURL.lastPathComponent
                    persistence.updateReferenceThumbnail(id: refID, thumbPath: path)
                    return path
                }
                return nil
            }
        }

        if generatedThumbnailPath == nil && response.mimeType?.localizedCaseInsensitiveContains("html") != true {
            if let pngData = await LociImageLoader.pngData(from: managedURL, maxPixelSize: 600) {
                generatedThumbnailPath = await MainActor.run { () -> String? in
                    if let thumbURL = persistence.writeThumbnailPNGData(pngData, for: refID) {
                        let path = thumbURL.lastPathComponent
                        persistence.updateReferenceThumbnail(id: refID, thumbPath: path)
                        return path
                    }
                    return nil
                }
            }
        }

        if generatedThumbnailPath == nil,
           response.mimeType?.localizedCaseInsensitiveContains("html") != true,
           let pngData = await LibraryStore.quickLookThumbnailPNGData(for: managedURL) {
            generatedThumbnailPath = await MainActor.run { () -> String? in
                if let thumbURL = persistence.writeThumbnailPNGData(pngData, for: refID) {
                    let path = thumbURL.lastPathComponent
                    persistence.updateReferenceThumbnail(id: refID, thumbPath: path)
                    return path
                }
                return nil
            }
        }
        await MainActor.run {
            persistence.updateImportJobStatus(id: job.id, status: .succeeded)
        }
        let result = ImportJobResult(
            id: job.id,
            source: job.source,
            status: .succeeded,
            title: url.host() ?? payloadURLString,
            referenceID: refID,
            thumbnailPath: generatedThumbnailPath,
            timestamp: Date()
        )
        record(result)
    }

    private func websitePreviewImageURL(
        for pageURL: URL,
        data: Data,
        response: URLResponse,
        extensionPayload: BrowserExtensionReferencePayload?
    ) async -> URL? {
        if let ogImageURL = extensionPayload?.ogImageURL.flatMap({ resolvedURL($0, relativeTo: pageURL) }) {
            return ogImageURL
        }
        if let firstImageURL = extensionPayload?.imageURLs?.compactMap({ resolvedURL($0, relativeTo: pageURL) }).first {
            return firstImageURL
        }
        guard response.mimeType?.localizedCaseInsensitiveContains("html") == true,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return previewImageURL(in: html, relativeTo: pageURL)
    }

    private func previewImageURL(in html: String, relativeTo pageURL: URL) -> URL? {
        let patterns = [
            #"<meta[^>]+property=["']og:image(?::secure_url)?["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image(?::secure_url)?["']"#,
            #"<meta[^>]+name=["']twitter:image(?::src)?["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+name=["']twitter:image(?::src)?["']"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, options: [], range: range),
                  let valueRange = Range(match.range(at: 1), in: html) else { continue }
            let value = String(html[valueRange])
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = resolvedURL(value, relativeTo: pageURL) {
                return url
            }
        }
        return nil
    }

    private func resolvedURL(_ value: String, relativeTo pageURL: URL) -> URL? {
        if let absoluteURL = URL(string: value), absoluteURL.scheme != nil {
            return absoluteURL
        }
        return URL(string: value, relativeTo: pageURL)?.absoluteURL
    }

    private func fetchPreviewImageData(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count <= 8 * 1_024 * 1_024,
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }
        if let pngData = LociImageLoader.pngData(from: data, maxPixelSize: 1200) {
            return pngData
        }
        return data
    }

    private func sanitizedFileName(from url: URL) -> String {
        let ext = url.pathExtension.isEmpty ? "html" : url.pathExtension
        let name = url.lastPathComponent.replacingOccurrences(of: "\\.[^\\.]+$", with: "", options: .regularExpression)
        return "\(name).\(ext)"
    }
}
