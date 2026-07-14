import CryptoKit
import Foundation

enum GraphRelation: String, Hashable, CaseIterable, Identifiable {
    case collection = "Same Collection"
    case kind = "Same Type"
    case concept = "Concept"
    case contradiction = "Contradiction"
    case crossRef = "Cross Reference"
    case domain = "Same Domain"
    case related = "Related"
    case group = "Same Group"
    case authoredBy = "Authored By"
    case containsMedia = "Contains Media"
    case tagged = "Tagged"

    var id: String { rawValue }

    var color: String {
        switch self {
        case .collection: return "collection"
        case .kind: return "kind"
        case .concept: return "concept"
        case .contradiction: return "contradiction"
        case .crossRef: return "crossref"
        case .domain: return "domain"
        case .related: return "related"
        case .group: return "group"
        case .authoredBy: return "author"
        case .containsMedia: return "media"
        case .tagged: return "tag"
        }
    }
}

enum VaultGraphNodeKind: String, Hashable, CaseIterable, Identifiable {
    case reference
    case xAuthor
    case xMedia
    case domain
    case tag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reference: "Reference"
        case .xAuthor: "X Author"
        case .xMedia: "Media"
        case .domain: "Domain"
        case .tag: "Tag"
        }
    }
}

struct VaultDocument: Identifiable, Hashable {
    var id: UUID
    var title: String
    var slug: String
    var relativePath: String
    var outgoingLinks: [String]
    var outgoingRelations: [String: GraphRelation]
    var backlinks: [String]
    var tags: [String]
    var kind: VisualKind
    var group: ReferenceGroup
}

struct VaultGraphNode: Identifiable, Hashable {
    var slug: String
    var title: String
    var group: ReferenceGroup
    var kind: VaultGraphNodeKind = .reference
    var subtitle: String?

    var id: String { slug }
}

struct VaultGraphEdge: Identifiable, Hashable {
    var source: String
    var target: String
    var relation: GraphRelation

    var id: String { "\(source)->\(target):\(relation.rawValue)" }
}

struct VaultGraph: Hashable {
    var nodes: [VaultGraphNode]
    var edges: [VaultGraphEdge]
}

struct MarkdownVaultSnapshot: Hashable {
    var rootURL: URL
    var documents: [VaultDocument]
    var graph: VaultGraph
    var items: [ReferenceItem]

    var documentSlugsByID: [ReferenceItem.ID: String] {
        Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.slug) })
    }
}

enum MarkdownVault {
    static let vaultFolderName = "\(AppBrand.name) Vault"

    static func lightweightSnapshot(
        collections: [ReferenceCollection],
        items: [ReferenceItem]
    ) -> MarkdownVaultSnapshot {
        let rootURL = defaultVaultURL()
        createVaultDirectories(at: rootURL)
        writeReadmeIfNeeded(at: rootURL)
        writeSystemFiles(at: rootURL)
        let activeItems = items.filter { !$0.isTrashed }
        return MarkdownVaultSnapshot(
            rootURL: rootURL,
            documents: [],
            graph: VaultGraph(nodes: [], edges: []),
            items: activeItems
        )
    }

