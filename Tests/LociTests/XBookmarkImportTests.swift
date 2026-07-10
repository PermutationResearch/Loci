import Foundation
import Testing
@testable import Loci

@Suite("XBookmarkImport")
struct XBookmarkImportTests {
    @MainActor
    @Test("Batch import creates visible X bookmark cards")
    func testBatchImportCreatesVisibleXBookmarks() throws {
        let store = LibraryStore(collections: [], items: [], persistence: nil)
        let payload = BrowserExtensionReferencePayload(
            url: "https://x.com/designer/status/123456789",
            title: "Designer @designer",
            note: "Designer @designer",
            selectedText: "A useful visual reference for product moodboards.",
            pageHTML: nil,
            articleMarkdown: "A useful visual reference for product moodboards.",
            transcriptText: nil,
            imageURLs: ["https://pbs.twimg.com/media/example.jpg"],
            autoTags: ["x-bookmarked"],
            source: "x-bookmark-sync",
            faviconURL: nil,
            ogImageURL: "https://pbs.twimg.com/media/example.jpg",
            alsoBookmarkOnX: true,
            sourceCreatedAt: "2026-07-06T14:30:00.000Z",
            mediaCount: 1,
            mediaTypes: ["photo"]
        )
        let payloadString = String(data: try! JSONEncoder().encode(payload), encoding: .utf8)!

        let result = store.upsertXBookmarkReferences([
            XBookmarkImportCandidate(
                url: "https://x.com/designer/status/123456789",
                title: "Designer @designer: A useful visual reference for product moodboards.",
                payload: payload,
                payloadString: payloadString
            )
        ])

        #expect(result.imported == 1)
        #expect(result.updated == 0)
        #expect(store.selectedFilter == .xBookmarks)
        #expect(store.visibleItems.count == 1)
        #expect(store.visibleItems.first?.isXBookmark == true)
        #expect(store.visibleItems.first?.title.contains("@designer") == true)
        let item = try #require(store.visibleItems.first)
        let cachedPayload = try #require(store.xBookmarkPayload(for: item))
        #expect(cachedPayload.mediaCount == 1)
        let card = XBookmarkDisplay.cardData(item: item, payload: cachedPayload)
        #expect(card.handle == "@designer")
        #expect(card.mediaBadge == "1 image")
        #expect(card.metaLabel.contains("image"))
    }

    @MainActor
    @Test("Batch import handles 5,000 X bookmarks without per-item UI churn")
    func testBatchImportHandlesLargeXBookmarkPage() {
        let store = LibraryStore(collections: [], items: [], persistence: nil)
        let candidates = (0..<5_000).map { index in
            let url = "https://x.com/designer/status/\(123_456_000 + index)"
            let payload = BrowserExtensionReferencePayload(
                url: url,
                title: "Designer @designer",
                note: "Designer @designer",
                selectedText: "Reference \(index)",
                pageHTML: nil,
                articleMarkdown: "Reference \(index)",
                transcriptText: nil,
                imageURLs: nil,
                autoTags: ["x-bookmarked"],
                source: "x-bookmark-sync",
                faviconURL: nil,
                ogImageURL: nil,
                alsoBookmarkOnX: true
            )
            let payloadString = String(data: try! JSONEncoder().encode(payload), encoding: .utf8)!
            return XBookmarkImportCandidate(
                url: url,
                title: "Designer @designer: Reference \(index)",
                payload: payload,
                payloadString: payloadString
            )
        }

        let start = ContinuousClock.now
        let result = store.upsertXBookmarkReferences(candidates)
        let duration = start.duration(to: ContinuousClock.now)

        #expect(result.imported == 5_000)
        #expect(result.updated == 0)
        #expect(store.selectedFilter == .xBookmarks)
        #expect(store.visibleItems.count == 5_000)
        #expect(duration < .seconds(15))
    }
}
