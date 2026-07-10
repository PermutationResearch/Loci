import Foundation
import Testing
@testable import Loci

@Suite("Search")
struct SearchTests {
    @Test("Search queries normalize pasted whitespace")
    func testSearchQueryNormalization() {
        #expect(LibraryStore.normalizedSearchQuery("  product\n\tcard   mockup  ") == "product card mockup")
        #expect(LibraryStore.sanitizedSearchInput("  product\n\tcard") == "product card")
        #expect(LibraryStore.sanitizedSearchInput("product ") == "product ")
    }

    @MainActor
    @Test("Multi-word fallback search matches all query terms")
    func testMultiWordFallbackSearch() async {
        let matchingID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let store = LibraryStore(
            collections: [],
            items: [
                ReferenceItem(
                    id: matchingID,
                    title: "Blue product card",
                    subtitle: "Landing page reference",
                    fileName: "blue-card.png",
                    kind: .website,
                    group: .website,
                    theme: .marine,
                    aspectRatio: 0.8,
                    collectionID: nil,
                    isInbox: true,
                    isTrashed: false,
                    canvasPosition: .zero,
                    infinityPosition: .zero
                ),
                ReferenceItem(
                    id: otherID,
                    title: "Blue icon set",
                    subtitle: "Interface details",
                    fileName: "icons.png",
                    kind: .app,
                    group: .file,
                    theme: .aurora,
                    aspectRatio: 1.0,
                    collectionID: nil,
                    isInbox: true,
                    isTrashed: false,
                    canvasPosition: .zero,
                    infinityPosition: .zero
                )
            ],
            persistence: nil
        )

        store.searchText = "  product   card  "

        #expect(store.normalizedSearchText == "product card")

        // Filtering is debounced while typing; wait for the query to apply.
        for _ in 0..<100 where store.visibleItems.map(\.id) != [matchingID] {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.visibleItems.map(\.id) == [matchingID])
    }
}
