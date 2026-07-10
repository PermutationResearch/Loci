import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

struct XOAuthStatus: Equatable {
    var isConfigured: Bool
    var isConnected: Bool
    var canSyncBookmarks: Bool
    var needsReconnectForSync: Bool
    var username: String?
    var message: String
}

struct XBookmarkSyncResult: Equatable {
    var imported: Int
    var updated: Int
    var total: Int
}

struct XBookmarkImportCandidate: Hashable {
    var url: String
    var title: String
    var payload: BrowserExtensionReferencePayload
    var payloadString: String

    var hasMediaPreview: Bool {
        payload.ogImageURL?.isEmpty == false || payload.imageURLs?.isEmpty == false
    }
}

struct XBookmarkImportSummary: Equatable {
    var imported: Int
    var updated: Int
    var touchedIDs: [ReferenceItem.ID]
}

enum XOAuthRedirectMode: String, CaseIterable, Identifiable {
    case localHostname
    case loopback
    case appScheme

    static let recommended: XOAuthRedirectMode = .loopback
    static let setupModes: [XOAuthRedirectMode] = [.loopback, .localHostname]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localHostname:
            "Local hostname"
        case .loopback:
            "127.0.0.1 recommended"
        case .appScheme:
            "App scheme"
        }
    }

    var callbackURL: String {
        switch self {
        case .localHostname:
            "http://localtest.me:17641/oauth/x/callback"
        case .loopback:
            "http://127.0.0.1:17641/oauth/x/callback"
        case .appScheme:
            "loci://x-oauth"
        }
    }

    var websiteURL: String {
        switch self {
        case .localHostname:
            "http://localtest.me:17641"
        case .loopback:
            "http://127.0.0.1:17641"
        case .appScheme:
            "https://example.com"
        }
    }

    var opensInBrowser: Bool {
        self != .appScheme
    }
}

