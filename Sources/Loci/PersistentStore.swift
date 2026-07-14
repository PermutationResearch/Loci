import Foundation
import GRDB
import SQLite3
import SwiftUI

enum ImportSourceKind: String, CaseIterable, Identifiable, Sendable {
    case url
    case file
    case screenshot
    case clipboard
    case browserExtension = "extension"
    case api
    case extract
    case wikiCompile = "wiki-compile"

    var id: String { rawValue }
}

enum ImportJobStatus: String, CaseIterable, Identifiable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    var id: String { rawValue }
}

struct ImportJobRecord: Identifiable, Hashable {
    var id: UUID
    var source: ImportSourceKind
    var status: ImportJobStatus
    var payload: String
    var referenceID: UUID?
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
}

struct PersistentStoreSnapshot {
    var collections: [ReferenceCollection]
    var references: [ReferenceItem]
    var importJobs: [ImportJobRecord]
}

struct PersistentStoreStats {
    var databaseURL: URL
    var assetRootURL: URL
    var originalsURL: URL
    var thumbnailsURL: URL
    var referenceCount: Int
    var collectionCount: Int
    var smartCollectionCount: Int
    var tagCount: Int
    var linkCount: Int
    var assetCount: Int
    var importJobCount: Int
    var apiTokenCount: Int
    var historyEventCount: Int
    var queuedImportCount: Int
    var recentAPIRequestCount: Int

    static let empty = PersistentStoreStats(
        databaseURL: URL(fileURLWithPath: "/"),
        assetRootURL: URL(fileURLWithPath: "/"),
        originalsURL: URL(fileURLWithPath: "/"),
        thumbnailsURL: URL(fileURLWithPath: "/"),
        referenceCount: 0,
        collectionCount: 0,
        smartCollectionCount: 0,
        tagCount: 0,
        linkCount: 0,
        assetCount: 0,
        importJobCount: 0,
        apiTokenCount: 0,
        historyEventCount: 0,
        queuedImportCount: 0,
        recentAPIRequestCount: 0
    )
}

@MainActor
final class LociPersistentStore {
    static let shared = try? LociPersistentStore()

    let rootURL: URL
    let databaseURL: URL
    let assetRootURL: URL
    let originalsURL: URL
    let thumbnailsURL: URL
    let importStagingURL: URL

    private var db: OpaquePointer?
    var grdbQueue: DatabaseQueue?
    private let iso8601 = ISO8601DateFormatter()
    private static let managedDocumentSQLPredicate = """
    (
        ri.group_name = 'Files'
        OR ri.kind = 'typography'
        OR ri.subtitle = 'Quick Note'
        OR lower(ri.file_name) GLOB '*.pdf'
        OR lower(ri.file_name) GLOB '*.doc'
        OR lower(ri.file_name) GLOB '*.docx'
        OR lower(ri.file_name) GLOB '*.pages'
        OR lower(ri.file_name) GLOB '*.key'
        OR lower(ri.file_name) GLOB '*.ppt'
        OR lower(ri.file_name) GLOB '*.pptx'
        OR lower(ri.file_name) GLOB '*.xls'
        OR lower(ri.file_name) GLOB '*.xlsx'
        OR lower(ri.file_name) GLOB '*.csv'
        OR lower(ri.file_name) GLOB '*.txt'
        OR lower(ri.file_name) GLOB '*.md'
        OR lower(ri.file_name) GLOB '*.rtf'
        OR lower(ri.file_name) GLOB '*.png'
        OR lower(ri.file_name) GLOB '*.jpg'
        OR lower(ri.file_name) GLOB '*.jpeg'
        OR lower(ri.file_name) GLOB '*.gif'
        OR lower(ri.file_name) GLOB '*.webp'
        OR lower(ri.file_name) GLOB '*.heic'
        OR lower(ri.file_name) GLOB '*.svg'
        OR lower(ri.file_name) GLOB '*.zip'
        OR lower(ri.file_name) GLOB '*.json'
    )
    """

    init() throws {
        rootURL = LibraryLocation.currentRootURL
        databaseURL = Self.databaseURL(in: rootURL)
        assetRootURL = rootURL.appendingPathComponent("Assets", isDirectory: true)
        originalsURL = assetRootURL.appendingPathComponent("Originals", isDirectory: true)
        thumbnailsURL = assetRootURL.appendingPathComponent("Thumbnails", isDirectory: true)
        importStagingURL = rootURL.appendingPathComponent("Imports", isDirectory: true)

        try createDirectories()
        try open()
        try configure()
        try migrate()
        try openGRDB()
    }

    private static func databaseURL(in rootURL: URL) -> URL {
        let lociURL = rootURL.appendingPathComponent(AppBrand.databaseFileName)
        let legacyURL = rootURL.appendingPathComponent(AppBrand.legacyDatabaseFileName)
        if FileManager.default.fileExists(atPath: legacyURL.path),
           !FileManager.default.fileExists(atPath: lociURL.path) {
            return legacyURL
        }
        return lociURL
    }

