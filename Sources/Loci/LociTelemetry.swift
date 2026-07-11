import Foundation

enum LociTelemetryEventName: String, Codable, Sendable {
    case appLaunched = "app_launched"
    case librarySnapshot = "library_snapshot"
    case modeChanged = "mode_changed"
    case filterChanged = "filter_changed"
    case importCompleted = "import_completed"
    case xBookmarkSyncCompleted = "x_bookmark_sync_completed"
    case graphOpened = "graph_opened"
    case llmNotebookAnswered = "llm_notebook_answered"
    case llmCompileCompleted = "llm_compile_completed"
}

struct LociTelemetryPayload: Codable, Sendable {
    var id: UUID
    var installID: String
    var event: LociTelemetryEventName
    var createdAt: String
    var appVersion: String
    var buildNumber: String
    var properties: [String: String]
}

enum LociTelemetry {
    static let enabledKey = "LociTelemetryEnabled"
    static let endpointKey = "LociTelemetryEndpointURL"
    static let installIDKey = "LociTelemetryInstallID"
    private static let legacyEnabledKey = "AtlasTelemetryEnabled"
    private static let legacyEndpointKey = "AtlasTelemetryEndpointURL"
    private static let legacyInstallIDKey = "AtlasTelemetryInstallID"

    private static let allowedPropertyKeys: Set<String> = [
        "active_reference_count",
        "asset_count",
        "auto_compile_enabled",
        "auto_extract_enabled",
        "collection_count",
        "contradiction_count",
        "count",
        "database_megabytes",
        "file_reference_count",
        "filter",
        "graph_edge_count",
        "graph_node_count",
        "history_turns",
        "import_job_count",
        "imported",
        "link_count",
        "mode",
        "note_reference_count",
        "originals_megabytes",
        "provider",
        "queued_import_count",
        "recent_api_request_count",
        "source",
        "source_count",
        "success",
        "tag_count",
        "thumbnails_megabytes",
        "total",
        "updated",
        "used_llm",
        "website_reference_count",
        "write_count",
        "x_bookmark_count"
    ]

