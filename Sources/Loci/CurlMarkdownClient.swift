import Foundation
import Darwin

enum CurlMarkdownError: LocalizedError, Equatable {
    case invalidTarget
    case privateTarget
    case sensitiveTarget
    case invalidEndpoint
    case responseTooLarge
    case emptyResponse
    case unexpectedContentType(String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            "curl.md only accepts HTTP and HTTPS website URLs."
        case .privateTarget:
            "curl.md is not used for localhost or literal private-network URLs."
        case .sensitiveTarget:
            "curl.md is not used for URLs containing credential-like query parameters or fragments."
        case .invalidEndpoint:
            "The curl.md endpoint is invalid or insecure."
        case .responseTooLarge:
            "The curl.md response exceeded Loci's 10 MB import limit."
        case .emptyResponse:
            "curl.md returned an empty document."
        case .unexpectedContentType(let contentType):
            "curl.md returned \(contentType) instead of Markdown."
        case .http(let status, let message):
            "curl.md returned HTTP \(status): \(message)"
        }
    }
}

enum CurlMarkdownClient {
    static let enabledKey = "LociCurlMarkdownEnabled"
    static let apiKeyKey = "Loci.CurlMarkdown.APIKey"
    private static let legacyAPIKeyDefaultsKey = "LociCurlMarkdownAPIKey"

    struct Metadata: Codable, Sendable {
        var sourceURL: String
        var fetchedAt: String
        var requestID: String?
        var cache: String?
        var tokenCount: Int?
        var tokensSaved: Int?
    }

    struct FetchResult: Sendable {
        var markdown: String
        var metadata: Metadata
    }

    private struct APIError: Decodable {
        var code: String?
        var message: String?
    }

