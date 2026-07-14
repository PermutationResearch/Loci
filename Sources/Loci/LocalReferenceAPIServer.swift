import Foundation
import Network
import Security

@MainActor
enum KeychainHelper {
    private static let service = AppBrand.bundleID
    private static let legacyService = "com.codex.referenceatlas"
    private static var valueCache: [String: String] = [:]
    private static var missingKeys = Set<String>()

    private static func query(for key: String, service serviceName: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let query = query(for: key)
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            valueCache.removeValue(forKey: key)
            missingKeys.remove(key)
            return false
        }
        valueCache[key] = value
        missingKeys.remove(key)
        return true
    }

    static func load(key: String, legacyKeys: [String] = []) -> String? {
        if let cached = valueCache[key] {
            return cached
        }
        if missingKeys.contains(key), legacyKeys.isEmpty {
            return nil
        }
        if let value = loadStoredValue(key: key, service: service) {
            valueCache[key] = value
            return value
        }

        for candidate in legacyCandidates(for: key, legacyKeys: legacyKeys) {
            guard let value = loadStoredValue(key: candidate.key, service: candidate.service) else {
                continue
            }
            save(key: key, value: value)
            return value
        }

        missingKeys.insert(key)
        return nil
    }

    private static func loadStoredValue(key: String, service serviceName: String) -> String? {
        var query = query(for: key, service: serviceName)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func exists(key: String, legacyKeys: [String] = []) -> Bool {
        load(key: key, legacyKeys: legacyKeys) != nil
    }

    @discardableResult
    static func delete(key: String, legacyKeys: [String] = []) -> Bool {
        let deleteQuery = query(for: key)
        let primaryStatus = SecItemDelete(deleteQuery as CFDictionary)
        var succeeded = primaryStatus == errSecSuccess || primaryStatus == errSecItemNotFound
        for candidate in legacyCandidates(for: key, legacyKeys: legacyKeys) {
            let status = SecItemDelete(query(for: candidate.key, service: candidate.service) as CFDictionary)
            succeeded = succeeded && (status == errSecSuccess || status == errSecItemNotFound)
        }
        valueCache.removeValue(forKey: key)
        if succeeded {
            missingKeys.insert(key)
        } else {
            missingKeys.remove(key)
        }
        return succeeded
    }

    static func migrateFromUserDefaults(key: String, userDefaultsKey: String) {
        if load(key: key) != nil { return }
        if let legacy = UserDefaults.standard.string(forKey: userDefaultsKey) {
            if save(key: key, value: legacy) {
                UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            }
        }
    }

    private static func legacyCandidates(for key: String, legacyKeys: [String]) -> [(key: String, service: String)] {
        var candidates: [(key: String, service: String)] = []
        var seen = Set<String>()
        func append(_ key: String, _ service: String) {
            let identifier = "\(service)\u{0}\(key)"
            guard seen.insert(identifier).inserted else { return }
            candidates.append((key, service))
        }
        append(key, legacyService)
        for legacyKey in legacyKeys {
            append(legacyKey, service)
            append(legacyKey, legacyService)
        }
        return candidates
    }
}

struct BrowserExtensionReferencePayload: Codable, Hashable {
    var url: String?
    var title: String?
    var note: String?
    var selectedText: String?
    var pageHTML: String?
    var articleMarkdown: String?
    var transcriptText: String?
    var imageURLs: [String]?
    var autoTags: [String]?
    var source: String?
    var faviconURL: String?
    var ogImageURL: String?
    var alsoBookmarkOnX: Bool?
    var sourceCreatedAt: String? = nil
    var mediaCount: Int? = nil
    var mediaTypes: [String]? = nil
}

/// Compact, UI-facing projection of an extension payload. Raw import jobs keep
/// the complete HTML/transcript for extraction, while the long-lived library
/// model retains only card, graph, and media metadata plus bounded text.
struct XBookmarkPayloadSummary: Hashable, Sendable {
    var url: String?
    var title: String?
    var note: String?
    var selectedText: String?
    var articleMarkdown: String?
    var imageURLs: [String]?
    var autoTags: [String]?
    var source: String?
    var faviconURL: String?
    var ogImageURL: String?
    var sourceCreatedAt: String?
    var mediaCount: Int?
    var mediaTypes: [String]?