    /// Disabled by default; users opt in from Settings → Privacy. An explicit
    /// choice under either the current or legacy key always wins.
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) != nil {
                return UserDefaults.standard.bool(forKey: enabledKey)
            }
            if UserDefaults.standard.object(forKey: legacyEnabledKey) != nil {
                return UserDefaults.standard.bool(forKey: legacyEnabledKey)
            }
            return false
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var endpointString: String {
        get {
            if let endpoint = UserDefaults.standard.string(forKey: endpointKey),
               !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return endpoint
            }
            return UserDefaults.standard.string(forKey: legacyEndpointKey) ?? ""
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: endpointKey) }
    }

    static var installID: String {
        if let existing = UserDefaults.standard.string(forKey: installIDKey), !existing.isEmpty {
            return existing
        }
        if let legacy = UserDefaults.standard.string(forKey: legacyInstallIDKey), !legacy.isEmpty {
            UserDefaults.standard.set(legacy, forKey: installIDKey)
            return legacy
        }

        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: installIDKey)
        return generated
    }

    static var localQueueURL: URL {
        applicationSupportURL
            .appendingPathComponent("Telemetry", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    static func record(_ event: LociTelemetryEventName, properties: [String: String] = [:]) {
        guard isEnabled else { return }

        let payload = LociTelemetryPayload(
            id: UUID(),
            installID: installID,
            event: event,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            properties: sanitized(properties)
        )
        let queueURL = localQueueURL
        let endpoint = URL(string: endpointString).flatMap { $0.scheme == "https" ? $0 : nil }

        Task.detached(priority: .utility) {
            await append(payload, to: queueURL)
            if let endpoint {
                await upload(payload, to: endpoint)
            }
        }
    }

    @MainActor
    static func recordAppLaunch(store: LibraryStore) {
        record(.appLaunched, properties: libraryProperties(for: store))
    }

    @MainActor
    static func recordLibrarySnapshot(store: LibraryStore) {
        record(.librarySnapshot, properties: libraryProperties(for: store))
    }

    static func recordImport(source: ImportSourceKind, count: Int) {
        record(.importCompleted, properties: [
            "source": source.rawValue,
            "count": "\(max(0, count))"
        ])
    }

    static func recordXBookmarkSync(total: Int, imported: Int, updated: Int) {
        record(.xBookmarkSyncCompleted, properties: [
            "total": "\(max(0, total))",
            "imported": "\(max(0, imported))",
            "updated": "\(max(0, updated))"
        ])
    }

    static func recordLLMNotebookAnswer(success: Bool, usedLLM: Bool, sourceCount: Int, historyTurns: Int) {
        record(.llmNotebookAnswered, properties: [
            "success": "\(success)",
            "used_llm": "\(usedLLM)",
            "source_count": "\(max(0, sourceCount))",
            "history_turns": "\(max(0, historyTurns))"
        ])
    }

    static func recordLLMCompile(success: Bool, provider: String?, writeCount: Int, contradictionCount: Int) {
        record(.llmCompileCompleted, properties: [
            "success": "\(success)",
            "provider": providerFamily(provider),
            "write_count": "\(max(0, writeCount))",
            "contradiction_count": "\(max(0, contradictionCount))"
        ])
    }

    @MainActor
    static func graphProperties(for store: LibraryStore) -> [String: String] {
        [
            "graph_node_count": "\(store.graphNodeCount)",
            "graph_edge_count": "\(store.graphEdgeCount)",
            "active_reference_count": "\(store.items.filter { !$0.isTrashed }.count)"
        ]
    }

    static func clearLocalQueue() {
        try? FileManager.default.removeItem(at: localQueueURL)
    }

    private static var applicationSupportURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let lociRoot = appSupport.appendingPathComponent(AppBrand.name, isDirectory: true)
        let legacyRoot = appSupport.appendingPathComponent(AppBrand.legacyName, isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyRoot.path),
           !FileManager.default.fileExists(atPath: lociRoot.path) {
            return legacyRoot
        }
        return lociRoot
    }

    @MainActor
    private static func libraryProperties(for store: LibraryStore) -> [String: String] {
        let activeItems = store.items.filter { !$0.isTrashed }
        let stats = store.storageStats
        return [
            "active_reference_count": "\(activeItems.count)",
            "asset_count": "\(stats.assetCount)",
            "auto_compile_enabled": "\(UserDefaults.standard.bool(forKey: "LociAutoCompile"))",
            "auto_extract_enabled": "\(UserDefaults.standard.object(forKey: "LociAutoExtract") as? Bool ?? true)",
            "collection_count": "\(store.collections.count)",
            "database_megabytes": megabytesString(fileSize(at: stats.databaseURL.path)),
            "file_reference_count": "\(activeItems.filter { $0.group == .file }.count)",
            "graph_edge_count": "\(store.graphEdgeCount)",
            "graph_node_count": "\(store.graphNodeCount)",
            "import_job_count": "\(stats.importJobCount)",
            "link_count": "\(stats.linkCount)",
            "note_reference_count": "\(activeItems.filter { $0.subtitle == "Quick Note" }.count)",
            "originals_megabytes": megabytesString(folderSize(at: stats.originalsURL.path)),
            "queued_import_count": "\(stats.queuedImportCount)",
            "recent_api_request_count": "\(stats.recentAPIRequestCount)",
            "tag_count": "\(stats.tagCount)",
            "thumbnails_megabytes": megabytesString(folderSize(at: stats.thumbnailsURL.path)),
            "website_reference_count": "\(activeItems.filter { $0.kind == .website }.count)",
            "x_bookmark_count": "\(activeItems.filter(\.isXBookmark).count)"
        ]
    }

    private static func sanitized(_ properties: [String: String]) -> [String: String] {
        properties.reduce(into: [:]) { result, entry in
            guard allowedPropertyKeys.contains(entry.key) else { return }
            result[entry.key] = String(entry.value.prefix(96))
        }
    }

    private static func providerFamily(_ provider: String?) -> String {
        guard let provider, !provider.isEmpty else { return "none" }
        if provider.hasPrefix("openrouter/") { return "openrouter" }
        if provider.hasPrefix("ollama/") { return "ollama" }
        return "other"
    }

    private static func megabytesString(_ bytes: Int64) -> String {
        String(format: "%.2f", Double(max(0, bytes)) / 1_048_576.0)
    }

    private static func fileSize(at path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }

    private static func folderSize(at path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let file as String in enumerator {
            total += fileSize(at: (path as NSString).appendingPathComponent(file))
        }
        return total
    }

    private static func append(_ payload: LociTelemetryPayload, to queueURL: URL) async {
        do {
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            let lineData = Data(line.utf8)

            if FileManager.default.fileExists(atPath: queueURL.path) {
                let handle = try FileHandle(forWritingTo: queueURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
                try handle.close()
            } else {
                try lineData.write(to: queueURL, options: .atomic)
            }
        } catch {
            return
        }
    }

    private static func upload(_ payload: LociTelemetryPayload, to endpoint: URL) async {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let data = try JSONEncoder().encode(payload)
            _ = try await URLSession.shared.upload(for: request, from: data)
        } catch {
            return
        }
    }
}
