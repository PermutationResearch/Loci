import ImageIO
import SwiftUI

extension NSImage: @retroactive @unchecked Sendable {}

final class ThumbnailImageCache: @unchecked Sendable {
    static let shared = ThumbnailImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private let aspectRatioCache = NSCache<NSString, NSNumber>()
    private let lock = NSLock()
    private var inFlightLoads: [String: [CheckedContinuation<NSImage?, Never>]] = [:]

    init() {
        cache.countLimit = 180
        cache.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func imageOrLoadSynchronously(forKey key: String, from url: URL, maxPixelSize: Int = 512) -> NSImage? {
        if let cached = image(forKey: key) {
            return cached
        }

        let image = Self.loadImage(from: url, maxPixelSize: maxPixelSize)
        if let image {
            setImage(image, forKey: key)
        }
        return image
    }

    func setImage(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.memoryCost)
        if image.size.width > 0, image.size.height > 0 {
            setAspectRatio(image.size.width / image.size.height, forKey: key)
        }
    }

    func aspectRatio(forKey key: String) -> CGFloat? {
        aspectRatioCache.object(forKey: key as NSString).map { CGFloat(truncating: $0) }
    }

    func setAspectRatio(_ aspectRatio: CGFloat, forKey key: String) {
        aspectRatioCache.setObject(NSNumber(value: Double(aspectRatio)), forKey: key as NSString)
    }

    func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func loadImage(forKey key: String, from url: URL, on queue: OperationQueue, maxPixelSize: Int = 512) async -> NSImage? {
        if let cached = image(forKey: key) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            if let cached = image(forKey: key) {
                lock.unlock()
                continuation.resume(returning: cached)
                return
            }
            if inFlightLoads[key] != nil {
                inFlightLoads[key]?.append(continuation)
                lock.unlock()
                return
            }
            inFlightLoads[key] = [continuation]
            lock.unlock()

            queue.addOperation { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                let image = Self.loadImage(from: url, maxPixelSize: maxPixelSize)
                if let image {
                    self.setImage(image, forKey: key)
                }

                self.lock.lock()
                let continuations = self.inFlightLoads.removeValue(forKey: key) ?? []
                self.lock.unlock()

                continuations.forEach { $0.resume(returning: image) }
            }
        }
    }

    private static func loadImage(from url: URL, maxPixelSize: Int) -> NSImage? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                return nil
            }

            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ] as CFDictionary

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                return nil
            }

            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }
}

private extension NSImage {
    var memoryCost: Int {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        return width * height * 4
    }
}

private struct ThumbnailImageSource: Hashable {
    var key: String
    var url: URL
    var maxPixelSize: Int
}

struct ReferenceThumbnail: View {
    var item: ReferenceItem
    var xBookmarkPayload: XBookmarkPayloadSummary? = nil
    @State private var image: NSImage?
    @State private var imageKey: String?
    @State private var failedThumbnailPath: String?

