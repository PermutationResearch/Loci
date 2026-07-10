import AppKit
import PDFKit
import QuickLookUI
import SwiftUI

// Extend UI–inspired document viewer: dark canvas, continuous PDF scroll, toolbar with zoom + page nav.
// https://github.com/extend-hq/ui

struct ExtendDocumentViewer: View {
    var item: ReferenceItem
    var originalURL: URL?
    @Binding var pageIndex: Int
    /// Set when viewing a standalone file that is not in the library yet;
    /// surfaces an "Add to Library" action in the toolbar.
    var onAddToLibrary: (() -> Void)?

    @State private var content: DocumentViewerContent = .unsupported("Loading…")
    @State private var pageCount = 0
    @State private var zoomPercent = 100
    @State private var showsSidebar = false
    @State private var showsBacklinks = false
    @State private var searchText = ""
    @State private var showsSearch = false
    @State private var showsEditor = false
    @State private var viewID: UUID?
    @State private var lastPageIndex: Int = 0
    @State private var pageStartTime: Date?

    private let chrome = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let canvas = Color(red: 0.07, green: 0.07, blue: 0.08)

    private var isWebsitePreview: Bool {
        if case .websitePreview = content { return true }
        return false
    }

    private var toolbarTitle: String {
        if isWebsitePreview, let host = item.websiteURL?.host(percentEncoded: false) {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        if pageCount > 0 {
            return "Page \(pageIndex + 1) of \(pageCount)"
        }
        return item.fileName
    }

    var body: some View {
        VStack(spacing: 0) {
            viewerToolbar
            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 0) {
                if showsSidebar, case .pdf = content {
                    pdfSidebar
                    Divider().overlay(Color.white.opacity(0.08))
                }

                viewerBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showsBacklinks {
                    Divider().overlay(Color.white.opacity(0.08))
                    backlinksSidebar
                }
            }
        }
        .background(canvas)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .task(id: taskID) {
            recordClose()
            zoomPercent = 100
            showsSidebar = false
            showsSearch = false
            searchText = ""
            await loadContent()
            recordOpen()
        }
        .onDisappear {
            recordClose()
        }
        .onChange(of: pageIndex) { _, newPage in
            recordPageDuration()
            lastPageIndex = newPage
            pageStartTime = Date()
            DocumentAnalytics.recordPageView(viewID: viewID ?? UUID(), referenceID: item.id, pageIndex: newPage)
        }
        .sheet(isPresented: $showsEditor) {
            WikiEditorView(
                slug: MarkdownVault.slug(for: item),
                vaultRoot: MarkdownVault.defaultVaultURL()
            )
        }
    }

    private var taskID: String {
        "\(item.id.uuidString)-\(originalURL?.path ?? "")"
    }

    private var isWikiPage: Bool {
        let slug = MarkdownVault.slug(for: item)
        let wikiPath = MarkdownVault.defaultVaultURL().appendingPathComponent("wiki/references/\(slug).md")
        return FileManager.default.fileExists(atPath: wikiPath.path)
    }

