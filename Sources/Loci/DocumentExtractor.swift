import Foundation

enum DocumentExtractor {
    private static let trivialExtensions: Set<String> = [
        "txt", "md", "markdown", "html", "htm", "json", "csv", "rtf", "xml"
    ]

    private static let extractableExtensions: Set<String> = [
        "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "pages", "key", "numbers",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg"
    ]

    static func shouldExtract(fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        if trivialExtensions.contains(ext) {
            return false
        }
        return extractableExtensions.contains(ext)
    }

    @discardableResult
    static func run(inputURL: URL, outputDirectory: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            return false
        }

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        if let invocation = locateInvocation() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: invocation.python)
            process.arguments = [invocation.script.path, "--input", inputURL.path, "--output-dir", outputDirectory.path]
            process.environment = ProcessInfo.processInfo.environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let pythonResult = await Task.detached {
                do {
                    try process.run()
                } catch {
                    return false
                }
                process.waitUntilExit()
                return process.terminationStatus == 0 || hasExtractOutput(outputDirectory)
            }.value

            if pythonResult { return true }
        }

        let ext = inputURL.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"].contains(ext) {
            if let text = await VisionOCR.extractText(from: inputURL),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? (text + "\n").write(to: outputDirectory.appendingPathComponent("extracted.md"), atomically: true, encoding: .utf8)
                try? (text + "\n").write(to: outputDirectory.appendingPathComponent("extracted.txt"), atomically: true, encoding: .utf8)
                let meta: [String: Any] = [
                    "extractor": "apple-vision",
                    "ocr_used": true,
                    "status": "ok",
                    "word_count": text.split { $0.isWhitespace }.count
                ]
                if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
                    try? data.write(to: outputDirectory.appendingPathComponent("extract-meta.json"))
                }
                return true
            }
        }

        if ext == "pdf" {
            if let text = await VisionOCR.extractText(fromPDF: inputURL),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? (text + "\n").write(to: outputDirectory.appendingPathComponent("extracted.md"), atomically: true, encoding: .utf8)
                try? (text + "\n").write(to: outputDirectory.appendingPathComponent("extracted.txt"), atomically: true, encoding: .utf8)
                let meta: [String: Any] = [
                    "extractor": "apple-vision",
                    "ocr_used": true,
                    "status": "ok",
                    "word_count": text.split { $0.isWhitespace }.count
                ]
                if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
                    try? data.write(to: outputDirectory.appendingPathComponent("extract-meta.json"))
                }
                return true
            }
        }

        return hasExtractOutput(outputDirectory)
    }

    private struct Invocation {
        var python: String
        var script: URL
    }

    private static func locateInvocation() -> Invocation? {
        guard let python = locatePython() else { return nil }
        guard let script = locateScript() else { return nil }
        return Invocation(python: python, script: script)
    }

    private static func locatePython() -> String? {
        let candidates = [
            LociEnvironment.value(for: ["LOCI_PYTHON"]),
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for candidate in candidates {
            guard let path = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty,
                  FileManager.default.isExecutableFile(atPath: path) else {
                continue
            }
            return path
        }
        return nil
    }

    private static func locateScript() -> URL? {
        if let path = LociEnvironment.value(for: ["LOCI_EXTRACT_SCRIPT"]),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let bundled = Bundle.main.url(forResource: "loci-extract", withExtension: "py", subdirectory: "scripts") {
            return bundled
        }

        if let bundled = Bundle.module.url(forResource: "loci-extract", withExtension: "py", subdirectory: "scripts") {
            return bundled
        }

        var directory = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<10 {
            guard let dir = directory else { break }
            let candidate = dir.appendingPathComponent("scripts/loci-extract.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = dir.deletingLastPathComponent()
        }

        return nil
    }

    private static func hasExtractOutput(_ directory: URL) -> Bool {
        fileHasContent(directory.appendingPathComponent("extracted.md"))
            || fileHasContent(directory.appendingPathComponent("extracted.txt"))
    }

    private static func fileHasContent(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