    var body: some View {
        ZStack {
            if let store = LociPersistentStore.shared {
                let sources = Self.imageSources(for: item, store: store)
                let displayImage = Self.displayImage(for: sources, image: image, imageKey: imageKey)
                if let displayImage {
                    if item.importedPreviewKind == .xLink {
                        XMediaBookmarkGraphic(item: item, image: displayImage, xBookmarkPayload: xBookmarkPayload)
                    } else {
                        Image(nsImage: displayImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                } else {
                    proceduralContent
                }
                Color.clear
                    .task(id: sources.map(\.key).joined(separator: "|")) {
                        guard !sources.isEmpty else { return }
                        if !sources.contains(where: { $0.key == imageKey }) {
                            image = nil
                            imageKey = nil
                        }
                        failedThumbnailPath = nil
                        for source in sources {
                            if let cached = ThumbnailImageCache.shared.image(forKey: source.key) {
                                imageKey = source.key
                                image = cached
                                return
                            }
                            if let loadedImage = await Self.loadImage(from: source.url, key: source.key, maxPixelSize: source.maxPixelSize) {
                                imageKey = source.key
                                image = loadedImage
                                return
                            }
                        }
                        failedThumbnailPath = sources.first?.key
                    }
            } else {
                proceduralContent
            }
        }
        .clipped()
    }

    private static let thumbnailQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()

    static func preloadImages(for items: some Sequence<ReferenceItem>) {
        guard let store = LociPersistentStore.shared else { return }
        for item in items {
            let sources = imageSources(for: item, store: store)
            guard displayImage(for: sources, image: nil, imageKey: nil) == nil,
                  let source = sources.first else { continue }
            Task(priority: .utility) {
                _ = await loadImage(from: source.url, key: source.key, maxPixelSize: source.maxPixelSize)
            }
        }
    }

    @discardableResult
    static func warmImagesForFirstPaint(
        for items: some Sequence<ReferenceItem>,
        limit: Int = 36,
        timeBudget: TimeInterval = 0.08
    ) -> Int {
        guard let store = LociPersistentStore.shared else { return 0 }
        let deadline = Date().addingTimeInterval(timeBudget)
        var warmed = 0

        for item in items {
            if warmed >= limit || Date() >= deadline { break }
            for source in imageSources(for: item, store: store) {
                if ThumbnailImageCache.shared.image(forKey: source.key) != nil {
                    break
                }
                if ThumbnailImageCache.shared.imageOrLoadSynchronously(
                    forKey: source.key,
                    from: source.url,
                    maxPixelSize: source.maxPixelSize
                ) != nil {
                    warmed += 1
                    break
                }
            }
        }

        return warmed
    }

    private static func displayImage(for sources: [ThumbnailImageSource], image: NSImage?, imageKey: String?) -> NSImage? {
        if let image, let imageKey, sources.contains(where: { $0.key == imageKey }) {
            return image
        }
        return sources.lazy.compactMap { ThumbnailImageCache.shared.image(forKey: $0.key) }.first
    }

    static func cachedAspectRatio(for item: ReferenceItem) -> CGFloat? {
        guard let store = LociPersistentStore.shared else { return nil }
        return imageSources(for: item, store: store)
            .lazy
            .compactMap { ThumbnailImageCache.shared.aspectRatio(forKey: $0.key) }
            .first
    }

    private static func loadImage(from url: URL, key: String, maxPixelSize: Int) async -> NSImage? {
        await ThumbnailImageCache.shared.loadImage(forKey: key, from: url, on: thumbnailQueue, maxPixelSize: maxPixelSize)
    }

    private static func imageSources(for item: ReferenceItem, store: LociPersistentStore) -> [ThumbnailImageSource] {
        var sources: [ThumbnailImageSource] = []
        if let thumbPath = item.thumbnailPath {
            let thumbURL = store.thumbnailsURL.appendingPathComponent(thumbPath)
            if FileManager.default.fileExists(atPath: thumbURL.path) {
                sources.append(ThumbnailImageSource(key: "thumb:\(thumbPath)", url: thumbURL, maxPixelSize: 512))
            }
        }

        if item.canPreviewOriginalImage {
            let originalURL = store.originalsURL.appendingPathComponent(item.fileName)
            if FileManager.default.fileExists(atPath: originalURL.path) {
                sources.append(ThumbnailImageSource(key: "original:\(item.fileName)", url: originalURL, maxPixelSize: 512))
            }
        }

        return sources
    }

    @ViewBuilder
    private var proceduralContent: some View {
        ThumbnailBackdrop(item: item)

        ImportedReferenceGraphic(item: item, xBookmarkPayload: xBookmarkPayload)
    }
}

private enum ImportedPreviewKind {
    case xLink
    case website
    case note
    case document
    case file
}

private extension ReferenceItem {
    var prefersImportPreview: Bool {
        isInbox || subtitle.hasPrefix("http://") || subtitle.hasPrefix("https://") || subtitle == "Quick Note"
    }

    var importedPreviewKind: ImportedPreviewKind {
	        let loweredURL = subtitle.lowercased()
	        let ext = fileName.split(separator: ".").last.map { String($0).lowercased() } ?? ""

	        if isXBookmark {
	            return .xLink
	        }
	        if kind == .website {
	            return .website
	        }
	        if loweredURL.hasPrefix("http://") || loweredURL.hasPrefix("https://") || ext == "webloc" || ext == "html" || ext == "htm" {
	            return .website
	        }
	        if subtitle == "Quick Note" || ext == "md" || ext == "txt" || ext == "rtf" {
	            return .note
	        }
	        if kind == .typography {
	            return .document
	        }
	        if ["pdf", "doc", "docx", "pages", "key", "ppt", "pptx", "xls", "xlsx"].contains(ext) {
	            return .document
	        }
        return .file
    }

    var displayDomain: String {
        guard let url = URL(string: subtitle), let host = url.host(percentEncoded: false) else {
            return subtitle.isEmpty ? fileName : subtitle
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    var fileExtensionLabel: String {
        let ext = fileName.split(separator: ".").last.map { String($0).uppercased() } ?? "FILE"
        return ext.isEmpty || ext == fileName.uppercased() ? "FILE" : ext
    }

    var canPreviewOriginalImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "heic", "heif", "bmp"].contains(fileExtension)
    }
}

private struct ImportedReferenceGraphic: View {
    var item: ReferenceItem
    var xBookmarkPayload: XBookmarkPayloadSummary?

    var body: some View {
        switch item.importedPreviewKind {
        case .xLink:
            XWebsitePreviewGraphic(item: item, xBookmarkPayload: xBookmarkPayload)
        case .website:
            ImportedWebsitePreviewGraphic(item: item)
        case .note:
            NotePreviewGraphic(item: item)
        case .document:
            DocumentPreviewGraphic(item: item)
        case .file:
            FilePreviewGraphic(item: item)
        }
    }
}

private struct ImportedWebsitePreviewGraphic: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let accent = item.theme.colors.dropFirst().first ?? .gray

            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 1.0, green: 0.36, blue: 0.32)).frame(width: 5, height: 5)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.20)).frame(width: 5, height: 5)
                    Circle().fill(Color(red: 0.24, green: 0.78, blue: 0.33)).frame(width: 5, height: 5)

                    Text(item.displayDomain)
                        .lociFont(size: max(6, size.width * 0.045), weight: .semibold, relativeTo: .body)
                        .lineLimit(1)
                        .foregroundStyle(.black.opacity(0.42))
                        .padding(.leading, 5)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: size.height * 0.17)
                .background(Color.white.opacity(0.92))

                ZStack(alignment: .topLeading) {
                    LinearGradient(
                        colors: [accent.opacity(0.22), Color.white, Color.black.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

	                    VStack(alignment: .leading, spacing: size.height * 0.050) {
	                        Text(item.title)
	                            .lociFont(size: max(10, min(18, size.width * 0.075)), weight: .semibold, relativeTo: .body)
	                            .lineLimit(2)
	                            .minimumScaleFactor(0.78)
	                            .foregroundStyle(.black.opacity(0.78))

	                        Text(item.displayDomain)
	                            .lociFont(size: max(7, min(11, size.width * 0.043)), weight: .medium, relativeTo: .body)
	                            .lineLimit(1)
	                            .foregroundStyle(.black.opacity(0.40))

                        HStack(spacing: size.width * 0.035) {
                            ForEach(0..<3) { index in
                                VStack(alignment: .leading, spacing: 5) {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(index == 1 ? accent.opacity(0.56) : Color.black.opacity(0.08))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.black.opacity(0.18))
                                        .frame(height: 4)
                                }
                            }
                        }

                        HStack(spacing: 5) {
                            ForEach(0..<5) { index in
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(index == 0 ? accent.opacity(0.34) : Color.black.opacity(0.075))
                                    .frame(height: size.height * 0.16)
                            }
                        }
                    }
                    .padding(size.width * 0.075)
                }
            }
            .frame(width: size.width * 0.88, height: size.height * 0.74)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.14), radius: 12, y: 7)
            .position(x: size.width * 0.5, y: size.height * 0.52)
        }
    }
}

