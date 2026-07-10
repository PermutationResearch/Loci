import AppKit
import Foundation
import PDFKit

struct WikiCompilerResult: Hashable {
    var title: String
    var summary: String
    var imageCount: Int
    var contradictionCount: Int
}

enum WikiCompiler {
    static func extract(item: ReferenceItem, source: ImportSourceKind, payload: String) async -> WikiCompilerResult {
        MarkdownVault.writeRawSourcePackage(for: item, source: source, payload: payload)
        let rootURL = MarkdownVault.defaultVaultURL()
        let slug = MarkdownVault.slug(for: item)
        let rawURL = rootURL.appendingPathComponent("raw/\(slug)", isDirectory: true)
        createDirectoryIfNeeded(rawURL)

        let sourceText = await sourceText(for: item, source: source, payload: payload, rawURL: rawURL)
        if readExtractedText(from: rawURL) == nil {
            write(sourceText, to: rawURL.appendingPathComponent("extracted.txt"))
        }
        let imageCount = await downloadImages(from: imageURLs(from: payload), into: rawURL.appendingPathComponent("images", isDirectory: true))

        let summary = summarize(sourceText, fallback: item.subtitle)
        let contradictions = contradictionSignals(in: sourceText)
        writeExtractReport(item: item, summary: summary, imageCount: imageCount, contradictions: contradictions, rawURL: rawURL)

        return WikiCompilerResult(
            title: item.title,
            summary: summary,
            imageCount: imageCount,
            contradictionCount: contradictions.count
        )
    }

    static func compile(item: ReferenceItem, source: ImportSourceKind, payload: String) async -> WikiCompilerResult {
        let rootURL = MarkdownVault.defaultVaultURL()
        let slug = MarkdownVault.slug(for: item)
        let rawURL = rootURL.appendingPathComponent("raw/\(slug)", isDirectory: true)
        let sourceText = readExtractedText(from: rawURL) ?? payload
        let summary = summarize(sourceText, fallback: item.subtitle)
        let concepts = conceptCandidates(from: sourceText, item: item)
        let contradictions = contradictionSignals(in: sourceText)
        let tags = [item.kind.rawValue, item.group.rawValue.lowercased(), "compiled"]

        writeCompiledReference(
            item: item,
            sourceText: sourceText,
            summary: summary,
            concepts: concepts,
            contradictions: contradictions,
            tags: tags,
            rootURL: rootURL
        )
        writeConceptPages(concepts: concepts, item: item, rootURL: rootURL)
        writeContradictions(contradictions, item: item, rootURL: rootURL)
        updateEvolvingThesis(item: item, summary: summary, concepts: concepts, contradictions: contradictions, rootURL: rootURL)
        updateSearchIndex(rootURL: rootURL)

        if let llmResult = await LLMWikiCompiler.compile(
            item: item,
            sourceText: sourceText,
            heuristicSummary: summary,
            heuristicConcepts: concepts,
            heuristicContradictions: contradictions,
            rootURL: rootURL,
            rawURL: rawURL
        ) {
            updateSearchIndex(rootURL: rootURL)
            return WikiCompilerResult(
                title: item.title,
                summary: llmResult.summary,
                imageCount: files(in: rawURL.appendingPathComponent("images", isDirectory: true)).count,
                contradictionCount: llmResult.contradictionCount
            )
        }

        return WikiCompilerResult(
            title: item.title,
            summary: summary,
            imageCount: files(in: rawURL.appendingPathComponent("images", isDirectory: true)).count,
            contradictionCount: contradictions.count
        )
    }

    static func search(query: String, limit: Int = 12) -> [String] {
        let rootURL = MarkdownVault.defaultVaultURL()
        let indexURL = rootURL.appendingPathComponent("system/search-index.tsv")
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }

        if let indexContent = try? String(contentsOf: indexURL, encoding: .utf8) {
            let rows = indexContent.components(separatedBy: .newlines).filter { !$0.isEmpty }
            return rows.compactMap { row -> (score: Int, line: String)? in
                let lower = row.lowercased()
                let score = terms.reduce(0) { total, term in total + lower.components(separatedBy: term).count - 1 }
                guard score > 0 else { return nil }
                return (score, row)
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.line)
        }

        let files = markdownFiles(in: rootURL.appendingPathComponent("wiki", isDirectory: true))
            + markdownFiles(in: rootURL.appendingPathComponent("outputs", isDirectory: true))

