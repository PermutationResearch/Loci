import AppKit
import PDFKit
import SwiftUI

struct FileSystemWorkspaceView: View {
    @Bindable var store: LibraryStore
    @Environment(\.undoManager) private var undoManager
    @FocusState private var isKeyboardFocused: Bool
    @State private var selectedFolderID: FileSystemNode.ID = FileSystemNode.rootID
    @State private var layout: FileSystemLayout = .list
    @State private var selectedItemID: ReferenceItem.ID?
    @State private var columnPath: [FileSystemNode.ID] = [FileSystemNode.rootID]
    @State private var visibleLimit = 160
    @State private var pagedRootDocuments: [ReferenceItem] = []
    @State private var rootDocumentCount = 0
    @State private var expandedSourceSections: Set<String> = []
    private let pageSize = 160

    private var allDocuments: [ReferenceItem] {
        store.items
            .filter { $0.isManagedDocument && !$0.isTrashed }
            .filter { item in
                store.activeSearchQuery.isEmpty
                    || item.title.localizedStandardContains(store.activeSearchQuery)
                    || item.subtitle.localizedStandardContains(store.activeSearchQuery)
                    || item.fileName.localizedStandardContains(store.activeSearchQuery)
            }
            .sorted(by: fileSort)
    }

    private var folderTree: [FileSystemNode] {
        FileSystemNode.buildTree(items: allDocuments, collections: store.collections)
    }

    private var railRows: [FileSystemRailRow] {
        FileSystemNode.flatten(folderTree)
    }

    private var selectedFolder: FileSystemNode {
        FileSystemNode.find(selectedFolderID, in: folderTree) ?? folderTree[0]
    }

    private var documents: [ReferenceItem] {
        if selectedFolderID == FileSystemNode.rootID {
            return usesPagedRootDocuments ? pagedRootDocuments : allDocuments
        }
        return selectedFolder.folderItems.sorted(by: fileSort)
    }

    private var visibleDocuments: [ReferenceItem] {
        usesPagedRootDocuments ? pagedRootDocuments : Array(documents.prefix(visibleLimit))
    }

    private var documentCount: Int {
        usesPagedRootDocuments ? rootDocumentCount : documents.count
    }

    private var usesPagedRootDocuments: Bool {
        selectedFolderID == FileSystemNode.rootID && LociPersistentStore.shared != nil
    }

    private var selectedItem: ReferenceItem? {
        guard let selectedItemID else { return documents.first }
        return documents.first { $0.id == selectedItemID }
    }

    private var canGoBack: Bool {
        selectedFolder.parentID != nil
    }