    private var viewerToolbar: some View {
        HStack(spacing: 12) {
            if pageCount > 0 {
                Button {
                    showsSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                        .lociFont(size: 12, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(showsSidebar ? .white : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Page sidebar")
                .accessibilityLabel("Page sidebar")
            }

            Button {
                showsBacklinks.toggle()
            } label: {
                Image(systemName: "arrow.triangle.branch")
                    .lociFont(size: 12, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(showsBacklinks ? .white : .white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Backlinks")
            .accessibilityLabel("Backlinks")

            Text(toolbarTitle)
                .lociFont(size: 11, weight: .medium, design: pageCount > 0 ? .rounded : .default, relativeTo: .caption)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

            Spacer()

            if !isWebsitePreview {
                HStack(spacing: 6) {
                    viewerIconButton("minus") { adjustZoom(by: -10) }
                    Menu {
                        Button("Fit to View") { zoomPercent = 100 }
                        Divider()
                        ForEach([50, 75, 100, 125, 150, 200], id: \.self) { value in
                            Button("\(value)%") { zoomPercent = value }
                        }
                    } label: {
                        Text("\(zoomPercent)%")
                            .lociFont(size: 11, weight: .semibold, design: .rounded, relativeTo: .caption)
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    viewerIconButton("plus") { adjustZoom(by: 10) }
                }
            }

            if pageCount > 0 {
                viewerIconButton("magnifyingglass") {
                    showsSearch.toggle()
                }
            }

            if isWikiPage {
                Button("Edit") {
                    showsEditor = true
                }
                .buttonStyle(.plain)
                .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if let onAddToLibrary {
                Button("Add to Library", action: onAddToLibrary)
                    .buttonStyle(.plain)
                    .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help("Import a copy of this file into the Loci library")
            }

            if let websiteURL = item.websiteURL, isWebsitePreview {
                Button("Open in Browser") {
                    NSWorkspace.shared.open(websiteURL)
                }
                .buttonStyle(.plain)
                .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let originalURL {
                Menu {
                    Button("Open in Default App") {
                        NSWorkspace.shared.open(originalURL)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([originalURL])
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .lociFont(size: 12, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(chrome)
        .overlay(alignment: .bottom) {
            if showsSearch {
                HStack(spacing: 8) {
                    TextField("Search in document", text: $searchText)
                        .textFieldStyle(.plain)
                        .lociFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.white)
                        .onSubmit { performSearch() }
                    Button("Find") { performSearch() }
                        .buttonStyle(.plain)
                        .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.92))
            }
        }
    }

    @ViewBuilder
    private var viewerBody: some View {
        switch content {
        case .pdf(let url):
            ExtendPDFScrollView(
                url: url,
                pageIndex: $pageIndex,
                pageCount: $pageCount,
                zoomPercent: zoomPercent,
                searchText: searchText
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .quickLook(let url):
            ExtendQuickLookCanvas(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let url):
            ExtendImageCanvas(url: url, zoomPercent: zoomPercent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .plainText(let text):
            ExtendTextCanvas(text: text)
        case .markdown(let text):
            ExtendMarkdownCanvas(text: text)
        case .websitePreview(let thumbnailURL, let websiteURL):
            ExtendWebsitePreviewCanvas(
                item: item,
                thumbnailURL: thumbnailURL,
                websiteURL: websiteURL
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preparing(let message):
            ExtendPreparingCanvas(message: message)
        case .unsupported(let message):
            ExtendFallbackCanvas(item: item, message: message)
        }
    }

    private var pdfSidebar: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Button {
                        pageIndex = index
                    } label: {
                        PDFPageThumbnail(url: originalURL, pageIndex: index)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(
                                        pageIndex == index ? Color.white.opacity(0.85) : Color.white.opacity(0.12),
                                        lineWidth: pageIndex == index ? 1.5 : 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .frame(width: 92)
        .background(chrome)
    }

    private var backlinksSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                        .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(.white.opacity(0.40))
                    Text("BACKLINKS")
                        .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                        .tracking(0.3)
                        .foregroundStyle(.white.opacity(0.40))
                    Spacer()
                    Button {
                        showsBacklinks = false
                    } label: {
                        Image(systemName: "xmark")
                            .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                            .foregroundStyle(.white.opacity(0.40))
                    }
                    .buttonStyle(.plain)
                }

                let slug = MarkdownVault.slug(for: item)
                let vaultRoot = MarkdownVault.defaultVaultURL()
                let links = BacklinksEngine.backlinks(for: slug, vaultRoot: vaultRoot)

                if links.isEmpty {
                    Text("No backlinks yet")
                        .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                        .foregroundStyle(.white.opacity(0.30))
                        .padding(.top, 8)
                } else {
                    ForEach(links) { link in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                                    .foregroundStyle(.white.opacity(0.30))
                                Text(link.sourceTitle)
                                    .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                                    .foregroundStyle(.white.opacity(0.70))
                                    .lineLimit(1)
                            }
                            if !link.contextSnippet.isEmpty {
                                Text(link.contextSnippet)
                                    .lociFont(size: 9, weight: .medium, relativeTo: .caption2)
                                    .foregroundStyle(.white.opacity(0.40))
                                    .lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 200)
        .background(chrome)
    }

    private func viewerIconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .lociFont(size: 12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }

    private func adjustZoom(by delta: Int) {
        zoomPercent = min(200, max(25, zoomPercent + delta))
    }

    private func performSearch() {
        // PDF search handled inside ExtendPDFScrollView via searchText binding refresh
    }

    @MainActor
    private func loadContent() async {
        if DocumentPreviewConverter.isOfficeDocument(extension: item.fileExtension) {
            content = .preparing("Rendering formatted preview…")
        }

        let resolved = await DocumentViewerContentResolver.resolve(item: item, originalURL: originalURL)
        content = resolved.content
        pageCount = resolved.pdfPageCount
        pageIndex = min(pageIndex, max(0, pageCount - 1))
    }

    private func recordOpen() {
        viewID = DocumentAnalytics.recordOpen(referenceID: item.id)
        lastPageIndex = pageIndex
        pageStartTime = Date()
    }

    private func recordClose() {
        guard let viewID else { return }
        recordPageDuration()
        DocumentAnalytics.recordClose(viewID: viewID, pageCount: pageCount)
        self.viewID = nil
    }

    private func recordPageDuration() {
        guard let viewID, let startTime = pageStartTime else { return }
        let duration = Date().timeIntervalSince(startTime)
        DocumentAnalytics.recordPageDuration(viewID: viewID, pageIndex: lastPageIndex, duration: duration)
    }
}

private struct ExtendPDFScrollView: NSViewRepresentable {
    var url: URL
    @Binding var pageIndex: Int
    @Binding var pageCount: Int
    var zoomPercent: Int
    var searchText: String

    func makeCoordinator() -> Coordinator {
        Coordinator(pageIndex: $pageIndex, pageCount: $pageCount)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        view.pageShadowsEnabled = true
        view.delegate = context.coordinator
        if let document = PDFDocument(url: url) {
            view.document = document
            context.coordinator.attach(view: view, document: document)
        }
        return view
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            if let document = PDFDocument(url: url) {
                pdfView.document = document
                context.coordinator.attach(view: pdfView, document: document)
            }
        }

        context.coordinator.applyZoom(zoomPercent, in: pdfView)

        context.coordinator.syncPageIndex(to: pageIndex, in: pdfView)

        if !searchText.isEmpty, let document = pdfView.document {
            context.coordinator.search(query: searchText, in: pdfView, document: document)
        }
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        pdfView.delegate = nil
        pdfView.document = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        private var pageIndex: Binding<Int>
        private var pageCount: Binding<Int>
        private weak var pdfView: PDFView?
        private var isUpdatingFromView = false
        private var baseFitScale: CGFloat = 1

        init(pageIndex: Binding<Int>, pageCount: Binding<Int>) {
            self.pageIndex = pageIndex
            self.pageCount = pageCount
        }

        func attach(view: PDFView, document: PDFDocument) {
            pdfView = view
            pageCount.wrappedValue = document.pageCount
            refreshBaseFitScale(in: view)
        }

        func detach() {
            pdfView = nil
        }

        func applyZoom(_ zoomPercent: Int, in view: PDFView) {
            refreshBaseFitScale(in: view)
            let targetScale = baseFitScale * CGFloat(zoomPercent) / 100.0
            guard targetScale > 0, abs(view.scaleFactor - targetScale) > 0.005 else { return }
            view.scaleFactor = targetScale
        }

        private func refreshBaseFitScale(in view: PDFView) {
            guard view.bounds.width > 1, view.bounds.height > 1 else { return }
            view.layoutSubtreeIfNeeded()
            let fit = view.scaleFactorForSizeToFit
            if fit > 0 {
                baseFitScale = fit
            }
        }

        func syncPageIndex(to index: Int, in view: PDFView) {
            guard !isUpdatingFromView,
                  let document = view.document,
                  index >= 0, index < document.pageCount,
                  let page = document.page(at: index),
                  view.currentPage != page else { return }
            isUpdatingFromView = true
            view.go(to: page)
            isUpdatingFromView = false
        }

        func search(query: String, in view: PDFView, document: PDFDocument) {
            let selections = document.findString(query, withOptions: .caseInsensitive)
            if let first = selections.first {
                view.setCurrentSelection(first, animate: true)
                view.go(to: first)
            }
        }

        func pdfViewCurrentPageDidChange(_ sender: PDFView) {
            guard !isUpdatingFromView,
                  let page = sender.currentPage,
                  let document = sender.document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            isUpdatingFromView = true
            pageIndex.wrappedValue = index
            isUpdatingFromView = false
        }
    }
}

private struct PDFPageThumbnail: View {
    var url: URL?
    var pageIndex: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 68, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: "\(url?.path ?? "")-\(pageIndex)") {
            guard let url, let document = PDFDocument(url: url), let page = document.page(at: pageIndex) else { return }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(68 / max(bounds.width, 1), 88 / max(bounds.height, 1))
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            image = page.thumbnail(of: size, for: .mediaBox)
        }
        .onDisappear {
            image = nil
        }
    }
}

private struct ExtendQuickLookCanvas: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.autoresizingMask = [.width, .height]
        view.layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1).cgColor
        return view
    }

    func updateNSView(_ previewView: QLPreviewView, context: Context) {
        if (previewView.previewItem as? URL) != url {
            previewView.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ previewView: QLPreviewView, coordinator: ()) {
        previewView.previewItem = nil
    }
}

private struct ExtendImageCanvas: View {
    var url: URL
    var zoomPercent: Int

    @State private var image: NSImage?

    private let canvas = Color(red: 0.07, green: 0.07, blue: 0.08)
    private let padding: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                if let image {
                    let fitted = fittedSize(for: image, in: geometry.size)
                    let zoom = CGFloat(zoomPercent) / 100.0

                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height,
                            alignment: .center
                        )
                        .padding(padding)
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(canvas)
        }
        .background(canvas)
        .task(id: url) {
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

    private func fittedSize(for image: NSImage, in container: CGSize) -> CGSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return imageSize }

        let availableWidth = max(container.width - padding * 2, 1)
        let availableHeight = max(container.height - padding * 2, 1)
        let fitScale = min(availableWidth / imageSize.width, availableHeight / imageSize.height)

        return CGSize(
            width: imageSize.width * fitScale,
            height: imageSize.height * fitScale
        )
    }
}

private struct ExtendTextCanvas: View {
    var text: String

    var body: some View {
        ScrollView {
            Text(text)
                .lociFont(size: 12, design: .monospaced, relativeTo: .caption)
                .foregroundStyle(.white.opacity(0.82))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }
}

/// Renders markdown as formatted text on the dark viewer canvas. Block
/// structure (headings, lists, quotes, fences) is parsed by hand because
/// AttributedString's markdown init flattens it; inline emphasis, code, and
/// links go through AttributedString. Obsidian-style [[wikilinks]] display as
/// their titles — there is no vault context to resolve them against here.
private struct ExtendMarkdownCanvas: View {
    private enum Block {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case listItem(marker: String, text: AttributedString, indent: Int)
        case quote(AttributedString)
        case code(String)
        case rule
    }

    private let blocks: [Block]

    init(text: String) {
        blocks = Self.parse(text)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .textSelection(.enabled)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .lociFont(
                    size: [20, 17, 14.5, 13, 12.5, 12][min(level, 6) - 1],
                    weight: .semibold,
                    relativeTo: .headline
                )
                .foregroundStyle(.white.opacity(0.94))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(text)
                .lociFont(size: 12.5, relativeTo: .body)
                .lineSpacing(3.5)
                .foregroundStyle(.white.opacity(0.82))
        case .listItem(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .lociFont(size: 12, weight: .semibold, design: .rounded, relativeTo: .body)
                    .foregroundStyle(.white.opacity(0.45))
                Text(text)
                    .lociFont(size: 12.5, relativeTo: .body)
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.26))
                    .frame(width: 3)
                Text(text)
                    .lociFont(size: 12.5, relativeTo: .body)
                    .italic()
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.64))
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            Text(code)
                .lociFont(size: 11, design: .monospaced, relativeTo: .caption)
                .foregroundStyle(.white.opacity(0.80))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .rule:
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private static func parse(_ raw: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var fenceLines: [String]?
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]

        // YAML frontmatter is metadata, not prose; show it as a code block.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            blocks.append(.code(lines[lines.startIndex + 1..<closing].joined(separator: "\n")))
            lines = lines[(closing + 1)...]
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: " "))))
            paragraph.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if fenceLines != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(fenceLines?.joined(separator: "\n") ?? ""))
                    fenceLines = nil
                } else {
                    fenceLines?.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                fenceLines = []
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flushParagraph()
                let content = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: hashes, text: inline(content)))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let content = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(inline(content)))
                continue
            }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.listItem(marker: "•", text: inline(String(trimmed.dropFirst(2))), indent: indent))
                continue
            }
            if let match = trimmed.firstMatch(of: /^(\d{1,3})\.\s+(.*)$/) {
                flushParagraph()
                blocks.append(.listItem(marker: "\(match.1).", text: inline(String(match.2)), indent: indent))
                continue
            }
            paragraph.append(trimmed)
        }
        if let fenceLines {
            blocks.append(.code(fenceLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func inline(_ text: String) -> AttributedString {
        var normalized = text.replacing(/\[\[([^\]|]+)\|([^\]]+)\]\]/) { String($0.output.2) }
        normalized = normalized.replacing(/\[\[([^\]]+)\]\]/) { String($0.output.1) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(normalized)
    }
}

