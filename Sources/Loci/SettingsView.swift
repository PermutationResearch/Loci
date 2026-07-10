import AppKit
import SwiftUI

private enum SettingsNoticeTone {
    case info
    case success
    case warning
    case error

    var symbol: String {
        switch self {
        case .info:
            "info.circle"
        case .success:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .info:
            .secondary
        case .success:
            .green
        case .warning:
            .orange
        case .error:
            .red
        }
    }
}

struct SettingsView: View {
    @Bindable var store: LibraryStore

    @AppStorage("LociOpenRouterAPIKey") private var openRouterKey = ""
    @AppStorage("LociOpenRouterModel") private var openRouterModel = "openai/gpt-4o-mini"
    @AppStorage("LociLLMCompileModel") private var ollamaModel = ""
    @AppStorage("LociAutoExtract") private var autoExtract = true
    @AppStorage("LociAutoCompile") private var autoCompile = false
    @AppStorage("LociVaultPath") private var vaultPath = ""
    @AppStorage("LociXRedirectMode") private var xRedirectModeRaw = XOAuthRedirectMode.recommended.rawValue
    @AppStorage(LociTelemetry.enabledKey) private var telemetryEnabled = true
    @AppStorage(LociTelemetry.endpointKey) private var telemetryEndpoint = ""

    @StateObject private var xOAuth = XOAuthManager.shared
    @State private var xClientID = ""
    @State private var xAccessToken = ""
    @State private var xRefreshToken = ""
    @State private var showOpenRouterKey = false
    @State private var ollamaRunning = false
    @State private var xMessage = ""
    @State private var xMessageTone: SettingsNoticeTone = .info
    @State private var libraryMessage = ""
    @State private var libraryMessageTone: SettingsNoticeTone = .info
    @State private var telemetryMessage = ""
    @State private var telemetryMessageTone: SettingsNoticeTone = .info
    @State private var isSyncingX = false
    @State private var isImportingXTokens = false
    @State private var showAdvancedXTokens = false
    @State private var selectedTab = "x"

    private let xDeveloperPortalURL = URL(string: "https://developer.x.com/en/portal/dashboard")!
    private var xWebsiteURL: String { XOAuthManager.websiteURL }
    private var xBasicScopes: String { XOAuthManager.basicDiagnosticScopes.joined(separator: " ") }
    private var xBookmarkScopes: String { XOAuthManager.requiredScopes.joined(separator: " ") }
    private var xClientIDStatus: String {
        hasXClientID ? "OAuth 2.0 Client ID format OK" : "Paste OAuth 2.0 Client ID"
    }
    private var activeLibraryURL: URL { store.vaultRootURL.standardizedFileURL }
    private var configuredLibraryURL: URL { LibraryLocation.currentRootURL.standardizedFileURL }
    private var libraryNeedsRelaunch: Bool {
        activeLibraryURL.path != configuredLibraryURL.path
    }
    private var configuredLibraryProvider: String {
        LibraryLocation.providerName(for: configuredLibraryURL)
    }

    private var shouldShowXMessage: Bool {
        !xMessage.isEmpty && !isStaleXRefreshError
    }

    private var isStaleXRefreshError: Bool {
        xMessage == XOAuthError.authorizationExpired.localizedDescription &&
            xOAuth.status.canSyncBookmarks &&
            !xOAuth.status.needsReconnectForSync
    }

    private var xRedirectModeBinding: Binding<String> {
        Binding(
            get: { xRedirectModeRaw },
            set: { newValue in
                xRedirectModeRaw = newValue
                xOAuth.refreshStatus()
                setXMessage("X callback mode changed. Update the X Developer Portal callback to match.", tone: .warning)
            }
        )
    }

    private var xConnectButtonTitle: String {
        (xOAuth.status.isConnected || xOAuth.status.needsReconnectForSync) ? "Reconnect Bookmarks" : "Connect Bookmarks"
    }

    private var xConnectionSymbol: String {
        if xOAuth.status.needsReconnectForSync {
            return "exclamationmark.circle.fill"
        }
        if xOAuth.status.canSyncBookmarks {
            return "checkmark.circle.fill"
        }
        return "circle"
    }