    private var canGoForward: Bool {
        !selectedFolder.children.isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            folderRail
                .frame(width: 180)
                .background(Color.black.opacity(0.018))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.black.opacity(0.045)).frame(width: 1)
                }

            VStack(spacing: 0) {
                toolbar

                Divider().opacity(0.35)

                Group {
                    switch layout {
                    case .icons:
                        iconBrowser
                    case .list:
                        listBrowser
                    case .columns:
                        columnBrowser
                    case .gallery:
                        galleryBrowser
                    }
                }
                .focused($isKeyboardFocused)
                .focusEffectDisabled()
            }
        }
        .focusable()
        .focused($isKeyboardFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.leftArrow) { keyboardBack() }
        .onKeyPress(.rightArrow) { keyboardForward() }
        .onKeyPress(.return) { openSelected() }
        .onKeyPress(.space) { openSelected() }
        .background(LociColor.surface)
        .onAppear {
            isKeyboardFocused = true
            reloadRootDocumentPage()
            syncSelection()
            syncColumnPath(to: selectedFolderID)
            ensureVisible(selectedFolderID)
        }
        .onTapGesture {
            isKeyboardFocused = true
        }
        .onChange(of: selectedFolderID) { _, newValue in
            visibleLimit = 160
            if newValue == FileSystemNode.rootID {
                reloadRootDocumentPage()
            }
            syncSelection()
            syncColumnPath(to: newValue)
        }
        .onChange(of: documents.map(\.id)) { _, _ in
            syncSelection()
        }
        .onChange(of: store.items.map(\.id)) { _, _ in
            reloadRootDocumentPage()
            syncSelection()
        }
        .onChange(of: store.activeSearchQuery) { _, _ in
            reloadRootDocumentPage()
            syncSelection()
        }
        .onChange(of: store.focusedItemID) { _, newValue in
            if newValue == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isKeyboardFocused = true
                }
            }
        }
    }

    private var folderRail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                Text("FILES")
                    .font(LociFont.label)
                    .tracking(0.35)
                    .foregroundStyle(LociColor.inkTertiary)
                    .padding(.top, 24)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                ForEach(folderTree) { root in
                    folderRow(node: root, depth: 0)
                    if expandedSourceSections.contains(root.id) {
                        ForEach(root.children) { child in
                            folderRowRecursive(node: child, depth: 1)
                        }
                    }
                }
            }
            .padding(.bottom, 88)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func folderRowRecursive(node: FileSystemNode, depth: Int) -> some View {
        folderRow(node: node, depth: depth)
        if expandedSourceSections.contains(node.id) {
            ForEach(node.children) { child in
                folderRow(node: child, depth: depth + 1)
                if expandedSourceSections.contains(child.id) {
                    ForEach(child.children) { grandchild in
                        folderRow(node: grandchild, depth: depth + 2)
                    }
                }
            }
        }
    }

    private func folderRow(node: FileSystemNode, depth: Int) -> some View {
        let hasChildren = !node.children.isEmpty
        let isExpanded = expandedSourceSections.contains(node.id)

        return Button {
            if hasChildren {
                withAnimation(AppMotion.quick) {
                    if isExpanded {
                        expandedSourceSections.remove(node.id)
                    } else {
                        expandedSourceSections.insert(node.id)
                    }
                }
            }
            selectFolder(node.id)
        } label: {
            HStack(spacing: 5) {
                if hasChildren {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .lociFont(size: 7, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(LociColor.inkFaint)
                        .frame(width: 8)
                } else {
                    Color.clear.frame(width: 8)
                }
                Image(systemName: node.symbol)
                    .lociFont(size: 9.5, weight: .semibold, relativeTo: .caption2)
                    .frame(width: 12)
                Text(node.title)
                    .lociFont(size: 10, weight: selectedFolderID == node.id ? .semibold : .medium, relativeTo: .caption2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(node.totalCount.formatted())
                    .font(LociFont.badge)
                    .monospacedDigit()
                    .foregroundStyle(LociColor.inkTertiary)
            }
            .foregroundStyle(selectedFolderID == node.id ? LociColor.ink : LociColor.inkTertiary)
            .padding(.leading, CGFloat(8 + depth * 12))
            .padding(.trailing, 6)
            .frame(minHeight: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selectedFolderID == node.id ? LociColor.surfaceSelected : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                Button {
                    _ = keyboardBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(.black.opacity(canGoBack ? 0.55 : 0.18))
                        .frame(width: 22, height: 22)
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canGoBack)

                Button {
                    _ = keyboardForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(.black.opacity(canGoForward ? 0.55 : 0.18))
                        .frame(width: 22, height: 22)
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canGoForward)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    ForEach(selectedFolder.breadcrumbs.indices, id: \.self) { index in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .lociFont(size: 6, weight: .bold, relativeTo: .caption2)
                                .foregroundStyle(.black.opacity(0.20))
                        }
                        Text(selectedFolder.breadcrumbs[index].uppercased())
                            .lociFont(size: 8, weight: index == selectedFolder.breadcrumbs.indices.last ? .bold : .semibold, relativeTo: .caption2)
                            .tracking(0.3)
                            .foregroundStyle(.black.opacity(index == selectedFolder.breadcrumbs.indices.last ? 0.62 : 0.30))
                            .lineLimit(1)
                    }
                }

                Text("\(documentCount.formatted()) ITEMS")
                    .lociFont(size: 7, weight: .semibold, design: .rounded, relativeTo: .caption2)
                    .tracking(0.18)
                    .foregroundStyle(.black.opacity(0.30))
            }

            Spacer()

            HStack(spacing: 1) {
                ForEach(FileSystemLayout.allCases) { option in
                    Button {
                        withAnimation(AppMotion.instant) {
                            layout = option
                        }
                    } label: {
                        Image(systemName: option.symbol)
                            .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                            .foregroundStyle(layout == option ? .black.opacity(0.78) : .black.opacity(0.38))
                            .frame(width: 26, height: 22)
                            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .background {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(layout == option ? Color.black.opacity(0.060) : Color.clear)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(option.title)
                    .accessibilityLabel(option.title)
                }
            }
            .padding(2)
            .background(Color.black.opacity(0.030), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: 52)
    }

    private var listBrowser: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(visibleDocuments) { item in
                            fileRow(item)
                                .id(item.id)
                        }
                        loadMoreButton
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 84)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selectedItemID) { _, id in
                    guard let id else { return }
                    withAnimation(AppMotion.instant) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Divider().opacity(0.35)

            if let selectedItem {
                previewInspector(item: selectedItem, compact: false)
                    .frame(width: 380)
            } else {
                emptyPreview
            }
        }
    }

    private var iconBrowser: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 14)], spacing: 18) {
                        ForEach(visibleDocuments) { item in
                            fileIcon(item)
                                .id(item.id)
                        }
                        loadMoreButton
                    }
                    .padding(22)
                    .padding(.bottom, 72)
                }
                .frame(maxWidth: .infinity)
                .scrollIndicators(.hidden)
                .onChange(of: selectedItemID) { _, id in
                    guard let id else { return }
                    withAnimation(AppMotion.instant) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Divider().opacity(0.35)

            if let selectedItem {
                previewInspector(item: selectedItem, compact: false)
                    .frame(width: 380)
            } else {
                emptyPreview
            }
        }
    }

    private var columnBrowser: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(columnPath, id: \.self) { nodeID in
                    let node = FileSystemNode.find(nodeID, in: folderTree) ?? folderTree[0]
                    column(node)
                        .frame(width: 236)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(.black.opacity(0.045)).frame(width: 1)
                        }
                }

                if let selectedItem {
                    previewInspector(item: selectedItem, compact: true)
                        .frame(width: 306)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var galleryBrowser: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleDocuments) { item in
                            galleryListRow(item)
                                .id(item.id)
                        }
                        loadMoreButton
                    }
                    .padding(12)
                    .padding(.bottom, 76)
                }
                .frame(width: 260)
                .scrollIndicators(.hidden)
                .onChange(of: selectedItemID) { _, id in
                    guard let id else { return }
                    withAnimation(AppMotion.instant) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Divider().opacity(0.35)

            if let selectedItem {
                previewInspector(item: selectedItem, compact: false)
            } else {
                emptyPreview
            }
        }
    }

    private func column(_ node: FileSystemNode) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(node.children) { child in
                    columnFolderRow(child)
                }

                if !node.children.isEmpty && !node.directItems.isEmpty {
                    Divider().padding(.vertical, 4).opacity(0.25)
                }

                ForEach(node.directItems.sorted(by: fileSort)) { item in
                    compactFileRow(item, showsChevron: false)
                }
            }
            .padding(8)
            .padding(.bottom, 76)
        }
        .scrollIndicators(.hidden)
    }

    private func columnFolderRow(_ node: FileSystemNode) -> some View {
        Button {
            selectFolder(node.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: node.symbol)
                    .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                    .frame(width: 16)
                    .foregroundStyle(.black.opacity(0.50))
                Text(node.title)
                    .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(node.totalCount.formatted())
                    .lociFont(size: 8.5, weight: .semibold, design: .rounded, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.30))
                Image(systemName: "chevron.right")
                    .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.24))
            }
            .foregroundStyle(.black.opacity(selectedFolderID == node.id ? 0.82 : 0.58))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectedFolderID == node.id ? Color.black.opacity(0.060) : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }

    private func fileRow(_ item: ReferenceItem) -> some View {
        HStack(spacing: 10) {
            listThumbnail(item, width: 36, height: 36, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.76))
                    .lineLimit(1)
                Text(item.fileName)
                    .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.55))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { openPreview(item) }
            }

            Spacer(minLength: 8)

            Text(typeLabel(for: item))
                .lociFont(size: 10, weight: .semibold, design: .rounded, relativeTo: .caption2)
                .foregroundStyle(.black.opacity(0.55))
                .frame(width: 64, alignment: .leading)

            Text(locationLabel(for: item))
                .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                .foregroundStyle(.black.opacity(0.55))
                .frame(width: 100, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(selectionBackground(for: item))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture { selectItem(item) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { openPreview(item) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selectItem(item) }
        .accessibilityAction(named: "Open") { openPreview(item) }
        .contextMenu { fileMenu(for: item) }
    }

    private func compactFileRow(_ item: ReferenceItem, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            listThumbnail(item, width: 36, height: 36, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.72))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { openPreview(item) }
                Text(typeLabel(for: item))
                    .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.34))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.22))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(selectionBackground(for: item))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture { selectItem(item) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { openPreview(item) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selectItem(item) }
        .accessibilityAction(named: "Open") { openPreview(item) }
        .contextMenu { fileMenu(for: item) }
    }

    private func fileIcon(_ item: ReferenceItem) -> some View {
        Button {
            selectItem(item)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail(item, width: nil, height: 92, cornerRadius: 8)
                    .frame(maxWidth: .infinity)

                Text(item.title)
                    .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.70))
                    .lineLimit(1)
                Text(typeLabel(for: item))
                    .lociFont(size: 8.5, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.38))
                    .lineLimit(1)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(selectionBackground(for: item))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { openPreview(item) })
        .contextMenu { fileMenu(for: item) }
    }

    private func galleryListRow(_ item: ReferenceItem) -> some View {
        HStack(spacing: 10) {
            listThumbnail(item, width: 48, height: 40, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.76))
                    .lineLimit(1)
                Text(item.fileName)
                    .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.40))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { openPreview(item) }
            }
            Spacer(minLength: 8)
        }
        .foregroundStyle(.black.opacity(0.72))
        .padding(.horizontal, 12)
        .frame(height: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(selectionBackground(for: item))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { selectItem(item) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { openPreview(item) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selectItem(item) }
        .accessibilityAction(named: "Open") { openPreview(item) }
        .contextMenu { fileMenu(for: item) }
    }

    private func previewInspector(item: ReferenceItem, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if compact {
                thumbnail(item, width: nil, height: 156, cornerRadius: 10)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
            } else {
                thumbnail(item, width: nil, height: 290, cornerRadius: 10)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .lociFont(size: compact ? 13 : 14, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(.black.opacity(0.80))
                    .lineLimit(2)
                Text(item.fileName)
                    .lociFont(size: 9.5, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.42))
                    .lineLimit(1)
            }

            pagePreviewStrip(for: item)

            Divider().opacity(0.28)

            VStack(spacing: 8) {
                metadataRow("Type", typeLabel(for: item))
                metadataRow("Location", locationLabel(for: item))
                metadataRow("Source", sourceLabel(for: item))
                if let url = originalFileURL(for: item) {
                    metadataRow("Original", url.lastPathComponent)
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.openInNotebook(item)
                } label: {
                    Label("Open in Notebook", systemImage: "text.bubble")
                }

                Button {
                    openPreview(item)
                } label: {
                    Label("Open Full View", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                if let url = originalFileURL(for: item) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal", systemImage: "finder")
                    }
                }
            }
            .buttonStyle(.borderless)
            .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 16 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.010))
    }

    private var emptyPreview: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.viewfinder")
                .lociFont(size: 26, weight: .semibold, relativeTo: .title)
                .foregroundStyle(.black.opacity(0.18))
            Text("Select a file")
                .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(.black.opacity(0.42))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var loadMoreButton: some View {
        if visibleDocuments.count < documentCount {
            Button {
                loadMoreDocuments()
            } label: {
                Text("LOAD \(min(pageSize, documentCount - visibleDocuments.count)) MORE")
                    .lociFont(size: 8.5, weight: .bold, relativeTo: .caption2)
                    .tracking(0.28)
                    .foregroundStyle(.black.opacity(0.46))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.plain)
        }
    }

    private func reloadRootDocumentPage() {
        guard selectedFolderID == FileSystemNode.rootID,
              let persistence = LociPersistentStore.shared else { return }
        rootDocumentCount = persistence.referenceCount(filter: store.activeSearchQuery, managedDocumentsOnly: true)
        pagedRootDocuments = persistence.loadReferencesPage(
            offset: 0,
            limit: pageSize,
            filter: store.activeSearchQuery,
            managedDocumentsOnly: true
        )
    }

    private func loadMoreDocuments() {
        if usesPagedRootDocuments, let persistence = LociPersistentStore.shared {
            let nextPage = persistence.loadReferencesPage(
                offset: pagedRootDocuments.count,
                limit: pageSize,
                filter: store.activeSearchQuery,
                managedDocumentsOnly: true
            )
            pagedRootDocuments.append(contentsOf: nextPage)
        } else {
            visibleLimit = min(documents.count, visibleLimit + pageSize)
        }
    }

    private func listThumbnail(_ item: ReferenceItem, width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let thumbPath = item.thumbnailPath,
               let store = LociPersistentStore.shared {
                FileSystemThumbnailImage(
                    thumbnailURL: store.thumbnailsURL.appendingPathComponent(thumbPath),
                    cacheKey: thumbPath
                )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.04))
                    Image(systemName: listThumbnailSymbol(for: item))
                        .lociFont(size: min(width, height) * 0.42, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.black.opacity(0.34))
                }
            }
        }
        .frame(width: width, height: height)
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.black.opacity(0.055), lineWidth: 1)
        }
    }

    private func listThumbnailSymbol(for item: ReferenceItem) -> String {
        switch item.fileExtension {
        case "pdf":
            "doc.richtext"
        case "doc", "docx", "pages", "rtf", "txt":
            "doc.text"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "tif", "tiff":
            "photo"
        case "mp4", "mov", "m4v":
            "film"
        case "ppt", "pptx", "key":
            "play.rectangle"
        case "xls", "xlsx", "numbers", "csv":
            "tablecells"
        default:
            item.kindSymbol
        }
    }

    private func thumbnail(_ item: ReferenceItem, width: CGFloat?, height: CGFloat, cornerRadius: CGFloat) -> some View {
        ReferenceThumbnail(item: item)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .fixedSize(horizontal: width != nil, vertical: true)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.black.opacity(0.055), lineWidth: 1)
            }
    }

    private func selectionBackground(for item: ReferenceItem) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selectedItemID == item.id ? Color.black.opacity(0.060) : Color.clear)
    }

    @ViewBuilder
    private func pagePreviewStrip(for item: ReferenceItem) -> some View {
        if item.fileExtension == "pdf" || ["doc", "docx", "pages", "ppt", "pptx", "xls", "xlsx"].contains(item.fileExtension) {
            VStack(alignment: .leading, spacing: 7) {
                Text(item.fileExtension == "pdf" ? "PAGES" : "PREVIEW PAGES")
                    .lociFont(size: 7.5, weight: .bold, relativeTo: .caption2)
                    .tracking(0.32)
                    .foregroundStyle(.black.opacity(0.34))

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(0..<previewPageCount(for: item), id: \.self) { index in
                            PreviewPageTile(item: item, index: index, originalURL: originalFileURL(for: item))
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(height: 74)
                .scrollIndicators(.hidden)
            }
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .lociFont(size: 7.5, weight: .bold, relativeTo: .caption2)
                .tracking(0.25)
                .foregroundStyle(.black.opacity(0.32))
                .frame(width: 58, alignment: .leading)
            Text(value)
                .lociFont(size: 9.5, weight: .medium, relativeTo: .caption2)
                .foregroundStyle(.black.opacity(0.58))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func fileMenu(for item: ReferenceItem) -> some View {
        Button {
            store.openInNotebook(item)
        } label: {
            Label("Open in Notebook", systemImage: "text.bubble")
        }

        Button {
            openPreview(item)
        } label: {
            Label("Open Full View", systemImage: "arrow.up.left.and.arrow.down.right")
        }

        if let url = originalFileURL(for: item) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }
        }

        Button {
            store.select(item)
            selectedItemID = item.id
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }

        Divider()

        Button(role: .destructive) {
            store.trashReference(id: item.id, undoManager: undoManager)
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }

    private func selectFolder(_ id: FileSystemNode.ID) {
        withAnimation(AppMotion.instant) {
            selectedFolderID = id
            isKeyboardFocused = true
        }
    }

    private func ensureVisible(_ id: FileSystemNode.ID) {
        let path = FileSystemNode.path(to: id, in: folderTree)
        for ancestorID in path where ancestorID != id {
            expandedSourceSections.insert(ancestorID)
        }
    }

    private func selectItem(_ item: ReferenceItem) {
        withAnimation(AppMotion.instant) {
            selectedItemID = item.id
            store.select(item)
            isKeyboardFocused = true
        }
    }

    private func openPreview(_ item: ReferenceItem) {
        withAnimation(AppMotion.smooth) {
            selectItem(item)
            store.openPreview(item)
        }
    }

    private func openSelected() -> KeyPress.Result {
        guard let selectedItem else { return .ignored }
        openPreview(selectedItem)
        return .handled
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard !documents.isEmpty else { return .ignored }
        let currentID = selectedItemID ?? documents.first?.id
        let currentIndex = documents.firstIndex { $0.id == currentID } ?? 0
        if delta > 0, currentIndex >= documents.count - 10, visibleDocuments.count < documentCount {
            loadMoreDocuments()
        }
        let nextIndex = max(0, min(documents.count - 1, currentIndex + delta))
        let next = documents[nextIndex]
        selectItem(next)
        return .handled
    }

    private func keyboardBack() -> KeyPress.Result {
        if layout == .columns, columnPath.count > 1 {
            let target = columnPath[columnPath.count - 2]
            ensureVisible(target)
            selectFolder(target)
            return .handled
        }
        guard let parent = selectedFolder.parentID else { return .ignored }
        ensureVisible(parent)
        selectFolder(parent)
        return .handled
    }

    private func keyboardForward() -> KeyPress.Result {
        if layout == .columns, let firstChild = selectedFolder.children.first {
            ensureVisible(firstChild.id)
            selectFolder(firstChild.id)
            return .handled
        }
        guard let selectedItem else { return .ignored }
        openPreview(selectedItem)
        return .handled
    }

    private func syncSelection() {
        if let selectedItemID, documents.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = documents.first?.id
    }

    private func syncColumnPath(to nodeID: FileSystemNode.ID) {
        columnPath = FileSystemNode.path(to: nodeID, in: folderTree)
    }

    private func fileSort(_ first: ReferenceItem, _ second: ReferenceItem) -> Bool {
        if first.fileExtension == second.fileExtension {
            return first.title.localizedStandardCompare(second.title) == .orderedAscending
        }
        return first.fileExtension < second.fileExtension
    }

    private func typeLabel(for item: ReferenceItem) -> String {
        let ext = item.fileExtension.uppercased()
        return ext.isEmpty ? item.group.rawValue : ext
    }

    private func locationLabel(for item: ReferenceItem) -> String {
        if let id = item.collectionID, let collection = store.collections.first(where: { $0.id == id }) {
            return collection.name
        }
        return item.isInbox ? "Inbox" : "No Collection"
    }

    private func sourceLabel(for item: ReferenceItem) -> String {
        FileSystemNode.sourceBucket(for: item)
    }

    private func originalFileURL(for item: ReferenceItem) -> URL? {
        store.originalFileURL(for: item)
    }

    private func previewPageCount(for item: ReferenceItem) -> Int {
        if item.fileExtension == "pdf",
           let url = originalFileURL(for: item),
           let document = PDFDocument(url: url) {
            return min(8, max(1, document.pageCount))
        }
        return item.fileExtension == "pdf" ? 6 : 4
    }
}

private enum FileSystemLayout: String, CaseIterable, Identifiable {
    case icons
    case list
    case columns
    case gallery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icons: "Icons"
        case .list: "List"
        case .columns: "Columns"
        case .gallery: "Gallery"
        }
    }

    var symbol: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        case .gallery: "rectangle.stack"
        }
    }
}

