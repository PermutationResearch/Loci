import AppKit
import Foundation

enum VaultExporter {
    static func exportVault(to destination: URL) async throws {
        let rootURL = MarkdownVault.defaultVaultURL()
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            throw VaultExportError.vaultNotFound
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let folders = ["raw", "wiki", "system", "outputs", "Assets"]
        for folder in folders {
            let source = rootURL.appendingPathComponent(folder, isDirectory: true)
            let target = destination.appendingPathComponent(folder, isDirectory: true)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
            }
        }

        let files = ["README.md", "index.md", "log.md", "loci.env"]
        for file in files {
            let source = rootURL.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(file))
            }
        }

        let dbSource = rootURL.appendingPathComponent("Loci.sqlite")
        if FileManager.default.fileExists(atPath: dbSource.path) {
            try? FileManager.default.copyItem(at: dbSource, to: destination.appendingPathComponent("Loci.sqlite"))
        }

        let exportManifest = """
        {
            "exported_at": "\(ISO8601DateFormatter().string(from: Date()))",
            "app": "\(AppBrand.name)",
            "version": "1.0"
        }
        """
        try exportManifest.write(to: destination.appendingPathComponent("export.json"), atomically: true, encoding: .utf8)
    }

    @MainActor
    static func showExportPanel() {
        let panel = NSSavePanel()
        panel.title = "Export Vault"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(AppBrand.name)-Vault-\(Self.dateStamp())"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await exportVault(to: url)
                } catch {
                    print("Vault export failed: \(error)")
                }
            }
        }
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

enum VaultExportError: LocalizedError {
    case vaultNotFound

    var errorDescription: String? {
        switch self {
        case .vaultNotFound: "Vault directory not found. Import some documents first."
        }
    }
}