@MainActor
final class XOAuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = XOAuthManager()

    static let requiredScopes = ["tweet.read", "users.read", "bookmark.read", "offline.access"]
    static let basicDiagnosticScopes = ["tweet.read", "users.read", "offline.access"]

    static var redirectMode: XOAuthRedirectMode {
        let rawValue = userDefaultString("LociXRedirectMode", Keys.Legacy.redirectMode) ?? XOAuthRedirectMode.recommended.rawValue
        return XOAuthRedirectMode(rawValue: rawValue) ?? .recommended
    }

    static var redirectURI: String {
        redirectMode.callbackURL
    }

    static var websiteURL: String {
        redirectMode.websiteURL
    }

    static var bundledClientID: String {
        for key in ["LOCI_X_CLIENT_ID", "ATLAS_X_CLIENT_ID"] {
            if let environmentValue = ProcessInfo.processInfo.environment[key],
               looksLikeOAuth2ClientID(normalizedClientIDInput(environmentValue)) {
                return normalizedClientIDInput(environmentValue)
            }
        }
        for key in ["LociXClientID", "ReferenceAtlasXClientID"] {
            if let bundleValue = Bundle.main.object(forInfoDictionaryKey: key) as? String,
               looksLikeOAuth2ClientID(normalizedClientIDInput(bundleValue)) {
                return normalizedClientIDInput(bundleValue)
            }
        }
        return ""
    }

    private enum Keys {
        static let clientSecret = "Loci.X.ClientSecret"
        static let accessToken = "Loci.X.AccessToken"
        static let refreshToken = "Loci.X.RefreshToken"
        static let tokenExpiry = "Loci.X.TokenExpiry"
        static let pendingState = "Loci.X.PendingState"
        static let pendingVerifier = "Loci.X.PendingVerifier"
        static let pendingRedirectURI = "Loci.X.PendingRedirectURI"
        static let pendingScopes = "Loci.X.PendingScopes"
        static let tokenScopes = "Loci.X.TokenScopes"
        static let refreshTokenRejected = "Loci.X.RefreshTokenRejected"
        static let accessTokenSaved = "Loci.X.AccessTokenSaved"
        static let refreshTokenSaved = "Loci.X.RefreshTokenSaved"

        enum Legacy {
            static let clientID = "AtlasXClientID"
            static let username = "AtlasXUsername"
            static let userID = "AtlasXUserID"
            static let redirectMode = "AtlasXRedirectMode"
            static let clientSecret = "ReferenceAtlas.X.ClientSecret"
            static let accessToken = "ReferenceAtlas.X.AccessToken"
            static let refreshToken = "ReferenceAtlas.X.RefreshToken"
            static let tokenExpiry = "ReferenceAtlas.X.TokenExpiry"
            static let pendingState = "ReferenceAtlas.X.PendingState"
            static let pendingVerifier = "ReferenceAtlas.X.PendingVerifier"
            static let pendingRedirectURI = "ReferenceAtlas.X.PendingRedirectURI"
            static let pendingScopes = "ReferenceAtlas.X.PendingScopes"
            static let tokenScopes = "ReferenceAtlas.X.TokenScopes"
            static let refreshTokenRejected = "ReferenceAtlas.X.RefreshTokenRejected"
            static let accessTokenSaved = "ReferenceAtlas.X.AccessTokenSaved"
            static let refreshTokenSaved = "ReferenceAtlas.X.RefreshTokenSaved"
        }
    }

    @Published private(set) var status: XOAuthStatus
    @Published private(set) var authorizationMessage = ""

    private var authSession: ASWebAuthenticationSession?
    private let xAPISession: URLSession

    private override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        xAPISession = URLSession(configuration: configuration)
        status = Self.currentStatus()
        super.init()
    }

    var clientID: String {
        get {
            if let saved = Self.userDefaultString("LociXClientID", Keys.Legacy.clientID) {
                return Self.normalizedClientIDInput(saved)
            }
            return Self.bundledClientID
        }
        set {
            UserDefaults.standard.set(Self.normalizedClientIDInput(newValue), forKey: "LociXClientID")
            refreshStatus()
        }
    }

    var clientSecret: String {
        get { "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainHelper.delete(key: Keys.clientSecret, legacyKeys: [Keys.Legacy.clientSecret])
            } else {
                KeychainHelper.save(key: Keys.clientSecret, value: trimmed)
            }
            refreshStatus()
        }
    }

    func refreshStatus() {
        status = Self.currentStatus()
    }

    func diagnostics() -> [String: Any] {
        let expiryText = Self.userDefaultString(Keys.tokenExpiry, Keys.Legacy.tokenExpiry)
        let expiry = expiryText.flatMap(TimeInterval.init)
        return [
            "hasAccessToken": Self.hasSavedAccessToken(),
            "hasRefreshToken": Self.hasSavedRefreshToken(),
            "hasTokenExpiry": expiryText != nil,
            "tokenSecondsRemaining": expiry.map { Int(Date(timeIntervalSince1970: $0).timeIntervalSinceNow) } as Any,
            "refreshTokenRejected": Self.userDefaultBool(Keys.refreshTokenRejected, legacy: Keys.Legacy.refreshTokenRejected),
            "clientIDConfigured": !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "username": Self.userDefaultString("LociXUsername", Keys.Legacy.username) as Any,
            "userID": Self.userDefaultString("LociXUserID", Keys.Legacy.userID) as Any,
            "tokenScopes": Self.userDefaultString(Keys.tokenScopes, Keys.Legacy.tokenScopes) as Any,
            "statusMessage": status.message,
            "canSyncBookmarks": status.canSyncBookmarks,
            "needsReconnectForSync": status.needsReconnectForSync
        ]
    }

    func isExpectedCallbackState(_ state: String?) -> Bool {
        guard let expectedState = Self.userDefaultString(Keys.pendingState, Keys.Legacy.pendingState) else {
            return false
        }
        return state == expectedState
    }

    func authorizationURL(scopes: [String] = XOAuthManager.requiredScopes) throws -> URL {
        let clientID = Self.normalizedClientIDInput(clientID)
        guard !clientID.isEmpty else {
            throw XOAuthError.missingClientID
        }
        guard Self.looksLikeOAuth2ClientID(clientID) else {
            throw XOAuthError.invalidClientID
        }

        let redirectURI = Self.redirectURI
        let verifier = Self.randomToken(byteCount: 48)
        let state = Self.randomToken(byteCount: 32)
        let challenge = Self.codeChallenge(for: verifier)
        UserDefaults.standard.set(verifier, forKey: Keys.pendingVerifier)
        UserDefaults.standard.set(state, forKey: Keys.pendingState)
        UserDefaults.standard.set(redirectURI, forKey: Keys.pendingRedirectURI)
        UserDefaults.standard.set(Self.scopeString(scopes), forKey: Keys.pendingScopes)

        let query = Self.strictQuery([
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("scope", Self.scopeString(scopes)),
            ("state", state),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256")
        ])

        guard let url = URL(string: "https://x.com/i/oauth2/authorize?\(query)") else {
            throw XOAuthError.invalidAuthorizeURL
        }
        return url
    }

    func startAuthorization(scopes: [String] = XOAuthManager.requiredScopes) throws {
        let url = try authorizationURL(scopes: scopes)
        if Self.redirectMode.opensInBrowser {
            authorizationMessage = "Opening X authorization in your browser..."
            NSWorkspace.shared.open(url)
            return
        }
        authorizationMessage = "Opening X authorization..."
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "loci") { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.authSession = nil }
                if let callbackURL {
                    do {
                        try await self.completeAuthorization(from: callbackURL)
                        self.authorizationMessage = "X account connected."
                    } catch {
                        self.authorizationMessage = error.localizedDescription
                        self.refreshStatus()
                    }
                    return
                }
                if let error {
                    self.authorizationMessage = error.localizedDescription
                } else {
                    self.authorizationMessage = "X authorization was cancelled."
                }
                self.refreshStatus()
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() {
            authSession = nil
            authorizationMessage = "Could not start X authorization."
            throw XOAuthError.invalidAuthorizeURL
        }
    }

    func startBasicAuthorization() throws {
        try startAuthorization(scopes: Self.basicDiagnosticScopes)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }

    func completeAuthorization(code: String, state: String?) async throws {
        guard let expectedState = Self.userDefaultString(Keys.pendingState, Keys.Legacy.pendingState),
              let verifier = Self.userDefaultString(Keys.pendingVerifier, Keys.Legacy.pendingVerifier),
              state == expectedState else {
            throw XOAuthError.invalidState
        }

        let redirectURI = Self.userDefaultString(Keys.pendingRedirectURI, Keys.Legacy.pendingRedirectURI) ?? Self.redirectURI
        let body = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]

        let response = try await requestToken(body: body)
        save(tokenResponse: response)
        Self.removeUserDefaults(Keys.pendingState, Keys.Legacy.pendingState)
        Self.removeUserDefaults(Keys.pendingVerifier, Keys.Legacy.pendingVerifier)
        Self.removeUserDefaults(Keys.pendingRedirectURI, Keys.Legacy.pendingRedirectURI)
        Self.removeUserDefaults(Keys.pendingScopes, Keys.Legacy.pendingScopes)
        _ = try? await loadCurrentUser()
        refreshStatus()
    }

    func completeAuthorization(from callbackURL: URL) async throws {
        guard [AppBrand.lowercaseName, AppBrand.legacyLowercaseName].contains(callbackURL.scheme ?? ""),
              callbackURL.host == "x-oauth",
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw XOAuthError.invalidCallbackURL
        }
        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard let code else {
            throw XOAuthError.missingCode
        }
        try await completeAuthorization(code: code, state: state)
    }

    func disconnect() {
        KeychainHelper.delete(key: Keys.accessToken, legacyKeys: [Keys.Legacy.accessToken])
        KeychainHelper.delete(key: Keys.refreshToken, legacyKeys: [Keys.Legacy.refreshToken])
        KeychainHelper.delete(key: Keys.tokenExpiry, legacyKeys: [Keys.Legacy.tokenExpiry])
        Self.removeUserDefaults(Keys.accessTokenSaved, Keys.Legacy.accessTokenSaved)
        Self.removeUserDefaults(Keys.refreshTokenSaved, Keys.Legacy.refreshTokenSaved)
        Self.removeUserDefaults(Keys.tokenExpiry, Keys.Legacy.tokenExpiry)
        Self.removeUserDefaults(Keys.pendingState, Keys.Legacy.pendingState)
        Self.removeUserDefaults(Keys.pendingVerifier, Keys.Legacy.pendingVerifier)
        Self.removeUserDefaults(Keys.pendingRedirectURI, Keys.Legacy.pendingRedirectURI)
        Self.removeUserDefaults(Keys.pendingScopes, Keys.Legacy.pendingScopes)
        Self.removeUserDefaults(Keys.tokenScopes, Keys.Legacy.tokenScopes)
        Self.removeUserDefaults(Keys.refreshTokenRejected, Keys.Legacy.refreshTokenRejected)
        Self.removeUserDefaults("LociXUsername", Keys.Legacy.username)
        Self.removeUserDefaults("LociXUserID", Keys.Legacy.userID)
        refreshStatus()
    }

    func importExistingTokens(accessToken: String, refreshToken: String) async throws {
        let accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = Self.normalizedClientIDInput(clientID)
        guard !clientID.isEmpty else {
            throw XOAuthError.missingClientID
        }
        guard Self.looksLikeOAuth2ClientID(clientID) else {
            throw XOAuthError.invalidClientID
        }
        guard !accessToken.isEmpty, !refreshToken.isEmpty else {
            throw XOAuthError.missingTokens
        }
        guard Self.looksLikeXAccessToken(accessToken), Self.looksLikeXRefreshToken(refreshToken) else {
            throw XOAuthError.invalidTokenPair
        }

        do {
            _ = try await loadCurrentUser(accessToken: accessToken)
            let refreshedTokens = try await refreshAccessToken(using: refreshToken)
            save(tokenResponse: refreshedTokens)
            _ = try? await loadCurrentUser()
        } catch XOAuthError.developerAppNotInProject {
            clearSavedTokens(markNeedsReconnect: true)
            throw XOAuthError.developerAppNotInProject
        } catch XOAuthError.httpError(let message) where Self.isInvalidTokenMessage(message) {
            clearSavedTokens(markNeedsReconnect: true)
            throw XOAuthError.authorizationExpired
        } catch XOAuthError.unauthorized {
            clearSavedTokens(markNeedsReconnect: true)
            throw XOAuthError.authorizationExpired
        } catch {
            clearSavedTokens()
            throw error
        }
        refreshStatus()
    }

    func syncBookmarks(into store: LibraryStore) async throws -> XBookmarkSyncResult {
        do {
            return try await syncBookmarksOnce(into: store)
        } catch XOAuthError.developerAppNotInProject {
            clearSavedTokens(markNeedsReconnect: true)
            throw XOAuthError.developerAppNotInProject
        } catch XOAuthError.unauthorized {
            let refreshedToken = try await refreshedAccessTokenAfterUnauthorized()
            do {
                return try await syncBookmarksOnce(into: store, accessToken: refreshedToken)
            } catch XOAuthError.developerAppNotInProject {
                clearSavedTokens(markNeedsReconnect: true)
                throw XOAuthError.developerAppNotInProject
            }
        }
    }

    private func syncBookmarksOnce(into store: LibraryStore, accessToken providedAccessToken: String? = nil) async throws -> XBookmarkSyncResult {
        let accessToken: String
        if let providedAccessToken {
            accessToken = providedAccessToken
        } else {
            accessToken = try await validAccessToken()
        }
        let user = try await loadCurrentUser(accessToken: accessToken)
        var imported = 0
        var updated = 0
        var total = 0
        var paginationToken: String?
        var seenPaginationTokens = Set<String>()

        repeat {
            let page = try await fetchBookmarks(userID: user.id, accessToken: accessToken, paginationToken: paginationToken)
            total += page.tweets.count
            var candidates: [XBookmarkImportCandidate] = []
            candidates.reserveCapacity(page.tweets.count)
            for tweet in page.tweets {
                let author = tweet.authorID.flatMap { page.users[$0] }
                let url = tweet.url(authorUsername: author?.username)
                var titleParts: [String] = []
                if let displayName = author?.displayName, !displayName.isEmpty {
                    titleParts.append(displayName)
                }
                if let username = author?.username, !username.isEmpty {
                    titleParts.append("@\(username)")
                }
                let authorTitle = titleParts.joined(separator: " ")
                let tweetText = tweet.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = Self.bookmarkTitle(author: authorTitle, text: tweetText)
                let mediaURLs = page.mediaURLs(for: tweet)
                let mediaTypes = page.mediaTypes(for: tweet)
                let payload = BrowserExtensionReferencePayload(
                    url: url,
                    title: authorTitle.isEmpty ? title : authorTitle,
                    note: authorTitle.isEmpty ? nil : authorTitle,
                    selectedText: tweet.text,
                    pageHTML: nil,
                    articleMarkdown: tweet.text,
                    transcriptText: nil,
                    imageURLs: mediaURLs.isEmpty ? nil : mediaURLs,
                    autoTags: ["x-bookmarked"],
                    source: "x-bookmark-sync",
                    faviconURL: nil,
                    ogImageURL: mediaURLs.first,
                    alsoBookmarkOnX: true,
                    sourceCreatedAt: tweet.createdAt,
                    mediaCount: mediaURLs.count,
                    mediaTypes: mediaTypes.isEmpty ? nil : mediaTypes
                )
                let payloadString = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? url
                candidates.append(XBookmarkImportCandidate(
                    url: url,
                    title: title,
                    payload: payload,
                    payloadString: payloadString
                ))
            }
            let pageResult = store.upsertXBookmarkReferences(candidates)
            imported += pageResult.imported
            updated += pageResult.updated
            let nextToken = page.nextToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let nextToken, !nextToken.isEmpty, seenPaginationTokens.insert(nextToken).inserted {
                paginationToken = nextToken
            } else {
                paginationToken = nil
            }
        } while paginationToken != nil

        return XBookmarkSyncResult(imported: imported, updated: updated, total: total)
    }

    private static func bookmarkTitle(author: String, text: String) -> String {
        XBookmarkDisplay.title(author: author, text: text, fallback: "X Bookmark")
    }

    private func validAccessToken() async throws -> String {
        if Self.hasFreshAccessToken(), let token = KeychainHelper.load(key: Keys.accessToken, legacyKeys: [Keys.Legacy.accessToken]) {
            return Self.normalizedToken(token)
        }

        guard let refreshToken = KeychainHelper.load(key: Keys.refreshToken, legacyKeys: [Keys.Legacy.refreshToken]) else {
            if Self.hasSavedAccessToken() {
                clearSavedTokens(markNeedsReconnect: true)
                throw XOAuthError.authorizationExpired
            }
            throw XOAuthError.missingRefreshToken
        }

        let response: XTokenResponse
        do {
            response = try await refreshAccessToken(using: refreshToken)
        } catch XOAuthError.developerAppNotInProject {
            clearSavedTokens(markNeedsReconnect: true)
            throw XOAuthError.developerAppNotInProject
        } catch XOAuthError.unauthorized {
            if let fallbackToken = fallbackAccessTokenAfterRefreshFailure() {
                return fallbackToken
            }
            clearSavedTokens(markNeedsReconnect: true)
            throw XOAuthError.authorizationExpired
        } catch XOAuthError.httpError(let message) where Self.isInvalidTokenMessage(message) {
            if let fallbackToken = fallbackAccessTokenAfterRefreshFailure() {
                return fallbackToken
            }
            clearSavedTokens(markNeedsReconnect: true)
            throw XOAuthError.authorizationExpired
        } catch {
            throw error
        }
        save(tokenResponse: response)
        guard let token = KeychainHelper.load(key: Keys.accessToken, legacyKeys: [Keys.Legacy.accessToken]) else {
            throw XOAuthError.notConnected
        }
        return Self.normalizedToken(token)
    }

    private func refreshedAccessTokenAfterUnauthorized() async throws -> String {
        guard let refreshToken = KeychainHelper.load(key: Keys.refreshToken, legacyKeys: [Keys.Legacy.refreshToken]) else {
            throw XOAuthError.authorizationExpired
        }
        do {
            let response = try await refreshAccessToken(using: refreshToken)
            save(tokenResponse: response)
            guard let token = KeychainHelper.load(key: Keys.accessToken, legacyKeys: [Keys.Legacy.accessToken]) else {
                throw XOAuthError.notConnected
            }
            return Self.normalizedToken(token)
        } catch XOAuthError.developerAppNotInProject {
            clearSavedTokens(markNeedsReconnect: true)
            throw XOAuthError.developerAppNotInProject
        } catch XOAuthError.unauthorized {
            clearSavedTokens(markNeedsReconnect: true)
            throw XOAuthError.authorizationExpired
        } catch XOAuthError.httpError(let message) where Self.isInvalidTokenMessage(message) {
            clearSavedTokens(markNeedsReconnect: true)
            throw XOAuthError.authorizationExpired
        }
    }

    private func refreshAccessToken(using refreshToken: String) async throws -> XTokenResponse {
        try await requestToken(body: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": Self.normalizedToken(refreshToken)
        ])
    }

    private func fallbackAccessTokenAfterRefreshFailure() -> String? {
        guard let token = KeychainHelper.load(key: Keys.accessToken, legacyKeys: [Keys.Legacy.accessToken]) else {
            return nil
        }
        markRefreshTokenRejected()
        let shortExpiry = Date().addingTimeInterval(15 * 60).timeIntervalSince1970
        UserDefaults.standard.set("\(shortExpiry)", forKey: Keys.tokenExpiry)
        UserDefaults.standard.set(true, forKey: Keys.accessTokenSaved)
        return Self.normalizedToken(token)
    }

    private func clearSavedTokens(markNeedsReconnect: Bool = false) {
        KeychainHelper.delete(key: Keys.accessToken, legacyKeys: [Keys.Legacy.accessToken])
        KeychainHelper.delete(key: Keys.refreshToken, legacyKeys: [Keys.Legacy.refreshToken])
        KeychainHelper.delete(key: Keys.tokenExpiry, legacyKeys: [Keys.Legacy.tokenExpiry])
        Self.removeUserDefaults(Keys.accessTokenSaved, Keys.Legacy.accessTokenSaved)
        Self.removeUserDefaults(Keys.refreshTokenSaved, Keys.Legacy.refreshTokenSaved)
        Self.removeUserDefaults(Keys.tokenExpiry, Keys.Legacy.tokenExpiry)
        Self.removeUserDefaults(Keys.tokenScopes, Keys.Legacy.tokenScopes)
        if markNeedsReconnect {
            UserDefaults.standard.set(true, forKey: Keys.refreshTokenRejected)
        } else {
            Self.removeUserDefaults(Keys.refreshTokenRejected, Keys.Legacy.refreshTokenRejected)
        }
    }

    private func markRefreshTokenRejected() {
        KeychainHelper.delete(key: Keys.refreshToken, legacyKeys: [Keys.Legacy.refreshToken])
        Self.removeUserDefaults(Keys.refreshTokenSaved, Keys.Legacy.refreshTokenSaved)
        UserDefaults.standard.set(true, forKey: Keys.refreshTokenRejected)
    }

    private func requestToken(body: [String: String]) async throws -> XTokenResponse {
        guard let url = URL(string: "https://api.x.com/2/oauth2/token") else {
            throw XOAuthError.invalidTokenURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        Self.prepareXAPIRequest(&request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(body)

        let (data, response) = try await xAPISession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Self.apiError(data: data, response: response)
        }
        return try JSONDecoder().decode(XTokenResponse.self, from: data)
    }

    private func save(tokenResponse: XTokenResponse) {
        KeychainHelper.save(key: Keys.accessToken, value: Self.normalizedToken(tokenResponse.accessToken))
        UserDefaults.standard.set(true, forKey: Keys.accessTokenSaved)
        if let refresh = tokenResponse.refreshToken {
            KeychainHelper.save(key: Keys.refreshToken, value: Self.normalizedToken(refresh))
            UserDefaults.standard.set(true, forKey: Keys.refreshTokenSaved)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn ?? 7200)).timeIntervalSince1970
        UserDefaults.standard.set("\(expiry)", forKey: Keys.tokenExpiry)
        KeychainHelper.delete(key: Keys.tokenExpiry, legacyKeys: [Keys.Legacy.tokenExpiry])
        if let scopes = tokenResponse.scope?.trimmingCharacters(in: .whitespacesAndNewlines), !scopes.isEmpty {
            UserDefaults.standard.set(scopes, forKey: Keys.tokenScopes)
        } else if let pendingScopes = Self.userDefaultString(Keys.pendingScopes, Keys.Legacy.pendingScopes), !pendingScopes.isEmpty {
            UserDefaults.standard.set(pendingScopes, forKey: Keys.tokenScopes)
        }
        Self.removeUserDefaults(Keys.refreshTokenRejected, Keys.Legacy.refreshTokenRejected)
    }

    private func loadCurrentUser(accessToken: String? = nil) async throws -> XUser {
        let token: String
        if let accessToken {
            token = Self.normalizedToken(accessToken)
        } else {
            token = try await validAccessToken()
        }
        guard let url = URL(string: "https://api.x.com/2/users/me?user.fields=username,name") else {
            throw XOAuthError.invalidUserURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        Self.prepareXAPIRequest(&request)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await xAPISession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Self.apiError(data: data, response: response)
        }
        let decoded = try JSONDecoder().decode(XMeResponse.self, from: data)
        UserDefaults.standard.set(decoded.data.id, forKey: "LociXUserID")
        UserDefaults.standard.set(decoded.data.username, forKey: "LociXUsername")
        return decoded.data
    }

    private func fetchBookmarks(userID: String, accessToken: String, paginationToken: String?) async throws -> XBookmarksPage {
        var components = URLComponents(string: "https://api.x.com/2/users/\(userID)/bookmarks")
        components?.queryItems = [
            URLQueryItem(name: "max_results", value: "100"),
            URLQueryItem(name: "tweet.fields", value: "author_id,created_at,entities,attachments"),
            URLQueryItem(name: "expansions", value: "author_id,attachments.media_keys"),
            URLQueryItem(name: "user.fields", value: "username,name"),
            URLQueryItem(name: "media.fields", value: "media_key,type,url,preview_image_url,alt_text,width,height,duration_ms")
        ]
        if let paginationToken {
            components?.queryItems?.append(URLQueryItem(name: "pagination_token", value: paginationToken))
        }
        guard let url = components?.url else {
            throw XOAuthError.invalidBookmarksURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        Self.prepareXAPIRequest(&request)
        request.setValue("Bearer \(Self.normalizedToken(accessToken))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await xAPISession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Self.apiError(data: data, response: response)
        }
        return try JSONDecoder().decode(XBookmarksPage.self, from: data)
    }

    private static func currentStatus() -> XOAuthStatus {
        let clientID = userDefaultString("LociXClientID", Keys.Legacy.clientID) ?? bundledClientID
        let username = userDefaultString("LociXUsername", Keys.Legacy.username)
        let hasAccessToken = Self.hasSavedAccessToken()
        let hasRefreshToken = Self.hasSavedRefreshToken()
        let hasFreshAccessToken = Self.hasFreshAccessToken()
        let refreshTokenRejected = userDefaultBool(Keys.refreshTokenRejected, legacy: Keys.Legacy.refreshTokenRejected)
        let hasDurableRefreshToken = hasRefreshToken && !refreshTokenRejected
        let connected = hasDurableRefreshToken || hasFreshAccessToken
        let hasBookmarkScope = Self.savedScopes()?.contains("bookmark.read") ?? true
        let canSyncBookmarks = connected && hasBookmarkScope
        let hasKnownAccount = username?.isEmpty == false
        let needsReconnectForSync = refreshTokenRejected || (connected && !hasBookmarkScope) || (!connected && (hasAccessToken || hasKnownAccount))
        let configured = !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let message: String
        if connected, !hasBookmarkScope, let username {
            message = "Basic OAuth works for @\(username), but bookmark.read was not granted. Fix the bookmark scope or API access in X, then reconnect."
        } else if connected, !hasBookmarkScope {
            message = "Basic OAuth works, but bookmark.read was not granted. Fix the bookmark scope or API access in X, then reconnect."
        } else if refreshTokenRejected, hasFreshAccessToken, let username {
            message = "Connected temporarily as @\(username). Reconnect X to keep sync working."
        } else if refreshTokenRejected, hasFreshAccessToken {
            message = "Connected temporarily. Reconnect X to keep sync working."
        } else if refreshTokenRejected, let username {
            message = "Reconnect X to resume bookmark sync for @\(username)."
        } else if refreshTokenRejected {
            message = "Reconnect X to resume bookmark sync."
        } else if hasDurableRefreshToken, let username {
            message = "Connected as @\(username)"
        } else if hasDurableRefreshToken {
            message = "Connected"
        } else if hasFreshAccessToken, let username {
            message = "Connected as @\(username). Reconnect once for durable sync."
        } else if hasFreshAccessToken {
            message = "Connected. Reconnect once for durable sync."
        } else if needsReconnectForSync, let username {
            message = "Reconnect X to resume bookmark sync for @\(username)."
        } else if needsReconnectForSync {
            message = "Reconnect X to resume bookmark sync."
        } else if configured {
            message = "Ready to connect"
        } else {
            message = "Add your X OAuth 2.0 Client ID"
        }
        return XOAuthStatus(
            isConfigured: configured,
            isConnected: connected,
            canSyncBookmarks: canSyncBookmarks,
            needsReconnectForSync: needsReconnectForSync,
            username: username,
            message: message
        )
    }

    private static func scopeString(_ scopes: [String]) -> String {
        scopes.joined(separator: " ")
    }

    private static func savedScopes() -> Set<String>? {
        guard let raw = userDefaultString(Keys.tokenScopes, Keys.Legacy.tokenScopes)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return Set(raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
    }

    private static func hasSavedAccessToken() -> Bool {
        if userDefaultBool(Keys.accessTokenSaved, legacy: Keys.Legacy.accessTokenSaved) {
            return true
        }
        let exists = KeychainHelper.exists(key: Keys.accessToken, legacyKeys: [Keys.Legacy.accessToken])
        if exists {
            UserDefaults.standard.set(true, forKey: Keys.accessTokenSaved)
        }
        return exists
    }

    private static func hasSavedRefreshToken() -> Bool {
        if userDefaultBool(Keys.refreshTokenSaved, legacy: Keys.Legacy.refreshTokenSaved) {
            return true
        }
        let exists = KeychainHelper.exists(key: Keys.refreshToken, legacyKeys: [Keys.Legacy.refreshToken])
        if exists {
            UserDefaults.standard.set(true, forKey: Keys.refreshTokenSaved)
        }
        return exists
    }

    private static func hasFreshAccessToken() -> Bool {
        guard Self.hasSavedAccessToken(),
              let expiryText = userDefaultString(Keys.tokenExpiry, Keys.Legacy.tokenExpiry),
              let expiry = TimeInterval(expiryText) else {
            return false
        }
        return Date(timeIntervalSince1970: expiry).timeIntervalSinceNow > 60
    }

    private static func userDefaultString(_ keys: String...) -> String? {
        for key in keys {
            if let value = UserDefaults.standard.string(forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func userDefaultBool(_ key: String, legacy legacyKey: String) -> Bool {
        UserDefaults.standard.bool(forKey: key) || UserDefaults.standard.bool(forKey: legacyKey)
    }

    private static func removeUserDefaults(_ keys: String...) {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func formEncoded(_ values: [String: String]) -> Data {
        formEncodedString(values).data(using: .utf8) ?? Data()
    }

    private static func formEncodedString(_ values: [String: String]) -> String {
        values
            .map { key, value in
                "\(key.formEscaped)=\(value.formEscaped)"
            }
            .joined(separator: "&")
    }

    private static func strictQuery(_ values: [(String, String)]) -> String {
        values
            .map { key, value in
                "\(key.formEscaped)=\(value.formEscaped)"
            }
            .joined(separator: "&")
    }

    private static func prepareXAPIRequest(_ request: inout URLRequest) {
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppBrand.name)/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("close", forHTTPHeaderField: "Connection")
    }

    private static func normalizedToken(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedClientIDInput(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        let candidates = normalizedCredentialFragments(trimmed)
        if let likely = candidates.first(where: looksLikeOAuth2ClientID) {
            return likely
        }
        return trimmed
    }

    static func normalizedCredentialFragments(_ value: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        let trimCharacters = CharacterSet(charactersIn: "\"'`()[]{}<>:")
        return value
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: trimCharacters) }
            .filter { !$0.isEmpty }
    }

    static func looksLikeOAuth2ClientID(_ value: String) -> Bool {
        guard let decoded = decodedCredential(value) else { return false }
        return decoded.hasSuffix(":ci") || decoded.contains(":ci:")
    }

    static func looksLikeXAccessToken(_ value: String) -> Bool {
        decodedCredential(value)?.contains(":at:") == true
    }

    static func looksLikeXRefreshToken(_ value: String) -> Bool {
        decodedCredential(value)?.contains(":rt:") == true
    }

    static func xTokenPair(in value: String) -> (accessToken: String, refreshToken: String)? {
        var accessToken: String?
        var refreshToken: String?
        for fragment in normalizedCredentialFragments(value) {
            if accessToken == nil, looksLikeXAccessToken(fragment) {
                accessToken = fragment
            } else if refreshToken == nil, looksLikeXRefreshToken(fragment) {
                refreshToken = fragment
            }
        }
        guard let accessToken, let refreshToken else { return nil }
        return (accessToken, refreshToken)
    }

    private static func decodedCredential(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 30,
              clean.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              clean.rangeOfCharacter(from: CharacterSet(charactersIn: ",;%")) == nil else {
            return nil
        }
        var base64 = clean
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func apiError(data: Data, response: URLResponse) -> XOAuthError {
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let message = responseMessage(data: data, statusCode: statusCode)
        if statusCode == 401 {
            return .unauthorized
        }
        if statusCode == 403, isDeveloperAppProjectError(message) {
            return .developerAppNotInProject
        }
        return .httpError(message)
    }

    private static func responseMessage(data: Data, statusCode: Int?) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (json["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let error = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorDescription = (json["error_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidates: [String?] = [title, detail, message, error, errorDescription]
            let parts = candidates
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
            if !parts.isEmpty {
                return parts.joined(separator: ": ")
            }
        }

        let fallback = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty {
            return fallback
        }

        if let statusCode {
            return "X API request failed with HTTP \(statusCode)."
        }
        return "X API request failed."
    }

    private static func isInvalidTokenMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("invalid_request")
            || (lowercased.contains("invalid") && lowercased.contains("token"))
    }

    private static func isDeveloperAppProjectError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("client forbidden")
            || lowercased.contains("attached to a project")
            || (lowercased.contains("developer app") && lowercased.contains("project"))
    }
}

private struct XTokenResponse: Decodable {
    let tokenType: String?
    let expiresIn: Int?
    let accessToken: String
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case scope
    }
}

private struct XMeResponse: Decodable {
    let data: XUser
}

private struct XUser: Decodable {
    let id: String
    let username: String
    let name: String?

    var displayName: String? { name }
}

private struct XBookmarksPage: Decodable {
    let data: [XTweet]?
    let includes: XIncludes?
    let meta: XMeta?

    var tweets: [XTweet] { data ?? [] }
    var nextToken: String? { meta?.nextToken }

    var users: [String: XUser] {
        Dictionary(uniqueKeysWithValues: (includes?.users ?? []).map { ($0.id, $0) })
    }

    private var mediaByKey: [String: XMedia] {
        (includes?.media ?? []).reduce(into: [String: XMedia]()) { result, media in
            result[media.mediaKey] = media
        }
    }

    func mediaURLs(for tweet: XTweet) -> [String] {
        var seen = Set<String>()
        return tweet.mediaKeys.compactMap { key in
            guard let media = mediaByKey[key],
                  let url = media.previewURL,
                  seen.insert(url).inserted else {
                return nil
            }
            return url
        }
    }

    func mediaTypes(for tweet: XTweet) -> [String] {
        var seen = Set<String>()
        return tweet.mediaKeys.compactMap { key in
            guard let type = mediaByKey[key]?.type?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !type.isEmpty,
                  seen.insert(type).inserted else {
                return nil
            }
            return type
        }
    }
}

private struct XIncludes: Decodable {
    let users: [XUser]?
    let media: [XMedia]?
}

private struct XMeta: Decodable {
    let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case nextToken = "next_token"
    }
}