    private static let responseLimit = 10 * 1_024 * 1_024

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) != nil {
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        guard let value = LociEnvironment.value(for: ["LOCI_CURLMD_ENABLED"])?.lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }

    @MainActor
    static var storedAPIKey: String {
        migrateLegacyAPIKey()
        return KeychainHelper.load(key: apiKeyKey) ?? ""
    }

    @MainActor
    @discardableResult
    static func storeAPIKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return KeychainHelper.delete(key: apiKeyKey)
        } else {
            return KeychainHelper.save(key: apiKeyKey, value: trimmed)
        }
    }

    @MainActor
    static func migrateLegacyAPIKey() {
        KeychainHelper.migrateFromUserDefaults(key: apiKeyKey, userDefaultsKey: legacyAPIKeyDefaultsKey)
        // The shared helper returns early when the Keychain already has a value. Remove any
        // older plaintext copy even in that case.
        if KeychainHelper.load(key: apiKeyKey) != nil {
            UserDefaults.standard.removeObject(forKey: legacyAPIKeyDefaultsKey)
        }
    }

    static func fetchMarkdown(
        for targetURL: URL,
        session: URLSession = .shared
    ) async throws -> FetchResult {
        let request = try makeRequest(for: targetURL, token: await configuredAPIKey())
        let (downloadURL, response) = try await session.download(for: request)
        guard let fileSize = try downloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw CurlMarkdownError.responseTooLarge
        }
        guard fileSize <= responseLimit else { throw CurlMarkdownError.responseTooLarge }
        let data = try Data(contentsOf: downloadURL, options: .mappedIfSafe)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CurlMarkdownError.http(status: 0, message: "Invalid response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIError.self, from: data)
            let fallback = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw CurlMarkdownError.http(
                status: httpResponse.statusCode,
                message: apiError?.message ?? apiError?.code ?? fallback
            )
        }
        if let contentType = response.mimeType?.lowercased() {
            let allowedContentTypes: Set<String> = [
                "application/octet-stream", "text/markdown", "text/plain", "text/x-markdown"
            ]
            guard allowedContentTypes.contains(contentType) else {
                throw CurlMarkdownError.unexpectedContentType(contentType)
            }
        }
        guard let markdown = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !markdown.isEmpty else {
            throw CurlMarkdownError.emptyResponse
        }

        return FetchResult(
            markdown: markdown,
            metadata: Metadata(
                sourceURL: targetURL.absoluteString,
                fetchedAt: ISO8601DateFormatter().string(from: Date()),
                requestID: httpResponse.value(forHTTPHeaderField: "x-request-id"),
                cache: httpResponse.value(forHTTPHeaderField: "x-cache"),
                tokenCount: headerInteger("x-tokens-count", in: httpResponse),
                tokensSaved: headerInteger("x-tokens-saved", in: httpResponse)
            )
        )
    }

    static func makeRequest(
        for targetURL: URL,
        baseURL: URL? = nil,
        objective: String? = nil,
        keywords: [String] = [],
        fresh: Bool = false,
        token: String? = nil
    ) throws -> URLRequest {
        guard let scheme = targetURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              targetURL.host != nil,
              targetURL.user == nil,
              targetURL.password == nil else {
            throw CurlMarkdownError.invalidTarget
        }
        guard !isPrivateTarget(targetURL) else { throw CurlMarkdownError.privateTarget }
        guard !hasSensitiveURLComponents(targetURL) else { throw CurlMarkdownError.sensitiveTarget }

        let endpoint = try resolvedBaseURL(baseURL)
        var targetComponents = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)
        let anchor = targetComponents?.fragment
        targetComponents?.fragment = nil
        guard let target = targetComponents?.url?.absoluteString else {
            throw CurlMarkdownError.invalidTarget
        }

        let encodedTarget: String
        if let queryIndex = target.firstIndex(of: "?") {
            let prefix = target[..<queryIndex]
            let query = target[queryIndex...]
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
            guard let encodedQuery = String(query).addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw CurlMarkdownError.invalidTarget
            }
            encodedTarget = String(prefix) + encodedQuery
        } else {
            encodedTarget = target
        }

        let endpointString = endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let requestURL = URL(string: "\(endpointString)/\(encodedTarget)"),
              var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            throw CurlMarkdownError.invalidEndpoint
        }

        var queryItems: [URLQueryItem] = []
        if let anchor, !anchor.isEmpty {
            queryItems.append(URLQueryItem(name: "anchor", value: anchor))
        }
        if let objective = objective?.trimmingCharacters(in: .whitespacesAndNewlines), !objective.isEmpty {
            queryItems.append(URLQueryItem(name: "objective", value: objective))
        }
        let cleanKeywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanKeywords.isEmpty {
            queryItems.append(URLQueryItem(name: "keywords", value: cleanKeywords.joined(separator: ",")))
        }
        if fresh {
            queryItems.append(URLQueryItem(name: "fresh", value: "true"))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw CurlMarkdownError.invalidEndpoint }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("text/markdown", forHTTPHeaderField: "Accept")
        request.setValue("Loci/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let authorization = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let authorization, !authorization.isEmpty {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func isPrivateTarget(_ url: URL) -> Bool {
        guard let rawHost = url.host?.lowercased() else {
            return true
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost"
            || host == "ip6-localhost"
            || host == "ip6-loopback"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".localdomain")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".lan")
            || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".corp")
            || host.hasSuffix(".intranet") {
            return true
        }
        // Treat literal IPv6 targets conservatively. Hostnames that resolve publicly remain
        // eligible, while IPv6 literals stay local instead of risking private-range leakage.
        if host.contains(":") {
            return true
        }

        // inet_aton also recognizes legacy numeric spellings such as 127.1, octal,
        // hexadecimal, and a single 32-bit integer. Treat every non-public literal as
        // local-only so alternate notation cannot bypass the remote-fallback boundary.
        var address = in_addr()
        if inet_aton(host, &address) == 1 {
            let value = UInt32(bigEndian: address.s_addr)
            let first = UInt8((value >> 24) & 0xff)
            let second = UInt8((value >> 16) & 0xff)
            let third = UInt8((value >> 8) & 0xff)
            return first == 0
                || first == 10
                || (first == 100 && (64...127).contains(second))
                || first == 127
                || (first == 169 && second == 254)
                || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 0 && third == 0)
                || (first == 192 && second == 0 && third == 2)
                || (first == 192 && second == 88 && third == 99)
                || (first == 192 && second == 168)
                || (first == 198 && (second == 18 || second == 19))
                || (first == 198 && second == 51 && third == 100)
                || (first == 203 && second == 0 && third == 113)
                || first >= 224
        }
        if !host.contains(".") {
            return true
        }
        return false
    }

    static func hasSensitiveURLComponents(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return true
        }
        let sensitiveNames: Set<String> = [
            "access_token", "api_key", "apikey", "auth", "authorization", "code",
            "credential", "jwt", "key", "password", "passwd", "secret", "session",
            "session_id", "sessionid", "sig", "signature", "token"
        ]
        let isSensitiveName: (String) -> Bool = { rawName in
            let name = rawName.lowercased().replacingOccurrences(of: "-", with: "_")
            return sensitiveNames.contains(name)
                || name.hasSuffix("_credential")
                || name.hasSuffix("_key")
                || name.hasSuffix("_secret")
                || name.hasSuffix("_sig")
                || name.hasSuffix("_signature")
                || name.hasSuffix("_token")
        }
        if components.queryItems?.contains(where: { item in
            isSensitiveName(item.name)
        }) == true {
            return true
        }
        guard let fragment = components.fragment?.lowercased(), !fragment.isEmpty else {
            return false
        }
        return sensitiveNames.contains { name in
            fragment.contains("\(name)=") || fragment.contains("\(name)%3d")
        }
    }

    private static func resolvedBaseURL(_ override: URL?) throws -> URL {
        let configured = override
            ?? LociEnvironment.value(for: ["LOCI_CURLMD_BASE_URL"]).flatMap(URL.init(string:))
            ?? URL(string: "https://curl.md")!
        guard let scheme = configured.scheme?.lowercased(),
              configured.host != nil,
              configured.user == nil,
              configured.password == nil,
              configured.query == nil,
              configured.fragment == nil else {
            throw CurlMarkdownError.invalidEndpoint
        }
        let isLocalDevelopment = scheme == "http" && isPrivateTarget(configured)
        guard scheme == "https" || isLocalDevelopment else {
            throw CurlMarkdownError.invalidEndpoint
        }
        return configured
    }

    private static func headerInteger(_ name: String, in response: HTTPURLResponse) -> Int? {
        response.value(forHTTPHeaderField: name).flatMap(Int.init)
    }

    private static func configuredAPIKey() async -> String? {
        if let environmentKey = LociEnvironment.value(for: ["CURLMD_API_KEY", "LOCI_CURLMD_API_KEY"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty {
            return environmentKey
        }
        return await MainActor.run {
            let stored = storedAPIKey
            return stored.isEmpty ? nil : stored
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