    init(_ payload: BrowserExtensionReferencePayload) {
        url = payload.url
        title = payload.title
        note = payload.note
        selectedText = Self.bounded(payload.selectedText)
        articleMarkdown = Self.bounded(payload.articleMarkdown)
        imageURLs = payload.imageURLs
        autoTags = payload.autoTags
        source = payload.source
        faviconURL = payload.faviconURL
        ogImageURL = payload.ogImageURL
        sourceCreatedAt = payload.sourceCreatedAt
        mediaCount = payload.mediaCount
        mediaTypes = payload.mediaTypes
    }

    private static func bounded(_ value: String?, limit: Int = 8_192) -> String? {
        guard let value, value.count > limit else { return value }
        return String(value.prefix(limit))
    }
}

private struct AskVaultPayload: Codable {
    var question: String
}

@MainActor
final class LocalReferenceAPIServer {
    static let port: NWEndpoint.Port = 17641
    static let tokenKey = "Loci.APIToken"
    private static let legacyTokenKey = "ReferenceAtlas.APIToken"
    private static let maxRequestBytes = 5 * 1_024 * 1_024

    private weak var store: LibraryStore?
    private var listener: NWListener?
    private var listenerGeneration = 0
    private var isListening = false
    private var connectionTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private let networkQueue = DispatchQueue(label: "Loci.LocalAPI", qos: .userInitiated)