    func removeGeneratedDemoDataIfNeeded() {
        let version = migrationVersion()

        if version < 2 {
            transaction {
                withStatement("DELETE FROM import_jobs WHERE payload IN (?, ?, ?)") { statement in
                    bind(statement, 1, "https://asekachov.com/atlasformac")
                    bind(statement, 2, originalsURL.path)
                    bind(statement, 3, "POST /references")
                    step(statement)
                }

                execute("""
                DELETE FROM assets
                WHERE reference_id IN (
                    SELECT id FROM reference_items
                    WHERE file_name GLOB 'reference-[0-9][0-9][0-9].png'
                    AND collection_id IN (
                        SELECT id FROM collections
                        WHERE name IN ('Hello_Loci', 'Graphic design', 'Mac Apps', 'Loci versions', 'Objects')
                    )
                )
                """)
                execute("""
                DELETE FROM references_fts
                WHERE reference_id IN (
                    SELECT id FROM reference_items
                    WHERE file_name GLOB 'reference-[0-9][0-9][0-9].png'
                    AND collection_id IN (
                        SELECT id FROM collections
                        WHERE name IN ('Hello_Loci', 'Graphic design', 'Mac Apps', 'Loci versions', 'Objects')
                    )
                )
                """)
                execute("""
                DELETE FROM links
                WHERE source_reference_id IN (
                    SELECT id FROM reference_items
                    WHERE file_name GLOB 'reference-[0-9][0-9][0-9].png'
                    AND collection_id IN (
                        SELECT id FROM collections
                        WHERE name IN ('Hello_Loci', 'Graphic design', 'Mac Apps', 'Loci versions', 'Objects')
                    )
                )
                OR target_reference_id IN (
                    SELECT id FROM reference_items
                    WHERE file_name GLOB 'reference-[0-9][0-9][0-9].png'
                    AND collection_id IN (
                        SELECT id FROM collections
                        WHERE name IN ('Hello_Loci', 'Graphic design', 'Mac Apps', 'Loci versions', 'Objects')
                    )
                )
                """)
                execute("""
                DELETE FROM reference_items
                WHERE file_name GLOB 'reference-[0-9][0-9][0-9].png'
                    AND collection_id IN (
                        SELECT id FROM collections
                        WHERE name IN ('Hello_Loci', 'Graphic design', 'Mac Apps', 'Loci versions', 'Objects')
                    )
                """)
                execute("""
                DELETE FROM collections
                WHERE name IN ('Hello_Loci', 'Graphic design', 'Mac Apps', 'Loci versions', 'Objects')
                AND NOT EXISTS (
                    SELECT 1 FROM reference_items
                    WHERE reference_items.collection_id = collections.id
                )
                """)
            }

            execute("INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (2, '\(timestamp())')")
        }

        if version < 3 {
            transaction {
                execute("""
                DELETE FROM assets
                WHERE reference_id IN (
                    SELECT id FROM reference_items
                    WHERE collection_id IN (SELECT id FROM collections WHERE name = 'Demo Library')
                    AND (
                        title IN (
                            'Apple Human Interface Guidelines',
                            'Linear product motion',
                            'Raycast command palette',
                            'Mobbin mobile flow references',
                            'Figma community systems',
                            'Saved X thread: visual research',
                            'Design system audit checklist',
                            'Reference capture workflow'
                        )
                        OR subtitle IN (
                            'https://developer.apple.com/design/human-interface-guidelines',
                            'https://linear.app',
                            'https://raycast.com',
                            'https://mobbin.com',
                            'https://www.figma.com/community',
                            'https://x.com/design/status/1789200000000000000'
                        )
                    )
                )
                """)
                execute("""
                DELETE FROM references_fts
                WHERE reference_id IN (
                    SELECT id FROM reference_items
                    WHERE collection_id IN (SELECT id FROM collections WHERE name = 'Demo Library')
                    AND (
                        title IN (
                            'Apple Human Interface Guidelines',
                            'Linear product motion',
                            'Raycast command palette',
                            'Mobbin mobile flow references',
                            'Figma community systems',
                            'Saved X thread: visual research',
                            'Design system audit checklist',
                            'Reference capture workflow'
                        )
                        OR subtitle IN (
                            'https://developer.apple.com/design/human-interface-guidelines',
                            'https://linear.app',
                            'https://raycast.com',
                            'https://mobbin.com',
                            'https://www.figma.com/community',
                            'https://x.com/design/status/1789200000000000000'
                        )
                    )
                )
                """)
                execute("""
                DELETE FROM links
                WHERE source_reference_id IN (
                    SELECT id FROM reference_items
                    WHERE collection_id IN (SELECT id FROM collections WHERE name = 'Demo Library')
                    AND (
                        title IN (
                            'Apple Human Interface Guidelines',
                            'Linear product motion',
                            'Raycast command palette',
                            'Mobbin mobile flow references',
                            'Figma community systems',
                            'Saved X thread: visual research',
                            'Design system audit checklist',
                            'Reference capture workflow'
                        )
                        OR subtitle IN (
                            'https://developer.apple.com/design/human-interface-guidelines',
                            'https://linear.app',
                            'https://raycast.com',
                            'https://mobbin.com',
                            'https://www.figma.com/community',
                            'https://x.com/design/status/1789200000000000000'
                        )
                    )
                )
                OR target_reference_id IN (
                    SELECT id FROM reference_items
                    WHERE collection_id IN (SELECT id FROM collections WHERE name = 'Demo Library')
                    AND (
                        title IN (
                            'Apple Human Interface Guidelines',
                            'Linear product motion',
                            'Raycast command palette',
                            'Mobbin mobile flow references',
                            'Figma community systems',
                            'Saved X thread: visual research',
                            'Design system audit checklist',
                            'Reference capture workflow'
                        )
                        OR subtitle IN (
                            'https://developer.apple.com/design/human-interface-guidelines',
                            'https://linear.app',
                            'https://raycast.com',
                            'https://mobbin.com',
                            'https://www.figma.com/community',
                            'https://x.com/design/status/1789200000000000000'
                        )
                    )
                )
                """)
                execute("""
                DELETE FROM reference_items
                WHERE collection_id IN (SELECT id FROM collections WHERE name = 'Demo Library')
                AND (
                    title IN (
                        'Apple Human Interface Guidelines',
                        'Linear product motion',
                        'Raycast command palette',
                        'Mobbin mobile flow references',
                        'Figma community systems',
                        'Saved X thread: visual research',
                        'Design system audit checklist',
                        'Reference capture workflow'
                    )
                    OR subtitle IN (
                        'https://developer.apple.com/design/human-interface-guidelines',
                        'https://linear.app',
                        'https://raycast.com',
                        'https://mobbin.com',
                        'https://www.figma.com/community',
                        'https://x.com/design/status/1789200000000000000'
                    )
                )
                """)
                execute("""
                DELETE FROM collections
                WHERE name = 'Demo Library'
                AND NOT EXISTS (
                    SELECT 1 FROM reference_items
                    WHERE reference_items.collection_id = collections.id
                )
                """)
            }

            let generatedFileNames = [
                "apple-human-interface-guidelines.webloc",
                "linear-product-motion.webloc",
                "raycast-command-palette.webloc",
                "mobbin-mobile-flow-references.webloc",
                "figma-community-systems.webloc",
                "saved-x-thread-visual-research.webloc",
                "design-system-audit-checklist.md",
                "reference-capture-workflow.md"
            ]
            for fileName in generatedFileNames {
                try? FileManager.default.removeItem(at: originalsURL.appendingPathComponent(fileName))
            }

            execute("INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (3, '\(timestamp())')")
        }
    }

