import AppKit
import SwiftUI

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    var role: ChatRole
    var text: String
    var sources: [VaultChatSourceBundle]
    var isError: Bool

    init(role: ChatRole, text: String, sources: [VaultChatSourceBundle] = [], isError: Bool = false) {
        self.role = role
        self.text = text
        self.sources = sources
        self.isError = isError
    }
}

enum ChatRole: String, Hashable {
    case user
    case assistant
}

enum ChatSourceScope: String, CaseIterable, Identifiable {
    case allDocuments = "Library"
    case selected = "Selected"
    case currentThread = "Thread"

    var id: String { rawValue }
}

private enum NotebookPane: String {
    case sources
    case document
    case stats
}

struct ChatWorkspaceView: View {
    @Bindable var store: LibraryStore
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var scope: ChatSourceScope = .allDocuments
    @State private var isSending = false
    @State private var viewerPageIndex = 0
    @State private var pane: NotebookPane = .sources
    @State private var sourceQuery = ""
    @State private var browserSelectedID: ReferenceItem.ID?
    @State private var showShareSheet = false
    @AppStorage("LociOpenRouterModel") private var configuredModel = "openai/gpt-4o-mini"
    @AppStorage("LociNotebookInspectorVisible") private var isInspectorVisible = true

    private let primaryText = LociColor.ink
    private let secondaryText = LociColor.inkTertiary
    private let panelBackground = LociColor.surfaceRecessed

    var body: some View {
        Group {
            if isInspectorVisible {
                HSplitView {
                    leftPanel
                        .frame(minWidth: 360, maxWidth: .infinity)
                        .layoutPriority(1)

                    chatPanel
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
                }
            } else {
                leftPanel
            }
        }
        .background(LociColor.surface)
        .onAppear {
            LociEnvironment.reload()
            syncScopeFromSelection()
            pane = store.notebookActiveItemID == nil ? .sources : .document
        }
        .onChange(of: store.notebookActiveItemID) { _, id in
            viewerPageIndex = 0
            if id != nil {
                pane = .document
                scope = .selected
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lociToggleNotebookInspector)) { _ in
            withAnimation(AppMotion.quick) {
                isInspectorVisible.toggle()
            }
        }
    }

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            leftHeader
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider().opacity(0.35)

