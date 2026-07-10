import Foundation
import GRDB

struct DocumentViewRecord: Identifiable, Hashable {
    var id: UUID
    var referenceID: ReferenceItem.ID
    var openedAt: Date
    var closedAt: Date?
    var durationSeconds: Double
    var pageCount: Int
}

struct PageViewRecord: Identifiable, Hashable {
    var id: UUID
    var referenceID: ReferenceItem.ID
    var viewID: UUID
    var pageIndex: Int
    var viewedAt: Date
    var durationSeconds: Double
}

struct ShareTokenRecord: Identifiable, Hashable {
    var id: UUID
    var referenceID: ReferenceItem.ID
    var token: String
    var createdAt: Date
    var expiresAt: Date?
    var accessCount: Int
}

struct DocumentEngagement {
    var totalViews: Int
    var totalDurationSeconds: Double
    var uniquePagesViewed: Int
    var averageViewDuration: Double
    var lastViewedAt: Date?
    var topPages: [PageHeat]
    var viewHistory: [DocumentViewRecord]
}

struct PageHeat: Identifiable {
    var id: Int { pageIndex }
    var pageIndex: Int
    var viewCount: Int
    var totalDurationSeconds: Double
}

@MainActor
enum DocumentAnalytics {
    private static let iso8601 = ISO8601DateFormatter()