    private func migrationVersion() -> Int {
        var version = 0
        withStatement("SELECT COALESCE(MAX(version), 0) FROM schema_migrations") { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                version = Int(sqlite3_column_int64(statement, 0))
            }
        }
        return version
    }

    func loadSnapshot() -> PersistentStoreSnapshot {
        PersistentStoreSnapshot(
            collections: loadCollections(),
            references: loadReferences(),
            importJobs: loadImportJobs(limit: 30)
        )
    }

    func loadCollectionsSnapshot() -> [ReferenceCollection] {
        loadCollections()
    }

    func loadRecentImportJobs() -> [ImportJobRecord] {
        loadImportJobs(limit: 30)
    }

    func stats() -> PersistentStoreStats {
        guard let queue = grdbQueue else {
            return PersistentStoreStats(
                databaseURL: databaseURL, assetRootURL: assetRootURL, originalsURL: originalsURL, thumbnailsURL: thumbnailsURL,
                referenceCount: 0, collectionCount: 0, smartCollectionCount: 0, tagCount: 0, linkCount: 0,
                assetCount: 0, importJobCount: 0, apiTokenCount: 0, historyEventCount: 0, queuedImportCount: 0, recentAPIRequestCount: 0
            )
        }
        do {
            return try queue.read { db in
                let refCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reference_items WHERE deleted_at IS NULL") ?? 0
                let colCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collections WHERE deleted_at IS NULL") ?? 0
                let smartCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM smart_collections") ?? 0
                let tagCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags") ?? 0
                let linkCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM links") ?? 0
                let assetCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") ?? 0
                let jobCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_jobs") ?? 0
                let tokenCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM api_tokens") ?? 0
                let historyCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM history_events") ?? 0
                let queuedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_jobs WHERE status IN ('queued', 'running')") ?? 0
                let apiReqCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM api_requests") ?? 0
                return PersistentStoreStats(
                    databaseURL: databaseURL, assetRootURL: assetRootURL, originalsURL: originalsURL, thumbnailsURL: thumbnailsURL,
                    referenceCount: refCount, collectionCount: colCount, smartCollectionCount: smartCount,
                    tagCount: tagCount, linkCount: linkCount, assetCount: assetCount,
                    importJobCount: jobCount, apiTokenCount: tokenCount, historyEventCount: historyCount,
                    queuedImportCount: queuedCount, recentAPIRequestCount: apiReqCount
                )
            }
        } catch {
            print("GRDB stats failed: \(error)")
            return PersistentStoreStats(
                databaseURL: databaseURL, assetRootURL: assetRootURL, originalsURL: originalsURL, thumbnailsURL: thumbnailsURL,
                referenceCount: 0, collectionCount: 0, smartCollectionCount: 0, tagCount: 0, linkCount: 0,
                assetCount: 0, importJobCount: 0, apiTokenCount: 0, historyEventCount: 0, queuedImportCount: 0, recentAPIRequestCount: 0
            )
        }
    }

    func upsert(collection: ReferenceCollection) {
        guard let queue = grdbQueue else { return }
        let now = timestamp()
        do {
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO collections (id, name, symbol, tint_hex, brief, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM collections WHERE id = ?), ?), ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    symbol = excluded.symbol,
                    tint_hex = excluded.tint_hex,
                    brief = excluded.brief,
                    updated_at = excluded.updated_at,
                    deleted_at = NULL
                """, arguments: [collection.id.uuidString, collection.name, collection.symbol, "system-gray", collection.brief, collection.id.uuidString, now, now])
            }
        } catch {
            print("GRDB upsert(collection:) failed: \(error)")
        }
        recordHistory(entity: "collection", entityID: collection.id, action: "upsert", summary: collection.name)
    }

    func softDeleteCollection(id: UUID) {
        guard let queue = grdbQueue else { return }
        let now = timestamp()
        do {
            try queue.write { db in
                try db.execute(sql: "UPDATE collections SET deleted_at = ?, updated_at = ? WHERE id = ?", arguments: [now, now, id.uuidString])
            }
        } catch {
            print("GRDB softDeleteCollection failed: \(error)")
        }
        recordHistory(entity: "collection", entityID: id, action: "delete", summary: "Soft deleted collection")
    }

    func upsert(reference: ReferenceItem, recordsHistory: Bool = true, refreshFTS: Bool = true) {
        guard let queue = grdbQueue else { return }
        let now = timestamp()
        do {
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO reference_items (
                    id, title, subtitle, file_name, kind, group_name, theme, aspect_ratio, collection_id,
                    is_inbox, is_trashed, canvas_x, canvas_y, infinity_x, infinity_y, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM reference_items WHERE id = ?), ?), ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    subtitle = excluded.subtitle,
                    file_name = excluded.file_name,
                    kind = excluded.kind,
                    group_name = excluded.group_name,
                    theme = excluded.theme,
                    aspect_ratio = excluded.aspect_ratio,
                    collection_id = excluded.collection_id,
                    is_inbox = excluded.is_inbox,
                    is_trashed = excluded.is_trashed,
                    canvas_x = excluded.canvas_x,
                    canvas_y = excluded.canvas_y,
                    infinity_x = excluded.infinity_x,
                    infinity_y = excluded.infinity_y,
                    updated_at = excluded.updated_at,
                    deleted_at = NULL
                """, arguments: [
                    reference.id.uuidString, reference.title, reference.subtitle, reference.fileName,
                    reference.kind.rawValue, reference.group.rawValue, reference.theme.rawValue,
                    Double(reference.aspectRatio), reference.collectionID?.uuidString,
                    reference.isInbox ? 1 : 0, reference.isTrashed ? 1 : 0,
                    Double(reference.canvasPosition.width), Double(reference.canvasPosition.height),
                    Double(reference.infinityPosition.x), Double(reference.infinityPosition.y),
                    reference.id.uuidString, now, now
                ])
            }
        } catch {
            print("GRDB upsert(reference:) failed: \(error)")
        }
        if refreshFTS {
            refreshSearchIndex(for: reference)
        }
        if recordsHistory {
            recordHistory(entity: "reference", entityID: reference.id, action: "upsert", summary: reference.title)
        }
    }

    @discardableResult
    func enqueueImportJob(
        source: ImportSourceKind,
        payload: String,
        status: ImportJobStatus = .queued,
        referenceID: UUID? = nil,
        errorMessage: String? = nil
    ) -> ImportJobRecord {
        let job = ImportJobRecord(
            id: UUID(),
            source: source,
            status: status,
            payload: payload,
            referenceID: referenceID,
            errorMessage: errorMessage,
            createdAt: Date(),
            updatedAt: Date()
        )
        guard let queue = grdbQueue else { return job }
        do {
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO import_jobs (id, source, status, payload, reference_id, error_message, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    job.id.uuidString, job.source.rawValue, job.status.rawValue, job.payload,
                    job.referenceID?.uuidString, job.errorMessage,
                    iso8601.string(from: job.createdAt), iso8601.string(from: job.updatedAt)
                ])
            }
        } catch {
            print("GRDB enqueueImportJob failed: \(error)")
        }
        recordHistory(entity: "import_job", entityID: job.id, action: "enqueue", summary: "\(source.rawValue): \(payload)")
        return job
    }

    func transaction<T>(_ body: () throws -> T) -> T? {
        guard let queue = grdbQueue else { return nil }
        do {
            return try queue.write { _ in try body() }
        } catch {
            print("GRDB transaction failed: \(error)")
            return nil
        }
    }

    func importFileToOriginals(from sourceURL: URL) -> URL? {
        let rawExt = sourceURL.pathExtension.lowercased()
        let safeExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "tiff", "heic", "bmp", "svg",
            "pdf", "txt", "md", "rtf", "html", "htm",
            "webloc", "url",
            "app", "pages", "key", "ppt", "pptx", "doc", "docx", "xls", "xlsx",
            "json", "csv", "zip", "dmg"
        ]
        let ext = safeExtensions.contains(rawExt) ? rawExt : "dat"
        let fileName = "\(UUID().uuidString.lowercased()).\(ext)"
        let destURL = originalsURL.appendingPathComponent(fileName)
        try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        guard FileManager.default.fileExists(atPath: destURL.path) else { return nil }
        return destURL
    }

    func generateThumbnail(from fileURL: URL, for item: ReferenceItem, maxSize: CGSize = CGSize(width: 400, height: 400)) -> URL? {
        let maxPixelSize = max(Int(max(maxSize.width, maxSize.height)), 1)
        guard let pngData = LociImageLoader.pngDataSync(from: fileURL, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return writeThumbnailPNGData(pngData, for: item.id)
    }

    func generateThumbnail(from image: NSImage, for itemID: ReferenceItem.ID, maxSize: CGSize = CGSize(width: 400, height: 400)) -> URL? {
        let thumbName = "thumb_\(itemID.uuidString.lowercased()).png"
        let thumbURL = thumbnailsURL.appendingPathComponent(thumbName)

        let targetSize = image.size.aspectFitting(NSSize(width: maxSize.width, height: maxSize.height))
        guard let resized = image.resized(to: targetSize),
              let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        try? pngData.write(to: thumbURL, options: .atomic)
        return FileManager.default.fileExists(atPath: thumbURL.path) ? thumbURL : nil
    }

    func writeThumbnailPNGData(_ data: Data, for itemID: ReferenceItem.ID) -> URL? {
        let thumbName = "thumb_\(itemID.uuidString.lowercased()).png"
        let thumbURL = thumbnailsURL.appendingPathComponent(thumbName)
        try? data.write(to: thumbURL, options: .atomic)
        return FileManager.default.fileExists(atPath: thumbURL.path) ? thumbURL : nil
    }

    func createWeblocFile(for urlString: String, itemID: UUID) -> URL? {
        let fileName = "webloc_\(itemID.uuidString.lowercased()).webloc"
        let destURL = originalsURL.appendingPathComponent(fileName)
        let plist: [String: Any] = ["URL": urlString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return nil }
        try? data.write(to: destURL, options: .atomic)
        return FileManager.default.fileExists(atPath: destURL.path) ? destURL : nil
    }

    func batchTrashReferences(ids: Set<UUID>) {
        guard !ids.isEmpty, let queue = grdbQueue else { return }
        let now = timestamp()
        do {
            try queue.write { db in
                for id in ids {
                    try db.execute(sql: "UPDATE reference_items SET is_trashed = 1, updated_at = ? WHERE id = ?", arguments: [now, id.uuidString])
                }
            }
        } catch {
            print("GRDB batchTrashReferences failed: \(error)")
        }
        for id in ids {
            recordHistory(entity: "reference", entityID: id, action: "trash", summary: "Batch trashed")
        }
    }

    func batchDeleteReferences(ids: Set<UUID>) {
        guard !ids.isEmpty, let queue = grdbQueue else { return }
        do {
            try queue.write { db in
                for id in ids {
                    try db.execute(sql: "DELETE FROM references_fts WHERE reference_id = ?", arguments: [id.uuidString])
                    try db.execute(sql: "DELETE FROM reference_items WHERE id = ?", arguments: [id.uuidString])
                }
            }
        } catch {
            print("GRDB batchDeleteReferences failed: \(error)")
        }
        for id in ids {
            recordHistory(entity: "reference", entityID: id, action: "delete", summary: "Permanently deleted")
        }
    }

    func loadReference(id: UUID) -> ReferenceItem? {
        guard let queue = grdbQueue else { return nil }
        do {
            return try queue.read { db in
                let sql = """
                SELECT ri.id, ri.title, ri.subtitle, ri.file_name, ri.kind, ri.group_name, ri.theme, ri.aspect_ratio, ri.collection_id,
                       ri.is_inbox, ri.is_trashed, ri.canvas_x, ri.canvas_y, ri.infinity_x, ri.infinity_y,
                       a.thumbnail_path
                FROM reference_items ri
                LEFT JOIN assets a ON a.reference_id = ri.id AND (a.role = 'screenshot' OR a.role = 'primary')
                WHERE ri.id = ? AND ri.deleted_at IS NULL
                """
                guard let row = try Row.fetchOne(db, sql: sql, arguments: [id.uuidString]) else { return nil }
                guard let refID = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                      let title = row["title"] as String?,
                      let subtitle = row["subtitle"] as String?,
                      let fileName = row["file_name"] as String?,
                      let kindStr = row["kind"] as String?,
                      let kind = VisualKind(rawValue: kindStr),
                      let groupStr = row["group_name"] as String?,
                      let group = ReferenceGroup(rawValue: groupStr),
                      let themeStr = row["theme"] as String?,
                      let theme = ReferenceTheme(rawValue: themeStr) else { return nil }
                return ReferenceItem(
                    id: refID, title: title, subtitle: subtitle, fileName: fileName,
                    kind: kind, group: group, theme: theme,
                    aspectRatio: CGFloat(row["aspect_ratio"] as Double? ?? 1.0),
                    collectionID: (row["collection_id"] as String?).flatMap(UUID.init(uuidString:)),
                    isInbox: (row["is_inbox"] as Int? ?? 0) != 0,
                    isTrashed: (row["is_trashed"] as Int? ?? 0) != 0,
                    thumbnailPath: row["thumbnail_path"] as String?,
                    canvasPosition: CGSize(
                        width: CGFloat(row["canvas_x"] as Double? ?? 0),
                        height: CGFloat(row["canvas_y"] as Double? ?? 0)
                    ),
                    infinityPosition: CGPoint(
                        x: CGFloat(row["infinity_x"] as Double? ?? 0),
                        y: CGFloat(row["infinity_y"] as Double? ?? 0)
                    )
                )
            }
        } catch {
            print("GRDB loadReference failed: \(error)")
            return nil
        }
    }

    func nextQueuedJob() -> ImportJobRecord? {
        guard let queue = grdbQueue else { return nil }
        do {
            return try queue.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                SELECT id, source, status, payload, reference_id, error_message, created_at, updated_at
                FROM import_jobs WHERE status = 'queued' ORDER BY created_at ASC, rowid ASC LIMIT 1
                """) else { return nil }
                guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                      let sourceStr = row["source"] as String?,
                      let source = ImportSourceKind(rawValue: sourceStr),
                      let statusStr = row["status"] as String?,
                      let status = ImportJobStatus(rawValue: statusStr),
                      let payload = row["payload"] as String? else { return nil }
                return ImportJobRecord(
                    id: id, source: source, status: status, payload: payload,
                    referenceID: (row["reference_id"] as String?).flatMap(UUID.init(uuidString:)),
                    errorMessage: row["error_message"] as String?,
                    createdAt: iso8601.date(from: row["created_at"] as String? ?? "") ?? Date(),
                    updatedAt: iso8601.date(from: row["updated_at"] as String? ?? "") ?? Date()
                )
            }
        } catch {
            print("GRDB nextQueuedJob failed: \(error)")
            return nil
        }
    }

    func hasPendingImportJob(source: ImportSourceKind, referenceID: UUID) -> Bool {
        guard let queue = grdbQueue else { return false }
        do {
            return try queue.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM import_jobs
                    WHERE source = ? AND reference_id = ? AND status IN ('queued', 'running')
                    """,
                    arguments: [source.rawValue, referenceID.uuidString]
                ) ?? 0
            } > 0
        } catch {
            print("GRDB hasPendingImportJob failed: \(error)")
            return false
        }
    }

    func updateImportJobStatus(id: UUID, status: ImportJobStatus, errorMessage: String? = nil) {
        guard let queue = grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: "UPDATE import_jobs SET status = ?, updated_at = ?, error_message = ? WHERE id = ?",
                               arguments: [status.rawValue, timestamp(), errorMessage, id.uuidString])
            }
        } catch {
            print("GRDB updateImportJobStatus failed: \(error)")
        }
    }

    func updateReferenceThumbnail(id: ReferenceItem.ID, thumbPath: String) {
        guard let queue = grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO assets (id, reference_id, role, thumbnail_path, created_at)
                VALUES (?, ?, 'screenshot', ?, ?)
                ON CONFLICT(id) DO UPDATE SET thumbnail_path = excluded.thumbnail_path
                """, arguments: [id.uuidString, id.uuidString, thumbPath, timestamp()])
            }
        } catch {
            print("GRDB updateReferenceThumbnail failed: \(error)")
        }
    }

    private func createDirectories() throws {
        let urls = [rootURL, assetRootURL, originalsURL, thumbnailsURL, importStagingURL]
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func open() throws {
        if sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw NSError(domain: "Loci.SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }

    private func configure() throws {
        execute("PRAGMA foreign_keys = ON")
        execute("PRAGMA journal_mode = WAL")
        execute("PRAGMA synchronous = NORMAL")
        execute("PRAGMA busy_timeout = 5000")
    }

    private func openGRDB() throws {
        var config = GRDB.Configuration()
        config.readonly = false
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        grdbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
    }

    private func migrate() throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS collections (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                symbol TEXT NOT NULL,
                tint_hex TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                deleted_at TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS reference_items (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                subtitle TEXT NOT NULL,
                file_name TEXT NOT NULL,
                kind TEXT NOT NULL,
                group_name TEXT NOT NULL,
                theme TEXT NOT NULL,
                aspect_ratio REAL NOT NULL,
                collection_id TEXT REFERENCES collections(id) ON DELETE SET NULL,
                is_inbox INTEGER NOT NULL DEFAULT 0,
                is_trashed INTEGER NOT NULL DEFAULT 0,
                canvas_x REAL NOT NULL DEFAULT 0,
                canvas_y REAL NOT NULL DEFAULT 0,
                infinity_x REAL NOT NULL DEFAULT 0,
                infinity_y REAL NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                deleted_at TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS smart_collections (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                predicate_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS tags (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                color_hex TEXT,
                created_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS reference_tags (
                reference_id TEXT NOT NULL REFERENCES reference_items(id) ON DELETE CASCADE,
                tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                created_at TEXT NOT NULL,
                PRIMARY KEY (reference_id, tag_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS links (
                id TEXT PRIMARY KEY,
                source_reference_id TEXT NOT NULL REFERENCES reference_items(id) ON DELETE CASCADE,
                target_reference_id TEXT REFERENCES reference_items(id) ON DELETE SET NULL,
                url TEXT,
                relation TEXT NOT NULL,
                title TEXT,
                created_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY,
                reference_id TEXT REFERENCES reference_items(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                original_path TEXT,
                thumbnail_path TEXT,
                mime_type TEXT,
                byte_count INTEGER NOT NULL DEFAULT 0,
                width REAL,
                height REAL,
                checksum TEXT,
                created_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS import_jobs (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                status TEXT NOT NULL,
                payload TEXT NOT NULL,
                reference_id TEXT REFERENCES reference_items(id) ON DELETE SET NULL,
                error_message TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS api_tokens (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                token_prefix TEXT NOT NULL,
                token_hash TEXT NOT NULL,
                permissions_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_used_at TEXT,
                revoked_at TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS api_requests (
                id TEXT PRIMARY KEY,
                token_id TEXT REFERENCES api_tokens(id) ON DELETE SET NULL,
                endpoint TEXT NOT NULL,
                status_code INTEGER NOT NULL,
                payload_summary TEXT,
                created_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS automation_rules (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                trigger_json TEXT NOT NULL,
                action_json TEXT NOT NULL,
                is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS history_events (
                id TEXT PRIMARY KEY,
                entity TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                action TEXT NOT NULL,
                summary TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS references_fts USING fts5(
                reference_id UNINDEXED,
                title,
                subtitle,
                file_name,
                tokenize = 'unicode61'
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS document_views (
                id TEXT PRIMARY KEY,
                reference_id TEXT NOT NULL REFERENCES reference_items(id) ON DELETE CASCADE,
                opened_at TEXT NOT NULL,
                closed_at TEXT,
                duration_seconds REAL NOT NULL DEFAULT 0,
                page_count INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS page_views (
                id TEXT PRIMARY KEY,
                reference_id TEXT NOT NULL REFERENCES reference_items(id) ON DELETE CASCADE,
                view_id TEXT NOT NULL REFERENCES document_views(id) ON DELETE CASCADE,
                page_index INTEGER NOT NULL,
                viewed_at TEXT NOT NULL,
                duration_seconds REAL NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS share_tokens (
                id TEXT PRIMARY KEY,
                reference_id TEXT NOT NULL REFERENCES reference_items(id) ON DELETE CASCADE,
                token TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                expires_at TEXT,
                access_count INTEGER NOT NULL DEFAULT 0
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_references_collection ON reference_items(collection_id)",
            "CREATE INDEX IF NOT EXISTS idx_references_trash ON reference_items(is_trashed)",
            "CREATE INDEX IF NOT EXISTS idx_import_jobs_status ON import_jobs(status)",
            "CREATE INDEX IF NOT EXISTS idx_doc_views_ref ON document_views(reference_id)",
            "CREATE INDEX IF NOT EXISTS idx_page_views_ref ON page_views(reference_id)",
            "CREATE INDEX IF NOT EXISTS idx_page_views_view ON page_views(view_id)",
            "CREATE INDEX IF NOT EXISTS idx_share_tokens_ref ON share_tokens(reference_id)",
            "CREATE INDEX IF NOT EXISTS idx_share_tokens_token ON share_tokens(token)",
            "INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (1, '\(timestamp())')"
        ]
        for statement in statements {
            execute(statement)
        }

        if migrationVersion() < 2 {
            let v2: [String] = [
                "INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (2, '\(timestamp())')"
            ]
            for statement in v2 {
                execute(statement)
            }
        }

        if migrationVersion() < 3 {
            let v3 = [
                """
                CREATE TABLE IF NOT EXISTS wiki_backlinks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_slug TEXT NOT NULL,
                    target_slug TEXT NOT NULL,
                    source_title TEXT NOT NULL DEFAULT '',
                    context_snippet TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_backlinks_target ON wiki_backlinks(target_slug)",
                "CREATE INDEX IF NOT EXISTS idx_backlinks_source ON wiki_backlinks(source_slug)",
                """
                CREATE TABLE IF NOT EXISTS review_queue (
                    id TEXT PRIMARY KEY,
                    reference_id TEXT NOT NULL REFERENCES reference_items(id) ON DELETE CASCADE,
                    next_review_at TEXT NOT NULL,
                    interval_days REAL NOT NULL DEFAULT 1,
                    ease_factor REAL NOT NULL DEFAULT 2.5,
                    review_count INTEGER NOT NULL DEFAULT 0,
                    last_reviewed_at TEXT,
                    created_at TEXT NOT NULL
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_review_queue_next ON review_queue(next_review_at)",
                "CREATE INDEX IF NOT EXISTS idx_review_queue_ref ON review_queue(reference_id)",
                """
                CREATE TABLE IF NOT EXISTS auto_rules (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    trigger_json TEXT NOT NULL,
                    action_json TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    run_count INTEGER NOT NULL DEFAULT 0,
                    last_run_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS batch_operations (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    item_count INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL DEFAULT 'pending',
                    result_summary TEXT,
                    created_at TEXT NOT NULL,
                    completed_at TEXT
                )
                """,
                "INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (3, '\(timestamp())')"
            ]
            for statement in v3 {
                execute(statement)
            }
        }

        if migrationVersion() < 4 {
            let v4 = [
                "ALTER TABLE collections ADD COLUMN brief TEXT NOT NULL DEFAULT ''",
                "INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (4, '\(timestamp())')"
            ]
            for statement in v4 {
                execute(statement)
            }
        }
    }

    private func loadCollections() -> [ReferenceCollection] {
        guard let queue = grdbQueue else { return [] }
        do {
            return try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT id, name, symbol, tint_hex, brief FROM collections WHERE deleted_at IS NULL ORDER BY created_at ASC").compactMap { row in
                    guard let idStr = row["id"] as String?,
                          let id = UUID(uuidString: idStr),
                          let name = row["name"] as String?,
                          let symbol = row["symbol"] as String? else { return nil }
                    let tintHex = row["tint_hex"] as String? ?? "system-gray"
                    return ReferenceCollection(
                        id: id,
                        name: name,
                        symbol: symbol,
                        tint: colorFromHex(tintHex),
                        brief: row["brief"] as String? ?? ""
                    )
                }
            }
        } catch {
            print("GRDB loadCollections failed: \(error)")
            return []
        }
    }

    private func colorFromHex(_ hex: String) -> Color {
        switch hex {
        case "system-gray": return .gray
        case "system-blue": return .blue
        case "system-green": return .green
        case "system-red": return .red
        case "system-orange": return .orange
        case "system-purple": return .purple
        case "system-pink": return .pink
        case "system-yellow": return .yellow
        case "system-teal": return .teal
        case "system-indigo": return .indigo
        default:
            let cleaned = hex.replacingOccurrences(of: "#", with: "")
            guard cleaned.count == 6,
                  let rgb = UInt32(cleaned, radix: 16) else { return .gray }
            return Color(
                red: Double((rgb >> 16) & 0xFF) / 255.0,
                green: Double((rgb >> 8) & 0xFF) / 255.0,
                blue: Double(rgb & 0xFF) / 255.0
            )
        }
    }

    private func loadReferences() -> [ReferenceItem] {
        guard let queue = grdbQueue else { return [] }
        do {
            return try queue.read { db in
                let sql = """
                SELECT ri.id, ri.title, ri.subtitle, ri.file_name, ri.kind, ri.group_name, ri.theme, ri.aspect_ratio, ri.collection_id,
                       ri.is_inbox, ri.is_trashed, ri.canvas_x, ri.canvas_y, ri.infinity_x, ri.infinity_y,
                       a.thumbnail_path
                FROM reference_items ri
                LEFT JOIN assets a ON a.reference_id = ri.id AND (a.role = 'screenshot' OR a.role = 'primary')
                WHERE ri.deleted_at IS NULL
                ORDER BY ri.created_at ASC
                """
                return try Row.fetchAll(db, sql: sql).compactMap { row in
                    guard let idStr = row["id"] as String?,
                          let id = UUID(uuidString: idStr),
                          let title = row["title"] as String?,
                          let subtitle = row["subtitle"] as String?,
                          let fileName = row["file_name"] as String?,
                          let kindStr = row["kind"] as String?,
                          let kind = VisualKind(rawValue: kindStr),
                          let groupStr = row["group_name"] as String?,
                          let group = ReferenceGroup(rawValue: groupStr),
                          let themeStr = row["theme"] as String?,
                          let theme = ReferenceTheme(rawValue: themeStr) else { return nil }
                    return ReferenceItem(
                        id: id,
                        title: title,
                        subtitle: subtitle,
                        fileName: fileName,
                        kind: kind,
                        group: group,
                        theme: theme,
                        aspectRatio: CGFloat(row["aspect_ratio"] as Double? ?? 1.0),
                        collectionID: (row["collection_id"] as String?).flatMap(UUID.init(uuidString:)),
                        isInbox: (row["is_inbox"] as Int? ?? 0) != 0,
                        isTrashed: (row["is_trashed"] as Int? ?? 0) != 0,
                        thumbnailPath: row["thumbnail_path"] as String?,
                        canvasPosition: CGSize(
                            width: CGFloat(row["canvas_x"] as Double? ?? 0),
                            height: CGFloat(row["canvas_y"] as Double? ?? 0)
                        ),
                        infinityPosition: CGPoint(
                            x: CGFloat(row["infinity_x"] as Double? ?? 0),
                            y: CGFloat(row["infinity_y"] as Double? ?? 0)
                        )
                    )
                }
            }
        } catch {
            print("GRDB loadReferences failed: \(error)")
            return []
        }
    }

    func loadReferencesPage(offset: Int, limit: Int, filter: String? = nil, managedDocumentsOnly: Bool = false) -> [ReferenceItem] {
        guard let queue = grdbQueue else { return [] }
        do {
            return try queue.read { db in
                var sql = """
                SELECT ri.id, ri.title, ri.subtitle, ri.file_name, ri.kind, ri.group_name, ri.theme, ri.aspect_ratio, ri.collection_id,
                       ri.is_inbox, ri.is_trashed, ri.canvas_x, ri.canvas_y, ri.infinity_x, ri.infinity_y,
                       a.thumbnail_path
                FROM reference_items ri
                LEFT JOIN assets a ON a.reference_id = ri.id AND (a.role = 'screenshot' OR a.role = 'primary')
                WHERE ri.deleted_at IS NULL
                """
                var args: [any DatabaseValueConvertible] = []
                if managedDocumentsOnly {
                    sql += " AND \(Self.managedDocumentSQLPredicate)"
                }
                if let filter, !filter.isEmpty {
                    sql += " AND (ri.title LIKE ? OR ri.subtitle LIKE ? OR ri.file_name LIKE ?)"
                    args.append("%\(filter)%")
                    args.append("%\(filter)%")
                    args.append("%\(filter)%")
                }
                if managedDocumentsOnly {
                    sql += " ORDER BY lower(ri.file_name) ASC, lower(ri.title) ASC LIMIT ? OFFSET ?"
                } else {
                    sql += " ORDER BY ri.created_at ASC LIMIT ? OFFSET ?"
                }
                args.append(limit)
                args.append(offset)

                return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).compactMap { row in
                    guard let idStr = row["id"] as String?,
                          let id = UUID(uuidString: idStr),
                          let title = row["title"] as String?,
                          let subtitle = row["subtitle"] as String?,
                          let fileName = row["file_name"] as String?,
                          let kindStr = row["kind"] as String?,
                          let kind = VisualKind(rawValue: kindStr),
                          let groupStr = row["group_name"] as String?,
                          let group = ReferenceGroup(rawValue: groupStr),
                          let themeStr = row["theme"] as String?,
                          let theme = ReferenceTheme(rawValue: themeStr) else { return nil }
                    return ReferenceItem(
                        id: id, title: title, subtitle: subtitle, fileName: fileName,
                        kind: kind, group: group, theme: theme,
                        aspectRatio: CGFloat(row["aspect_ratio"] as Double? ?? 1.0),
                        collectionID: (row["collection_id"] as String?).flatMap(UUID.init(uuidString:)),
                        isInbox: (row["is_inbox"] as Int? ?? 0) != 0,
                        isTrashed: (row["is_trashed"] as Int? ?? 0) != 0,
                        thumbnailPath: row["thumbnail_path"] as String?,
                        canvasPosition: CGSize(
                            width: CGFloat(row["canvas_x"] as Double? ?? 0),
                            height: CGFloat(row["canvas_y"] as Double? ?? 0)
                        ),
                        infinityPosition: CGPoint(
                            x: CGFloat(row["infinity_x"] as Double? ?? 0),
                            y: CGFloat(row["infinity_y"] as Double? ?? 0)
                        )
                    )
                }
            }
        } catch {
            print("GRDB loadReferencesPage failed: \(error)")
            return []
        }
    }

    func referenceCount(filter: String? = nil, managedDocumentsOnly: Bool = false) -> Int {
        guard let queue = grdbQueue else { return 0 }
        do {
            return try queue.read { db in
                var sql = "SELECT COUNT(*) FROM reference_items ri WHERE ri.deleted_at IS NULL"
                var args: [any DatabaseValueConvertible] = []
                if managedDocumentsOnly {
                    sql += " AND \(Self.managedDocumentSQLPredicate)"
                }
                if let filter, !filter.isEmpty {
                    sql += " AND (ri.title LIKE ? OR ri.subtitle LIKE ? OR ri.file_name LIKE ?)"
                    args.append("%\(filter)%")
                    args.append("%\(filter)%")
                    args.append("%\(filter)%")
                }
                return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
            }
        } catch {
            return 0
        }
    }

    /// Payloads kept in memory for card display and graph building. The heavy
    /// full-content fields (`pageHTML`, `transcriptText`) are stripped here —
    /// nothing reads them from this dictionary; consumers that need full
    /// content decode the raw job payload from the database instead.
    func loadXBookmarkPayloadsByReferenceID() -> [UUID: XBookmarkPayloadSummary] {
        guard let queue = grdbQueue else { return [:] }
        do {
            return try queue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                SELECT reference_id, payload
                FROM import_jobs
                WHERE reference_id IS NOT NULL
                  AND (source = 'extension' OR source = 'wiki-compile')
                ORDER BY created_at ASC
                """)
                var payloads: [UUID: XBookmarkPayloadSummary] = [:]
                for row in rows {
                    guard let idText = row["reference_id"] as String?,
                          let id = UUID(uuidString: idText),
                          let payloadText = row["payload"] as String?,
                          let data = payloadText.data(using: .utf8),
                          let payload = try? JSONDecoder().decode(BrowserExtensionReferencePayload.self, from: data) else {
                        continue
                    }

                    let isXPayload = payload.source == "x-bookmark-sync"
                        || payload.url.flatMap(URL.init(string:))?.isXFamilyURL == true
                    guard isXPayload else { continue }
                    payloads[id] = XBookmarkPayloadSummary(payload)
                }
                return payloads
            }
        } catch {
            print("GRDB loadXBookmarkPayloadsByReferenceID failed: \(error)")
            return [:]
        }
    }

    /// Cheap change token for the rows backing `loadXBookmarkPayloadsByReferenceID()`;
    /// lets callers skip the JSON decode pass when nothing changed.
    func xBookmarkPayloadChangeToken() -> String {
        guard let queue = grdbQueue else { return "" }
        do {
            return try queue.read { db in
                try String.fetchOne(db, sql: """
                SELECT COUNT(*) || ':' || IFNULL(MAX(updated_at), '')
                FROM import_jobs
                WHERE reference_id IS NOT NULL
                  AND (source = 'extension' OR source = 'wiki-compile')
                """) ?? ""
            }
        } catch {
            return ""
        }
    }

    private func loadImportJobs(limit: Int) -> [ImportJobRecord] {
        guard let queue = grdbQueue else { return [] }
        do {
            return try queue.read { db in
                try Row.fetchAll(db, sql: """
                SELECT id, source, status, payload, reference_id, error_message, created_at, updated_at
                FROM import_jobs
                ORDER BY created_at DESC
                LIMIT ?
                """, arguments: [limit]).compactMap { row in
                    guard let idStr = row["id"] as String?,
                          let id = UUID(uuidString: idStr),
                          let sourceStr = row["source"] as String?,
                          let source = ImportSourceKind(rawValue: sourceStr),
                          let statusStr = row["status"] as String?,
                          let status = ImportJobStatus(rawValue: statusStr),
                          let payload = row["payload"] as String? else { return nil }
                    return ImportJobRecord(
                        id: id,
                        source: source,
                        status: status,
                        payload: payload,
                        referenceID: (row["reference_id"] as String?).flatMap(UUID.init(uuidString:)),
                        errorMessage: row["error_message"] as String?,
                        createdAt: iso8601.date(from: row["created_at"] as String? ?? "") ?? Date(),
                        updatedAt: iso8601.date(from: row["updated_at"] as String? ?? "") ?? Date()
                    )
                }
            }
        } catch {
            print("GRDB loadImportJobs failed: \(error)")
            return []
        }
    }

    private func createPrimaryAssetIfNeeded(for reference: ReferenceItem) {
        guard let queue = grdbQueue else { return }
        let thumbnailName = reference.fileName
        do {
            try queue.write { db in
                try db.execute(sql: """
                INSERT OR IGNORE INTO assets (
                    id, reference_id, role, original_path, thumbnail_path, mime_type, width, height, created_at
                )
                VALUES (?, ?, 'primary', ?, ?, 'image/png', ?, ?, ?)
                """, arguments: [
                    UUID().uuidString, reference.id.uuidString, reference.fileName, thumbnailName,
                    Double(900), Double(900 / max(0.1, reference.aspectRatio)), timestamp()
                ])
            }
        } catch {
            print("GRDB createPrimaryAssetIfNeeded failed: \(error)")
        }
    }

    private func refreshSearchIndex(for reference: ReferenceItem) {
        guard let queue = grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM references_fts WHERE reference_id = ?", arguments: [reference.id.uuidString])
                try db.execute(sql: "INSERT INTO references_fts (reference_id, title, subtitle, file_name) VALUES (?, ?, ?, ?)",
                               arguments: [reference.id.uuidString, reference.title, reference.subtitle, reference.fileName])
            }
        } catch {
            print("GRDB refreshSearchIndex failed: \(error)")
        }
    }

    func ftsSearch(_ query: String) -> [UUID]? {
        let ftsQuery = query
            .replacingOccurrences(of: "'", with: "''")
            .replacingOccurrences(of: "\"", with: "\"\"")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { term in "\"\(term)\"*" }
            .joined(separator: " ")
        guard !ftsQuery.isEmpty, let queue = grdbQueue else { return nil }
        do {
            let ids: [UUID] = try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT reference_id FROM references_fts WHERE references_fts MATCH ? ORDER BY rank LIMIT 200", arguments: [ftsQuery]).compactMap { row in
                    (row["reference_id"] as String?).flatMap(UUID.init(uuidString:))
                }
            }
            return ids.isEmpty ? nil : ids
        } catch {
            print("GRDB ftsSearch failed: \(error)")
            return nil
        }
    }

    private func recordHistory(entity: String, entityID: UUID, action: String, summary: String) {
        guard let queue = grdbQueue else { return }
        do {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO history_events (id, entity, entity_id, action, summary, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: [UUID().uuidString, entity, entityID.uuidString, action, summary, timestamp()])
            }
        } catch {
            print("GRDB recordHistory failed: \(error)")
        }
    }

    private func countReferenceItems() -> Int {
        guard let queue = grdbQueue else { return 0 }
        do {
            return try queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reference_items") ?? 0
            }
        } catch {
            return 0
        }
    }

    func withStatement(_ sql: String, _ body: (OpaquePointer?) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Loci SQLite prepare failed: \(errorMessage)")
            return
        }
        defer { sqlite3_finalize(statement) }
        body(statement)
    }

    func execute(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            print("Loci SQLite execute failed: \(message)")
        }
    }

    private func step(_ statement: OpaquePointer?) {
        let result = sqlite3_step(statement)
        if result != SQLITE_DONE {
            print("Loci SQLite step failed: \(errorMessage)")
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Bool) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    func string(_ statement: OpaquePointer?, _ index: Int32) -> String {
        optionalString(statement, index) ?? ""
    }

    func optionalString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func timestamp() -> String {
        iso8601.string(from: Date())
    }

    private var errorMessage: String {
        guard let db, let message = sqlite3_errmsg(db) else { return "Unknown SQLite error" }
        return String(cString: message)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension NSSize {
    func aspectFitting(_ maxSize: NSSize) -> NSSize {
        let ratio = min(maxSize.width / width, maxSize.height / height)
        return NSSize(width: width * ratio, height: height * ratio)
    }
}

extension NSImage {
    func resized(to targetSize: NSSize) -> NSImage? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let imageRep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(targetSize.width),
                                        pixelsHigh: Int(targetSize.height),
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0)
        guard let imageRep else { return nil }
        imageRep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: imageRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(origin: .zero, size: targetSize)
        NSGraphicsContext.current?.cgContext.draw(cgImage, in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(size: targetSize, flipped: false) { _ in
            imageRep.draw(in: NSRect(origin: .zero, size: targetSize))
            return true
        }
    }
}