private struct FileSystemRailRow: Identifiable, Hashable {
    var node: FileSystemNode
    var depth: Int

    var id: String {
        "\(node.id)-\(depth)"
    }
}

private struct FileSystemNode: Identifiable, Hashable {
    static let rootID = "root"

    let id: String
    var title: String
    var symbol: String
    var parentID: String?
    var breadcrumbs: [String]
    var directItems: [ReferenceItem]
    var children: [FileSystemNode]

    var folderItems: [ReferenceItem] {
        if children.isEmpty {
            return directItems
        }
        return directItems + children.flatMap(\.folderItems)
    }

    var items: [ReferenceItem] {
        folderItems
    }

    var totalCount: Int {
        if id == Self.rootID {
            return directItems.count
        }
        if children.isEmpty {
            return directItems.count
        }
        return children.reduce(0) { $0 + $1.totalCount }
    }

    static func buildTree(items: [ReferenceItem], collections: [ReferenceCollection]) -> [FileSystemNode] {
        let root = FileSystemNode(
            id: rootID,
            title: "All Documents",
            symbol: "externaldrive.fill",
            parentID: nil,
            breadcrumbs: ["Files"],
            directItems: items,
            children: [
                sourceNode(items: items),
                typeNode(items: items),
                collectionNode(items: items, collections: collections)
            ]
        )
        return [root]
    }

