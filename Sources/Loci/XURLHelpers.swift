import Foundation

extension URL {
    var isXFamilyURL: Bool {
        guard var host = host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return false
        }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host == "x.com"
            || host.hasSuffix(".x.com")
            || host == "twitter.com"
            || host.hasSuffix(".twitter.com")
    }
}

extension ReferenceItem {
    var isXBookmark: Bool {
        guard let url = URL(string: subtitle) else {
            let lowered = subtitle.lowercased()
            return lowered.contains("x.com/") || lowered.contains("twitter.com/")
        }
        return url.isXFamilyURL
    }
}

struct XBookmarkParts: Hashable {
    var name: String
    var handle: String?
    var text: String
    var hasPostText: Bool
}

struct XBookmarkCardData: Hashable {
    var name: String
    var handle: String?
    var text: String
    var hasPostText: Bool
    var sourceLabel: String
    var metaLabel: String
    var mediaBadge: String?
}

enum XBookmarkDisplay {
    static func title(author: String?, text: String?, fallback: String) -> String {
        let cleanAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let clippedText = cleanText.map { String($0.prefix(260)) }
        if let cleanAuthor, !cleanAuthor.isEmpty, let clippedText, !clippedText.isEmpty {
            return "\(cleanAuthor): \(clippedText)"
        }
        if let clippedText, !clippedText.isEmpty {
            return clippedText
        }
        if let cleanAuthor, !cleanAuthor.isEmpty {
            return cleanAuthor
        }
        return fallback
    }

    static func parts(from title: String) -> XBookmarkParts {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return missingTextParts(name: "X", handle: nil)
        }

        if let separator = trimmed.range(of: ": ") {
            let author = String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let authorParts = Self.authorParts(from: author)
            if !text.isEmpty {
                return XBookmarkParts(
                    name: authorParts.name,
                    handle: authorParts.handle,
                    text: String(text.prefix(360)),
                    hasPostText: true
                )
            }
        }

        if trimmed.localizedCaseInsensitiveContains("x bookmark") {
            return missingTextParts(name: "X", handle: nil)
        }

        let authorParts = Self.authorParts(from: trimmed)
        return missingTextParts(name: authorParts.name, handle: authorParts.handle)
    }

    static func cardData(item: ReferenceItem, payload: XBookmarkPayloadSummary?) -> XBookmarkCardData {
        let author = payload?.note ?? payload?.title
        let text = payload?.selectedText ?? payload?.articleMarkdown
        let title = title(author: author, text: text, fallback: item.title)
        let parts = parts(from: title)
        let sourceLabel = sourceLabel(from: payload?.url ?? item.subtitle)
        let metaParts = [
            relativeDateLabel(from: payload?.sourceCreatedAt),
            mediaSummary(payload: payload)
        ].compactMap { $0 }

        return XBookmarkCardData(
            name: parts.name,
            handle: parts.handle,
            text: parts.text,
            hasPostText: parts.hasPostText,
            sourceLabel: sourceLabel,
            metaLabel: metaParts.isEmpty ? sourceLabel : metaParts.joined(separator: " · "),
            mediaBadge: mediaSummary(payload: payload)
        )
    }

    private static func missingTextParts(name: String, handle: String?) -> XBookmarkParts {
        XBookmarkParts(
            name: name,
            handle: handle,
            text: "Saved X bookmark. Sync adds the original post text and media when available.",
            hasPostText: false
        )
    }

    private static func authorParts(from author: String) -> (name: String, handle: String?) {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("X", nil) }

        let pieces = trimmed.split(separator: " ")
        guard let handlePiece = pieces.last(where: { $0.hasPrefix("@") }) else {
            return (trimmed, nil)
        }

        let handle = String(handlePiece)
        let name = trimmed
            .replacingOccurrences(of: handle, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? handle : name, handle)
    }

    private static func sourceLabel(from value: String?) -> String {
        guard let value,
              let url = URL(string: value),
              url.isXFamilyURL else {
            return "x.com/post"
        }
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if let username = components.first,
           !["i", "home", "explore", "notifications", "messages", "search", "settings"].contains(username.lowercased()) {
            return "@\(username)"
        }
        return "x.com/post"
    }

    private static func mediaSummary(payload: XBookmarkPayloadSummary?) -> String? {
        let explicitCount = payload?.mediaCount ?? 0
        let mediaURLCount = mediaURLs(payload: payload).count
        let count = max(explicitCount, mediaURLCount)
        guard count > 0 else { return nil }

        let type = payload?.mediaTypes?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty }

        let noun: String
        switch type {
        case "video":
            noun = count == 1 ? "video" : "videos"
        case "animated_gif":
            noun = count == 1 ? "GIF" : "GIFs"
        default:
            noun = count == 1 ? "image" : "images"
        }
        return "\(count) \(noun)"
    }

    private static func mediaURLs(payload: XBookmarkPayloadSummary?) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        for value in (payload?.imageURLs ?? []) + [payload?.ogImageURL].compactMap({ $0 }) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            urls.append(trimmed)
        }
        return urls
    }

    private static func relativeDateLabel(from value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? {
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            return fallback.date(from: value)
        }()
        guard let date else { return nil }

        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: date, to: Date())
        if let day = components.day, day >= 7 {
            let display = DateFormatter()
            display.dateFormat = "MMM d"
            return display.string(from: date)
        }
        if let day = components.day, day > 0 {
            return "\(day)d ago"
        }
        if let hour = components.hour, hour > 0 {
            return "\(hour)h ago"
        }
        let minute = max(1, components.minute ?? 0)
        return "\(minute)m ago"
    }
}