private struct XTweet: Decodable {
    let id: String
    let text: String
    let authorID: String?
    let createdAt: String?
    let attachments: XTweetAttachments?

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case authorID = "author_id"
        case createdAt = "created_at"
        case attachments
    }

    var mediaKeys: [String] {
        attachments?.mediaKeys ?? []
    }

    func url(authorUsername: String?) -> String {
        if let authorUsername, !authorUsername.isEmpty {
            return "https://x.com/\(authorUsername)/status/\(id)"
        }
        return "https://x.com/i/web/status/\(id)"
    }
}

private struct XTweetAttachments: Decodable {
    let mediaKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case mediaKeys = "media_keys"
    }
}

private struct XMedia: Decodable {
    let mediaKey: String
    let type: String?
    let url: String?
    let previewImageURL: String?
    let altText: String?
    let width: Int?
    let height: Int?
    let durationMS: Int?

    enum CodingKeys: String, CodingKey {
        case mediaKey = "media_key"
        case type
        case url
        case previewImageURL = "preview_image_url"
        case altText = "alt_text"
        case width
        case height
        case durationMS = "duration_ms"
    }

    var previewURL: String? {
        switch type {
        case "photo":
            return url ?? previewImageURL
        default:
            return previewImageURL ?? url
        }
    }
}