private struct XMediaBookmarkGraphic: View {
    var item: ReferenceItem
    var image: NSImage
    var xBookmarkPayload: XBookmarkPayloadSummary?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let card = XBookmarkDisplay.cardData(item: item, payload: xBookmarkPayload)
            let cardWidth = size.width * 0.90
            let cardHeight = size.height * 0.90
            let mediaHeight = cardHeight * 0.53

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cardWidth, height: mediaHeight)
                        .clipped()

                    Label(card.mediaBadge ?? "Saved", systemImage: "bookmark.fill")
                        .labelStyle(.iconOnly)
                        .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(.white)
                        .frame(width: 25, height: 25)
                        .background(.black.opacity(0.48), in: Circle())
                        .padding(8)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                        .frame(height: 0.8)
                }

                VStack(alignment: .leading, spacing: 7) {
                    XBookmarkCardHeader(card: card, compact: true)

                    Text(card.text)
                        .lociFont(size: 10.5, weight: .medium, relativeTo: .caption)
                        .lineSpacing(2)
                        .foregroundStyle(card.hasPostText ? .black.opacity(0.78) : .black.opacity(0.42))
                        .lineLimit(3)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    XBookmarkMetaRow(
                        icon: card.mediaBadge == nil ? "bookmark.fill" : "photo.on.rectangle.angled",
                        text: card.mediaBadge ?? card.metaLabel
                    )
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.075), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.10), radius: 10, y: 5)
            .position(x: size.width * 0.5, y: size.height * 0.5)
        }
    }
}