private struct ExtendPreparingCanvas: View {
    var message: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text(message)
                .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                .foregroundStyle(.white.opacity(0.56))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }
}

private struct ExtendWebsitePreviewCanvas: View {
    var item: ReferenceItem
    var thumbnailURL: URL?
    var websiteURL: URL?

    private let canvas = Color(red: 0.07, green: 0.07, blue: 0.08)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let thumbnailURL {
                    ExtendImageCanvas(url: thumbnailURL, zoomPercent: 100)
                } else {
                    ReferenceThumbnail(item: item)
                        .aspectRatio(item.aspectRatio, contentMode: .fit)
                        .frame(
                            width: fittedWidth(in: geometry.size),
                            height: fittedWidth(in: geometry.size) / max(item.aspectRatio, 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(canvas)
        }
        .background(canvas)
    }

    private func fittedWidth(in size: CGSize) -> CGFloat {
        min(size.width - 48, 760)
    }
}

private struct ExtendFallbackCanvas: View {
    var item: ReferenceItem
    var message: String

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 16) {
                ReferenceThumbnail(item: item)
                    .aspectRatio(item.aspectRatio, contentMode: .fit)
                    .frame(
                        width: min(geometry.size.width - 48, 640),
                        height: min(geometry.size.height - 80, 480)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    }
                Text(message)
                    .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(.white.opacity(0.48))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }
}