enum XOAuthError: LocalizedError {
    case missingClientID
    case invalidClientID
    case invalidAuthorizeURL
    case invalidTokenURL
    case invalidUserURL
    case invalidBookmarksURL
    case invalidCallbackURL
    case invalidState
    case missingCode
    case missingTokens
    case invalidTokenPair
    case notConnected
    case missingRefreshToken
    case unauthorized
    case authorizationExpired
    case developerAppNotInProject
    case httpError(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Add the X OAuth 2.0 Client ID first."
        case .invalidClientID:
            "That does not look like an X OAuth 2.0 Client ID. Paste the Client ID from OAuth 2.0 Keys inside the X app attached to your Project, not the API Key, Client Secret, Bearer token, access token, or refresh token."
        case .invalidAuthorizeURL:
            "Could not build the X authorization URL."
        case .invalidTokenURL:
            "Could not build the X token URL."
        case .invalidUserURL:
            "Could not build the X user URL."
        case .invalidBookmarksURL:
            "Could not build the X bookmarks URL."
        case .invalidCallbackURL:
            "That X callback URL does not belong to \(AppBrand.name)."
        case .invalidState:
            "The OAuth callback did not match this connection attempt."
        case .missingCode:
            "The X callback did not include an authorization code."
        case .missingTokens:
            "Paste both the X access token and refresh token."
        case .invalidTokenPair:
            "Those do not look like a matching X access token and refresh token pair. Paste the access token in the first field and the refresh token in the second."
        case .notConnected:
            "Connect your X account first."
        case .missingRefreshToken:
            "Reconnect X once. The previous connection did not include offline.access, so \(AppBrand.name) cannot refresh it for resync."
        case .unauthorized:
            "X rejected the saved access token. \(AppBrand.name) is refreshing it and will retry once."
        case .authorizationExpired:
            "X rejected the saved refresh token. Reconnect X or import fresh tokens before syncing."
        case .developerAppNotInProject:
            "X refused this token because the X developer app is not attached to a Project. In the X Developer Portal, create or open a Project, attach the app there, copy that app's OAuth 2.0 Client ID into \(AppBrand.name), then reconnect X."
        case .httpError(let message):
            message
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEscaped: String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