private struct XWebsitePreviewGraphic: View {
    var item: ReferenceItem
    var xBookmarkPayload: XBookmarkPayloadSummary?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let card = XBookmarkDisplay.cardData(item: item, payload: xBookmarkPayload)
            let cardWidth = min(size.width * 0.86, 380)
            let cardHeight = min(size.height * 0.78, max(148, cardWidth * 0.72))
            let bodySize = min(14, max(10.5, cardWidth * 0.042))

            VStack(alignment: .leading, spacing: 0) {
                XBookmarkCardHeader(card: card, compact: false)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                Text(card.text)
                    .lociFont(size: bodySize, weight: .medium, relativeTo: .body)
                    .lineSpacing(2.4)
                    .foregroundStyle(card.hasPostText ? .black.opacity(0.78) : .black.opacity(0.58))
                    .lineLimit(card.hasPostText ? 5 : 3)
                    .minimumScaleFactor(0.82)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)

                Spacer(minLength: 0)

                XBookmarkMetaRow(
                    icon: card.hasPostText ? "bookmark.fill" : "clock.badge.checkmark",
                    text: card.hasPostText ? card.metaLabel : "Post details pending"
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.022))
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.07), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.10), radius: 10, y: 5)
            .position(x: size.width * 0.5, y: size.height * 0.51)
        }
    }
}

private struct XBookmarkCardHeader: View {
    var card: XBookmarkCardData
    var compact: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle().fill(Color.black)
                Text("X")
                    .lociFont(size: compact ? 8.5 : 9, weight: .bold, relativeTo: .body)
                    .foregroundStyle(.white)
            }
            .frame(width: compact ? 22 : 24, height: compact ? 22 : 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(card.name)
                    .lociFont(size: compact ? 9.5 : 10, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(.black.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                Text(card.handle ?? card.sourceLabel)
                    .lociFont(size: compact ? 7.5 : 7.8, weight: .medium, relativeTo: .body)
                    .foregroundStyle(.black.opacity(0.42))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)

            if !compact {
                Image(systemName: card.hasPostText ? "text.quote" : "arrow.clockwise")
                    .lociFont(size: 9, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.30))
                    .frame(width: 20, height: 20)
                    .background(Color.black.opacity(0.035), in: Circle())
            }
        }
    }
}

private struct XBookmarkMetaRow: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
        }
        .lociFont(size: 7.8, weight: .semibold, relativeTo: .caption2)
        .foregroundStyle(.black.opacity(0.36))
    }
}

private struct XLinkPreviewGraphic: View {
    var item: ReferenceItem

