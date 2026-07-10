import Foundation

enum LociEnvironment {
    nonisolated(unsafe) private static var cachedFileValues: [String: String]?
    private static let envFileNames = ["atlas.env", "loci.env", ".env"]

    static func value(for keys: [String]) -> String? {
        for key in expandedKeys(for: keys) {
            if let env = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !env.isEmpty {
                return env
            }
            if let file = fileValue(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !file.isEmpty {
                return file
            }
            for defaultsKey in userDefaultsKeys(for: key) {
                if let defaults = UserDefaults.standard.string(forKey: defaultsKey)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !defaults.isEmpty {
                    return defaults
                }
            }
        }
        return nil
    }

    static func reload() {
        cachedFileValues = nil
    }

    private static func fileValue(_ key: String) -> String? {
        loadFileValues()[key]
    }

    private static func loadFileValues() -> [String: String] {
        if let cachedFileValues {
            return cachedFileValues
        }

        var merged: [String: String] = [:]
        for url in envFileURLs() {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                merged[key] = value
            }
        }
        cachedFileValues = merged
        return merged
    }

    private static func envFileURLs() -> [URL] {
        var urls: [URL] = []
        let libraryRoot = LibraryLocation.currentRootURL
        for name in envFileNames {
            urls.append(libraryRoot.appendingPathComponent(name))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for name in envFileNames {
            urls.append(cwd.appendingPathComponent(name))
        }
        return urls
    }

    private static func expandedKeys(for keys: [String]) -> [String] {
        var expanded: [String] = []
        var seen = Set<String>()
        func append(_ key: String) {
            guard seen.insert(key).inserted else { return }
            expanded.append(key)
        }
        for key in keys {
            append(key)
            if key.hasPrefix("LOCI_") {
                append("ATLAS_" + String(key.dropFirst("LOCI_".count)))
            }
        }
        return expanded
    }

    private static func userDefaultsKeys(for envKey: String) -> [String] {
        switch envKey {
        case "OPENROUTER_API_KEY", "LOCI_OPENROUTER_API_KEY", "ATLAS_OPENROUTER_API_KEY":
            return ["LociOpenRouterAPIKey", "AtlasOpenRouterAPIKey"]
        case "OPENROUTER_MODEL", "LOCI_OPENROUTER_MODEL", "ATLAS_OPENROUTER_MODEL":
            return ["LociOpenRouterModel", "AtlasOpenRouterModel"]
        case "LOCI_LLM_MODEL", "ATLAS_LLM_MODEL":
            return ["LociLLMCompileModel", "AtlasLLMCompileModel"]
        default:
            if envKey.hasPrefix("LOCI_") {
                return ["LociEnv.\(envKey)", "AtlasEnv.ATLAS_\(String(envKey.dropFirst("LOCI_".count)))"]
            }
            if envKey.hasPrefix("ATLAS_") {
                return ["AtlasEnv.\(envKey)"]
            }
            return ["LociEnv.\(envKey)"]
        }
    }
}