        return files.compactMap { url -> (score: Int, line: String)? in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lower = content.lowercased()
            let score = terms.reduce(0) { total, term in total + lower.components(separatedBy: term).count - 1 }
            guard score > 0 else { return nil }
            let title = content.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent
            return (score, "\(score)\t\(title)\t\(url.path)")
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map(\.line)
    }

    private static func sourceText(for item: ReferenceItem, source: ImportSourceKind, payload: String, rawURL: URL) async -> String {
        if source == .browserExtension,
           let browserPayload = browserPayload(from: payload) {
            let article = browserPayload.articleMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines)
            let transcript = browserPayload.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let selected = browserPayload.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let htmlText = browserPayload.pageHTML.map(cleanHTMLText)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let article, !article.isEmpty {
                write(article, to: rawURL.appendingPathComponent("article.md"))
            }
            if let transcript, !transcript.isEmpty {
                write(transcript, to: rawURL.appendingPathComponent("transcript.txt"))
            }
            return [article, transcript, browserPayload.note, selected, htmlText, browserPayload.url]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n---\n\n")
        }

        if source == .file {
            let url = URL(fileURLWithPath: payload)

            if let extracted = readExtractedText(from: rawURL) {
                return extracted
            }

            if DocumentExtractor.shouldExtract(fileURL: url) {
                await DocumentExtractor.run(inputURL: url, outputDirectory: rawURL)
                if let extracted = readExtractedText(from: rawURL) {
                    return extracted
                }
            }

            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
            if imageExts.contains(url.pathExtension.lowercased()) {
                if let text = await VisionOCR.extractText(from: url) {
                    write(text, to: rawURL.appendingPathComponent("extracted.txt"))
                    return text
                }
            }

            if url.pathExtension.lowercased() == "pdf" {
                if let embedded = pdfText(from: url), !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return embedded
                }
                if let text = await VisionOCR.extractText(fromPDF: url) {
                    write(text, to: rawURL.appendingPathComponent("extracted.txt"))
                    return text
                }
                return item.subtitle
            }
            if ["txt", "md", "html", "htm", "json", "csv"].contains(url.pathExtension.lowercased()),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }

        return [item.title, item.subtitle, payload]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private static func writeCompiledReference(
        item: ReferenceItem,
        sourceText: String,
        summary: String,
        concepts: [String],
        contradictions: [String],
        tags: [String],
        rootURL: URL
    ) {
        let slug = MarkdownVault.slug(for: item)
        let conceptLinks = concepts.map { "- [[\(slugify($0))]]" }.joined(separator: "\n")
        let contradictionLinks = contradictions.enumerated().map { index, _ in "- [[\(slug)-contradiction-\(index + 1)]]" }.joined(separator: "\n")
        let quotes = notableLines(from: sourceText).map { "> \($0)" }.joined(separator: "\n\n")
        let sourceWordCount = sourceText.split { $0.isWhitespace || $0.isNewline }.count
        let reviewStatus = sourceWordCount >= 120 ? "heuristic-needs-model-review" : "needs-better-extraction"
        let evidenceQuality = sourceWordCount >= 500 ? "strong" : sourceWordCount >= 120 ? "mixed" : "thin"
        let content = """
        ---
        id: "\(item.id.uuidString)"
        title: "\(escapeYAML(item.title))"
        type: reference
        status: \(reviewStatus)
        kind: "\(item.kind.rawValue)"
        group: "\(item.group.rawValue)"
        raw: "../../raw/\(slug)/"
        tags: [\(tags.map { "\"\($0)\"" }.joined(separator: ", "))]
        ---

        # \(item.title)

        ## Summary

        \(summary)

        ## Compile Quality

        - Status: \(reviewStatus)
        - Evidence quality: \(evidenceQuality)
        - Source words: \(sourceWordCount)
        - Review action: confirm, correct, or promote this page in Loci.

        ## Source

        - Raw package: [raw/\(slug)/](../../raw/\(slug)/)
        - Original: `\(item.fileName)`
        - Kind: \(item.kind.rawValue)
        - Group: \(item.group.rawValue)

        ## Concepts

        \(conceptLinks.isEmpty ? "- [[\(slugify(item.group.rawValue))]]" : conceptLinks)

        ## Synthesis

        \(synthesize(sourceText, concepts: concepts))

        ## Useful Next Links

        - Review related concepts under `wiki/concepts/`.
        - Promote this page when it is reusable for an output or decision.
        - Return to the raw package before editing contested claims.

        ## Contradictions And Tensions

        \(contradictionLinks.isEmpty ? "- No explicit contradictions detected by the local compiler." : contradictionLinks)

        ## Notable Evidence

        \(quotes.isEmpty ? "- Needs more extracted text." : quotes)

        ## Backlinks

        Backlinks are maintained through wiki links and `system/graph.md`.
        """
        write(content, to: rootURL.appendingPathComponent("wiki/references/\(slug).md"))
        write(content, to: rootURL.appendingPathComponent("References/\(slug).md"))
    }

    private static func writeConceptPages(concepts: [String], item: ReferenceItem, rootURL: URL) {
        for concept in concepts {
            let slug = slugify(concept)
            let url = rootURL.appendingPathComponent("wiki/concepts/\(slug).md")
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? conceptSeed(title: concept, slug: slug)
            let link = "- [[\(MarkdownVault.slug(for: item))]]"
            let next = existing.contains(link) ? existing : existing + "\n\(link)\n"
            write(next, to: url)
        }
    }

    private static func writeContradictions(_ contradictions: [String], item: ReferenceItem, rootURL: URL) {
        let refSlug = MarkdownVault.slug(for: item)
        for (index, contradiction) in contradictions.enumerated() {
            let slug = "\(refSlug)-contradiction-\(index + 1)"
            let content = """
            ---
            title: "\(escapeYAML(item.title)) contradiction \(index + 1)"
            type: contradiction
            status: needs-review
            source: "[[\(refSlug)]]"
            ---

            # \(item.title) Tension \(index + 1)

            \(contradiction)

            ## Source

            - [[\(refSlug)]]
            """
            write(content, to: rootURL.appendingPathComponent("wiki/contradictions/\(slug).md"))
        }
    }

    private static func updateEvolvingThesis(item: ReferenceItem, summary: String, concepts: [String], contradictions: [String], rootURL: URL) {
        let url = rootURL.appendingPathComponent("wiki/summaries/evolving-thesis.md")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Evolving Thesis\n\n"
        let entry = """

        ## \(item.title)

        \(summary)

        - Concepts: \(concepts.prefix(8).joined(separator: ", "))
        - Contradictions or tensions: \(contradictions.count)
        - Source: [[\(MarkdownVault.slug(for: item))]]
        """
        write(existing.contains("[[\(MarkdownVault.slug(for: item))]]") ? existing : existing + entry, to: url)
    }

    private static func updateSearchIndex(rootURL: URL) {
        let rows = markdownFiles(in: rootURL.appendingPathComponent("wiki", isDirectory: true)).compactMap { url -> String? in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let title = content.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent
            let words = Set(content.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
                .filter { $0.count > 3 }
                .sorted()
                .prefix(80)
                .joined(separator: " ")
            return "\(title)\t\(url.path)\t\(words)"
        }
        write(rows.joined(separator: "\n") + "\n", to: rootURL.appendingPathComponent("system/search-index.tsv"))
    }

    private static func readExtractedText(from rawURL: URL) -> String? {
        let markdownURL = rawURL.appendingPathComponent("extracted.md")
        if let markdown = try? String(contentsOf: markdownURL, encoding: .utf8),
           !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return markdown
        }

        let textURL = rawURL.appendingPathComponent("extracted.txt")
        if let text = try? String(contentsOf: textURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        return nil
    }

    private static func writeExtractReport(item: ReferenceItem, summary: String, imageCount: Int, contradictions: [String], rawURL: URL) {
        let metaURL = rawURL.appendingPathComponent("extract-meta.json")
        let metaSummary: String
        if let data = try? Data(contentsOf: metaURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let extractor = object["extractor"] as? String ?? "unknown"
            let status = object["status"] as? String ?? "unknown"
            let wordCount = object["word_count"] as? Int ?? 0
            let ocrUsed = (object["ocr_used"] as? Bool) == true
            metaSummary = "Extractor: \(extractor), status: \(status), words: \(wordCount), OCR: \(ocrUsed ? "yes" : "no")"
        } else {
            metaSummary = "Extractor: local fallback"
        }

        let content = """
        # Extract Report

        - Reference: \(item.title)
        - Summary: \(summary)
        - \(metaSummary)
        - Images downloaded: \(imageCount)
        - Tensions detected: \(contradictions.count)
        """
        write(content, to: rawURL.appendingPathComponent("extract-report.md"))
    }

    private static func summarize(_ text: String, fallback: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = cleaned.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 28 }
        let summary = sentences.prefix(3).joined(separator: ". ")
        if !summary.isEmpty {
            return summary + "."
        }
        return fallback.isEmpty ? "Needs synthesis after richer extraction." : fallback
    }

    private static func synthesize(_ text: String, concepts: [String]) -> String {
        let conceptText = concepts.prefix(6).joined(separator: ", ")
        let length = text.split { $0.isWhitespace || $0.isNewline }.count
        return "Local compile pass found \(length) source words and organized the source around \(conceptText.isEmpty ? "its source type and reference group" : conceptText). A model-backed compile pass should deepen this into comparisons, examples, and claims."
    }

    private static func conceptCandidates(from text: String, item: ReferenceItem) -> [String] {
        var concepts = [item.group.rawValue, item.kind.rawValue.capitalized]
        let matches = text.matches(of: /(?:[A-Z][A-Za-z0-9&-]+(?:\s+[A-Z][A-Za-z0-9&-]+){0,3})/)
            .map { String($0.output).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 3 && !$0.hasPrefix("HTTP") }
        concepts.append(contentsOf: matches)
        return Array(NSOrderedSet(array: concepts).compactMap { $0 as? String }).prefix(16).map { $0 }
    }

    private static func contradictionSignals(in text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let markers = ["but", "however", "contradict", "conflict", "despite", "although", "tension", "versus", "vs."]
        return lines.filter { line in
            let lower = line.lowercased()
            return markers.contains { lower.contains($0) }
        }
        .prefix(8)
        .map { $0 }
    }

    private static func notableLines(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 50 && $0.count < 260 }
            .prefix(5)
            .map { $0 }
    }

    private static func browserPayload(from payload: String) -> BrowserExtensionReferencePayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BrowserExtensionReferencePayload.self, from: data)
    }

    private static func imageURLs(from payload: String) -> [URL] {
        guard let browserPayload = browserPayload(from: payload) else { return [] }
        let urls = (browserPayload.imageURLs ?? []) + [browserPayload.ogImageURL, browserPayload.faviconURL].compactMap { $0 }
        return urls.compactMap(URL.init(string:))
    }

    private static func downloadImages(from urls: [URL], into directory: URL) async -> Int {
        guard !urls.isEmpty else { return 0 }
        createDirectoryIfNeeded(directory)
        let maxImageBytes: Int64 = 10 * 1_024 * 1_024
        var count = 0
        for url in urls.prefix(12) {
            var headRequest = URLRequest(url: url)
            headRequest.httpMethod = "HEAD"
            headRequest.timeoutInterval = 8
            if let (_, headResponse) = try? await URLSession.shared.data(for: headRequest),
               let httpResponse = headResponse as? HTTPURLResponse,
               let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let bytes = Int64(contentLength), bytes > maxImageBytes {
                continue
            }
            guard let (data, response) = try? await URLSession.shared.data(from: url), !data.isEmpty else { continue }
            let ext = preferredImageExtension(url: url, mimeType: response.mimeType)
            let name = "\(slugify(url.deletingPathExtension().lastPathComponent.isEmpty ? url.host() ?? "image" : url.deletingPathExtension().lastPathComponent)).\(ext)"
            write(data, to: uniqueURL(directory.appendingPathComponent(name)))
            count += 1
        }
        return count
    }

    private static func preferredImageExtension(url: URL, mimeType: String?) -> String {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(ext) { return ext }
        switch mimeType {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        default: return "jpg"
        }
    }

    private static func pdfText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        return (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanHTMLText(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<(script|style)[\s\S]*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func markdownFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension.lowercased() == "md" else { return nil }
            return url
        }
    }

    private static func files(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
    }

    private static func conceptSeed(title: String, slug: String) -> String {
        """
        ---
        title: "\(escapeYAML(title))"
        type: concept
        status: compiled
        ---

        # \(title)

        ## References
        """
    }

    private static func slugify(_ value: String) -> String {
        let slug = value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "untitled" : slug
    }

    private static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6).lowercased()).\(ext)")
    }

    private static func createDirectoryIfNeeded(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func write(_ content: String, to url: URL) {
        createDirectoryIfNeeded(url.deletingLastPathComponent())
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func write(_ data: Data, to url: URL) {
        createDirectoryIfNeeded(url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
    }

    private static func escapeYAML(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
