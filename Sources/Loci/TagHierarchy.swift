import Foundation
import GRDB

struct TagNode: Identifiable, Hashable {
    var id: String { fullPath }
    var name: String
    var fullPath: String
    var children: [TagNode]
    var referenceCount: Int
    var colorHex: String?
}

@MainActor
enum TagHierarchy {
    static func buildTree() -> [TagNode] {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return [] }
        do {
            return try queue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT t.id, t.name, t.color_hex, COUNT(rt.reference_id) as ref_count
                    FROM tags t
                    LEFT JOIN reference_tags rt ON rt.tag_id = t.id
                    GROUP BY t.id
                    ORDER BY t.name ASC
                """)

                var allTags: [(id: String, name: String, fullPath: String, count: Int, color: String?)] = []
                for row in rows {
                    guard let id = row["id"] as String?,
                          let name = row["name"] as String? else { continue }
                    let path = name
                    let count = row["ref_count"] as Int? ?? 0
                    let color = row["color_hex"] as String?
                    allTags.append((id, name, path, count, color))
                }

                return buildNodes(from: allTags, prefix: "")
            }
        } catch {
            return []
        }
    }

    static func addTag(_ name: String, to referenceID: ReferenceItem.ID, parentPath: String? = nil) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        let fullPath = parentPath != nil ? "\(parentPath!)/\(name)" : name
        do {
            try queue.write { db in
                let tagID = UUID().uuidString
                let existingTag = try? String.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [fullPath])
                let finalTagID: String
                if let existingTag {
                    finalTagID = existingTag
                } else {
                    try db.execute(sql: "INSERT INTO tags (id, name, created_at) VALUES (?, ?, ?)",
                                   arguments: [tagID, fullPath, ISO8601DateFormatter().string(from: Date())])
                    finalTagID = tagID
                }
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM reference_tags WHERE reference_id = ? AND tag_id = ?)",
                                               arguments: [referenceID.uuidString, finalTagID]) ?? false
                if !exists {
                    try db.execute(sql: "INSERT INTO reference_tags (reference_id, tag_id, created_at) VALUES (?, ?, ?)",
                                   arguments: [referenceID.uuidString, finalTagID, ISO8601DateFormatter().string(from: Date())])
                }
            }
        } catch {
            ErrorPresenter.shared.show(.unknown("Couldn't add tag \"\(name)\": \(error.localizedDescription)"))
        }
    }

    static func removeTag(_ tagID: String, from referenceID: ReferenceItem.ID) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM reference_tags WHERE reference_id = ? AND tag_id = ?",
                               arguments: [referenceID.uuidString, tagID])
            }
        } catch {
            ErrorPresenter.shared.show(.unknown("Couldn't remove tag: \(error.localizedDescription)"))
        }
    }

    static func tagsForReference(_ referenceID: ReferenceItem.ID) -> [String] {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return [] }
        do {
            return try queue.read { db in
                try String.fetchAll(db, sql: """
                    SELECT t.name FROM tags t
                    JOIN reference_tags rt ON rt.tag_id = t.id
                    WHERE rt.reference_id = ?
                    ORDER BY t.name ASC
                """, arguments: [referenceID.uuidString])
            }
        } catch {
            return []
        }
    }

    static func referencesForTag(_ tagPath: String) -> [ReferenceItem.ID] {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return [] }
        do {
            return try queue.read { db in
                let tagIDs = try String.fetchAll(db, sql: "SELECT id FROM tags WHERE name = ? OR name LIKE ?",
                                                 arguments: [tagPath, "\(tagPath)/%"])
                guard !tagIDs.isEmpty else { return [] }
                let placeholders = tagIDs.map { _ in "?" }.joined(separator: ",")
                let args = StatementArguments(tagIDs)
                return try String.fetchAll(db, sql: """
                    SELECT DISTINCT reference_id FROM reference_tags
                    WHERE tag_id IN (\(placeholders))
                """, arguments: args).compactMap(UUID.init(uuidString:))
            }
        } catch {
            return []
        }
    }

    private static func buildNodes(from tags: [(id: String, name: String, fullPath: String, count: Int, color: String?)], prefix: String) -> [TagNode] {
        var nodes: [TagNode] = []
        var childrenMap: [String: [(id: String, name: String, fullPath: String, count: Int, color: String?)]] = [:]

        for tag in tags {
            let relativePath = prefix.isEmpty ? tag.name : String(tag.name.dropFirst(prefix.count + 1))
            let parts = relativePath.split(separator: "/", maxSplits: 1).map(String.init)

            if parts.count == 1 {
                nodes.append(TagNode(
                    name: parts[0],
                    fullPath: tag.fullPath,
                    children: [],
                    referenceCount: tag.count,
                    colorHex: tag.color
                ))
            } else {
                let parentName = parts[0]
                childrenMap[parentName, default: []].append(tag)
            }
        }

        for i in nodes.indices {
            let childPrefix = nodes[i].fullPath
            if let childTags = childrenMap[nodes[i].name] {
                nodes[i].children = buildNodes(from: childTags, prefix: childPrefix)
            }
        }

        return nodes
    }
}
