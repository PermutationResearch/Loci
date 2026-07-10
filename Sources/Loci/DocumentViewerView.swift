import AppKit
import PDFKit
import QuickLookUI
import SwiftUI

enum DocumentViewerContent: Equatable {
    case pdf(URL)
    case image(URL)
    case quickLook(URL)
    case plainText(String)
    case websitePreview(thumbnailURL: URL?, websiteURL: URL?)
    case preparing(String)
    case unsupported(String)
}

struct DocumentViewerView: View {
    var item: ReferenceItem
    var originalURL: URL?
    var vaultRootURL: URL
    var pageIndex: Binding<Int>?

    @State private var localPageIndex = 0

    private var activePageBinding: Binding<Int> {
        if let pageIndex { return pageIndex }
        return $localPageIndex
    }

    var body: some View {
        ExtendDocumentViewer(
            item: item,
            originalURL: originalURL,
            pageIndex: activePageBinding
        )
    }
}

enum DocumentViewerContentResolver {
    struct Result {
        var content: DocumentViewerContent
        var pdfPageCount: Int
    }

    private static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "json", "xml", "log"
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg"
    ]

    @MainActor
    static func resolve(item: ReferenceItem, originalURL: URL?) async -> Result {
        let ext = item.fileExtension
        let isWebsite = item.kind == .website || ext == "webloc" || item.websiteURL != nil

        if isWebsite, let preview = websitePreviewResult(for: item) {
            return preview
        }

        guard let originalURL, FileManager.default.fileExists(atPath: originalURL.path) else {
            if let thumbURL = thumbnailURL(for: item) {
                return Result(content: .image(thumbURL), pdfPageCount: 0)
            }
            if isWebsite, let websiteURL = item.websiteURL {
                return Result(content: .websitePreview(thumbnailURL: nil, websiteURL: websiteURL), pdfPageCount: 0)
            }
            return Result(content: .unsupported("No preview available."), pdfPageCount: 0)
        }

        if ext == "webloc", let preview = websitePreviewResult(for: item) {
            return preview
        }

        if ext == "pdf" {
            let count = PDFDocument(url: originalURL)?.pageCount ?? 0
            return Result(content: .pdf(originalURL), pdfPageCount: count)
        }

        if imageExtensions.contains(ext) {
            return Result(content: .image(originalURL), pdfPageCount: 0)
        }

        if plainTextExtensions.contains(ext),
           !DocumentPreviewConverter.isOfficeDocument(originalURL),
           let text = try? String(contentsOf: originalURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(content: .plainText(text), pdfPageCount: 0)
        }

        if DocumentPreviewConverter.isOfficeDocument(originalURL) {
            if let previewPDF = await DocumentPreviewConverter.pdfPreviewURL(for: item, sourceURL: originalURL) {
                let count = PDFDocument(url: previewPDF)?.pageCount ?? 0
                return Result(content: .pdf(previewPDF), pdfPageCount: count)
            }
            if let thumbURL = thumbnailURL(for: item) {
                return Result(content: .image(thumbURL), pdfPageCount: 0)
            }
            return Result(
                content: .unsupported("Install LibreOffice to preview formatted Word/Excel/PowerPoint files."),
                pdfPageCount: 0
            )
        }

        if let thumbURL = thumbnailURL(for: item) {
            return Result(content: .image(thumbURL), pdfPageCount: 0)
        }

        return Result(content: .quickLook(originalURL), pdfPageCount: 0)
    }

    @MainActor
    private static func websitePreviewResult(for item: ReferenceItem) -> Result? {
        guard item.websiteURL != nil || item.kind == .website || item.fileExtension == "webloc" else {
            return nil
        }
        return Result(
            content: .websitePreview(
                thumbnailURL: thumbnailURL(for: item),
                websiteURL: item.websiteURL
            ),
            pdfPageCount: 0
        )
    }

    @MainActor
    private static func thumbnailURL(for item: ReferenceItem) -> URL? {
        guard let store = LociPersistentStore.shared,
              let thumbPath = item.thumbnailPath else { return nil }
        let url = store.thumbnailsURL.appendingPathComponent(thumbPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
