import Testing
import Foundation
@testable import Loci

@Suite("StartupLoading")
struct StartupLoadingTests {
    @MainActor
    @Test("Deferred vault bootstrap leaves references visible immediately")
    func testDeferredVaultBootstrapKeepsReferencesVisible() async {
        let item = ReferenceItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            title: "Immediate Reference",
            subtitle: "Quick Note",
            fileName: "immediate-reference.md",
            kind: .typography,
            group: .memory,
            theme: .paper,
            aspectRatio: 0.82,
            collectionID: nil,
            isInbox: true,
            isTrashed: false,
            canvasPosition: .zero,
            infinityPosition: .zero
        )

        let store = LibraryStore(
            collections: [],
            items: [item],
            persistence: nil,
            deferVaultBootstrap: true
        )

        #expect(store.visibleItems.count == 1)
        #expect(store.vaultSnapshot.items.count == 1)
        #expect(store.vaultSnapshot.documents.isEmpty)

        store.finishDeferredStartupWork()

        // Bootstrap now runs on a background queue; wait for the snapshot to publish.
        for _ in 0..<300 where store.vaultSnapshot.documents.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.vaultSnapshot.documents.isEmpty)
    }
}