    private var previewParts: (author: String, text: String) {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return ("X", "Bookmarked post") }
        if let separator = title.range(of: ": ") {
            let author = String(title[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(title[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !author.isEmpty, !text.isEmpty {
                return (author, text)
            }
        }
        if title.localizedCaseInsensitiveContains("x bookmark") {
            return ("X", "Bookmarked post")
        }
        return (title, "Bookmarked post")
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let parts = previewParts
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 1.0, green: 0.36, blue: 0.32)).frame(width: 5, height: 5)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.20)).frame(width: 5, height: 5)
                    Circle().fill(Color(red: 0.24, green: 0.78, blue: 0.33)).frame(width: 5, height: 5)
                    Text("x.com")
                        .lociFont(size: max(6, size.width * 0.044), weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.black.opacity(0.40))
                        .padding(.leading, 5)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: size.height * 0.17)
                .background(Color.white.opacity(0.94))

                VStack(alignment: .leading, spacing: size.height * 0.050) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().fill(Color.black)
                            Text("X")
                                .lociFont(size: max(9, size.width * 0.090), weight: .bold, relativeTo: .body)
                                .foregroundStyle(.white)
                        }
                        .frame(width: size.width * 0.15, height: size.width * 0.15)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(parts.author)
                                .lociFont(size: max(7, size.width * 0.055), weight: .semibold, relativeTo: .body)
                                .lineLimit(1)
                                .foregroundStyle(.black.opacity(0.82))
                            Text("Bookmarked post")
                                .lociFont(size: max(6, size.width * 0.040), weight: .medium, relativeTo: .body)
                                .foregroundStyle(.black.opacity(0.36))
                        }
                        Spacer(minLength: 0)
                    }

                    Text(parts.text)
                        .lociFont(size: max(8, size.width * 0.052), weight: .medium, relativeTo: .body)
                        .lineLimit(3)
                        .foregroundStyle(.black.opacity(0.74))
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left")
                        Image(systemName: "arrow.2.squarepath")
                        Image(systemName: "heart")
                        Spacer(minLength: 0)
                    }
                    .lociFont(size: max(7, size.width * 0.045), weight: .semibold, relativeTo: .body)
                    .foregroundStyle(.black.opacity(0.34))
                }
                .padding(size.width * 0.075)
                .background(
                    LinearGradient(
                        colors: [Color.white, Color.black.opacity(0.025)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .frame(width: size.width * 0.88, height: size.height * 0.76)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.12), radius: 11, y: 6)
            .position(x: size.width * 0.5, y: size.height * 0.52)
        }
    }
}

private struct NotePreviewGraphic: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let accent = item.theme.colors.dropFirst().first ?? .gray
            let cardWidth = min(size.width * 0.76, 360)
            let cardHeight = min(size.height * 0.66, max(138, cardWidth * 0.76))
            let padding = min(22, max(13, cardWidth * 0.085))
            let iconSize = min(22, max(12, cardWidth * 0.060))
            let labelSize = min(12, max(7, cardWidth * 0.034))
            let titleSize = min(22, max(12, cardWidth * 0.058))
            let lineHeight = min(5, max(3, cardWidth * 0.012))

            VStack(alignment: .leading, spacing: min(14, cardHeight * 0.050)) {
                HStack {
                    Image(systemName: "note.text")
                        .lociFont(size: iconSize, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(accent.opacity(0.88))
                    Spacer()
                    Text("NOTE")
                        .lociFont(size: labelSize, weight: .bold, relativeTo: .body)
                        .foregroundStyle(.black.opacity(0.28))
                }

                Text(item.title)
                    .lociFont(size: titleSize, weight: .semibold, relativeTo: .body)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .foregroundStyle(.black.opacity(0.78))

                ForEach(0..<5) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(index == 0 ? 0.24 : 0.13))
                        .frame(width: cardWidth * [0.68, 0.78, 0.55, 0.72, 0.42][index], height: lineHeight)
                }
                Spacer(minLength: 0)
            }
            .padding(padding)
            .frame(width: cardWidth, height: cardHeight)
            .background(Color(red: 1.0, green: 0.985, blue: 0.88), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(accent.opacity(0.42))
                    .frame(height: min(4, max(2.5, cardHeight * 0.012)))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
            .rotationEffect(.degrees(-1.2))
            .clipped()
            .position(x: size.width * 0.50, y: size.height * 0.50)
        }
    }
}

private struct DocumentPreviewGraphic: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let accent = item.theme.colors.dropFirst().first ?? .gray
            VStack(alignment: .leading, spacing: size.height * 0.045) {
                HStack {
                    Text(item.fileExtensionLabel)
                        .lociFont(size: max(8, size.width * 0.065), weight: .bold, relativeTo: .body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.88), in: Capsule())
                    Spacer()
                    Image(systemName: "doc.text")
                        .lociFont(size: max(9, size.width * 0.075), weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.black.opacity(0.30))
                }

                Text(item.title)
                    .lociFont(size: max(8, size.width * 0.062), weight: .semibold, relativeTo: .body)
                    .lineLimit(2)
                    .foregroundStyle(.black.opacity(0.74))

                ForEach(0..<7) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index == 2 ? accent.opacity(0.35) : Color.black.opacity(0.13))
                        .frame(width: size.width * [0.72, 0.58, 0.76, 0.64, 0.70, 0.50, 0.62][index], height: 4)
                }
                Spacer(minLength: 0)
            }
            .padding(size.width * 0.10)
            .frame(width: size.width * 0.74, height: size.height * 0.82)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .topTrailing) {
                TriangleFold()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: size.width * 0.16, height: size.width * 0.16)
                    .padding(1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.14), radius: 12, y: 7)
            .rotationEffect(.degrees(0.8))
            .position(x: size.width * 0.5, y: size.height * 0.52)
        }
    }
}

