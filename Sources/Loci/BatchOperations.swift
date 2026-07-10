import Foundation
import GRDB

struct BatchResult: Identifiable {
    var id: UUID
    var type: String
    var itemCount: Int
    var status: String
    var summary: String?
    var createdAt: Date
    var completedAt: Date?
}

@MainActor
enum BatchOperations {
    static func batchTag(items: [ReferenceItem.ID], tagName: String) -> BatchResult {
        let resultID = UUID()
        for itemID in items {
            TagHierarchy.addTag(tagName, to: itemID)
        }
        let result = BatchResult(
            id: resultID, type: "tag", itemCount: items.count,
            status: "completed", summary: "Tagged \(items.count) items with '\(tagName)'",
            createdAt: Date(), completedAt: Date()
        )
        recordResult(result)
        return result
    }

    static func batchMoveToCollection(items: [ReferenceItem.ID], collectionID: UUID?) -> BatchResult {
        let resultID = UUID()
        guard let queue = LociPersistentStore.shared?.grdbQueue else {
            return BatchResult(id: resultID, type: "move", itemCount: 0, status: "failed", createdAt: Date())
        }
        do {
            try queue.write { db in
                for itemID in items {
                    try db.execute(sql: "UPDATE reference_items SET collection_id = ?, updated_at = ? WHERE id = ?",
                                   arguments: [collectionID?.uuidString, ISO8601DateFormatter().string(from: Date()), itemID.uuidString])
                }
            }
        } catch {
            ErrorPresenter.shared.show(.unknown("Couldn't move \(items.count) item\(items.count == 1 ? "" : "s"): \(error.localizedDescription)"))
            let result = BatchResult(
                id: resultID, type: "move", itemCount: items.count,
                status: "failed", summary: "Move failed: \(error.localizedDescription)",
                createdAt: Date(), completedAt: Date()
            )
            recordResult(result)
            return result
        }
        let result = BatchResult(
            id: resultID, type: "move", itemCount: items.count,
            status: "completed", summary: "Moved \(items.count) items",
            createdAt: Date(), completedAt: Date()
        )
        recordResult(result)
        return result
    }

    static func batchTrash(items: [ReferenceItem.ID]) -> BatchResult {
        let resultID = UUID()
        LociPersistentStore.shared?.batchTrashReferences(ids: Set(items))
        let result = BatchResult(
            id: resultID, type: "trash", itemCount: items.count,
            status: "completed", summary: "Trashed \(items.count) items",
            createdAt: Date(), completedAt: Date()
        )
        recordResult(result)
        return result
    }

    static func batchDelete(items: [ReferenceItem.ID]) -> BatchResult {
        let resultID = UUID()
        LociPersistentStore.shared?.batchDeleteReferences(ids: Set(items))
        let result = BatchResult(
            id: resultID, type: "delete", itemCount: items.count,
            status: "completed", summary: "Deleted \(items.count) items",
            createdAt: Date(), completedAt: Date()
        )
        recordResult(result)
        return result
    }

    static func batchAddToReview(items: [ReferenceItem.ID]) -> BatchResult {
        let resultID = UUID()
        for itemID in items {
            ReviewScheduler.addToQueue(referenceID: itemID)
        }
        let result = BatchResult(
            id: resultID, type: "review", itemCount: items.count,
            status: "completed", summary: "Added \(items.count) items to review queue",
            createdAt: Date(), completedAt: Date()
        )
        recordResult(result)
        return result
    }

    static func recentOperations() -> [BatchResult] {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return [] }
        do {
            return try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM batch_operations ORDER BY created_at DESC LIMIT 20").compactMap { row in
                    guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                          let type = row["type"] as String? else { return nil }
                    return BatchResult(
                        id: id, type: type,
                        itemCount: row["item_count"] as Int? ?? 0,
                        status: row["status"] as String? ?? "unknown",
                        summary: row["result_summary"] as String?,
                        createdAt: ISO8601DateFormatter().date(from: row["created_at"] as String? ?? "") ?? Date(),
                        completedAt: (row["completed_at"] as String?).flatMap { ISO8601DateFormatter().date(from: $0) }
                    )
                }
            }
        } catch {
            return []
        }
    }

    private static func recordResult(_ result: BatchResult) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO batch_operations (id, type, item_count, status, result_summary, created_at, completed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    result.id.uuidString, result.type, result.itemCount, result.status,
                    result.summary, ISO8601DateFormatter().string(from: result.createdAt),
                    result.completedAt.flatMap { ISO8601DateFormatter().string(from: $0) }
                ])
            }
        } catch {}
    }
}
