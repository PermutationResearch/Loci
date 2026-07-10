import Foundation
import GRDB

struct ReviewItem: Identifiable, Hashable {
    var id: UUID
    var referenceID: ReferenceItem.ID
    var nextReviewAt: Date
    var intervalDays: Double
    var easeFactor: Double
    var reviewCount: Int
    var lastReviewedAt: Date?
}

struct ReviewSession {
    var totalDue: Int
    var reviewed: Int
    var correct: Int
}

@MainActor
enum ReviewScheduler {
    static func addToQueue(referenceID: ReferenceItem.ID) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try queue.write { db in
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM review_queue WHERE reference_id = ?)", arguments: [referenceID.uuidString]) ?? false
                if !exists {
                    try db.execute(sql: """
                        INSERT INTO review_queue (id, reference_id, next_review_at, interval_days, ease_factor, review_count, created_at)
                        VALUES (?, ?, ?, 1.0, 2.5, 0, ?)
                    """, arguments: [UUID().uuidString, referenceID.uuidString, now, now])
                }
            }
        } catch {
            print("GRDB addToQueue failed: \(error)")
        }
    }

    static func removeFromQueue(referenceID: ReferenceItem.ID) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM review_queue WHERE reference_id = ?", arguments: [referenceID.uuidString])
            }
        } catch {
            print("GRDB removeFromQueue failed: \(error)")
        }
    }

    static func dueItems() -> [ReviewItem] {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return [] }
        do {
            return try queue.read { db in
                let now = ISO8601DateFormatter().string(from: Date())
                return try Row.fetchAll(db, sql: """
                    SELECT id, reference_id, next_review_at, interval_days, ease_factor, review_count, last_reviewed_at
                    FROM review_queue
                    WHERE next_review_at <= ?
                    ORDER BY next_review_at ASC
                    LIMIT 50
                """, arguments: [now]).compactMap { row in
                    guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                          let refID = (row["reference_id"] as String?).flatMap(UUID.init(uuidString:)),
                          let nextStr = row["next_review_at"] as String? else { return nil }
                    return ReviewItem(
                        id: id,
                        referenceID: refID,
                        nextReviewAt: ISO8601DateFormatter().date(from: nextStr) ?? Date(),
                        intervalDays: row["interval_days"] as Double? ?? 1,
                        easeFactor: row["ease_factor"] as Double? ?? 2.5,
                        reviewCount: row["review_count"] as Int? ?? 0,
                        lastReviewedAt: (row["last_reviewed_at"] as String?).flatMap { ISO8601DateFormatter().date(from: $0) }
                    )
                }
            }
        } catch {
            print("GRDB dueItems failed: \(error)")
            return []
        }
    }

    static func recordReview(id: UUID, quality: Int) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try queue.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM review_queue WHERE id = ?", arguments: [id.uuidString]) else { return }
                let currentEF = row["ease_factor"] as Double? ?? 2.5
                let currentInterval = row["interval_days"] as Double? ?? 1
                let count = (row["review_count"] as Int? ?? 0) + 1

                let newEF = max(1.3, currentEF + (0.1 - Double(5 - quality) * (0.08 + Double(5 - quality) * 0.02)))
                let newInterval: Double
                if count == 1 {
                    newInterval = 1
                } else if count == 2 {
                    newInterval = 3
                } else {
                    newInterval = currentInterval * newEF
                }

                let nextReview = Date().addingTimeInterval(newInterval * 86400)
                let nextStr = ISO8601DateFormatter().string(from: nextReview)

                try db.execute(sql: """
                    UPDATE review_queue
                    SET interval_days = ?, ease_factor = ?, review_count = ?, last_reviewed_at = ?, next_review_at = ?
                    WHERE id = ?
                """, arguments: [newInterval, newEF, count, now, nextStr, id.uuidString])
            }
        } catch {
            print("GRDB recordReview failed: \(error)")
        }
    }

    static func stats() -> (due: Int, reviewedToday: Int, streak: Int) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return (0, 0, 0) }
        do {
            return try queue.read { db in
                let now = ISO8601DateFormatter().string(from: Date())
                let due = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_queue WHERE next_review_at <= ?", arguments: [now]) ?? 0
                let todayStart = Calendar.current.startOfDay(for: Date())
                let todayStr = ISO8601DateFormatter().string(from: todayStart)
                let reviewed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_queue WHERE last_reviewed_at >= ?", arguments: [todayStr]) ?? 0
                return (due, reviewed, 0)
            }
        } catch {
            return (0, 0, 0)
        }
    }

    static func surfaceForgottenReferences() -> [ReferenceItem.ID] {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return [] }
        let calendar = Calendar.current
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let thirtyDaysAgoStr = ISO8601DateFormatter().string(from: thirtyDaysAgo)

        do {
            return try queue.read { db in
                let forgottenIDs = try Row.fetchAll(db, sql: """
                    SELECT ri.id
                    FROM reference_items ri
                    LEFT JOIN document_views dv ON dv.reference_id = ri.id
                    LEFT JOIN review_queue rq ON rq.reference_id = ri.id
                    WHERE ri.deleted_at IS NULL
                      AND ri.is_trashed = 0
                      AND ri.is_inbox = 0
                      AND rq.id IS NULL
                      AND (dv.id IS NULL OR dv.opened_at < ?)
                    GROUP BY ri.id
                    HAVING COUNT(dv.id) <= 1
                    ORDER BY ri.created_at ASC
                    LIMIT 10
                """, arguments: [thirtyDaysAgoStr])

                var ids: [ReferenceItem.ID] = []
                for row in forgottenIDs {
                    if let idStr = row["id"] as String?,
                       let id = UUID(uuidString: idStr) {
                        ids.append(id)
                    }
                }
                return ids
            }
        } catch {
            print("GRDB surfaceForgottenReferences failed: \(error)")
            return []
        }
    }

    static func autoEnqueueForgottenReferences() -> Int {
        let forgottenIDs = surfaceForgottenReferences()
        for id in forgottenIDs {
            addToQueue(referenceID: id)
        }
        return forgottenIDs.count
    }
}