private struct FilePreviewGraphic: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let accent = item.theme.colors.dropFirst().first ?? .gray
            VStack(spacing: size.height * 0.045) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.18))
                    Image(systemName: item.kindSymbol)
                        .lociFont(size: max(20, size.width * 0.22), weight: .semibold, relativeTo: .body)
                        .foregroundStyle(accent.opacity(0.88))
                }
                .frame(width: size.width * 0.42, height: size.width * 0.42)

                Text(item.title)
                    .lociFont(size: max(8, size.width * 0.060), weight: .semibold, relativeTo: .body)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.black.opacity(0.72))

                Text(item.fileExtensionLabel)
                    .lociFont(size: max(6, size.width * 0.042), weight: .bold, relativeTo: .body)
                    .foregroundStyle(.black.opacity(0.32))
            }
            .padding(size.width * 0.10)
            .frame(width: size.width * 0.76, height: size.height * 0.74)
            .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.07), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.11), radius: 10, y: 6)
            .position(x: size.width * 0.5, y: size.height * 0.52)
        }
    }
}

private struct TriangleFold: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct ThumbnailBackdrop: View {
    var item: ReferenceItem

    var body: some View {
        ZStack {
            Rectangle()
                .fill(background)

            if usesDarkBackdrop {
                LinearGradient(
                    colors: [.white.opacity(0.06), .black.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [.white.opacity(0.62), accent.opacity(0.045), .black.opacity(0.018)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var usesDarkBackdrop: Bool {
        (item.theme == .graphite || item.theme == .dusk)
            && item.importedPreviewKind != .note
            && item.importedPreviewKind != .xLink
    }

    private var accent: Color {
        item.theme.colors.dropFirst().first ?? .gray
    }

    private var background: Color {
        if item.importedPreviewKind == .xLink {
            return Color(red: 0.972, green: 0.976, blue: 0.980)
        }
        if item.importedPreviewKind == .note {
            return Color(red: 0.982, green: 0.980, blue: 0.968)
        }

        return switch item.theme {
        case .aurora:
            Color(red: 0.965, green: 0.975, blue: 0.985)
        case .graphite:
            Color(red: 0.12, green: 0.12, blue: 0.125)
        case .citrus:
            Color(red: 0.982, green: 0.972, blue: 0.945)
        case .marine:
            Color(red: 0.955, green: 0.968, blue: 0.985)
        case .studio:
            Color(red: 0.984, green: 0.962, blue: 0.968)
        case .signal:
            Color(red: 0.986, green: 0.958, blue: 0.946)
        case .dusk:
            Color(red: 0.11, green: 0.112, blue: 0.13)
        case .paper:
            Color(red: 0.972, green: 0.968, blue: 0.952)
        }
    }
}

struct PhoneReferenceGraphic: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let dark = item.theme == .graphite || item.theme == .dusk

            RoundedRectangle(cornerRadius: size.width * 0.085, style: .continuous)
                .fill(Color.black.opacity(dark ? 0.74 : 0.82))
                .frame(width: size.width * 0.43, height: size.height * 0.82)
                .overlay {
                    RoundedRectangle(cornerRadius: size.width * 0.068, style: .continuous)
                        .fill(dark ? Color(red: 0.13, green: 0.14, blue: 0.17) : Color.white)
                        .padding(size.width * 0.026)
                        .overlay {
                            PhoneScreenContent(item: item)
                                .padding(size.width * 0.05)
                        }
                }
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(.black.opacity(dark ? 0.46 : 0.18))
                        .frame(width: size.width * 0.105, height: 4)
                        .padding(.top, size.height * 0.045)
                }
                .shadow(color: .black.opacity(0.22), radius: size.width * 0.035, y: size.height * 0.025)
                .rotationEffect(.degrees(CGFloat((abs(item.title.hashValue) % 7) - 3)))
                .position(x: size.width * 0.52, y: size.height * 0.52)
        }
    }
}

private struct PhoneScreenContent: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let accent = item.theme.colors.dropFirst().first ?? .gray
            VStack(alignment: .leading, spacing: size.height * 0.035) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(0.36))
                    .frame(height: size.height * 0.23)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.82)).frame(width: size.width * 0.42, height: 4)
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.46)).frame(width: size.width * 0.28, height: 4)
                        }
                        .padding(8)
                    }

                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(index == 0 ? Color.black.opacity(0.78) : Color.black.opacity(0.10))
                            .frame(height: size.height * 0.12)
                    }
                }

                ForEach(0..<5) { index in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(index.isMultiple(of: 2) ? accent.opacity(0.30) : Color.black.opacity(0.12))
                            .frame(width: 9, height: 9)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.black.opacity(index == 1 ? 0.52 : 0.18))
                            .frame(height: 4)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}