    static func recordOpen(referenceID: ReferenceItem.ID) -> UUID? {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return nil }
        let id = UUID()
        let now = iso8601.string(from: Date())
        do {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO document_views (id, reference_id, opened_at, duration_seconds, page_count)
                    VALUES (?, ?, ?, 0, 0)
                """, arguments: [id.uuidString, referenceID.uuidString, now])
            }
            return id
        } catch {
            print("GRDB recordOpen failed: \(error)")
            return nil
        }
    }

    static func recordClose(viewID: UUID, pageCount: Int) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        let now = iso8601.string(from: Date())
        do {
            try queue.write { db in
                try db.execute(sql: """
                    UPDATE document_views
                    SET closed_at = ?,
                        duration_seconds = (julianday(?) - julianday(opened_at)) * 86400,
                        page_count = ?
                    WHERE id = ?
                """, arguments: [now, now, pageCount, viewID.uuidString])
            }
        } catch {
            print("GRDB recordClose failed: \(error)")
        }
    }

    static func recordPageView(viewID: UUID, referenceID: ReferenceItem.ID, pageIndex: Int) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        let id = UUID()
        let now = iso8601.string(from: Date())
        do {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO page_views (id, reference_id, view_id, page_index, viewed_at, duration_seconds)
                    VALUES (?, ?, ?, ?, ?, 0)
                """, arguments: [id.uuidString, referenceID.uuidString, viewID.uuidString, pageIndex, now])
            }
        } catch {
            print("GRDB recordPageView failed: \(error)")
        }
    }

    static func recordPageDuration(viewID: UUID, pageIndex: Int, duration: Double) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: """
                    UPDATE page_views
                    SET duration_seconds = duration_seconds + ?
                    WHERE view_id = ? AND page_index = ?
                    ORDER BY viewed_at DESC LIMIT 1
                """, arguments: [duration, viewID.uuidString, pageIndex])
            }
        } catch {
            print("GRDB recordPageDuration failed: \(error)")
        }
    }

    static func engagement(for referenceID: ReferenceItem.ID) -> DocumentEngagement {
        guard let queue = LociPersistentStore.shared?.grdbQueue else {
            return DocumentEngagement(totalViews: 0, totalDurationSeconds: 0, uniquePagesViewed: 0, averageViewDuration: 0, lastViewedAt: nil, topPages: [], viewHistory: [])
        }

        do {
            return try queue.read { db in
                let refStr = referenceID.uuidString

                var totalViews = 0
                var totalDuration = 0.0
                var lastViewed: Date?
                var views: [DocumentViewRecord] = []

                let viewRows = try Row.fetchAll(db, sql: """
                    SELECT id, reference_id, opened_at, closed_at, duration_seconds, page_count
                    FROM document_views
                    WHERE reference_id = ?
                    ORDER BY opened_at DESC
                    LIMIT 50
                """, arguments: [refStr])

                for row in viewRows {
                    guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                          let refID = (row["reference_id"] as String?).flatMap(UUID.init(uuidString:)),
                          let openedStr = row["opened_at"] as String? else { continue }
                    let openedAt = iso8601.date(from: openedStr) ?? Date()
                    let closedAt = (row["closed_at"] as String?).flatMap { iso8601.date(from: $0) }
                    let duration = row["duration_seconds"] as Double? ?? 0
                    let pages = row["page_count"] as Int? ?? 0

                    totalViews += 1
                    totalDuration += duration
                    if lastViewed == nil { lastViewed = openedAt }

                    views.append(DocumentViewRecord(
                        id: id, referenceID: refID, openedAt: openedAt, closedAt: closedAt,
                        durationSeconds: duration, pageCount: pages
                    ))
                }

                var pageHeat: [Int: (count: Int, duration: Double)] = [:]
                let heatRows = try Row.fetchAll(db, sql: """
                    SELECT page_index, COUNT(*), SUM(duration_seconds)
                    FROM page_views
                    WHERE reference_id = ?
                    GROUP BY page_index
                    ORDER BY COUNT(*) DESC
                """, arguments: [refStr])

                for row in heatRows {
                    let pageIndex = row["page_index"] as Int? ?? 0
                    let count = row["COUNT(*)"] as Int? ?? 0
                    let duration = row["SUM(duration_seconds)"] as Double? ?? 0
                    pageHeat[pageIndex] = (count, duration)
                }

                let topPages = pageHeat.map { PageHeat(pageIndex: $0.key, viewCount: $0.value.count, totalDurationSeconds: $0.value.duration) }
                    .sorted { $0.viewCount > $1.viewCount }

                return DocumentEngagement(
                    totalViews: totalViews,
                    totalDurationSeconds: totalDuration,
                    uniquePagesViewed: pageHeat.count,
                    averageViewDuration: totalViews > 0 ? totalDuration / Double(totalViews) : 0,
                    lastViewedAt: lastViewed,
                    topPages: topPages,
                    viewHistory: views
                )
            }
        } catch {
            print("GRDB engagement failed: \(error)")
            return DocumentEngagement(totalViews: 0, totalDurationSeconds: 0, uniquePagesViewed: 0, averageViewDuration: 0, lastViewedAt: nil, topPages: [], viewHistory: [])
        }
    }

    static func createShareToken(for referenceID: ReferenceItem.ID) -> String? {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return nil }
        let id = UUID()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        let now = iso8601.string(from: Date())
        do {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO share_tokens (id, reference_id, token, created_at, access_count)
                    VALUES (?, ?, ?, ?, 0)
                """, arguments: [id.uuidString, referenceID.uuidString, String(token), now])
            }
            return String(token)
        } catch {
            print("GRDB createShareToken failed: \(error)")
            return nil
        }
    }

    static func revokeShareToken(_ token: String) {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM share_tokens WHERE token = ?", arguments: [token])
            }
        } catch {
            print("GRDB revokeShareToken failed: \(error)")
        }
    }

    static func shareTokens(for referenceID: ReferenceItem.ID) -> [ShareTokenRecord] {
        guard let queue = LociPersistentStore.shared?.grdbQueue else { return [] }
        do {
            return try queue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, reference_id, token, created_at, expires_at, access_count
                    FROM share_tokens
                    WHERE reference_id = ?
                    ORDER BY created_at DESC
                """, arguments: [referenceID.uuidString])

                return rows.compactMap { row in
                    guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                          let refID = (row["reference_id"] as String?).flatMap(UUID.init(uuidString:)),
                          let token = row["token"] as String?,
                          let createdStr = row["created_at"] as String? else { return nil }
                    let createdAt = iso8601.date(from: createdStr) ?? Date()
                    let expiresAt = (row["expires_at"] as String?).flatMap { iso8601.date(from: $0) }
                    let accessCount = row["access_count"] as Int? ?? 0
                    return ShareTokenRecord(id: id, referenceID: refID, token: token, createdAt: createdAt, expiresAt: expiresAt, accessCount: accessCount)
                }
            }
        } catch {
            print("GRDB shareTokens failed: \(error)")
            return []
        }
    }
}