    static func find(_ id: String, in nodes: [FileSystemNode]) -> FileSystemNode? {
        for node in nodes {
            if node.id == id { return node }
            if let match = find(id, in: node.children) { return match }
        }
        return nil
    }

    static func path(to id: String, in nodes: [FileSystemNode]) -> [String] {
        for node in nodes {
            if node.id == id { return [node.id] }
            let childPath = path(to: id, in: node.children)
            if !childPath.isEmpty { return [node.id] + childPath }
        }
        return [rootID]
    }

    static func flatten(_ nodes: [FileSystemNode], depth: Int = 0) -> [FileSystemRailRow] {
        nodes.flatMap { node in
            [FileSystemRailRow(node: node, depth: depth)]
                + flatten(node.children, depth: min(depth + 1, 3))
        }
    }

    private static func sourceNode(items: [ReferenceItem]) -> FileSystemNode {
        let grouped = Dictionary(grouping: items, by: sourceBucket(for:))

        let children = grouped.keys.sorted().map { key in
            FileSystemNode(
                id: "source/\(key)",
                title: key,
                symbol: sourceSymbol(for: key),
                parentID: "source",
                breadcrumbs: ["Files", "Origin", key],
                directItems: grouped[key, default: []],
                children: []
            )
        }

        return FileSystemNode(
            id: "source",
            title: "By Origin",
            symbol: "arrow.down.circle.fill",
            parentID: rootID,
            breadcrumbs: ["Files", "Origin"],
            directItems: [],
            children: children
        )
    }