struct LaptopReferenceGraphic: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                    .frame(width: size.width * 0.78, height: size.height * 0.56)
                    .overlay {
                        BrowserChrome(item: item, compact: true)
                            .padding(size.width * 0.026)
                    }
                Capsule()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: size.width * 0.88, height: 8)
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(.white.opacity(0.16))
                            .frame(width: size.width * 0.18, height: 2)
                            .padding(.top, 2)
                    }
            }
            .shadow(color: .black.opacity(0.20), radius: 8, y: 7)
            .position(x: size.width * 0.50, y: size.height * 0.57)
        }
    }
}

struct WebsiteReferenceGraphic: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            BrowserChrome(item: item, compact: false)
                .frame(width: size.width * 0.86, height: size.height * 0.72)
                .shadow(color: .black.opacity(0.12), radius: 9, y: 7)
                .rotationEffect(.degrees(CGFloat((abs(item.fileName.hashValue) % 5) - 2) * 0.55))
                .position(x: size.width * 0.50, y: size.height * 0.52)
        }
    }
}

private struct BrowserChrome: View {
    var item: ReferenceItem
    var compact: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let accent = item.theme.colors.dropFirst().first ?? .gray
            let dark = item.theme == .graphite || item.theme == .dusk
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Circle().fill(Color(red: 1.0, green: 0.36, blue: 0.32)).frame(width: compact ? 4 : 5)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.20)).frame(width: compact ? 4 : 5)
                    Circle().fill(Color(red: 0.24, green: 0.78, blue: 0.33)).frame(width: compact ? 4 : 5)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.black.opacity(dark ? 0.18 : 0.075))
                        .frame(width: size.width * 0.33, height: compact ? 6 : 8)
                        .padding(.leading, 6)
                    Spacer()
                }
                .padding(.horizontal, compact ? 7 : 9)
                .frame(height: compact ? 17 : 22)
                .background(dark ? Color.white.opacity(0.08) : Color.white.opacity(0.82))

                VStack(alignment: .leading, spacing: size.height * 0.045) {
                    HStack(alignment: .top, spacing: size.width * 0.055) {
                        VStack(alignment: .leading, spacing: 5) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(dark ? 0.18 : 0.62)).frame(width: size.width * 0.34, height: compact ? 6 : 8)
                            RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(dark ? 0.12 : 0.18)).frame(width: size.width * 0.28, height: compact ? 4 : 5)
                            RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(dark ? 0.12 : 0.18)).frame(width: size.width * 0.22, height: compact ? 4 : 5)
                        }
                        RoundedRectangle(cornerRadius: compact ? 7 : 10, style: .continuous)
                            .fill(accent.opacity(dark ? 0.72 : 0.82))
                            .frame(height: size.height * 0.23)
                    }

                    HStack(spacing: size.width * 0.035) {
                        ForEach(0..<3) { index in
                            VStack(alignment: .leading, spacing: 5) {
                                RoundedRectangle(cornerRadius: compact ? 4 : 6, style: .continuous)
                                    .fill(index == 1 ? accent.opacity(0.50) : Color.black.opacity(dark ? 0.16 : 0.10))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.black.opacity(dark ? 0.16 : 0.24))
                                    .frame(height: compact ? 3 : 4)
                            }
                        }
                    }

                    HStack(spacing: size.width * 0.025) {
                        ForEach(0..<5) { index in
                            RoundedRectangle(cornerRadius: 3)
                            .fill(index == 2 ? accent.opacity(0.24) : Color.black.opacity(dark ? 0.14 : 0.09))
                                .frame(height: compact ? 18 : 24)
                        }
                    }
                }
                .padding(compact ? 9 : 13)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(dark ? Color(red: 0.11, green: 0.115, blue: 0.14) : Color.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                    .stroke(Color.black.opacity(dark ? 0.12 : 0.08), lineWidth: 0.7)
            }
        }
    }
}

