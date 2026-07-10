import Foundation

@MainActor
enum LegacyAppMigration {
    static func run() {
        migrateDefaults()
        migrateApplicationSupport()
    }

    private static func migrateDefaults() {
        let legacyDomains = ["ReferenceAtlas", "com.codex.reference-atlas"]
        let defaults = UserDefaults.standard
        let mappings: [(legacy: String, current: String)] = [
            ("AtlasXClientID", "LociXClientID"),
            ("AtlasXUsername", "LociXUsername"),
            ("AtlasXUserID", "LociXUserID"),
            ("AtlasXRedirectMode", "LociXRedirectMode"),
            ("AtlasVaultPath", LibraryLocation.userDefaultsKey),
            ("ReferenceAtlas.APIToken", LocalReferenceAPIServer.tokenKey),
            ("AtlasTelemetryEnabled", LociTelemetry.enabledKey),
            ("AtlasTelemetryEndpointURL", LociTelemetry.endpointKey),
            ("AtlasTelemetryInstallID", LociTelemetry.installIDKey),
            ("ReferenceAtlas.X.AccessTokenSaved", "Loci.X.AccessTokenSaved"),
            ("ReferenceAtlas.X.RefreshTokenSaved", "Loci.X.RefreshTokenSaved"),
            ("ReferenceAtlas.X.TokenExpiry", "Loci.X.TokenExpiry"),
            ("ReferenceAtlas.X.TokenScopes", "Loci.X.TokenScopes"),
            ("ReferenceAtlas.X.RefreshTokenRejected", "Loci.X.RefreshTokenRejected")
        ]

        for mapping in mappings where defaults.object(forKey: mapping.current) == nil {
            guard let value = value(for: mapping.legacy, in: legacyDomains) else { continue }
            defaults.set(value, forKey: mapping.current)
        }
    }

    private static func value(for key: String, in domains: [String]) -> Any? {
        for domain in domains {
            guard let legacyDefaults = UserDefaults(suiteName: domain),
                  let value = legacyDefaults.object(forKey: key) else {
                continue
            }
            return value
        }
        return nil
    }

    private static func migrateApplicationSupport() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        let lociRoot = appSupport.appendingPathComponent(AppBrand.name, isDirectory: true)
        let legacyRoot = appSupport.appendingPathComponent(AppBrand.legacyName, isDirectory: true)
        if fileManager.fileExists(atPath: legacyRoot.path),
           !fileManager.fileExists(atPath: lociRoot.path) {
            try? fileManager.moveItem(at: legacyRoot, to: lociRoot)
            renameLegacyLibraryFiles(in: lociRoot)
            UserDefaults.standard.set(lociRoot.path, forKey: LibraryLocation.userDefaultsKey)
        } else if fileManager.fileExists(atPath: lociRoot.path) {
            renameLegacyLibraryFiles(in: lociRoot)
        }

        let lociVault = appSupport.appendingPathComponent("\(AppBrand.name) Vault", isDirectory: true)
        let legacyVault = appSupport.appendingPathComponent("\(AppBrand.legacyName) Vault", isDirectory: true)
        if fileManager.fileExists(atPath: legacyVault.path),
           !fileManager.fileExists(atPath: lociVault.path) {
            try? fileManager.moveItem(at: legacyVault, to: lociVault)
        }
    }

    private static func renameLegacyLibraryFiles(in root: URL) {
        renameIfNeeded(in: root, from: AppBrand.legacyDatabaseFileName, to: AppBrand.databaseFileName)
        renameIfNeeded(in: root, from: "\(AppBrand.legacyDatabaseFileName)-wal", to: "\(AppBrand.databaseFileName)-wal")
        renameIfNeeded(in: root, from: "\(AppBrand.legacyDatabaseFileName)-shm", to: "\(AppBrand.databaseFileName)-shm")
        renameIfNeeded(in: root, from: "atlas.env", to: "loci.env")
    }

    private static func renameIfNeeded(in root: URL, from legacyName: String, to currentName: String) {
        let fileManager = FileManager.default
        let legacyURL = root.appendingPathComponent(legacyName)
        let currentURL = root.appendingPathComponent(currentName)
        guard fileManager.fileExists(atPath: legacyURL.path),
              !fileManager.fileExists(atPath: currentURL.path) else {
            return
        }
        try? fileManager.moveItem(at: legacyURL, to: currentURL)
    }
}