    private var xConnectionColor: Color {
        if xOAuth.status.needsReconnectForSync {
            return .orange
        }
        if xOAuth.status.canSyncBookmarks {
            return .green
        }
        return .secondary
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            llmTab
                .tabItem { Label("AI Models", systemImage: "cpu") }
                .tag("ai")

            xTab
                .tabItem { Label("X Sync", systemImage: "bookmark") }
                .tag("x")

            extractionTab
                .tabItem { Label("Extraction", systemImage: "doc.text.magnifyingglass") }
                .tag("extraction")

            vaultTab
                .tabItem { Label("Vault", systemImage: "externaldrive") }
                .tag("vault")

            privacyTab
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag("privacy")

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 700, height: 620)
        .padding(.top, 8)
        .onAppear {
            xClientID = xOAuth.clientID
            xOAuth.refreshStatus()
            clearStaleXMessage()
            checkOllama()
        }
        .onChange(of: xOAuth.status) {
            clearStaleXMessage()
        }
    }

    private var llmTab: some View {
        Form {
            Section {
                HStack {
                    Label("API Key", systemImage: "key")
                    Spacer()
                    Group {
                        if showOpenRouterKey {
                            TextField("sk-or-...", text: $openRouterKey)
                        } else {
                            SecureField("sk-or-...", text: $openRouterKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)

                    Button {
                        showOpenRouterKey.toggle()
                    } label: {
                        Image(systemName: showOpenRouterKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Label("Model", systemImage: "brain")
                    Spacer()
                    TextField("openai/gpt-4o-mini", text: $openRouterModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
            } header: {
                Text("OpenRouter")
            }

            Section {
                HStack {
                    Label("Status", systemImage: ollamaRunning ? "checkmark.circle.fill" : "xmark.circle")
                    Spacer()
                    Text(ollamaRunning ? "Running" : "Not running")
                        .foregroundStyle(ollamaRunning ? .green : .secondary)
                }

                HStack {
                    Label("Compile model", systemImage: "shippingbox")
                    Spacer()
                    TextField("llama3.2", text: $ollamaModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
            } header: {
                Text("Local Ollama")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 16)
    }

    private var xTab: some View {
        Form {
            Section {
                setupStep(
                    number: 1,
                    title: "Open X Developer Portal",
                    detail: "Open a Project, select the app attached to that Project, then open User authentication settings.",
                    isComplete: false
                )

                HStack(spacing: 8) {
                    Button("Open X Developer Portal") {
                        NSWorkspace.shared.open(xDeveloperPortalURL)
                        setXMessage("Opened X Developer Portal.", tone: .info)
                    }
                    Button("Copy callback") {
                        copyToPasteboard(XOAuthManager.redirectURI)
                        setXMessage("Raw callback URL copied. Paste it into X exactly as shown, not percent-encoded.", tone: .success)
                    }
                }
                .controlSize(.small)

                setupStep(
                    number: 2,
                    title: "Enter these X Console values",
                    detail: "App permissions: Read. Type of App: Native App. Client type: Public client / PKCE. Paste the raw callback and website URLs in X; \(AppBrand.name) encodes redirect_uri only inside the generated auth link.",
                    isComplete: false
                )

                Picker("Callback mode", selection: xRedirectModeBinding) {
                    ForEach(XOAuthRedirectMode.setupModes) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                settingsValueRow("Callback / Redirect URL", value: XOAuthManager.redirectURI) {
                    copyToPasteboard(XOAuthManager.redirectURI)
                    setXMessage("Raw callback URL copied. Use this exact readable URL in X Developer Portal.", tone: .success)
                }
                settingsValueRow("Website URL", value: xWebsiteURL) {
                    copyToPasteboard(xWebsiteURL)
                    setXMessage("Website URL copied.", tone: .success)
                }
                settingsValueRow("Basic OAuth scopes", value: xBasicScopes) {
                    copyToPasteboard(xBasicScopes)
                    setXMessage("Basic OAuth scopes copied.", tone: .success)
                }

                settingsValueRow("Bookmark scopes", value: xBookmarkScopes) {
                    copyToPasteboard(xBookmarkScopes)
                    setXMessage("Bookmark scopes copied.", tone: .success)
                }

                setupStep(
                    number: 3,
                    title: "Save in X, then copy OAuth 2.0 Client ID",
                    detail: "After saving User authentication settings, open OAuth 2.0 Keys and paste only the Client ID below.",
                    isComplete: hasXClientID
                )
            } header: {
                Text("Guided X Bookmark Setup")
            } footer: {
                Text("\(AppBrand.name) uses OAuth 2.0 with PKCE. In X Developer Portal, paste readable URLs like http://127.0.0.1:17641/oauth/x/callback. Do not paste an encoded value containing %3A or %2F.")
            }

            Section {
                settingsValueRow("Selected callback", value: XOAuthManager.redirectURI) {
                    copyToPasteboard(XOAuthManager.redirectURI)
                    setXMessage("Callback URL copied.", tone: .success)
                }

                HStack {
                    Label("Client ID", systemImage: "person.text.rectangle")
                    Spacer()
                    TextField("OAuth 2.0 Client ID", text: $xClientID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 330)
                }

                HStack {
                    Label("Client ID check", systemImage: hasXClientID ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    Spacer()
                    Text(xClientIDStatus)
                        .font(.callout)
                        .foregroundStyle(hasXClientID ? .green : .secondary)
                }

                HStack(spacing: 8) {
                    Button("Paste") {
                        pasteXClientID()
                    }
                    Button("Save Client ID") {
                        saveXClientID()
                    }
                    Button("Test OAuth") {
                        connectBasicX()
                    }
                    .disabled(!hasXClientID)

                    Button(xConnectButtonTitle) {
                        connectX()
                    }
                    .disabled(!hasXClientID)

                    Button("Disconnect") {
                        xOAuth.disconnect()
                        setXMessage("X account disconnected.", tone: .info)
                    }
                    .disabled(!xOAuth.status.isConnected && !xOAuth.status.needsReconnectForSync)
                }
                .controlSize(.small)

                HStack(spacing: 8) {
                    Button("Copy OAuth Test URL") {
                        copyXAuthorizationURL(
                            scopes: XOAuthManager.basicDiagnosticScopes,
                            label: "OAuth test URL"
                        )
                    }
                    .disabled(!hasXClientID)

                    Button("Copy Bookmark URL") {
                        copyXAuthorizationURL(
                            scopes: XOAuthManager.requiredScopes,
                            label: "Bookmark authorization URL"
                        )
                    }
                    .disabled(!hasXClientID)
                }
                .controlSize(.small)

                HStack {
                    Label("Connection", systemImage: xConnectionSymbol)
                    Spacer()
                    Text(xOAuth.status.message)
                        .foregroundStyle(xConnectionColor)
                }
            } header: {
                Text("Connect \(AppBrand.name)")
            } footer: {
                Text("Run Test OAuth first. If Test OAuth opens X's Something went wrong page, the X Developer app is misconfigured before \(AppBrand.name) receives anything. If Test OAuth works but Connect Bookmarks fails, X is rejecting bookmark.read for this app/account.")
            }

            Section {
                Button(isSyncingX ? "Syncing..." : "Sync Bookmarks") {
                    syncXBookmarks()
                }
                .disabled(!xOAuth.status.canSyncBookmarks || isSyncingX)

                if shouldShowXMessage {
                    settingsNotice(xMessage, tone: xMessageTone)
                }
            } header: {
                Text("Import Bookmarks")
            } footer: {
                Text("Synced X bookmarks appear in Inbox and get tagged as x-bookmarked.")
            }

            Section {
                DisclosureGroup(isExpanded: $showAdvancedXTokens) {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Access token", text: $xAccessToken)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Refresh token", text: $xRefreshToken)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Button("Paste Tokens") {
                                pasteXTokens()
                            }

                            Button(isImportingXTokens ? "Importing..." : "Import Tokens") {
                                importXTokens()
                            }
                            .disabled(
                                isImportingXTokens ||
                                !hasXClientID ||
                                xAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                xRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Advanced token import", systemImage: "key.viewfinder")
                }
            } footer: {
                Text("Use this only if OAuth browser connection fails or you already generated tokens in X.")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 16)
    }

    private var extractionTab: some View {
        Form {
            Section {
                Toggle("Auto-extract on import", isOn: $autoExtract)
                Toggle("Auto-compile wiki pages", isOn: $autoCompile)
            } header: {
                Text("Pipeline")
            } footer: {
                Text("Auto-extract runs document extraction on imports. Auto-compile generates wiki pages from extracted content.")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 16)
    }

    private var vaultTab: some View {
        Form {
            Section {
                settingsValueRow("Active library", value: activeLibraryURL.path) {
                    copyToPasteboard(activeLibraryURL.path)
                    setLibraryMessage("Active library path copied.", tone: .success)
                }

                settingsValueRow("Sync location", value: configuredLibraryURL.path) {
                    copyToPasteboard(configuredLibraryURL.path)
                    setLibraryMessage("Sync location copied.", tone: .success)
                }

                HStack {
                    Label("Storage provider", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(configuredLibraryProvider)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Choose Synced Folder...") {
                        chooseLibraryLocation()
                    }
                    Button("Reveal Active Library") {
                        NSWorkspace.shared.activateFileViewerSelecting([activeLibraryURL])
                    }
                    Button("Use Local Default") {
                        resetLibraryLocation()
                    }
                    .disabled(vaultPath.isEmpty)
                }
                .controlSize(.small)

                if libraryNeedsRelaunch {
                    settingsNotice("Quit and reopen \(AppBrand.name) to finish switching to this library.", tone: .warning)
                    Button("Quit to Finish") {
                        NSApp.terminate(nil)
                    }
                    .controlSize(.small)
                }

                if !libraryMessage.isEmpty {
                    settingsNotice(libraryMessage, tone: libraryMessageTone)
                }
            } header: {
                Text("Library Location")
            } footer: {
                Text("Choose an iCloud Drive, Dropbox, Google Drive, or local folder. \(AppBrand.name) stores one .atlaslibrary folder there.")
            }

            Section {
                settingsValueRow("Database", value: ByteCountFormatter.string(fromByteCount: databaseSize, countStyle: .file))
                settingsValueRow("Originals", value: ByteCountFormatter.string(fromByteCount: originalsSize, countStyle: .file))
                settingsValueRow("Thumbnails", value: ByteCountFormatter.string(fromByteCount: thumbnailsSize, countStyle: .file))
            } header: {
                Text("Usage")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 16)
    }

    private var privacyTab: some View {
        Form {
            Section {
                Toggle("Share anonymous product analytics", isOn: $telemetryEnabled)

                settingsValueRow("Anonymous install ID", value: LociTelemetry.installID) {
                    copyToPasteboard(LociTelemetry.installID)
                    setTelemetryMessage("Anonymous install ID copied.", tone: .success)
                }

                HStack {
                    Label("Ingest endpoint", systemImage: "network")
                    Spacer()
                    TextField("https://analytics.example.com/events", text: $telemetryEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 330)
                }

                settingsValueRow("Local queue", value: ByteCountFormatter.string(fromByteCount: telemetryQueueSize, countStyle: .file))

                HStack(spacing: 8) {
                    Button("Record Snapshot") {
                        LociTelemetry.recordLibrarySnapshot(store: store)
                        setTelemetryMessage("Snapshot queued.", tone: telemetryEnabled ? .success : .warning)
                    }
                    .disabled(!telemetryEnabled)

                    Button("Clear Local Queue") {
                        LociTelemetry.clearLocalQueue()
                        setTelemetryMessage("Local telemetry queue cleared.", tone: .success)
                    }
                }
                .controlSize(.small)

                if !telemetryMessage.isEmpty {
                    settingsNotice(telemetryMessage, tone: telemetryMessageTone)
                }
            } header: {
                Text("Telemetry")
            } footer: {
                Text("Off by default. When enabled, \(AppBrand.name) sends anonymous counts and feature events only. It does not send file names, file contents, URLs, X bookmark text, prompts, model responses, graph node names, API keys, or OAuth tokens.")
            }

            Section {
                telemetryRow("Users", "Anonymous install ID and app version on launch.")
                telemetryRow("Library scale", "Counts for references, collections, tags, assets, queued jobs, and storage size.")
                telemetryRow("Feature usage", "Mode/filter changes, imports by source, X sync totals, graph opens, and LLM success/failure.")
                telemetryRow("Model improvement", "Only aggregate LLM usage metadata. Training datasets require a separate explicit export flow.")
            } header: {
                Text("What Can Be Measured")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 16)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            if let nsImage = NSApp.applicationIconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 64, height: 64)
            }

            Text(AppBrand.name)
                .font(.title2.weight(.semibold))
            Text("A local-first visual reference library.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func telemetryRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasXClientID: Bool {
        XOAuthManager.looksLikeOAuth2ClientID(XOAuthManager.normalizedClientIDInput(xClientID))
    }

    private func setupStep(number: Int, title: String, detail: String, isComplete: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12))
                if isComplete {
                    Image(systemName: "checkmark")
                        .lociFont(size: 11, weight: .bold, relativeTo: .caption)
                        .foregroundStyle(.green)
                } else {
                    Text("\(number)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsValueRow(_ title: String, value: String, copyAction: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .lociFont(size: 11, design: .monospaced, relativeTo: .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let copyAction {
                Button("Copy", action: copyAction)
                    .controlSize(.small)
            }
        }
    }

    private func settingsNotice(_ message: String, tone: SettingsNoticeTone) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone.symbol)
                .lociFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(tone.color)
                .frame(width: 16)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }

    private func setXMessage(_ message: String, tone: SettingsNoticeTone) {
        xMessage = message
        xMessageTone = tone
    }

    private func clearStaleXMessage() {
        if isStaleXRefreshError {
            xMessage = ""
            xMessageTone = .info
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func pasteXClientID() {
        let rawValue = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty else {
            setXMessage("Clipboard is empty.", tone: .warning)
            return
        }
        if applyXPastedTokens(rawValue) {
            return
        }
        let value = XOAuthManager.normalizedClientIDInput(rawValue)
        xClientID = value
        if XOAuthManager.looksLikeOAuth2ClientID(value) {
            let message = value == rawValue ? "OAuth 2.0 Client ID pasted." : "OAuth 2.0 Client ID extracted from clipboard."
            setXMessage(message, tone: .success)
        } else {
            setXMessage(XOAuthError.invalidClientID.localizedDescription, tone: .warning)
        }
    }

    private func pasteXTokens() {
        let rawValue = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty else {
            setXMessage("Clipboard is empty.", tone: .warning)
            return
        }
        guard applyXPastedTokens(rawValue) else {
            setXMessage("Clipboard does not contain both an X access token and refresh token.", tone: .warning)
            return
        }
    }

    @discardableResult
    private func applyXPastedTokens(_ rawValue: String) -> Bool {
        guard let tokens = XOAuthManager.xTokenPair(in: rawValue) else { return false }
        xAccessToken = tokens.accessToken
        xRefreshToken = tokens.refreshToken
        showAdvancedXTokens = true

        let possibleClientID = XOAuthManager.normalizedClientIDInput(rawValue)
        if XOAuthManager.looksLikeOAuth2ClientID(possibleClientID) {
            xClientID = possibleClientID
            setXMessage("That paste included X tokens, so I put them in Advanced token import and filled the Client ID. You can import them now.", tone: .success)
        } else if hasXClientID {
            setXMessage("That paste was an X access/refresh token pair, not a Client ID. I put it in Advanced token import. You can import it now.", tone: .warning)
        } else {
            setXMessage("That paste was an X access/refresh token pair, not a Client ID. I put it in Advanced token import. Paste the OAuth 2.0 Client ID above, then import.", tone: .warning)
        }
        return true
    }

    @discardableResult
    private func saveXClientID() -> Bool {
        let normalized = XOAuthManager.normalizedClientIDInput(xClientID)
        xClientID = normalized
        guard XOAuthManager.looksLikeOAuth2ClientID(normalized) else {
            setXMessage(XOAuthError.invalidClientID.localizedDescription, tone: .error)
            return false
        }
        xOAuth.clientID = normalized
        xOAuth.clientSecret = ""
        xOAuth.refreshStatus()
        setXMessage("X Client ID saved.", tone: .success)
        return true
    }

    private func connectX() {
        do {
            guard saveXClientID() else { return }
            try xOAuth.startAuthorization()
            setXMessage("Opened bookmark authorization. If X rejects this but Test OAuth works, bookmark.read is the failing part. Callback must be exactly: \(XOAuthManager.redirectURI)", tone: .info)
        } catch {
            setXMessage(error.localizedDescription, tone: .error)
        }
    }

    private func connectBasicX() {
        do {
            guard saveXClientID() else { return }
            try xOAuth.startBasicAuthorization()
            setXMessage("Opened OAuth test without bookmark.read. If X still shows Something went wrong, fix the X Developer app: OAuth 2.0 enabled, Project-attached app, raw callback saved exactly, and this same Client ID.", tone: .info)
        } catch {
            setXMessage(error.localizedDescription, tone: .error)
        }
    }

    private func copyXAuthorizationURL(scopes: [String], label: String) {
        do {
            guard saveXClientID() else { return }
            let url = try xOAuth.authorizationURL(scopes: scopes)
            copyToPasteboard(url.absoluteString)
            setXMessage("\(label) copied. Open it in the browser where you are already logged into X.", tone: .success)
        } catch {
            setXMessage(error.localizedDescription, tone: .error)
        }
    }

    private func importXTokens() {
        isImportingXTokens = true
        setXMessage("Importing X tokens...", tone: .info)
        Task {
            do {
                guard saveXClientID() else {
                    isImportingXTokens = false
                    return
                }
                try await xOAuth.importExistingTokens(
                    accessToken: xAccessToken,
                    refreshToken: xRefreshToken
                )
                xAccessToken = ""
                xRefreshToken = ""
                setXMessage("X tokens imported.", tone: .success)
            } catch {
                setXMessage(error.localizedDescription, tone: .error)
            }
            isImportingXTokens = false
            xOAuth.refreshStatus()
        }
    }

    private func syncXBookmarks() {
        xOAuth.refreshStatus()
        guard xOAuth.status.canSyncBookmarks else {
            let message = xOAuth.status.needsReconnectForSync
                ? "Reconnect X once, then sync. The old token cannot refresh."
                : "No usable X token is saved. Reconnect X above or import fresh tokens before syncing."
            setXMessage(message, tone: .warning)
            return
        }
        isSyncingX = true
        setXMessage("Syncing X bookmarks...", tone: .info)
        Task {
            do {
                let result = try await xOAuth.syncBookmarks(into: store)
                LociTelemetry.recordXBookmarkSync(
                    total: result.total,
                    imported: result.imported,
                    updated: result.updated
                )
                setXMessage(xSyncResultMessage(result), tone: .success)
            } catch XOAuthError.developerAppNotInProject {
                setXMessage(XOAuthError.developerAppNotInProject.localizedDescription, tone: .error)
            } catch XOAuthError.authorizationExpired {
                setXMessage(XOAuthError.authorizationExpired.localizedDescription, tone: .error)
            } catch {
                setXMessage(error.localizedDescription, tone: .error)
            }
            isSyncingX = false
            xOAuth.refreshStatus()
        }
    }

    private func xSyncResultMessage(_ result: XBookmarkSyncResult) -> String {
        if result.total == 0 {
            return "X connected, but returned 0 bookmarks. If you have bookmarks, check bookmark.read scope in the X Developer app."
        }
        if result.imported == 0, result.updated == 0 {
            return "Scanned \(result.total) X bookmarks. Nothing new changed."
        }
        if result.imported == 0 {
            return "All \(result.updated) X bookmarks already existed. They were refreshed in X Bookmarks."
        }
        if result.updated == 0 {
            return "Imported \(result.imported) X bookmarks to X Bookmarks."
        }
        return "Imported \(result.imported) new and refreshed \(result.updated) existing X bookmarks in X Bookmarks."
    }

    private var databaseSize: Int64 {
        fileSize(at: store.storageStats.databaseURL.path)
    }

    private var originalsSize: Int64 {
        folderSize(at: store.storageStats.originalsURL.path)
    }

    private var thumbnailsSize: Int64 {
        folderSize(at: store.storageStats.thumbnailsURL.path)
    }

    private var telemetryQueueSize: Int64 {
        fileSize(at: LociTelemetry.localQueueURL.path)
    }

    private func chooseLibraryLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose Library Sync Folder"
        panel.prompt = "Choose"
        panel.message = "Pick an iCloud Drive, Dropbox, Google Drive, or local folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        do {
            let destination = try LibraryLocation.prepareLibrary(
                at: selectedURL,
                copyingFrom: activeLibraryURL
            )
            vaultPath = destination.path
            setLibraryMessage("Library location set to \(LibraryLocation.providerName(for: destination)). Quit and reopen to finish.", tone: .success)
        } catch {
            setLibraryMessage(error.localizedDescription, tone: .error)
        }
    }

    private func resetLibraryLocation() {
        LibraryLocation.resetToDefault()
        vaultPath = ""
        setLibraryMessage("Library location reset to local storage. Quit and reopen to finish.", tone: .warning)
    }

    private func setLibraryMessage(_ message: String, tone: SettingsNoticeTone) {
        libraryMessage = message
        libraryMessageTone = tone
    }

    private func setTelemetryMessage(_ message: String, tone: SettingsNoticeTone) {
        telemetryMessage = message
        telemetryMessageTone = tone
    }

    private func fileSize(at path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }

    private func folderSize(at path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let file as String in enumerator {
            total += fileSize(at: (path as NSString).appendingPathComponent(file))
        }
        return total
    }

    private func checkOllama() {
        Task {
            guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
            ollamaRunning = ((try? await URLSession.shared.data(from: url).1 as? HTTPURLResponse)?.statusCode == 200)
        }
    }
}
