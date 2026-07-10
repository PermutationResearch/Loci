import Foundation
import PDFKit

/// Renders Office documents as PDF for in-app preview. QuickLook mangles complex DOCX layout;
/// LibreOffice conversion preserves pagination, TOC leaders, and fonts far better.
enum DocumentPreviewConverter {
    private static let officeExtensions: Set<String> = [
        "doc", "docx", "dot", "dotx",
        "ppt", "pptx", "pps", "ppsx",
        "xls", "xlsx", "xlsm",
        "odt", "ods", "odp", "odg",
        "rtf", "pages", "numbers", "key"
    ]

    private static let libreOfficeCandidates = [
        ProcessInfo.processInfo.environment["DOCLING_LIBREOFFICE_CMD"],
        LociEnvironment.value(for: ["LOCI_LIBREOFFICE"]),
        "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        "/Applications/LibreOffice.app/Contents/MacOS/libreoffice",
        "/usr/local/bin/soffice",
        "/opt/homebrew/bin/soffice"
    ]

    static func isOfficeDocument(_ url: URL) -> Bool {
        officeExtensions.contains(url.pathExtension.lowercased())
    }

    static func isOfficeDocument(extension ext: String) -> Bool {
        officeExtensions.contains(ext.lowercased())
    }

    static func cachedPreviewURL(for item: ReferenceItem, sourceURL: URL) -> URL {
        let slug = MarkdownVault.slug(for: item)
        return MarkdownVault.defaultVaultURL()
            .appendingPathComponent("raw/\(slug)/preview.pdf", isDirectory: false)
    }

    static func pdfPreviewURL(for item: ReferenceItem, sourceURL: URL) async -> URL? {
        guard isOfficeDocument(sourceURL),
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            return nil
        }

        let previewURL = cachedPreviewURL(for: item, sourceURL: sourceURL)
        if isPreviewFresh(sourceURL: sourceURL, previewURL: previewURL),
           PDFDocument(url: previewURL)?.pageCount ?? 0 > 0 {
            return previewURL
        }

        guard let libreOffice = locateLibreOffice() else { return nil }

        let outputDirectory = previewURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let converted = await convertToPDF(sourceURL: sourceURL, outputDirectory: outputDirectory, libreOffice: libreOffice)
        guard let converted else { return nil }

        if converted.path != previewURL.path {
            try? FileManager.default.removeItem(at: previewURL)
            try? FileManager.default.moveItem(at: converted, to: previewURL)
        }

        guard PDFDocument(url: previewURL)?.pageCount ?? 0 > 0 else {
            try? FileManager.default.removeItem(at: previewURL)
            return nil
        }

        return previewURL
    }

    private static func isPreviewFresh(sourceURL: URL, previewURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: previewURL.path),
              let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let previewAttributes = try? FileManager.default.attributesOfItem(atPath: previewURL.path),
              let sourceModified = sourceAttributes[.modificationDate] as? Date,
              let previewModified = previewAttributes[.modificationDate] as? Date else {
            return false
        }
        return previewModified >= sourceModified
    }

    private static func locateLibreOffice() -> String? {
        for candidate in libreOfficeCandidates {
            guard let path = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty,
                  FileManager.default.isExecutableFile(atPath: path) else {
                continue
            }
            return path
        }
        return nil
    }

    private static func convertToPDF(
        sourceURL: URL,
        outputDirectory: URL,
        libreOffice: String
    ) async -> URL? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: libreOffice)
            process.arguments = [
                "--headless",
                "--nologo",
                "--nofirststartwizard",
                "--convert-to", "pdf",
                "--outdir", outputDirectory.path,
                sourceURL.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let expectedName = sourceURL.deletingPathExtension().lastPathComponent + ".pdf"
            let expectedURL = outputDirectory.appendingPathComponent(expectedName)
            if FileManager.default.fileExists(atPath: expectedURL.path) {
                return expectedURL
            }

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: outputDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }

            return files
                .filter { $0.pathExtension.lowercased() == "pdf" }
                .max { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsDate < rhsDate
                }
        }.value
    }
}