    private var allowsRemoteAPI: Bool {
        let env = LociEnvironment.value(for: ["LOCI_REMOTE_API"])?.lowercased()
        return env == "1"
            || env == "true"
            || UserDefaults.standard.bool(forKey: "LociRemoteAPIEnabled")
            || UserDefaults.standard.bool(forKey: "AtlasRemoteAPIEnabled")
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private enum HTTPParseResult {
        case incomplete
        case invalid(String)
        case request(HTTPRequest)
    }

    private enum HTTPBodyParseResult {
        case incomplete
        case invalid(String)
        case body(Data)
    }

    var apiToken: String {
        if let existing = UserDefaults.standard.string(forKey: Self.tokenKey), !existing.isEmpty {
            return existing
        }
        if let legacy = UserDefaults.standard.string(forKey: Self.legacyTokenKey), !legacy.isEmpty {
            UserDefaults.standard.set(legacy, forKey: Self.tokenKey)
            return legacy
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        return token
    }

    init(store: LibraryStore) {
        self.store = store
    }

    func start() {
        guard listener == nil else { return }
        startListener(requiresLoopback: !allowsRemoteAPI)
    }

    private func startListener(requiresLoopback: Bool) {
        do {
            listenerGeneration += 1
            let generation = listenerGeneration
            isListening = false
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if requiresLoopback {
                parameters.requiredInterfaceType = .loopback
            }
            let listener = try NWListener(using: parameters, on: Self.port)
            listener.newConnectionHandler = { @Sendable [weak self] connection in
                Task { @MainActor in
                    self?.receive(connection)
                }
            }
            listener.stateUpdateHandler = { @Sendable [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state, requiresLoopback: requiresLoopback, generation: generation)
                }
            }
            listener.start(queue: networkQueue)
            self.listener = listener
            if requiresLoopback {
                networkQueue.asyncAfter(deadline: .now() + 1.5) { @Sendable [weak self] in
                    Task { @MainActor in
                        self?.fallbackIfListenerIsStillNotReady(generation: generation)
                    }
                }
            }
        } catch {
            NSLog("Loci local API failed to start: \(error.localizedDescription)")
            if requiresLoopback {
                startListener(requiresLoopback: false)
            }
        }
    }

    private func fallbackIfListenerIsStillNotReady(generation: Int) {
        guard generation == listenerGeneration, !isListening else { return }
        NSLog("Loci local API loopback listener did not become ready; retrying without interface pinning")
        listener?.cancel()
        listener = nil
        startListener(requiresLoopback: false)
    }

    private func handleListenerState(_ state: NWListener.State, requiresLoopback: Bool, generation: Int) {
        guard generation == listenerGeneration else { return }
        switch state {
        case .ready:
            isListening = true
            NSLog("Loci local API listening on port \(Self.port)")
        case .waiting(let error):
            NSLog("Loci local API listener waiting: \(error.localizedDescription)")
        case .failed(let error):
            NSLog("Loci local API listener failed: \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
            isListening = false
            if requiresLoopback {
                startListener(requiresLoopback: false)
            }
        case .cancelled:
            listener = nil
            isListening = false
        default:
            break
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: networkQueue)
        let connID = ObjectIdentifier(connection)
        let timeoutItem = DispatchWorkItem {
            connection.cancel()
        }
        connectionTimeouts[connID] = timeoutItem
        networkQueue.asyncAfter(deadline: .now() + 30, execute: timeoutItem)
        receiveNextChunk(on: connection, buffer: Data())
    }

    private func receiveNextChunk(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { @Sendable [weak self] data, _, isComplete, error in
            Task { @MainActor in
                self?.handleChunk(data: data, error: error, isComplete: isComplete, buffer: buffer, connection: connection)
            }
        }
    }

    private func cancelConnectionTimeout(for connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        connectionTimeouts[connID]?.cancel()
        connectionTimeouts.removeValue(forKey: connID)
    }

    private func handleChunk(data: Data?, error: Error?, isComplete: Bool, buffer: Data, connection: NWConnection) {
        guard error == nil else {
            cancelConnectionTimeout(for: connection)
            send(status: 400, body: #"{"ok":false,"error":"empty request"}"#, on: connection)
            return
        }

        var nextBuffer = buffer
        if let data {
            nextBuffer.append(data)
        }

        guard !nextBuffer.isEmpty else {
            cancelConnectionTimeout(for: connection)
            send(status: 400, body: #"{"ok":false,"error":"empty request"}"#, on: connection)
            return
        }

        guard nextBuffer.count <= Self.maxRequestBytes else {
            cancelConnectionTimeout(for: connection)
            send(status: 413, body: #"{"ok":false,"error":"request too large"}"#, on: connection)
            return
        }

        switch parseRequest(from: nextBuffer) {
        case .incomplete where !isComplete:
            receiveNextChunk(on: connection, buffer: nextBuffer)
        case .incomplete:
            cancelConnectionTimeout(for: connection)
            send(status: 400, body: #"{"ok":false,"error":"incomplete request"}"#, on: connection)
        case .invalid(let message):
            cancelConnectionTimeout(for: connection)
            send(status: 400, body: #"{"ok":false,"error":"\#(message)"}"#, on: connection)
        case .request(let request):
            cancelConnectionTimeout(for: connection)
            handle(request, connection: connection)
        }
    }

    private func handle(_ request: HTTPRequest, connection: NWConnection) {
        if request.method == "OPTIONS" {
            send(status: 204, body: "", origin: allowedCORSOrigin(for: request), on: connection)
            return
        }

        let route = routePath(from: request.path)

        if request.method == "GET", route == "/pairing-token" {
            send(status: 200, body: #"{"ok":true,"token":"\#(apiToken)"}"#, origin: allowedCORSOrigin(for: request), on: connection)
            return
        }

        if request.method == "GET", route == "/health" {
            send(status: 200, body: #"{"ok":true,"service":"Loci","agent":"available"}"#, origin: allowedCORSOrigin(for: request), on: connection)
            return
        }

        if request.method == "GET", route == "/oauth/x/callback" {
            let params = extractQueryParams(from: request.path)
            if let error = params["error"] {
                let detail = params["error_description"] ?? params["message"] ?? error
                send(
                    status: 400,
                    body: oauthCallbackHTML(
                        title: "X authorization failed",
                        message: detail
                    ),
                    origin: allowedCORSOrigin(for: request),
                    contentType: "text/html; charset=utf-8",
                    on: connection
                )
                return
            }
            guard let code = params["code"] else {
                send(
                    status: 400,
                    body: oauthCallbackHTML(
                        title: "X authorization failed",
                        message: "X did not return an authorization code. Check the OAuth 2.0 Client ID, callback URL, app permissions, and that the app is attached to a Project."
                    ),
                    origin: allowedCORSOrigin(for: request),
                    contentType: "text/html; charset=utf-8",
                    on: connection
                )
                return
            }
            let state = params["state"]
            guard XOAuthManager.shared.isExpectedCallbackState(state) else {
                send(
                    status: 400,
                    body: oauthCallbackHTML(
                        title: "X connection expired",
                        message: "Start Connect X again from \(AppBrand.name). This browser callback is from an older login attempt."
                    ),
                    origin: allowedCORSOrigin(for: request),
                    contentType: "text/html; charset=utf-8",
                    on: connection
                )
                return
            }
            Task {
                do {
                    try await XOAuthManager.shared.completeAuthorization(code: code, state: state)
                    send(
                        status: 200,
                        body: oauthCallbackHTML(
                            title: "X account connected",
                            message: "You can close this browser tab and return to \(AppBrand.name)."
                        ),
                        origin: allowedCORSOrigin(for: request),
                        contentType: "text/html; charset=utf-8",
                        on: connection
                    )
                } catch {
                    send(
                        status: 500,
                        body: oauthCallbackHTML(
                            title: "X connection failed",
                            message: error.localizedDescription
                        ),
                        origin: allowedCORSOrigin(for: request),
                        contentType: "text/html; charset=utf-8",
                        on: connection
                    )
                }
            }
            return
        }

        guard request.headers["authorization"] == "Bearer \(apiToken)" else {
            send(status: 401, body: #"{"ok":false,"error":"unauthorized"}"#, origin: allowedCORSOrigin(for: request), on: connection)
            return
        }

        switch (request.method, route) {
        case ("POST", "/references"):
            guard let payload = try? JSONDecoder().decode(BrowserExtensionReferencePayload.self, from: request.body) else {
                send(status: 422, body: #"{"ok":false,"error":"invalid json"}"#, origin: allowedCORSOrigin(for: request), on: connection)
                return
            }
            store?.importExtensionReference(payload)
            send(status: 200, body: #"{"ok":true}"#, origin: allowedCORSOrigin(for: request), on: connection)

        case ("POST", "/compile/run"):
            Task { await ImportCoordinator.shared.enqueueProcess() }
            send(status: 200, body: #"{"ok":true,"queued":true}"#, origin: allowedCORSOrigin(for: request), on: connection)

        case ("POST", "/x/bookmarks/sync"):
            guard let store else {
                send(status: 500, body: #"{"ok":false,"error":"library unavailable"}"#, origin: allowedCORSOrigin(for: request), on: connection)
                return
            }
            let origin = allowedCORSOrigin(for: request)
            Task {
                do {
                    let result = try await XOAuthManager.shared.syncBookmarks(into: store)
                    send(
                        status: 200,
                        body: jsonObject([
                            "ok": true,
                            "imported": result.imported,
                            "updated": result.updated,
                            "scanned": result.total
                        ]),
                        origin: origin,
                        on: connection
                    )
                } catch {
                    send(status: 500, body: jsonObject(["ok": false, "error": error.localizedDescription]), origin: origin, on: connection)
                }
            }

        case ("GET", "/x/diagnostics"):
            XOAuthManager.shared.refreshStatus()
            var diagnostics = XOAuthManager.shared.diagnostics()
            diagnostics["ok"] = true
            send(status: 200, body: jsonObject(diagnostics), origin: allowedCORSOrigin(for: request), on: connection)

        case ("POST", "/compile/recompile-all"):
            let count = store?.enqueueRecompileAllReferences() ?? 0
            send(status: 200, body: #"{"ok":true,"queued":\#(count)}"#, origin: allowedCORSOrigin(for: request), on: connection)

        case ("POST", "/agent/start"):
            Task { await ImportCoordinator.shared.startAutonomousAgent() }
            send(status: 200, body: #"{"ok":true,"agent":"running"}"#, origin: allowedCORSOrigin(for: request), on: connection)

        case ("POST", "/agent/stop"):
            Task { await ImportCoordinator.shared.stopAutonomousAgent() }
            send(status: 200, body: #"{"ok":true,"agent":"stopped"}"#, origin: allowedCORSOrigin(for: request), on: connection)

        case ("POST", "/ask"):
            guard let payload = try? JSONDecoder().decode(AskVaultPayload.self, from: request.body) else {
                send(status: 422, body: #"{"ok":false,"error":"invalid json"}"#, origin: allowedCORSOrigin(for: request), on: connection)
                return
            }
            let origin = allowedCORSOrigin(for: request)
            Task {
                let answer = await LLMWikiCompiler.answer(question: payload.question, rootURL: MarkdownVault.defaultVaultURL())
                    ?? fallbackAnswer(for: payload.question)
                send(status: 200, body: jsonObject(["ok": true, "answer": answer]), origin: origin, on: connection)
            }

        case ("GET", "/export/obsidian"), ("POST", "/export/obsidian"):
            do {
                let url = try MarkdownVault.exportObsidianVault()
                send(status: 200, body: jsonObject(["ok": true, "path": url.path]), origin: allowedCORSOrigin(for: request), on: connection)
            } catch {
                send(status: 500, body: jsonObject(["ok": false, "error": error.localizedDescription]), origin: allowedCORSOrigin(for: request), on: connection)
            }

        case ("GET", "/references"):
            let items = store?.items.filter { !$0.isTrashed } ?? []
            let jsonItems = items.prefix(200).map { item -> [String: Any] in
                var dict: [String: Any] = [
                    "id": item.id.uuidString,
                    "title": item.title,
                    "fileName": item.fileName,
                    "kind": item.kind.rawValue,
                    "group": item.group.rawValue,
                ]
                if let collectionID = item.collectionID {
                    dict["collectionID"] = collectionID.uuidString
                }
                return dict
            }
            send(status: 200, body: jsonObject(["ok": true, "count": items.count, "items": jsonItems]), origin: allowedCORSOrigin(for: request), on: connection)

        case ("GET", "/references/stats"):
            let totalRefs = store?.items.filter({ !$0.isTrashed }).count ?? 0
            let totalCols = store?.collections.count ?? 0
            let queuedJobs = store?.importJobs.filter({ $0.status == .queued || $0.status == .running }).count ?? 0
            send(status: 200, body: jsonObject([
                "ok": true,
                "references": totalRefs,
                "collections": totalCols,
                "queuedImports": queuedJobs
            ]), origin: allowedCORSOrigin(for: request), on: connection)

        case ("GET", "/tags"):
            let tree = TagHierarchy.buildTree()
            let flatTags = flattenTagTree(tree)
            let tagsJSON = flatTags.map { ["name": $0.fullPath, "count": $0.referenceCount] as [String: Any] }
            send(status: 200, body: jsonObject(["ok": true, "tags": tagsJSON]), origin: allowedCORSOrigin(for: request), on: connection)

        case ("GET", "/review/due"):
            let due = ReviewScheduler.dueItems()
            let dueJSON = due.map { ["id": $0.id.uuidString, "referenceID": $0.referenceID.uuidString, "intervalDays": $0.intervalDays] as [String: Any] }
            send(status: 200, body: jsonObject(["ok": true, "count": due.count, "items": dueJSON]), origin: allowedCORSOrigin(for: request), on: connection)

        case ("GET", "/review/stats"):
            let stats = ReviewScheduler.stats()
            send(status: 200, body: jsonObject(["ok": true, "due": stats.due, "reviewedToday": stats.reviewedToday]), origin: allowedCORSOrigin(for: request), on: connection)

        case ("GET", "/timeline"):
            let items = store?.items.filter { !$0.isTrashed } ?? []
            let entries = items.prefix(100).map { item -> [String: Any] in
                ["title": item.title, "fileName": item.fileName, "kind": item.kind.rawValue]
            }
            send(status: 200, body: jsonObject(["ok": true, "entries": entries]), origin: allowedCORSOrigin(for: request), on: connection)

        case ("GET", "/patterns"):
            let patterns = PromptLibrary.patterns.map { ["name": $0.name, "category": $0.category.rawValue, "description": $0.description, "icon": $0.icon] as [String: Any] }
            send(status: 200, body: jsonObject(["ok": true, "patterns": patterns]), origin: allowedCORSOrigin(for: request), on: connection)

        case ("GET", "/wiki/backlinks"):
            let params = extractQueryParams(from: request.path)
            guard let slug = params["slug"] else {
                send(status: 400, body: #"{"ok":false,"error":"missing ?slug="}"#, origin: allowedCORSOrigin(for: request), on: connection)
                return
            }
            let links = BacklinksEngine.backlinks(for: slug, vaultRoot: MarkdownVault.defaultVaultURL())
            let linksJSON = links.map { ["sourceSlug": $0.sourceSlug, "sourceTitle": $0.sourceTitle, "context": $0.contextSnippet] as [String: Any] }
            send(status: 200, body: jsonObject(["ok": true, "count": links.count, "backlinks": linksJSON]), origin: allowedCORSOrigin(for: request), on: connection)

        case ("GET", "/wiki/page"):
            let params = extractQueryParams(from: request.path)
            guard let slug = params["slug"] else {
                send(status: 400, body: #"{"ok":false,"error":"missing ?slug="}"#, origin: allowedCORSOrigin(for: request), on: connection)
                return
            }
            let url = MarkdownVault.defaultVaultURL().appendingPathComponent("wiki/references/\(slug).md")
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                send(status: 200, body: jsonObject(["ok": true, "slug": slug, "content": content]), origin: allowedCORSOrigin(for: request), on: connection)
            } else {
                send(status: 404, body: #"{"ok":false,"error":"page not found"}"#, origin: allowedCORSOrigin(for: request), on: connection)
            }

        default:
            send(status: 404, body: #"{"ok":false,"error":"not found"}"#, origin: allowedCORSOrigin(for: request), on: connection)
            return
        }
    }

    private func routePath(from path: String) -> String {
        path.components(separatedBy: "?").first ?? path
    }

    private func extractQueryParams(from path: String) -> [String: String] {
        guard let queryString = path.components(separatedBy: "?").dropFirst().first else { return [:] }
        var params: [String: String] = [:]
        for pair in queryString.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2 {
                params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return params
    }

    private func flattenTagTree(_ nodes: [TagNode]) -> [TagNode] {
        var result: [TagNode] = []
        for node in nodes {
            result.append(node)
            result.append(contentsOf: flattenTagTree(node.children))
        }
        return result
    }

    private func fallbackAnswer(for question: String) -> String {
        let rows = WikiCompiler.search(query: question, limit: 5)
        guard !rows.isEmpty else {
            return "No matching wiki context found yet."
        }
        return rows.map { row in
            let parts = row.components(separatedBy: "\t")
            let title = parts.dropFirst().first ?? "Untitled"
            let path = parts.last ?? ""
            return "- \(title) (\(path))"
        }.joined(separator: "\n")
    }

    private func jsonObject(_ values: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"json encoding failed"}"#
        }
        return text
    }

    private func parseRequest(from data: Data) -> HTTPParseResult {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter) else {
            return .incomplete
        }

        guard let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .invalid("invalid headers")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid("missing request line")
        }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return .invalid("invalid request line")
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch parseChunkedBody(from: data.subdata(in: bodyStart..<data.endIndex)) {
            case .incomplete:
                return .incomplete
            case .invalid(let message):
                return .invalid(message)
            case .body(let parsedBody):
                body = parsedBody
            }
        } else {
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            guard contentLength >= 0 else {
                return .invalid("invalid content length")
            }

            let bodyEnd = bodyStart + contentLength
            guard data.count >= bodyEnd else {
                return .incomplete
            }
            body = data.subdata(in: bodyStart..<bodyEnd)
        }

        return .request(HTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: body
        ))
    }

    private func parseChunkedBody(from data: Data) -> HTTPBodyParseResult {
        let crlf = Data([13, 10])
        var cursor = data.startIndex
        var body = Data()

        while cursor < data.endIndex {
            guard let sizeLineRange = data[cursor..<data.endIndex].range(of: crlf) else {
                return .incomplete
            }

            guard let sizeLine = String(data: data[cursor..<sizeLineRange.lowerBound], encoding: .ascii) else {
                return .invalid("invalid chunk size")
            }

            let sizeText = sizeLine
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let chunkSize = Int(sizeText, radix: 16), chunkSize >= 0 else {
                return .invalid("invalid chunk size")
            }

            let chunkStart = sizeLineRange.upperBound
            let chunkEnd = chunkStart + chunkSize
            guard data.count >= chunkEnd + crlf.count else {
                return .incomplete
            }

            guard data.subdata(in: chunkEnd..<(chunkEnd + crlf.count)) == crlf else {
                return .invalid("invalid chunk terminator")
            }

            if chunkSize == 0 {
                return .body(body)
            }

            body.append(contentsOf: data[chunkStart..<chunkEnd])
            cursor = chunkEnd + crlf.count
        }

        return .incomplete
    }

    private func allowedCORSOrigin(for request: HTTPRequest) -> String? {
        guard let origin = request.headers["origin"] else { return nil }
        if origin.hasPrefix("chrome-extension://")
            || origin.hasPrefix("moz-extension://")
            || origin.hasPrefix("safari-web-extension://")
            || origin == "http://127.0.0.1:\(Self.port)"
            || origin == "http://localhost:\(Self.port)" {
            return origin
        }
        if allowsRemoteAPI {
            return origin
        }
        return nil
    }

    private func oauthCallbackHTML(title: String, message: String) -> String {
        let safeTitle = htmlEscaped(title)
        let safeMessage = htmlEscaped(message)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(safeTitle)</title>
        <style>
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 15px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #f5f5f7; color: #1d1d1f; }
        main { width: min(420px, calc(100vw - 40px)); padding: 28px; border: 1px solid rgba(0,0,0,.08); border-radius: 18px; background: rgba(255,255,255,.86); box-shadow: 0 18px 60px rgba(0,0,0,.10); }
        h1 { margin: 0 0 8px; font-size: 22px; line-height: 1.2; }
        p { margin: 0; color: rgba(29,29,31,.68); line-height: 1.45; }
        </style>
        </head>
        <body><main><h1>\(safeTitle)</h1><p>\(safeMessage)</p></main></body>
        </html>
        """
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func send(
        status: Int,
        body: String,
        origin: String? = nil,
        contentType: String = "application/json; charset=utf-8",
        on connection: NWConnection
    ) {
        let reason = switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        case 422: "Unprocessable Entity"
        case 500: "Internal Server Error"
        default: "OK"
        }
        let responseBody = status == 204 ? "" : body
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(Data(responseBody.utf8).count)"
        ]
        if let origin {
            headers.append("Access-Control-Allow-Origin: \(origin)")
            headers.append("Vary: Origin")
            headers.append("Access-Control-Allow-Methods: GET, POST, OPTIONS")
            headers.append("Access-Control-Allow-Headers: Content-Type, Authorization")
        }
        headers.append("Connection: close")
        let response = headers.joined(separator: "\r\n") + "\r\n\r\n" + responseBody

        connection.send(content: Data(response.utf8), completion: .contentProcessed { @Sendable _ in
            connection.cancel()
        })
    }
}
