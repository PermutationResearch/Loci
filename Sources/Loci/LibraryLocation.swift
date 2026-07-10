import Foundation

enum LibraryLocation {
    static let userDefaultsKey = "LociVaultPath"
    static let legacyUserDefaultsKey = "AtlasVaultPath"
    static let portableLibraryName = "\(AppBrand.name) Library.atlaslibrary"

    static var currentRootURL: URL {
        if let savedPath = UserDefaults.standard.string(forKey: userDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !savedPath.isEmpty {
            return URL(fileURLWithPath: NSString(string: savedPath).expandingTildeInPath, isDirectory: true)
        }
        if let legacyPath = UserDefaults.standard.string(forKey: legacyUserDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyPath.isEmpty {
            return URL(fileURLWithPath: NSString(string: legacyPath).expandingTildeInPath, isDirectory: true)
        }
        return defaultRootURL
    }

    static var defaultRootURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let lociRoot = appSupport.appendingPathComponent(AppBrand.name, isDirectory: true)
        let legacyRoot = appSupport.appendingPathComponent(AppBrand.legacyName, isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyRoot.path),
           !FileManager.default.fileExists(atPath: lociRoot.path) {
            return legacyRoot
        }
        return lociRoot
    }

    static func rootURL(forUserSelected selectedURL: URL) -> URL {
        let standardized = selectedURL.standardizedFileURL
        if standardized.pathExtension == "atlaslibrary" {
            return standardized
        }
        if containsLibraryDatabase(standardized) {
            return standardized
        }
        return standardized.appendingPathComponent(portableLibraryName, isDirectory: true)
    }

    static func prepareLibrary(at selectedURL: URL, copyingFrom sourceRootURL: URL) throws -> URL {
        let destination = rootURL(forUserSelected: selectedURL)
        let source = sourceRootURL.standardizedFileURL
        guard destination.standardizedFileURL.path != source.path else {
            UserDefaults.standard.set(destination.path, forKey: userDefaultsKey)
            return destination
        }

        try validateDestination(destination, source: source)

        if containsLibraryDatabase(destination) {
            UserDefaults.standard.set(destination.path, forKey: userDefaultsKey)
            return destination
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try removeEmptyDirectory(at: destination)
        }

        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: nil)
        }

        UserDefaults.standard.set(destination.path, forKey: userDefaultsKey)
        return destination
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
    }

    static func providerName(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.contains("/Mobile Documents/") || path.contains("/iCloud Drive/") {
            return "iCloud Drive"
        }
        if path.localizedCaseInsensitiveContains("Dropbox") {
            return "Dropbox"
        }
        if path.localizedCaseInsensitiveContains("Google Drive") {
            return "Google Drive"
        }
        if path.localizedCaseInsensitiveContains("OneDrive") {
            return "OneDrive"
        }
        return "Local folder"
    }

    private static func validateDestination(_ destination: URL, source: URL) throws {
        let destinationPath = destination.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        if destinationPath.hasPrefix(sourcePath + "/") {
            throw NSError(
                domain: "Loci.LibraryLocation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Choose a folder outside the current \(AppBrand.name) library."]
            )
        }
    }

    static func containsLibraryDatabase(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(AppBrand.databaseFileName).path) ||
            FileManager.default.fileExists(atPath: url.appendingPathComponent(AppBrand.legacyDatabaseFileName).path)
    }

    private static func removeEmptyDirectory(at url: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
        guard contents.isEmpty else {
            throw NSError(
                domain: "Loci.LibraryLocation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "That library folder already contains files. Choose it directly if it is an existing \(AppBrand.name) library, or choose an empty folder."]
            )
        }
        try FileManager.default.removeItem(at: url)
    }
}