    static func sourceBucket(for item: ReferenceItem) -> String {
        if let host = item.websiteURL?.host(percentEncoded: false), !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }

        if item.subtitle == "Quick Note" {
            return "Quick Notes"
        }

        let subtitle = item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if subtitle.hasPrefix("http://") || subtitle.hasPrefix("https://"),
           let url = URL(string: subtitle),
           let host = url.host(percentEncoded: false), !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }

        if isMeaningfulSourceName(subtitle) {
            return subtitle
        }

        switch item.group {
        case .website:
            return "Websites"
        case .link:
            return "Saved Links"
        case .memory:
            return "Notes"
        case .file:
            return inferredFileSource(for: item)
        }
    }

    private static func inferredFileSource(for item: ReferenceItem) -> String {
        if item.isManagedDocument {
            switch item.fileExtension {
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tif", "tiff":
                return "Images & Assets"
            case "pdf", "doc", "docx", "pages", "rtf", "txt", "md":
                return "Documents"
            default:
                return "Imported Files"
            }
        }

        switch item.kind {
        case .app:
            return "App Icons & UI"
        case .phone, .laptop:
            return "Device Mockups"
        case .product:
            return "Product Shots"
        case .typography:
            return "Typography"
        case .website:
            return "Websites"
        }
    }

    private static func isMeaningfulSourceName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }

        let lowered = name.lowercased()
        if lowered == "originals" || lowered == "imports" || lowered == "import staging" {
            return false
        }

        if name.range(
            of: #"^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil {
            return false
        }

        if name.count >= 24 && name.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            return false
        }

        return true
    }

    private static func sourceSymbol(for bucket: String) -> String {
        if bucket.contains(".") {
            return "globe"
        }

        switch bucket {
        case "Quick Notes", "Notes":
            return "note.text"
        case "Saved Links":
            return "link"
        case "Websites":
            return "safari.fill"
        case "App Icons & UI":
            return "app.dashed"
        case "Images & Assets":
            return "photo.fill"
        case "Documents":
            return "doc.text.fill"
        case "Device Mockups":
            return "iphone"
        case "Product Shots":
            return "cube.fill"
        case "Typography":
            return "textformat"
        default:
            return "folder.fill"
        }
    }

    private static func typeNode(items: [ReferenceItem]) -> FileSystemNode {
        let groups: [(String, String, Set<String>)] = [
            ("PDFs", "doc.richtext.fill", ["pdf"]),
            ("Images", "photo.fill", ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"]),
            ("Office", "doc.text.fill", ["doc", "docx", "pages", "key", "ppt", "pptx", "xls", "xlsx", "csv"]),
            ("Notes", "note.text", ["txt", "md", "rtf"]),
            ("Archives", "archivebox.fill", ["zip", "json"])
        ]

        var usedIDs = Set<ReferenceItem.ID>()
        var children: [FileSystemNode] = groups.map { title, symbol, extensions in
            let matching = items.filter { item in
                let match = extensions.contains(item.fileExtension) || (title == "Notes" && item.subtitle == "Quick Note")
                if match { usedIDs.insert(item.id) }
                return match
            }
            return FileSystemNode(
                id: "type/\(title)",
                title: title,
                symbol: symbol,
                parentID: "type",
                breadcrumbs: ["Files", "Type", title],
                directItems: matching,
                children: []
            )
        }

        let other = items.filter { !usedIDs.contains($0.id) }
        children.append(
            FileSystemNode(
                id: "type/Other",
                title: "Other",
                symbol: "questionmark.folder.fill",
                parentID: "type",
                breadcrumbs: ["Files", "Type", "Other"],
                directItems: other,
                children: []
            )
        )

        return FileSystemNode(
            id: "type",
            title: "By Type",
            symbol: "square.grid.2x2.fill",
            parentID: rootID,
            breadcrumbs: ["Files", "Type"],
            directItems: [],
            children: children
        )
    }

    private static func collectionNode(items: [ReferenceItem], collections: [ReferenceCollection]) -> FileSystemNode {
        var children = collections.map { collection in
            FileSystemNode(
                id: "collection/\(collection.id.uuidString)",
                title: collection.name,
                symbol: collection.symbol,
                parentID: "collections",
                breadcrumbs: ["Files", "Collections", collection.name],
                directItems: items.filter { $0.collectionID == collection.id },
                children: []
            )
        }
        children.append(
            FileSystemNode(
                id: "collection/Unsorted",
                title: "Unsorted",
                symbol: "tray.fill",
                parentID: "collections",
                breadcrumbs: ["Files", "Collections", "Unsorted"],
                directItems: items.filter { $0.collectionID == nil },
                children: []
            )
        )

        return FileSystemNode(
            id: "collections",
            title: "Collections",
            symbol: "rectangle.stack.fill",
            parentID: rootID,
            breadcrumbs: ["Files", "Collections"],
            directItems: [],
            children: children.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        )
    }
}

