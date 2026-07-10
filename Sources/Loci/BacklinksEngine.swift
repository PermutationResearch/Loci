import Foundation
import GRDB

struct WikiLink: Hashable {
    var sourceSlug: String
    var targetSlug: String
    var sourceTitle: String
    var context: String
}

struct BacklinksResult: Identifiable {
    var id: String { sourceSlug }
    var sourceSlug: String
    var sourceTitle: String
    var contextSnippet: String
}

@MainActor
enum BacklinksEngine {
    nonisolated static func extractWikiLinks(from markdown: String, currentSlug: String) -> [String] {
        let pattern = /\[\[([a-z0-9_-]+)\]\]/
        let matches = markdown.matches(of: pattern)
        return matches.map { String($0.output.1) }
            .filter { $0 != currentSlug }
    }

    nonisolated static func buildIndex(vaultRoot: URL) -> [String: [BacklinksResult]] {
        let referencesDir = vaultRoot.appendingPathComponent("wiki/references", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: referencesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var allLinks: [(source: String, target: String, context: String)] = []
        var slugTitles: [String: String] = [:]

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let sourceSlug = fileURL.deletingPathExtension().lastPathComponent
            let title = extractTitle(from: content) ?? sourceSlug
            slugTitles[sourceSlug] = title

            let links = extractWikiLinks(from: content, currentSlug: sourceSlug)
            for target in links {
                let context = extractContextForLink(target, in: content)
                allLinks.append((source: sourceSlug, target: target, context: context))
            }
        }

        var index: [String: [BacklinksResult]] = [:]
        for link in allLinks {
            let result = BacklinksResult(
                sourceSlug: link.source,
                sourceTitle: slugTitles[link.source] ?? link.source,
                contextSnippet: link.context
            )
            index[link.target, default: []].append(result)
        }
        return index
    }

    nonisolated static func backlinks(for slug: String, vaultRoot: URL) -> [BacklinksResult] {
        let index = buildIndex(vaultRoot: vaultRoot)
        return index[slug] ?? []
    }

    static func insertBacklinksIntoDatabase(vaultRoot: URL) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        let index = buildIndex(vaultRoot: vaultRoot)

        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM wiki_backlinks")
                for (target, sources) in index {
                    for source in sources {
                        try db.execute(sql: """
                            INSERT INTO wiki_backlinks (source_slug, target_slug, source_title, context_snippet)
                            VALUES (?, ?, ?, ?)
                        """, arguments: [source.sourceSlug, target, source.sourceTitle, source.contextSnippet])
                    }
                }
            }
        } catch {
            print("GRDB insertBacklinksIntoDatabase failed: \(error)")
        }
    }

    static func queryBacklinks(from queue: GRDB.DatabaseQueue, targetSlug: String) -> [BacklinksResult] {
        do {
            return try queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT source_slug, source_title, context_snippet
                    FROM wiki_backlinks
                    WHERE target_slug = ?
                    ORDER BY source_title ASC
                """, arguments: [targetSlug]).compactMap { row in
                    guard let sourceSlug = row["source_slug"] as String?,
                          let sourceTitle = row["source_title"] as String? else { return nil }
                    return BacklinksResult(
                        sourceSlug: sourceSlug,
                        sourceTitle: sourceTitle,
                        contextSnippet: row["context_snippet"] as String? ?? ""
                    )
                }
            }
        } catch {
            return []
        }
    }

    nonisolated private static func extractTitle(from markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    nonisolated private static func extractContextForLink(_ targetSlug: String, in content: String) -> String {
        let pattern = "[[\(targetSlug)]]"
        guard let range = content.range(of: pattern) else { return "" }
        let start = content.index(range.lowerBound, offsetBy: -80, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(range.upperBound, offsetBy: 80, limitedBy: content.endIndex) ?? content.endIndex
        return String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
