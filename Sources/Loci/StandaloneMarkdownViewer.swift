import AppKit
import SwiftUI

/// Viewer for markdown files opened from Finder ("Open With → Loci") or via
/// drag onto the app icon. The file is read in place from wherever it lives on
/// disk — nothing is copied into the library unless the user asks with the
/// toolbar's Add to Library action.
struct StandaloneMarkdownViewer: View {
    let fileURL: URL
    var store: LibraryStore?

    @State private var itemID = UUID()
    @State private var pageIndex = 0
    @State private var addedToLibrary = false

    private var item: ReferenceItem {
        ReferenceItem(
            id: itemID,
            title: fileURL.deletingPathExtension().lastPathComponent,
            subtitle: fileURL.deletingLastPathComponent().lastPathComponent,
            fileName: fileURL.lastPathComponent,
            kind: .typography,
            group: .file,
            theme: .paper,
            aspectRatio: 0.77,
            collectionID: nil,
            isInbox: false,
            isTrashed: false,
            canvasPosition: .zero,
            infinityPosition: .zero
        )
    }

    var body: some View {
        ExtendDocumentViewer(
            item: item,
            originalURL: fileURL,
            pageIndex: $pageIndex,
            onAddToLibrary: addToLibraryAction
        )
        .padding(10)
        .frame(minWidth: 480, minHeight: 360)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }

    private var addToLibraryAction: (() -> Void)? {
        guard let store, !addedToLibrary else { return nil }
        return {
            store.importFiles([fileURL])
            addedToLibrary = true
        }
    }
}