    @discardableResult
    static func bootstrap(
        collections: [ReferenceCollection],
        items: [ReferenceItem],
        xPayloadsByReferenceID: [UUID: XBookmarkPayloadSummary] = [:]
    ) -> MarkdownVaultSnapshot {
        let rootURL = defaultVaultURL()
        createVaultDirectories(at: rootURL)
        writeReadmeIfNeeded(at: rootURL)
        writeSystemFiles(at: rootURL)

        let activeItems = items.filter { !$0.isTrashed }
        let slugsByID = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.id, slug(for: $0)) })
        var docs: [VaultDocument] = []

        for item in activeItems {
            docs.append(writeReferenceDocument(item, collections: collections, items: activeItems, slugsByID: slugsByID, rootURL: rootURL, existingDocuments: docs))
        }

        writeConceptPages(for: activeItems, rootURL: rootURL)
        let docsWithBacklinks = documentsWithBacklinks(docs)
        let graph = buildGraph(from: docsWithBacklinks, items: activeItems, xPayloadsByReferenceID: xPayloadsByReferenceID)
        writeIndexes(items: activeItems, documents: docsWithBacklinks, collections: collections, graph: graph, rootURL: rootURL)
        return MarkdownVaultSnapshot(rootURL: rootURL, documents: docsWithBacklinks, graph: graph, items: activeItems)
    }

    @discardableResult
    static func writeReference(
        _ item: ReferenceItem,
        collections: [ReferenceCollection],
        slugsByID: [ReferenceItem.ID: String],
        rootURL: URL,
        existing: MarkdownVaultSnapshot,
        xPayloadsByReferenceID: [UUID: XBookmarkPayloadSummary] = [:]
    ) -> MarkdownVaultSnapshot {
        createVaultDirectories(at: rootURL)
        let doc = writeReferenceDocument(
            item,
            collections: collections,
            items: existing.items,
            slugsByID: slugsByID.merging([item.id: slug(for: item)]) { current, _ in current },
            rootURL: rootURL,
            existingDocuments: existing.documents
        )

        var docs = existing.documents.filter { $0.id != item.id }
        docs.append(doc)
        let docsWithBacklinks = documentsWithBacklinks(docs)
        let updatedItems = existing.items.filter { $0.id != item.id } + [item]
        let graph = buildGraph(from: docsWithBacklinks, items: updatedItems, xPayloadsByReferenceID: xPayloadsByReferenceID)
        writeConceptPages(for: docsWithBacklinks, rootURL: rootURL)
        writeIndexes(items: nil, documents: docsWithBacklinks, collections: collections, graph: graph, rootURL: rootURL)
        return MarkdownVaultSnapshot(rootURL: rootURL, documents: docsWithBacklinks, graph: graph, items: updatedItems)
    }

    @discardableResult
    static func removeReference(
        _ item: ReferenceItem,
        existing: MarkdownVaultSnapshot,
        xPayloadsByReferenceID: [UUID: XBookmarkPayloadSummary] = [:]
    ) -> MarkdownVaultSnapshot {
        let slug = slug(for: item)
        try? FileManager.default.removeItem(at: existing.rootURL.appendingPathComponent("wiki/references/\(slug).md"))
        try? FileManager.default.removeItem(at: existing.rootURL.appendingPathComponent("References/\(slug).md"))

        let docs = documentsWithBacklinks(existing.documents.filter { $0.id != item.id })
        let remainingItems = existing.items.filter { $0.id != item.id }
        let graph = buildGraph(from: docs, items: remainingItems, xPayloadsByReferenceID: xPayloadsByReferenceID)
        writeIndexes(items: nil, documents: docs, collections: [], graph: graph, rootURL: existing.rootURL)
        return MarkdownVaultSnapshot(rootURL: existing.rootURL, documents: docs, graph: graph, items: remainingItems)
    }

    @discardableResult
    static func rebuildGraph(
        existing: MarkdownVaultSnapshot,
        items: [ReferenceItem],
        collections: [ReferenceCollection],
        xPayloadsByReferenceID: [UUID: XBookmarkPayloadSummary] = [:]
    ) -> MarkdownVaultSnapshot {
        let docs = documentsWithBacklinks(existing.documents)
        let activeItems = items.filter { !$0.isTrashed }
        let graph = buildGraph(from: docs, items: activeItems, xPayloadsByReferenceID: xPayloadsByReferenceID)
        writeIndexes(items: items.filter { !$0.isTrashed }, documents: docs, collections: collections, graph: graph, rootURL: existing.rootURL)
        return MarkdownVaultSnapshot(rootURL: existing.rootURL, documents: docs, graph: graph, items: items)
    }

    static func writeRawSourcePackage(
        for item: ReferenceItem,
        source: ImportSourceKind,
        payload: String,
        managedOriginalURL: URL? = nil,
        rootURL rootOverride: URL? = nil
    ) {
        let rootURL = rootOverride ?? defaultVaultURL()
        createVaultDirectories(at: rootURL)
        let slug = slug(for: item)
        let packageURL = rootURL.appendingPathComponent("raw/\(slug)", isDirectory: true)
        createDirectoryIfNeeded(packageURL)

        let metadata = rawMetadata(for: item, source: source, payload: payload, managedOriginalURL: managedOriginalURL)
        writeIfChanged(metadata, to: packageURL.appendingPathComponent("metadata.json"))
        writeIfMissing(rawSourceMarkdown(for: item, source: source, payload: payload), to: packageURL.appendingPathComponent("source.md"))
        writeIfMissing(extractedText(for: item, source: source, payload: payload), to: packageURL.appendingPathComponent("extracted.txt"))

        if let urlString = sourceURLString(for: source, payload: payload) {
            writeIfMissing(urlString + "\n", to: packageURL.appendingPathComponent("original.url"))
        }
        if let managedOriginalURL {
            writeIfMissing(managedOriginalURL.path + "\n", to: packageURL.appendingPathComponent("original-path.txt"))
        }
    }

    static func defaultVaultURL() -> URL {
        LibraryLocation.currentRootURL
    }

    static func exportObsidianVault() throws -> URL {
        let rootURL = defaultVaultURL()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "Z", with: "")
        let exportRoot = rootURL.appendingPathComponent("outputs/exports", isDirectory: true)
        let destination = exportRoot.appendingPathComponent("\(AppBrand.name)-Obsidian-\(stamp)", isDirectory: true)
        createDirectoryIfNeeded(destination)

        for folder in ["raw", "wiki", "system", "outputs"] {
            let source = rootURL.appendingPathComponent(folder, isDirectory: true)
            let target = destination.appendingPathComponent(folder, isDirectory: true)
            if folder == "outputs" {
                try copyDirectory(source, to: target, excludingRelativePrefixes: ["exports/"])
            } else {
                try copyDirectory(source, to: target)
            }
        }

        for file in ["README.md", "index.md", "log.md"] {
            let source = rootURL.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(file))
            }
        }

        return destination
    }

    static func markWikiPageReviewed(relativePath: String) {
        guard relativePath.hasPrefix("wiki/") else { return }
        let url = defaultVaultURL().appendingPathComponent(relativePath)
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
        content = replacingFrontmatterStatus(in: content, with: "reviewed")
        if !content.contains("## Human Review") {
            content += "\n\n## Human Review\n\n- Marked reviewed in \(AppBrand.name).\n"
        }
        writeIfChanged(content, to: url)
    }

    static func promoteWikiPage(relativePath: String) {
        guard relativePath.hasPrefix("wiki/") else { return }
        let rootURL = defaultVaultURL()
        let sourceURL = rootURL.appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: sourceURL, encoding: .utf8) else { return }
        let promoted = replacingFrontmatterStatus(in: content, with: "promoted")
        writeIfChanged(promoted, to: sourceURL)

        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = rootURL
            .appendingPathComponent("outputs/decisions", isDirectory: true)
            .appendingPathComponent("\(sourceName)-promoted.md")
        let output = """
        ---
        title: "\(escapedYAML(sourceName)) promoted"
        type: promoted-output
        source: "\(relativePath)"
        status: promoted
        ---

        # \(sourceName) Promoted

        Source wiki page: [\(relativePath)](../../\(relativePath))

        ## Why This Matters

        Promoted from Loci Creative Memory for reuse in decisions, boards, slides, or synthesis.

        ## Source Snapshot

        \(content)
        """
        writeIfChanged(output, to: outputURL)
    }

    static func slug(for item: ReferenceItem) -> String {
        let base = item.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = item.id.uuidString.prefix(8).lowercased()
        return "\(base.isEmpty ? "reference" : base)-\(suffix)"
    }

    static func managedOriginalPath(for item: ReferenceItem) -> URL? {
        let pathFile = defaultVaultURL()
            .appendingPathComponent("raw/\(slug(for: item))/original-path.txt")
        guard let text = try? String(contentsOf: pathFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    private static func writeReferenceDocument(
        _ item: ReferenceItem,
        collections: [ReferenceCollection],
        items: [ReferenceItem],
        slugsByID: [ReferenceItem.ID: String],
        rootURL: URL,
        existingDocuments: [VaultDocument]
    ) -> VaultDocument {
        let slug = slug(for: item)
        let content = markdownBody(for: item, collections: collections, items: items, slugsByID: slugsByID)
        let wikiURL = rootURL.appendingPathComponent("wiki/references/\(slug).md")
        let compatibilityURL = rootURL.appendingPathComponent("References/\(slug).md")
        writeReferenceIfNotCompiled(content, to: wikiURL)
        writeReferenceIfNotCompiled(content, to: compatibilityURL)

        let outgoingLinks = wikiLinks(in: content)
        let linkRelations = relatedWikiLinks(for: item, allItems: items, slugsByID: slugsByID)
        var outgoingRelations: [String: GraphRelation] = [:]
        for entry in linkRelations {
            outgoingRelations[entry.slug] = entry.relation
        }

        return VaultDocument(
            id: item.id,
            title: item.title,
            slug: slug,
            relativePath: "wiki/references/\(slug).md",
            outgoingLinks: outgoingLinks,
            outgoingRelations: outgoingRelations,
            backlinks: existingDocuments.filter { $0.id != item.id && $0.outgoingLinks.contains(slug) }.map(\.slug),
            tags: tags(for: item),
            kind: item.kind,
            group: item.group
        )
    }

    static func markdownBody(
        for item: ReferenceItem,
        collections: [ReferenceCollection],
        items: [ReferenceItem],
        slugsByID: [ReferenceItem.ID: String]
    ) -> String {
        let collectionName = item.collectionID.flatMap { id in collections.first { $0.id == id }?.name } ?? "Unfiled"
        let slug = slug(for: item)
        let allItems = Array(slugsByID.keys.compactMap { id in items.first(where: { $0.id == id }) })
        let relatedLinks = relatedWikiLinks(for: item, allItems: allItems, slugsByID: slugsByID)
        let linkBlock = relatedLinks.isEmpty ? "- Needs review: add related pages during compile.\n" : relatedLinks.map { "- [[\($0.slug)]] (\($0.relation.rawValue))" }.joined(separator: "\n") + "\n"
        let rawPath = "../raw/\(slug)/"

        return """
        ---
        id: "\(item.id.uuidString)"
        title: "\(escapedYAML(item.title))"
        type: reference
        kind: "\(item.kind.rawValue)"
        group: "\(item.group.rawValue)"
        collection: "\(escapedYAML(collectionName))"
        raw: "\(rawPath)"
        status: needs-review
        tags: [\(tags(for: item).map { "\"\($0)\"" }.joined(separator: ", "))]
        ---

        # \(item.title)

        > Compiled from [[\(slug)|raw source package]]. This page is safe for LLM maintenance; keep `raw/` immutable.

        ## Summary

        \(item.subtitle.isEmpty ? "Needs synthesis." : item.subtitle)

        ## Source

        - Raw package: [raw/\(slug)/](../../raw/\(slug)/)
        - Original file name: `\(item.fileName)`
        - Kind: \(item.kind.rawValue)
        - Group: \(item.group.rawValue)
        - Collection: \(collectionName)

        ## Connections

        \(linkBlock)
        ## Tags

        \(tags(for: item).map { "- #\($0)" }.joined(separator: "\n"))

        ## Compile Notes

        - Needs review: extract concepts, entities, contradictions, design features, and reusable patterns.
        - Suggested concept page: [[\(conceptSlug(for: item.group))]]
        - Suggested format page: [[\(conceptSlug(for: item.kind.rawValue))]]
        """
    }

    private static func relatedWikiLinks(for item: ReferenceItem, allItems: [ReferenceItem], slugsByID: [ReferenceItem.ID: String]) -> [(slug: String, relation: GraphRelation)] {
        var results: [(slug: String, relation: GraphRelation)] = []
        var seenSlugs = Set<String>()

        let sameCollection = allItems.filter { $0.collectionID == item.collectionID && $0.id != item.id && $0.collectionID != nil }
        for other in sameCollection.prefix(2) {
            guard let slug = slugsByID[other.id], !seenSlugs.contains(slug) else { continue }
            seenSlugs.insert(slug)
            results.append((slug, .collection))
        }

        if let host = hostKey(for: item) {
            let sameDomain = allItems.filter {
                $0.id != item.id && hostKey(for: $0) == host && !seenSlugs.contains(slugsByID[$0.id] ?? "")
            }
            for other in sameDomain.prefix(2) {
                guard let slug = slugsByID[other.id], !seenSlugs.contains(slug) else { continue }
                seenSlugs.insert(slug)
                results.append((slug, .domain))
            }
        }

        let sameKind = allItems.filter { $0.kind == item.kind && $0.id != item.id && !seenSlugs.contains(slugsByID[$0.id] ?? "") }
        for other in sameKind.prefix(1) {
            guard let slug = slugsByID[other.id], !seenSlugs.contains(slug) else { continue }
            seenSlugs.insert(slug)
            results.append((slug, .kind))
        }

        let sameGroup = allItems.filter { $0.group == item.group && $0.id != item.id && !seenSlugs.contains(slugsByID[$0.id] ?? "") }
        for other in sameGroup.prefix(1) {
            guard let slug = slugsByID[other.id], !seenSlugs.contains(slug) else { continue }
            seenSlugs.insert(slug)
            results.append((slug, .group))
        }

        let remaining = allItems.filter { $0.id != item.id && !seenSlugs.contains(slugsByID[$0.id] ?? "") }
        for other in remaining.prefix(max(0, 4 - results.count)) {
            guard let slug = slugsByID[other.id], !seenSlugs.contains(slug) else { continue }
            seenSlugs.insert(slug)
            results.append((slug, .related))
        }

        return results
    }

    private static func tags(for item: ReferenceItem) -> [String] {
        [
            item.kind.rawValue,
            item.group.rawValue.lowercased(),
            item.isInbox ? "inbox" : nil
        ].compactMap { $0 }
    }

    private static func wikiLinks(in markdown: String) -> [String] {
        let pattern = #"\[\[([^\]\|]+)(?:\|[^\]]+)?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return regex.matches(in: markdown, range: range).compactMap { match in
            guard let linkRange = Range(match.range(at: 1), in: markdown) else { return nil }
            return String(markdown[linkRange])
        }
    }

    private static func hostKey(for item: ReferenceItem) -> String? {
        guard let url = item.websiteURL,
              let host = url.host(percentEncoded: false)?.lowercased() else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func documentsWithBacklinks(_ documents: [VaultDocument]) -> [VaultDocument] {
        var backlinksBySlug: [String: [String]] = [:]
        for document in documents {
            for target in document.outgoingLinks {
                backlinksBySlug[target, default: []].append(document.slug)
            }
        }
        return documents.map { document in
            var copy = document
            copy.backlinks = backlinksBySlug[document.slug, default: []].sorted()
            return copy
        }
    }

    static func buildGraph(
        from documents: [VaultDocument],
        items: [ReferenceItem] = [],
        xPayloadsByReferenceID: [UUID: XBookmarkPayloadSummary] = [:]
    ) -> VaultGraph {
        var nodes = Dictionary(
            uniqueKeysWithValues: documents.map {
                (
                    $0.slug,
                    VaultGraphNode(slug: $0.slug, title: $0.title, group: $0.group)
                )
            }
        )
        var edges: [VaultGraphEdge] = []
        var seen = Set<String>()

        for document in documents {
            for link in document.outgoingLinks {
                let relation = document.outgoingRelations[link] ?? .related
                let edgeID = "\(document.slug)->\(link):\(relation.rawValue)"
                let reverseID = "\(link)->\(document.slug):\(relation.rawValue)"
                guard !seen.contains(edgeID) && !seen.contains(reverseID) else { continue }
                seen.insert(edgeID)
                edges.append(VaultGraphEdge(source: document.slug, target: link, relation: relation))
            }
        }

        addXBookmarkGraphNodes(
            items: items,
            documents: documents,
            xPayloadsByReferenceID: xPayloadsByReferenceID,
            nodes: &nodes,
            edges: &edges,
            seen: &seen
        )

        return VaultGraph(
            nodes: nodes.values.sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            },
            edges: edges
        )
    }

    /// Source-compatible boundary for import/test callers that still own raw
    /// extension payloads. The graph itself only receives compact projections.
    static func buildGraph(
        from documents: [VaultDocument],
        items: [ReferenceItem],
        xPayloadsByReferenceID: [UUID: BrowserExtensionReferencePayload]
    ) -> VaultGraph {
        buildGraph(
            from: documents,
            items: items,
            xPayloadsByReferenceID: xPayloadsByReferenceID.mapValues(XBookmarkPayloadSummary.init)
        )
    }

    private static func addXBookmarkGraphNodes(
        items: [ReferenceItem],
        documents: [VaultDocument],
        xPayloadsByReferenceID: [UUID: XBookmarkPayloadSummary],
        nodes: inout [String: VaultGraphNode],
        edges: inout [VaultGraphEdge],
        seen: inout Set<String>
    ) {
        let slugsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.slug) })
        for item in items where !item.isTrashed && item.isXBookmark {
            let referenceSlug = slugsByID[item.id] ?? slug(for: item)
            nodes[referenceSlug] = nodes[referenceSlug] ?? VaultGraphNode(
                slug: referenceSlug,
                title: item.title,
                group: item.group
            )

            let payload = xPayloadsByReferenceID[item.id]
            let author = xAuthorLabel(for: item, payload: payload)
            if !author.isEmpty {
                let authorSlug = "x-author-\(slugComponent(author))"
                nodes[authorSlug] = VaultGraphNode(
                    slug: authorSlug,
                    title: author,
                    group: .link,
                    kind: .xAuthor,
                    subtitle: "X author"
                )
                appendGraphEdge(source: referenceSlug, target: authorSlug, relation: .authoredBy, edges: &edges, seen: &seen)
            }

            if let domain = xDomainLabel(for: item, payload: payload) {
                let domainSlug = "domain-\(slugComponent(domain))"
                nodes[domainSlug] = VaultGraphNode(
                    slug: domainSlug,
                    title: domain,
                    group: .website,
                    kind: .domain,
                    subtitle: "Source domain"
                )
                appendGraphEdge(source: referenceSlug, target: domainSlug, relation: .domain, edges: &edges, seen: &seen)
            }

            let tags = xGraphTags(for: item, payload: payload)
            for tag in tags.prefix(6) {
                let tagSlug = "tag-\(slugComponent(tag))"
                nodes[tagSlug] = VaultGraphNode(
                    slug: tagSlug,
                    title: "#\(tag)",
                    group: .memory,
                    kind: .tag,
                    subtitle: "Tag"
                )
                appendGraphEdge(source: referenceSlug, target: tagSlug, relation: .tagged, edges: &edges, seen: &seen)
            }

            let mediaURLs = xMediaURLs(for: payload)
            for (index, mediaURL) in mediaURLs.prefix(4).enumerated() {
                let mediaSlug = "x-media-\(stableIDFragment(for: mediaURL))"
                nodes[mediaSlug] = VaultGraphNode(
                    slug: mediaSlug,
                    title: "Media \(index + 1)",
                    group: .file,
                    kind: .xMedia,
                    subtitle: URL(string: mediaURL)?.host(percentEncoded: false) ?? "X media"
                )
                appendGraphEdge(source: referenceSlug, target: mediaSlug, relation: .containsMedia, edges: &edges, seen: &seen)
            }
        }
    }

    private static func appendGraphEdge(
        source: String,
        target: String,
        relation: GraphRelation,
        edges: inout [VaultGraphEdge],
        seen: inout Set<String>
    ) {
        guard source != target else { return }
        let edgeID = "\(source)->\(target):\(relation.rawValue)"
        guard seen.insert(edgeID).inserted else { return }
        edges.append(VaultGraphEdge(source: source, target: target, relation: relation))
    }

    private static func xAuthorLabel(for item: ReferenceItem, payload: XBookmarkPayloadSummary?) -> String {
        if let note = payload?.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note
        }
        if let handle = xUsername(from: payload?.url ?? item.subtitle), !handle.isEmpty {
            return "@\(handle)"
        }
        let parts = XBookmarkDisplay.parts(from: payload?.title ?? item.title)
        if let handle = parts.handle, !handle.isEmpty { return handle }
        return parts.name == "X" ? "" : parts.name
    }

    private static func xDomainLabel(for item: ReferenceItem, payload: XBookmarkPayloadSummary?) -> String? {
        let value = payload?.url ?? item.subtitle
        guard let host = URL(string: value)?.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func xGraphTags(for item: ReferenceItem, payload: XBookmarkPayloadSummary?) -> [String] {
        var tags = Set(payload?.autoTags ?? [])
        tags.insert("x-bookmarked")
        if item.isInbox { tags.insert("inbox") }
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private static func xMediaURLs(for payload: XBookmarkPayloadSummary?) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        for url in (payload?.imageURLs ?? []) + [payload?.ogImageURL].compactMap({ $0 }) {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            urls.append(trimmed)
        }
        return urls
    }

    private static func xUsername(from value: String?) -> String? {
        guard let value,
              let url = URL(string: value),
              url.isXFamilyURL else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let username = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty,
              !["i", "home", "explore", "notifications", "messages", "search", "settings"].contains(username.lowercased()) else {
            return nil
        }
        return username
    }

    private static func slugComponent(_ value: String) -> String {
        let cleaned = value
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? stableIDFragment(for: value) : cleaned
    }

    private static func stableIDFragment(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeConceptPages(for items: [ReferenceItem], rootURL: URL) {
        let groups = Dictionary(grouping: items, by: \.group)
        for (group, groupItems) in groups {
            let slug = conceptSlug(for: group)
            let links = groupItems.map { "- [[\(Self.slug(for: $0))]]" }.joined(separator: "\n")
            let content = conceptPage(title: group.rawValue, slug: slug, kind: "group", links: links)
            writeIfChanged(content, to: rootURL.appendingPathComponent("wiki/concepts/\(slug).md"))
        }

        let kinds = Dictionary(grouping: items, by: \.kind)
        for (kind, kindItems) in kinds {
            let slug = conceptSlug(for: kind.rawValue)
            let links = kindItems.map { "- [[\(Self.slug(for: $0))]]" }.joined(separator: "\n")
            let content = conceptPage(title: kind.rawValue.capitalized, slug: slug, kind: "format", links: links)
            writeIfChanged(content, to: rootURL.appendingPathComponent("wiki/concepts/\(slug).md"))
        }
    }

    private static func writeConceptPages(for documents: [VaultDocument], rootURL: URL) {
        let groups = Dictionary(grouping: documents, by: \.group)
        for (group, docs) in groups {
            let slug = conceptSlug(for: group)
            let links = docs.map { "- [[\($0.slug)]]" }.joined(separator: "\n")
            let content = conceptPage(title: group.rawValue, slug: slug, kind: "group", links: links)
            writeIfChanged(content, to: rootURL.appendingPathComponent("wiki/concepts/\(slug).md"))
        }

        let kinds = Dictionary(grouping: documents, by: \.kind)
        for (kind, docs) in kinds {
            let slug = conceptSlug(for: kind.rawValue)
            let links = docs.map { "- [[\($0.slug)]]" }.joined(separator: "\n")
            let content = conceptPage(title: kind.rawValue.capitalized, slug: slug, kind: "format", links: links)
            writeIfChanged(content, to: rootURL.appendingPathComponent("wiki/concepts/\(slug).md"))
        }
    }

    private static func conceptPage(title: String, slug: String, kind: String, links: String) -> String {
        """
        ---
        title: "\(escapedYAML(title))"
        type: concept
        kind: "\(kind)"
        status: auto-index
        ---

        # \(title)

        ## References

        \(links.isEmpty ? "- No references yet." : links)

        ## Synthesis

        Needs compile pass: summarize patterns, tensions, contradictions, and notable examples.
        """
    }

    private static func writeIndexes(
        items: [ReferenceItem]?,
        documents: [VaultDocument],
        collections: [ReferenceCollection],
        graph: VaultGraph,
        rootURL: URL
    ) {
        let sortedDocs = documents.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let catalog = sortedDocs.map { "- [[\($0.slug)]] — \($0.group.rawValue), \($0.kind.rawValue)" }.joined(separator: "\n")
        let index = """
        # Loci Creative Memory

        ## Thesis

        This vault compiles raw sources into durable, inspectable Markdown knowledge.

        ## Layers

        - `raw/`: immutable source packages and provenance.
        - `wiki/`: LLM-maintained summaries, concept pages, comparisons, contradictions, and synthesis.
        - `system/`: schemas, instructions, health checks, compile rules, and plugin config notes.
        - `outputs/`: generated boards, slides, charts, briefs, and decisions that can be filed back into `wiki/`.

        ## Catalog

        \(catalog.isEmpty ? "- No compiled references yet." : catalog)

        ## Collections

        \(collections.isEmpty ? "- No collections yet." : collections.map { "- \($0.name)" }.joined(separator: "\n"))
        """
        writeIfChanged(index, to: rootURL.appendingPathComponent("index.md"))
        writeIfChanged(index, to: rootURL.appendingPathComponent("wiki/index.md"))

        let logRows: [String]
        if let items {
            logRows = items.map { "- \($0.title) — `\($0.id.uuidString)` — \($0.group.rawValue)/\($0.kind.rawValue)" }
        } else {
            logRows = sortedDocs.map { "- \($0.title) — `\($0.id.uuidString)` — \($0.group.rawValue)/\($0.kind.rawValue)" }
        }
        writeIfChanged("# Compile Log\n\n\(logRows.isEmpty ? "- No entries yet." : logRows.joined(separator: "\n"))\n", to: rootURL.appendingPathComponent("log.md"))
        writeIfChanged(healthReport(documents: documents), to: rootURL.appendingPathComponent("system/health.md"))
        writeGraphIndex(graph, rootURL: rootURL)
    }

    private static func healthReport(documents: [VaultDocument]) -> String {
        let orphanDocs = documents.filter { $0.outgoingLinks.isEmpty && $0.backlinks.isEmpty }
        let needsReview = documents.filter { $0.tags.contains("inbox") }
        return """
        # Vault Health

        - Reference pages: \(documents.count)
        - Orphans: \(orphanDocs.count)
        - Inbox / needs review: \(needsReview.count)

        ## Orphans

        \(orphanDocs.isEmpty ? "- None." : orphanDocs.map { "- [[\($0.slug)]]" }.joined(separator: "\n"))

        ## Needs Review

        \(needsReview.isEmpty ? "- None." : needsReview.map { "- [[\($0.slug)]]" }.joined(separator: "\n"))
        """
    }

    private static func writeReadmeIfNeeded(at rootURL: URL) {
        let content = """
        # Loci Vault

        A file-over-app creative memory vault. Loci writes portable Markdown and local source packages that can be read by humans, Obsidian, CLI tools, or other AI agents.

        - `raw/`: immutable source packages with provenance.
        - `wiki/`: maintained Markdown pages and synthesis.
        - `system/`: schemas, instructions, health checks, and compile rules.
        - `outputs/`: generated artifacts worth keeping.

        Compatibility folders such as `References/`, `Assets/`, `Imports/`, `Plugins/`, and `Published/` are kept for older Loci builds and plugins.
        """
        writeIfMissing(content, to: rootURL.appendingPathComponent("README.md"))
    }

    private static func writeSystemFiles(at rootURL: URL) {
        let instructions = """
        # Loci Compile Instructions

        Treat `raw/` as immutable source truth. Write and update synthesized knowledge in `wiki/`.

        ## Compile Flow

        1. Read the raw source package.
        2. Update or create the matching page in `wiki/references/`.
        3. Add concept, entity, comparison, contradiction, project, question, and summary pages under `wiki/` when useful.
        4. Preserve backlinks with `[[wiki-links]]`.
        5. Add uncertainty, contradiction, and `needs-review` notes instead of silently resolving ambiguity.
        6. File durable outputs back into `outputs/` or `wiki/` with provenance.

        ## Rules

        - Do not edit `raw/` except to add a new immutable package for a new source.
        - Prefer small, connected Markdown pages over one giant summary.
        - Keep source links and local file references visible.
        - Maintain `index.md`, `log.md`, and `system/health.md`.
        """

        let schema = """
        # Loci Vault Schema

        ## raw/<source-slug>/

        - `metadata.json`: machine-readable provenance and source metadata.
        - `source.md`: human-readable source package overview.
        - `extracted.txt`: cleaned extracted text or note content when available.
        - `original.url`: canonical URL for web sources.
        - `original-path.txt`: local managed original path when Loci has one.

        ## wiki/

        - `references/`: one page per saved source.
        - `concepts/`: concepts, entities, brands, people, media types, and clusters.
        - `comparisons/`: cross-source comparison notes.
        - `contradictions/`: explicit conflict records.
        - `questions/`: open research questions.
        - `summaries/`: periodic rollups and evolving theses.

        ## system/

        Agent instructions, health checks, schemas, and compile configuration.
        """

        let llmPrompt = """
        # LLM Compile Prompt

        You are compiling an Loci creative-memory vault.

        Read `raw/<source>/metadata.json`, `source.md`, `extracted.txt`, transcripts, image manifests, OCR text, and local original pointers. Update `wiki/` only.

        Required output for each compile:

        - A source summary with claims, examples, and uncertainty.
        - Concept/entity/brand/person pages when reusable.
        - Backlinks from new pages to source pages.
        - Contradiction or tension pages for conflicting claims.
        - Updates to `wiki/summaries/evolving-thesis.md`.
        - A `needs-review` flag whenever extraction was weak or ambiguous.

        Never mutate `raw/`. Preserve provenance and quote sparingly.
        """

        let obsidian = """
        # Obsidian Web Clipper

        Configure Obsidian Web Clipper to save into:

        `raw/clipper-inbox/`

        Recommended template frontmatter:

        ```yaml
        title: "{{title}}"
        source_url: "{{url}}"
        clipped_at: "{{date}}"
        status: raw-inbox
        ```

        Loci can ingest these Markdown files as immutable raw sources. Keep downloaded images beside the clipped Markdown under the same source folder.
        """

        let outputWorkflow = """
        # Source To Output Loop

        Durable outputs belong in `outputs/`.

        - `outputs/slides/`: Marp decks and rendered PDFs.
        - `outputs/boards/`: moodboards, visual boards, research boards.
        - `outputs/charts/`: generated charts and datasets.
        - `outputs/decisions/`: decisions, prompts, critiques, and analysis worth keeping.

        When an output matters, add a wiki page linking back to the raw sources and the output artifact.
        """

        writeIfChanged(instructions, to: rootURL.appendingPathComponent("system/INSTRUCTIONS.md"))
        writeIfChanged(instructions, to: rootURL.appendingPathComponent("system/CLAUDE.md"))
        writeIfChanged(schema, to: rootURL.appendingPathComponent("system/SCHEMA.md"))
        writeIfChanged(llmPrompt, to: rootURL.appendingPathComponent("system/LLM_COMPILE_PROMPT.md"))
        writeIfChanged(obsidian, to: rootURL.appendingPathComponent("system/OBSIDIAN_WEB_CLIPPER.md"))
        writeIfChanged(outputWorkflow, to: rootURL.appendingPathComponent("system/OUTPUT_WORKFLOW.md"))
        writeIfMissing("# Plugins\n\n- Marp slides: put slide decks in `outputs/slides/`.\n- Obsidian: open the vault root directly.\n", to: rootURL.appendingPathComponent("system/plugins.md"))
    }

    private static func writeGraphIndex(_ graph: VaultGraph, rootURL: URL) {
        let nodes = graph.nodes.map {
            "- \($0.slug) | \($0.title) | \($0.kind.title) | \($0.group.rawValue)"
        }.joined(separator: "\n")
        let edges = graph.edges.map {
            "- \($0.source) -> \($0.target) | \($0.relation.rawValue)"
        }.joined(separator: "\n")
        let content = """
        # Vault Graph

        ## Nodes

        \(nodes.isEmpty ? "- No nodes yet." : nodes)

        ## Edges

        \(edges.isEmpty ? "- No edges yet." : edges)
        """
        writeIfChanged(content, to: rootURL.appendingPathComponent("Graph.md"))
        writeIfChanged(content, to: rootURL.appendingPathComponent("system/graph.md"))
    }

    private static func rawMetadata(for item: ReferenceItem, source: ImportSourceKind, payload: String, managedOriginalURL: URL?) -> String {
        var dict: [String: Any] = [
            "id": item.id.uuidString,
            "title": item.title,
            "subtitle": item.subtitle,
            "fileName": item.fileName,
            "kind": item.kind.rawValue,
            "group": item.group.rawValue,
            "source": source.rawValue,
            "payload": payload,
            "wikiPath": "wiki/references/\(slug(for: item)).md"
        ]
        if let managedOriginalURL {
            dict["managedOriginalPath"] = managedOriginalURL.path
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func rawSourceMarkdown(for item: ReferenceItem, source: ImportSourceKind, payload: String) -> String {
        """
        # \(item.title)

        - Source kind: `\(source.rawValue)`
        - Reference ID: `\(item.id.uuidString)`
        - File name: `\(item.fileName)`
        - Wiki page: `wiki/references/\(slug(for: item)).md`

        ## Provenance

        ```text
        \(payload)
        ```
        """
    }

    private static func extractedText(for item: ReferenceItem, source: ImportSourceKind, payload: String) -> String {
        if source == .browserExtension,
           let data = payload.data(using: .utf8),
           let browserPayload = try? JSONDecoder().decode(BrowserExtensionReferencePayload.self, from: data) {
            return [
                browserPayload.title,
                browserPayload.note,
                browserPayload.selectedText,
                browserPayload.url,
                browserPayload.pageHTML.map { String($0.prefix(120_000)) }
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
        }
        return [item.title, item.subtitle, payload]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private static func sourceURLString(for source: ImportSourceKind, payload: String) -> String? {
        if source == .browserExtension,
           let data = payload.data(using: .utf8),
           let browserPayload = try? JSONDecoder().decode(BrowserExtensionReferencePayload.self, from: data) {
            return browserPayload.url
        }
        if source == .url, URL(string: payload) != nil {
            return payload
        }
        return nil
    }

    private static func createVaultDirectories(at rootURL: URL) {
        [
            "raw",
            "wiki",
            "wiki/references",
            "wiki/concepts",
            "wiki/comparisons",
            "wiki/contradictions",
            "wiki/questions",
            "wiki/summaries",
            "system",
            "outputs",
            "outputs/slides",
            "outputs/boards",
            "outputs/charts",
            "outputs/decisions",
            "References",
            "Assets",
            "Imports",
            "Plugins",
            "Published"
        ].forEach { createDirectoryIfNeeded(rootURL.appendingPathComponent($0, isDirectory: true)) }
    }

    private static func createDirectoryIfNeeded(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func copyDirectory(_ source: URL, to destination: URL, excludingRelativePrefixes: [String] = []) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        createDirectoryIfNeeded(destination)
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for case let fileURL as URL in enumerator {
            let relative = fileURL.path.replacingOccurrences(of: source.path + "/", with: "")
            if excludingRelativePrefixes.contains(where: { relative.hasPrefix($0) }) {
                enumerator.skipDescendants()
                continue
            }

            let targetURL = destination.appendingPathComponent(relative)
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                createDirectoryIfNeeded(targetURL)
            } else {
                createDirectoryIfNeeded(targetURL.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.copyItem(at: fileURL, to: targetURL)
            }
        }
    }

    private static func writeIfMissing(_ content: String, to url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        writeIfChanged(content, to: url)
    }

    private static func writeIfChanged(_ content: String, to url: URL) {
        createDirectoryIfNeeded(url.deletingLastPathComponent())
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content {
            return
        }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func replacingFrontmatterStatus(in content: String, with status: String) -> String {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else {
            return "status: \(status)\n\n\(content)"
        }

        let frontmatter = String(content[..<endRange.lowerBound])
        let rest = String(content[endRange.lowerBound...])
        let updatedFrontmatter: String
        if frontmatter.contains("\nstatus:") {
            updatedFrontmatter = frontmatter.replacingOccurrences(
                of: #"(?m)^status:\s*.*$"#,
                with: "status: \(status)",
                options: .regularExpression
            )
        } else {
            updatedFrontmatter = frontmatter + "\nstatus: \(status)"
        }
        return updatedFrontmatter + rest
    }

    private static func writeReferenceIfNotCompiled(_ content: String, to url: URL) {
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing.contains("status: compiled")
               || existing.contains("status: heuristic-needs-model-review")
               || existing.contains("## Synthesis") {
            return
        }
        writeIfChanged(content, to: url)
    }

    private static func conceptSlug(for group: ReferenceGroup) -> String {
        conceptSlug(for: group.rawValue)
    }

    private static func conceptSlug(for value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func escapedYAML(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapedJSON(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