struct AppReferenceGraphic: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let accent = item.theme.colors.dropFirst().first ?? .gray
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.94))
                .frame(width: size.width * 0.78, height: size.height * 0.70)
                .overlay {
                    HStack(spacing: 0) {
                        VStack(spacing: 7) {
                            ForEach(0..<5) { index in
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(index == 1 ? accent.opacity(0.26) : Color.black.opacity(0.08))
                                    .frame(width: size.width * 0.11, height: 11)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 11)
                        .frame(width: size.width * 0.19)
                        .background(Color.black.opacity(0.035))

                        VStack(alignment: .leading, spacing: size.height * 0.045) {
                            HStack {
                                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.62)).frame(width: size.width * 0.26, height: 7)
                                Spacer()
                                Circle().fill(accent.opacity(0.32)).frame(width: 12)
                            }
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.22))
                                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.07))
                            }
                            HStack(spacing: 7) {
                                ForEach(0..<3) { index in
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(index == 0 ? Color.black.opacity(0.72) : Color.black.opacity(0.09))
                                }
                            }
                            VStack(spacing: 5) {
                                ForEach(0..<4) { index in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.black.opacity(index == 2 ? 0.28 : 0.11))
                                        .frame(height: 5)
                                }
                            }
                        }
                        .padding(13)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 6)
                .position(x: size.width * 0.50, y: size.height * 0.52)
        }
    }
}

struct ProductReferenceGraphic: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let accent = item.theme.colors.dropFirst().first ?? .gray
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.white.opacity(0.86))
                    .frame(width: size.width * 0.56, height: size.height * 0.58)
                    .rotationEffect(.degrees(-6))
                    .offset(x: -size.width * 0.08, y: size.height * 0.02)
                    .shadow(color: .black.opacity(0.10), radius: 7, y: 5)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.98), accent.opacity(0.38), .black.opacity(0.26)],
                            center: .topLeading,
                            startRadius: 4,
                            endRadius: size.width * 0.34
                        )
                    )
                    .frame(width: size.width * 0.40, height: size.width * 0.40)
                    .offset(x: size.width * 0.14, y: size.height * 0.05)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 6)

                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.56)).frame(width: size.width * 0.25, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.16)).frame(width: size.width * 0.36, height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.12)).frame(width: size.width * 0.30, height: 4)
                }
                .offset(x: -size.width * 0.12, y: -size.height * 0.24)
            }
        }
    }
}

struct TypographyReferenceGraphic: View {
    var item: ReferenceItem

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let accent = item.theme.colors.dropFirst().first ?? .gray
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.84))
                    .frame(width: size.width * 0.72, height: size.height * 0.74)
                    .rotationEffect(.degrees(CGFloat((abs(item.title.hashValue) % 7) - 3)))
                    .shadow(color: .black.opacity(0.11), radius: 7, y: 5)

                VStack(alignment: .leading, spacing: size.height * 0.035) {
                    Text(item.title.prefix(2).uppercased())
                        .lociFont(size: min(size.width, size.height) * 0.22, weight: .black, design: .serif, relativeTo: .body)
                        .foregroundStyle(Color.black.opacity(0.82))
                        .lineLimit(1)
                    RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.58)).frame(width: size.width * 0.36, height: 5)
                    ForEach(0..<6) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.black.opacity(index == 0 ? 0.42 : 0.18))
                            .frame(width: size.width * CGFloat(0.48 - Double(index % 3) * 0.06), height: 4)
                    }
                }
                .frame(width: size.width * 0.52, alignment: .leading)
                .offset(x: size.width * 0.015)
            }
        }
    }
}