private struct FileSystemThumbnailImage: View {
    var thumbnailURL: URL
    var cacheKey: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black.opacity(0.04)
            }
        }
        .task(id: cacheKey) {
            if let cached = ThumbnailImageCache.shared.image(forKey: cacheKey) {
                image = cached
            } else {
                image = await Self.loadImage(from: thumbnailURL, key: cacheKey)
            }
        }
        .onDisappear {
            image = nil
        }
    }

    @MainActor
    private static func loadImage(from url: URL, key: String) async -> NSImage? {
        guard let image = await LociImageLoader.downsampledImage(from: url, maxPixelSize: 512) else { return nil }
        ThumbnailImageCache.shared.setImage(image, forKey: key)
        return image
    }
}

private struct PreviewPageTile: View {
    var item: ReferenceItem
    var index: Int
    var originalURL: URL?
    @State private var pageImage: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
                if let pageImage {
                    Image(nsImage: pageImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    ReferenceThumbnail(item: item)
                        .aspectRatio(item.aspectRatio, contentMode: .fit)
                        .padding(7)
                        .opacity(index == 0 ? 1 : 0.55)
                }
                if index > 0 {
                    Text("\(index + 1)")
                        .lociFont(size: 12, weight: .bold, design: .rounded, relativeTo: .caption)
                        .foregroundStyle(.black.opacity(0.20))
                }
            }
            .frame(width: 48, height: 58)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.black.opacity(0.055), lineWidth: 1)
            }

            Text("\(index + 1)")
                .lociFont(size: 7.5, weight: .semibold, design: .rounded, relativeTo: .caption2)
                .foregroundStyle(.black.opacity(0.34))
        }
        .task(id: "\(originalURL?.path ?? item.id.uuidString)-\(index)") {
            pageImage = await loadPDFPageThumbnail()
        }
        .onDisappear {
            pageImage = nil
        }
    }

    private func loadPDFPageThumbnail() async -> NSImage? {
        guard item.fileExtension == "pdf",
              let originalURL,
              let document = PDFDocument(url: originalURL),
              let page = document.page(at: index) else {
            return nil
        }
        let box = page.bounds(for: .mediaBox)
        let scale = min(120 / max(box.width, 1), 150 / max(box.height, 1))
        let size = NSSize(width: max(1, box.width * scale), height: max(1, box.height * scale))
        return page.thumbnail(of: size, for: .mediaBox)
    }
}
