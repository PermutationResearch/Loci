import Foundation

enum LociResources {
    private static let swiftPMBundleName = "Loci_Loci.bundle"

    static func url(
        forResource name: String,
        withExtension extensionName: String,
        subdirectory: String? = nil
    ) -> URL? {
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: extensionName,
            subdirectory: subdirectory
        ) {
            return url
        }

        #if DEBUG
        if let url = Bundle.module.url(
            forResource: name,
            withExtension: extensionName,
            subdirectory: subdirectory
        ) ?? (subdirectory == nil
            ? nil
            : Bundle.module.url(forResource: name, withExtension: extensionName)) {
            return url
        }
        #endif

        for bundleURL in candidateBundleURLs() {
            guard let bundle = Bundle(url: bundleURL) else { continue }
            if let url = bundle.url(
                forResource: name,
                withExtension: extensionName,
                subdirectory: subdirectory
            ) {
                return url
            }
            // SwiftPM's `.process` rule may flatten resource subdirectories.
            if subdirectory != nil,
               let url = bundle.url(forResource: name, withExtension: extensionName) {
                return url
            }
        }
        return nil
    }

    private static func candidateBundleURLs() -> [URL] {
        var candidates: [URL] = []
        if let resourcesURL = Bundle.main.resourceURL {
            candidates.append(
                resourcesURL
                    .appendingPathComponent("SwiftPM", isDirectory: true)
                    .appendingPathComponent(swiftPMBundleName, isDirectory: true)
            )
        }
        candidates.append(
            Bundle.main.bundleURL.appendingPathComponent(swiftPMBundleName, isDirectory: true)
        )
        candidates.append(
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(swiftPMBundleName, isDirectory: true)
        )
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            var directory = executableDirectory
            for _ in 0..<6 {
                candidates.append(
                    directory.appendingPathComponent(swiftPMBundleName, isDirectory: true)
                )
                directory.deleteLastPathComponent()
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