            Group {
                switch pane {
                case .sources:
                    sourceLibrary
                case .document:
                    documentViewer
                case .stats:
                    if let item = activeViewerItem {
                        DocumentEngagementView(item: item)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(panelBackground)
        .sheet(isPresented: $showShareSheet) {
            if let item = activeViewerItem {
                ShareDocumentSheet(item: item)
            }
        }
    }

    private var leftHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            if pane == .document || pane == .stats {
                Button {
                    withAnimation(AppMotion.instant) {
                        pane = .sources
                        store.clearNotebookDocument()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .lociFont(size: 10, weight: .bold, relativeTo: .caption2)
                        Text("Sources")
                            .font(LociFont.label)
                    }
                    .foregroundStyle(LociColor.inkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(LociColor.surfaceSelected, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(pane == .document ? "DOCUMENT" : pane == .stats ? "INSIGHTS" : "SOURCES")
                    .font(LociFont.label)
                    .tracking(0.35)
                    .foregroundStyle(LociColor.inkTertiary)
                Text(pane == .document ? (activeViewerItem?.title ?? "Document") : pane == .stats ? (activeViewerItem?.title ?? "") : "\(filteredSources.count) in scope")
                    .font(LociFont.headline)
                    .foregroundStyle(LociColor.ink)
                    .lineLimit(1)
            }

            Spacer()

            if pane == .document, let item = activeViewerItem {
                Button {
                    pane = .stats
                } label: {
                    Image(systemName: "chart.bar")
                        .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(LociColor.inkTertiary)
                        .frame(width: 28, height: 28)
                        .background(LociColor.surfaceSelected, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Engagement insights")
                .accessibilityLabel("Engagement insights")

                Button {
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(LociColor.inkTertiary)
                        .frame(width: 28, height: 28)
                        .background(LociColor.surfaceSelected, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Share document")
                .accessibilityLabel("Share document")

                if let url = store.originalFileURL(for: item) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.square")
                            .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(secondaryText)
                }
            }

            if pane == .stats {
                Button {
                    withAnimation(AppMotion.instant) { pane = .document }
                } label: {
                    HStack(spacing: 4) {
                        Text("Document")
                            .font(LociFont.label)
                        Image(systemName: "chevron.right")
                            .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                    }
                    .foregroundStyle(LociColor.inkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(LociColor.surfaceSelected, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sourceLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(LociColor.inkFaint)
                    .accessibilityHidden(true)
                TextField("Filter sources", text: $sourceQuery)
                    .textFieldStyle(.plain)
                    .font(LociFont.body)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LociColor.hairline, lineWidth: 1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Text("Click to select · Double-click or click filename to open")
                .font(LociFont.caption)
                .foregroundStyle(LociColor.inkTertiary)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            NotebookFileBrowser(
                items: filteredSources,
                selectedID: $browserSelectedID,
                onOpen: { openDocument($0) }
            )
        }
    }

    private var documentViewer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if scopedItems.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(scopedItems) { item in
                            NotebookSourceChip(
                                item: item,
                                isActive: activeViewerItem?.id == item.id,
                                action: { openDocument(item) }
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .frame(minHeight: 58)
            }

            if let item = activeViewerItem {
                ExtendDocumentViewer(
                    item: item,
                    originalURL: store.originalFileURL(for: item),
                    pageIndex: $viewerPageIndex
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else {
                DocumentEmptyPlaceholder()
                    .padding(.bottom, 18)
            }
        }
    }

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("NOTEBOOK")
                        .font(LociFont.label)
                        .tracking(0.35)
                        .foregroundStyle(LociColor.inkTertiary)
                    Text(chatScopeLabel)
                        .font(LociFont.body)
                        .foregroundStyle(secondaryText)
                        .lineLimit(2)
                }
                Spacer()
                if !messages.isEmpty {
                    Button("Clear") { messages.removeAll() }
                        .buttonStyle(.plain)
                        .font(LociFont.caption)
                        .foregroundStyle(secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            scopePicker
                .padding(.horizontal, 16)

            Button {
                isInspectorVisible = false
            } label: {
                Label("Hide Ask Loci", systemImage: "sidebar.right")
                    .font(LociFont.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(secondaryText)
            .padding(.horizontal, 16)

            activeSourceSummary
                .padding(.horizontal, 16)

            groundingBanner
                .padding(.horizontal, 16)

            messageList
                .padding(.horizontal, 12)

            inputBar
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .background(LociColor.surface)
    }

    private var chatScopeLabel: String {
        switch scope {
        case .allDocuments:
            "Across your library"
        case .selected:
            if let item = activeViewerItem, scopedItems.count == 1 {
                "Focused on \"\(item.title)\""
            } else {
                "Chat across \(scopedItems.count) selected sources"
            }
        case .currentThread:
            "\(activeThread?.name ?? "Creative Thread") · \(scopedItems.count) sources"
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 4) {
            ForEach(ChatSourceScope.allCases) { option in
                Button {
                    scope = option
                    if option == .allDocuments {
                        withAnimation(AppMotion.instant) {
                            pane = .sources
                            browserSelectedID = nil
                            store.notebookActiveItemID = nil
                        }
                    }
                } label: {
                    Text(option.rawValue)
                        .font(scope == option ? LociFont.label : LociFont.caption)
                        .foregroundStyle(scope == option ? LociColor.ink : LociColor.inkTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(scope == option ? LociColor.surfaceSelected : Color.clear)
                        }
                }
                .buttonStyle(.plain)
                .disabled(isScopeUnavailable(option))
            }
        }
        .padding(3)
        .background(LociColor.surfaceRecessed, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var activeSourceSummary: some View {
        if let item = activeViewerItem, pane == .document {
            HStack(spacing: 8) {
                NotebookThumbnail(item: item, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(LociFont.label)
                        .lineLimit(1)
                    Text(item.fileName)
                        .font(LociFont.caption)
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(LociColor.surfaceRecessed, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var groundingBanner: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lock.document")
                .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                .foregroundStyle(LociColor.inkTertiary)
            Text("Grounded in \(scopedItems.count) source\(scopedItems.count == 1 ? "" : "s") · \(configuredModel). Answers cite the files used.")
                .font(LociFont.caption)
                .foregroundStyle(LociColor.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(LociColor.surfaceRecessed, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { message in
                        ChatBubble(message: message) { source in
                            focusCitation(source)
                        }
                        .id(message.id)
                    }
                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Reading sources…")
                                .font(LociFont.caption)
                                .foregroundStyle(secondaryText)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(AppMotion.quick) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(LociColor.surfaceRecessed, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LociColor.hairline, lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about your library")
                .font(LociFont.headline)
                .foregroundStyle(LociColor.inkSecondary)
            Text("Pick a source on the left, or chat across all documents. Answers cite extracted text from your vault.")
                .font(LociFont.caption)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestedPrompts, id: \.self) { prompt in
                    Button {
                        draft = prompt
                        send()
                    } label: {
                        Text(prompt)
                            .font(LociFont.caption)
                            .foregroundStyle(LociColor.inkSecondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(LociColor.hairline, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending || scopedItems.isEmpty)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
    }

    private var suggestedPrompts: [String] {
        [
            "Find the visual themes across these sources.",
            "What is missing from this creative direction?",
            "Compare the strongest references and explain why they work.",
            "Make a concise creative brief from these sources."
        ]
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask a question…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(LociFont.body)
                .lineLimit(1...4)
                .foregroundStyle(primaryText)
                .tint(LociColor.ink)
                .onSubmit { send() }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .lociFont(size: 22, weight: .semibold, relativeTo: .title)
                    .foregroundStyle(canSend ? LociColor.ink : LociColor.inkFaint)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LociColor.hairline, lineWidth: 1)
        }
    }

    private var activeViewerItem: ReferenceItem? {
        if let id = store.notebookActiveItemID,
           let item = store.items.first(where: { $0.id == id && !$0.isTrashed }) {
            return item
        }
        return nil
    }

    private var scopedItems: [ReferenceItem] {
        switch scope {
        case .allDocuments:
            return store.items.filter { $0.isManagedDocument && !$0.isTrashed }
        case .selected:
            var ids = store.selectedItemIDs
            if ids.isEmpty, let notebookID = store.notebookActiveItemID {
                ids = [notebookID]
            }
            return store.items.filter { ids.contains($0.id) && !$0.isTrashed }
        case .currentThread:
            guard let activeThread else { return [] }
            return store.items.filter { $0.collectionID == activeThread.id && !$0.isTrashed }
        }
    }

    private var filteredSources: [ReferenceItem] {
        let query = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scopedItems }
        return scopedItems.filter {
            $0.title.localizedStandardContains(query)
                || $0.fileName.localizedStandardContains(query)
        }
    }

    private var canSend: Bool {
        !isSending
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !scopedItems.isEmpty
    }

    private func syncScopeFromSelection() {
        if store.notebookActiveItemID != nil || !store.selectedItemIDs.isEmpty {
            scope = .selected
        } else if activeThread != nil {
            scope = .currentThread
        }
    }

    private func openDocument(_ item: ReferenceItem) {
        withAnimation(AppMotion.instant) {
            browserSelectedID = item.id
            store.notebookActiveItemID = item.id
            store.selectedItemIDs = [item.id]
            scope = .selected
            pane = .document
            viewerPageIndex = 0
        }
    }

    private func focusCitation(_ source: VaultChatSourceBundle) {
        guard let item = store.items.first(where: {
            MarkdownVault.slug(for: $0) == source.slug && !$0.isTrashed
        }) else { return }
        openDocument(item)
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !scopedItems.isEmpty, !isSending else { return }

        draft = ""
        messages.append(ChatMessage(role: .user, text: question))
        isSending = true

        let history = messages
            .filter { !$0.isError }
            .map { (role: $0.role == .user ? "user" : "assistant", content: $0.text) }
        let items = scopedItems
        let rootURL = store.vaultRootURL
        let groundedQuestion: String
        if scope == .currentThread, let thread = activeThread, !thread.brief.isEmpty {
            groundedQuestion = "Creative thread: \(thread.name)\nBrief: \(thread.brief)\n\nQuestion: \(question)"
        } else {
            groundedQuestion = question
        }

        Task {
            let result = await LLMWikiCompiler.answerNotebook(
                question: groundedQuestion,
                items: items,
                rootURL: rootURL,
                history: history.dropLast().map { $0 }
            )
            await MainActor.run {
                isSending = false
                switch result {
                case .success(let answer):
                    messages.append(
                        ChatMessage(
                            role: .assistant,
                            text: answer.answer,
                            sources: answer.sources
                        )
                    )
                case .failure(let failure):
                    messages.append(
                        ChatMessage(
                            role: .assistant,
                            text: failure.message,
                            isError: true
                        )
                    )
                }
            }
        }
    }

    private var activeThread: ReferenceCollection? {
        guard let id = store.activeThreadID else { return nil }
        return store.collections.first(where: { $0.id == id })
    }

    private func isScopeUnavailable(_ option: ChatSourceScope) -> Bool {
        switch option {
        case .allDocuments:
            false
        case .selected:
            store.selectedItemIDs.isEmpty && store.notebookActiveItemID == nil
        case .currentThread:
            activeThread == nil
        }
    }
}

private struct NotebookSourceChip: View {
    var item: ReferenceItem
    var isActive: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                NotebookThumbnail(item: item, size: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(LociFont.label)
                        .foregroundStyle(LociColor.ink)
                        .lineLimit(1)
                    Text(item.fileExtension.uppercased())
                        .font(LociFont.badge)
                        .foregroundStyle(LociColor.inkTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? LociColor.surfaceSelected : LociColor.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? LociColor.border : LociColor.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DocumentEmptyPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.viewfinder")
                .lociFont(size: 28, weight: .semibold, relativeTo: .title)
                .foregroundStyle(LociColor.inkFaint)
            Text("Choose a source to preview")
                .font(LociFont.caption)
                .foregroundStyle(LociColor.inkTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatBubble: View {
    var message: ChatMessage
    var onCitationTap: (VaultChatSourceBundle) -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            Text(message.text)
                .font(LociFont.body)
                .foregroundStyle(message.isError ? Color.red.opacity(0.78) : LociColor.ink)
                .textSelection(.enabled)
                .multilineTextAlignment(message.role == .user ? .trailing : .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            message.role == .user
                                ? LociColor.surfaceSelected
                                : LociColor.surfaceRecessed
                        )
                }
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CITATIONS")
                        .font(LociFont.label)
                        .tracking(0.22)
                        .foregroundStyle(LociColor.inkTertiary)
                    ForEach(message.sources.prefix(4)) { source in
                        Button {
                            onCitationTap(source)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                                Text(source.title)
                                    .font(LociFont.label)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(LociColor.inkTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(LociColor.surfaceSelected, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }
        }
    }
}

private struct DocumentEngagementView: View {
    var item: ReferenceItem
    @State private var engagement: DocumentEngagement?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let engagement {
                    engagementStats(engagement)
                    if !engagement.topPages.isEmpty {
                        pageHeatMap(engagement)
                    }
                    viewHistory(engagement)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(18)
        }
        .task(id: item.id) {
            engagement = DocumentAnalytics.engagement(for: item.id)
        }
    }

    private func engagementStats(_ e: DocumentEngagement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ENGAGEMENT")
                .font(LociFont.label)
                .tracking(0.3)
                .foregroundStyle(LociColor.inkTertiary)

            HStack(spacing: 12) {
                statBox("Views", value: "\(e.totalViews)")
                statBox("Pages", value: "\(e.uniquePagesViewed)")
                statBox("Avg Time", value: formatDuration(e.averageViewDuration))
            }

            if let last = e.lastViewedAt {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .lociFont(size: 8, relativeTo: .caption2)
                        .foregroundStyle(LociColor.inkFaint)
                    Text("Last opened \(last.formatted(.relative(presentation: .named)))")
                        .font(LociFont.caption)
                        .foregroundStyle(LociColor.inkTertiary)
                }
            }
        }
    }

    private func statBox(_ label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(LociFont.title)
                .monospacedDigit()
                .foregroundStyle(LociColor.ink)
            Text(label.uppercased())
                .font(LociFont.label)
                .tracking(0.2)
                .foregroundStyle(LociColor.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(LociColor.surfaceRecessed, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pageHeatMap(_ e: DocumentEngagement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PAGE HEAT")
                .font(LociFont.label)
                .tracking(0.3)
                .foregroundStyle(LociColor.inkTertiary)

            ForEach(e.topPages.prefix(8)) { page in
                HStack(spacing: 8) {
                    Text("p.\(page.pageIndex + 1)")
                        .font(LociFont.badge)
                        .foregroundStyle(LociColor.inkTertiary)
                        .frame(width: 28, alignment: .trailing)

                    GeometryReader { geo in
                        let maxCount = e.topPages.first?.viewCount ?? 1
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(LociColor.border)
                            .frame(width: geo.size.width, height: 10)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(LociColor.inkTertiary)
                            .frame(width: geo.size.width * CGFloat(page.viewCount) / CGFloat(maxCount), height: 10)
                    }
                    .frame(height: 10)

                    Text("\(page.viewCount)")
                        .font(LociFont.badge)
                        .foregroundStyle(LociColor.inkTertiary)
                        .frame(width: 20, alignment: .trailing)
                }
                .frame(minHeight: 16)
            }
        }
    }

    private func viewHistory(_ e: DocumentEngagement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT VIEWS")
                .font(LociFont.label)
                .tracking(0.3)
                .foregroundStyle(LociColor.inkTertiary)

            ForEach(e.viewHistory.prefix(6)) { view in
                HStack(spacing: 8) {
                    Circle()
                        .fill(LociColor.border)
                        .frame(width: 6, height: 6)
                    Text(view.openedAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(LociFont.caption)
                        .foregroundStyle(LociColor.inkTertiary)
                    Spacer()
                    Text(formatDuration(view.durationSeconds))
                        .font(LociFont.badge)
                        .foregroundStyle(LociColor.inkTertiary)
                }
            }

            if e.viewHistory.isEmpty {
                Text("No views recorded yet")
                    .font(LociFont.caption)
                    .foregroundStyle(LociColor.inkFaint)
                    .padding(.top, 8)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(seconds / 3600))h \(Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }
}

private struct ShareDocumentSheet: View {
    var item: ReferenceItem
    @Environment(\.dismiss) private var dismiss
    @State private var tokens: [ShareTokenRecord] = []
    @State private var newToken: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Share Document")
                    .font(LociFont.title)
                    .foregroundStyle(LociColor.ink)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(LociColor.inkTertiary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }

            Text(item.title)
                .font(LociFont.body)
                .foregroundStyle(LociColor.inkSecondary)
                .lineLimit(2)

            Divider().opacity(0.2)

            Button {
                let token = DocumentAnalytics.createShareToken(for: item.id)
                if let token {
                    newToken = token
                    tokens = DocumentAnalytics.shareTokens(for: item.id)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("atlas://share/\(token)", forType: .string)
                }
            } label: {
                Label("Create Share Link", systemImage: "link.badge.plus")
                    .font(LociFont.label)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(LociColor.ink)

            if let newToken {
                HStack {
                    Text("atlas://share/\(newToken)")
                        .font(LociFont.caption.monospaced())
                        .foregroundStyle(LociColor.inkSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text("Copied!")
                        .font(LociFont.label)
                        .foregroundStyle(.green)
                }
                .padding(10)
                .background(LociColor.surfaceRecessed, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !tokens.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ACTIVE LINKS")
                        .font(LociFont.label)
                        .tracking(0.25)
                        .foregroundStyle(LociColor.inkTertiary)

                    ForEach(tokens) { token in
                        HStack(spacing: 8) {
                            Text(token.token)
                                .font(LociFont.caption.monospaced())
                                .foregroundStyle(LociColor.inkTertiary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(token.accessCount) views")
                                .font(LociFont.badge)
                                .foregroundStyle(LociColor.inkTertiary)
                            Button {
                                DocumentAnalytics.revokeShareToken(token.token)
                                tokens = DocumentAnalytics.shareTokens(for: item.id)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .lociFont(size: 10, relativeTo: .caption2)
                                    .foregroundStyle(LociColor.inkFaint)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Revoke link")
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            tokens = DocumentAnalytics.shareTokens(for: item.id)
        }
    }
}
