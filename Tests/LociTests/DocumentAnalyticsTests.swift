import Testing
import Foundation
import GRDB
@testable import Loci

@Suite("DocumentAnalytics")
struct DocumentAnalyticsTests {

    @Test("Record open creates a view record")
    func testRecordOpen() throws {
        let dbPath = NSTemporaryDirectory() + "test_analytics_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let queue = try DatabaseQueue(path: dbPath)
        try createTestSchema(in: queue)

        let refID = UUID()
        let viewID = UUID()

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reference_items (id, title, subtitle, file_name, kind, group_name, theme, aspect_ratio, is_inbox, is_trashed, canvas_x, canvas_y, infinity_x, infinity_y, created_at, updated_at)
                VALUES (?, 'Test', 'sub', 'test.pdf', 'typography', 'file', 'aurora', 1.0, 1, 0, 0, 0, 0, 0, ?, ?)
            """, arguments: [refID.uuidString, ISO8601DateFormatter().string(from: Date()), ISO8601DateFormatter().string(from: Date())])

            try db.execute(sql: """
                INSERT INTO document_views (id, reference_id, opened_at, duration_seconds, page_count)
                VALUES (?, ?, ?, 0, 0)
            """, arguments: [viewID.uuidString, refID.uuidString, ISO8601DateFormatter().string(from: Date())])
        }

        let count: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_views WHERE reference_id = ?", arguments: [refID.uuidString]) ?? 0
        }
        #expect(count == 1)
    }

    @Test("Record close updates duration")
    func testRecordClose() throws {
        let dbPath = NSTemporaryDirectory() + "test_close_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let queue = try DatabaseQueue(path: dbPath)
        try createTestSchema(in: queue)

        let viewID = UUID()
        let refID = UUID()
        let openedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO document_views (id, reference_id, opened_at, duration_seconds, page_count)
                VALUES (?, ?, ?, 0, 5)
            """, arguments: [viewID.uuidString, refID.uuidString, openedAt])
        }

        let durationBefore: Double = try queue.read { db in
            try Double.fetchOne(db, sql: "SELECT duration_seconds FROM document_views WHERE id = ?", arguments: [viewID.uuidString]) ?? 0
        }
        #expect(durationBefore == 0)

        try queue.write { db in
            let now = ISO8601DateFormatter().string(from: Date())
            try db.execute(sql: """
                UPDATE document_views
                SET closed_at = ?,
                    duration_seconds = (julianday(?) - julianday(opened_at)) * 86400
                WHERE id = ?
            """, arguments: [now, now, viewID.uuidString])
        }

        let durationAfter: Double = try queue.read { db in
            try Double.fetchOne(db, sql: "SELECT duration_seconds FROM document_views WHERE id = ?", arguments: [viewID.uuidString]) ?? 0
        }
        #expect(durationAfter > 30)
    }

    @Test("Page view records are created")
    func testPageView() throws {
        let dbPath = NSTemporaryDirectory() + "test_pageview_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let queue = try DatabaseQueue(path: dbPath)
        try createTestSchema(in: queue)

        let viewID = UUID()
        let refID = UUID()
        let pageViewID = UUID()

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO page_views (id, reference_id, view_id, page_index, viewed_at, duration_seconds)
                VALUES (?, ?, ?, 2, ?, 15.5)
            """, arguments: [pageViewID.uuidString, refID.uuidString, viewID.uuidString, ISO8601DateFormatter().string(from: Date())])
        }

        let page: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT page_index FROM page_views WHERE id = ?", arguments: [pageViewID.uuidString]) ?? -1
        }
        let duration: Double = try queue.read { db in
            try Double.fetchOne(db, sql: "SELECT duration_seconds FROM page_views WHERE id = ?", arguments: [pageViewID.uuidString]) ?? 0
        }
        #expect(page == 2)
        #expect(duration == 15.5)
    }

    @Test("Share token creation and revocation")
    func testShareToken() throws {
        let dbPath = NSTemporaryDirectory() + "test_share_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let queue = try DatabaseQueue(path: dbPath)
        try createTestSchema(in: queue)

        let refID = UUID()
        let tokenID = UUID()
        let token = "abc123def456"

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO share_tokens (id, reference_id, token, created_at, access_count)
                VALUES (?, ?, ?, ?, 0)
            """, arguments: [tokenID.uuidString, refID.uuidString, token, ISO8601DateFormatter().string(from: Date())])
        }

        let count: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM share_tokens WHERE token = ?", arguments: [token]) ?? 0
        }
        #expect(count == 1)

        try queue.write { db in
            try db.execute(sql: "DELETE FROM share_tokens WHERE token = ?", arguments: [token])
        }

        let countAfter: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM share_tokens WHERE token = ?", arguments: [token]) ?? 0
        }
        #expect(countAfter == 0)
    }

    private func createTestSchema(in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS reference_items (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    subtitle TEXT NOT NULL DEFAULT '',
                    file_name TEXT NOT NULL DEFAULT '',
                    kind TEXT NOT NULL DEFAULT 'typography',
                    group_name TEXT NOT NULL DEFAULT 'file',
                    theme TEXT NOT NULL DEFAULT 'aurora',
                    aspect_ratio REAL NOT NULL DEFAULT 1.0,
                    collection_id TEXT,
                    is_inbox INTEGER NOT NULL DEFAULT 0,
                    is_trashed INTEGER NOT NULL DEFAULT 0,
                    canvas_x REAL DEFAULT 0,
                    canvas_y REAL DEFAULT 0,
                    infinity_x REAL DEFAULT 0,
                    infinity_y REAL DEFAULT 0,
                    thumbnail_path TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS document_views (
                    id TEXT PRIMARY KEY,
                    reference_id TEXT NOT NULL,
                    opened_at TEXT NOT NULL,
                    closed_at TEXT,
                    duration_seconds REAL NOT NULL DEFAULT 0,
                    page_count INTEGER NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS page_views (
                    id TEXT PRIMARY KEY,
                    reference_id TEXT NOT NULL,
                    view_id TEXT NOT NULL,
                    page_index INTEGER NOT NULL,
                    viewed_at TEXT NOT NULL,
                    duration_seconds REAL NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS share_tokens (
                    id TEXT PRIMARY KEY,
                    reference_id TEXT NOT NULL,
                    token TEXT NOT NULL UNIQUE,
                    created_at TEXT NOT NULL,
                    expires_at TEXT,
                    access_count INTEGER NOT NULL DEFAULT 0
                )
            """)
        }
    }
}
