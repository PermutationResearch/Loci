import SwiftUI

// Extend UI file-system list: select on click, open viewer on double-click or filename click.
// https://github.com/extend-hq/ui

struct NotebookFileBrowser: View {
    var items: [ReferenceItem]
    @Binding var selectedID: ReferenceItem.ID?
    var onOpen: (ReferenceItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        NotebookFileRow(
                            item: item,
                            isSelected: selectedID == item.id,
                            onSelect: { selectedID = item.id },
                            onOpen: { onOpen(item) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.vertical, 4)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(AppMotion.instant) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

private struct NotebookFileRow: View {
    var item: ReferenceItem
    var isSelected: Bool
    var onSelect: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            NotebookThumbnail(item: item, size: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.78))
                    .lineLimit(1)
                Text(item.fileName)
                    .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.40))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen() }
            }

            Spacer(minLength: 8)

            Text(item.fileExtension.uppercased())
                .lociFont(size: 9, weight: .bold, design: .rounded, relativeTo: .caption2)
                .foregroundStyle(.black.opacity(0.34))
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.black.opacity(0.06) : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { onSelect() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: "Open") { onOpen() }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }
}

struct NotebookThumbnail: View {
    var item: ReferenceItem
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.black.opacity(0.04)
                    Image(systemName: fileSymbol)
                        .lociFont(size: size * 0.28, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.black.opacity(0.28))
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: item.thumbnailPath) {
            guard let thumbPath = item.thumbnailPath,
                  let store = LociPersistentStore.shared else { return }
            let url = store.thumbnailsURL.appendingPathComponent(thumbPath)
            if let cached = ThumbnailImageCache.shared.image(forKey: thumbPath) {
                image = cached
            } else {
                image = await Self.loadImage(from: url, key: thumbPath)
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

    private var fileSymbol: String {
        switch item.fileExtension {
        case "pdf": "doc.richtext"
        case "doc", "docx", "pages", "rtf", "txt", "md": "doc.text"
        case "xls", "xlsx", "csv": "tablecells"
        case "ppt", "pptx", "key": "play.rectangle"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": "photo"
        default: item.kindSymbol
        }
    }
}
