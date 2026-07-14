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
    static func extract(
        item: ReferenceItem,
        source: ImportSourceKind,
        payload: String,
        rootURL rootOverride: URL? = nil
    ) async -> WikiCompilerResult {
        let rootURL = rootOverride ?? MarkdownVault.defaultVaultURL()
        MarkdownVault.writeRawSourcePackage(
            for: item,
            source: source,
            payload: payload,
            rootURL: rootURL
        )
        let slug = MarkdownVault.slug(for: item)
        let rawURL = rootURL.appendingPathComponent("raw/\(slug)", isDirectory: true)
        createDirectoryIfNeeded(rawURL)
        if source == .url || source == .browserExtension {
            clearDerivedWebsiteArtifacts(in: rawURL, includesBrowserCapture: source == .browserExtension)
        }

        let sourceText = await sourceText(for: item, source: source, payload: payload, rawURL: rawURL)
        if source == .url || source == .browserExtension {
            // Website extraction chooses a deliberate, ordered source. Persist that exact input
            // so the later compile job cannot fall back to placeholder text or raw page HTML.
            write(sourceText, to: rawURL.appendingPathComponent("extracted.md"))
        } else if readExtractedText(from: rawURL) == nil {
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
            let rawArticle = browserPayload.articleMarkdown
            let article = rawArticle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTranscript = browserPayload.transcriptText
            let transcript = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
            let selected = browserPayload.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = browserPayload.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let htmlText = browserPayload.pageHTML.map(cleanHTMLText)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let capturedHTML = browserPayload.pageHTML,
               !capturedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Preserve the browser's evidence even when its article Markdown is already
                // strong enough that Loci does not need to render the capture a second time.
                write(capturedHTML, to: rawURL.appendingPathComponent("captured-page.html"))
            }
            let articleIsSubstantial = article.map(isSubstantialWebsiteText) == true
            let fetchedMarkdown: String?
            if !articleIsSubstantial,
               let urlString = browserPayload.url,
               let url = URL(string: urlString) {
                fetchedMarkdown = await websiteMarkdown(
                    for: url,
                    capturedHTML: browserPayload.pageHTML,
                    rawURL: rawURL
                )
            } else {
                fetchedMarkdown = nil
            }
            if let rawArticle, article?.isEmpty == false {
                write(rawArticle, to: rawURL.appendingPathComponent("article.md"))
            }
            if let rawTranscript, transcript?.isEmpty == false {
                write(rawTranscript, to: rawURL.appendingPathComponent("transcript.txt"))
            }
            let htmlFallback = (articleIsSubstantial || fetchedMarkdown != nil) ? nil : htmlText
            let shortArticle = articleIsSubstantial ? nil : article
            return [articleIsSubstantial ? article : fetchedMarkdown, shortArticle, transcript, note, selected, htmlFallback, browserPayload.url]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n---\n\n")
        }

        if source == .url,
           let url = URL(string: payload),
           let markdown = await websiteMarkdown(for: url, capturedHTML: nil, rawURL: rawURL) {
            return markdown
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

    private static func websiteMarkdown(for url: URL, capturedHTML: String?, rawURL: URL) async -> String? {
        let localExtraction: LocalWebsiteExtraction?
        if let capturedHTML = capturedHTML?.trimmingCharacters(in: .whitespacesAndNewlines),
           !capturedHTML.isEmpty {
            localExtraction = await LocalWebsiteExtractor.extract(html: capturedHTML, baseURL: url)
        } else {
            localExtraction = await LocalWebsiteExtractor.extract(url: url)
        }

        if let localExtraction {
            write(localExtraction.markdown, to: rawURL.appendingPathComponent("local-extracted.md"))
            if let metadata = try? JSONEncoder().encode(localExtraction.metadata) {
                write(metadata, to: rawURL.appendingPathComponent("local-extraction-meta.json"))
            }
            if localExtraction.isUsable {
                write(localExtraction.markdown, to: rawURL.appendingPathComponent("extracted.md"))
                return localExtraction.markdown
            }
        } else {
            let diagnostic = """
            Local rendered website extraction failed at \(ISO8601DateFormatter().string(from: Date())).
            Loci will try the configured remote fallback and then its basic source fallback.
            """
            write(diagnostic, to: rawURL.appendingPathComponent("local-extraction-error.txt"))
        }

        if let remoteMarkdown = await curlMarkdown(for: url, rawURL: rawURL) {
            return remoteMarkdown
        }

        if let localExtraction, localExtraction.wordCount >= 15 {
            write(localExtraction.markdown, to: rawURL.appendingPathComponent("extracted.md"))
            return localExtraction.markdown
        }
        return nil
    }

    private static func isSubstantialWebsiteText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split { $0.isWhitespace || $0.isNewline }.count
        return trimmed.count >= 280 && wordCount >= 50
    }

    private static func clearDerivedWebsiteArtifacts(in rawURL: URL, includesBrowserCapture: Bool) {
        var names = [
            "extracted.md",
            "extracted.txt",
            "extract-meta.json",
            "local-extracted.md",
            "local-extraction-meta.json",
            "local-extraction-error.txt",
            "curlmd-meta.json",
            "curlmd-error.txt",
            "images"
        ]
        if includesBrowserCapture {
            names += ["captured-page.html", "article.md", "transcript.txt"]
        }
        for name in names {
            try? FileManager.default.removeItem(at: rawURL.appendingPathComponent(name))
        }
    }

    private static func curlMarkdown(for url: URL, rawURL: URL) async -> String? {
        guard CurlMarkdownClient.isEnabled,
              !CurlMarkdownClient.isPrivateTarget(url) else {
            return nil
        }
        do {
            let result = try await CurlMarkdownClient.fetchMarkdown(for: url)
            write(result.markdown, to: rawURL.appendingPathComponent("extracted.md"))
            if let metadata = try? JSONEncoder().encode(result.metadata) {
                write(metadata, to: rawURL.appendingPathComponent("curlmd-meta.json"))
            }
            return result.markdown
        } catch {
            let diagnosticDetail: String
            if let curlError = error as? CurlMarkdownError {
                switch curlError {
                case .http(let status, _):
                    // Do not persist a server-controlled response message; a custom endpoint
                    // could echo request headers or other sensitive material in its error body.
                    diagnosticDetail = "HTTP \(status)"
                default:
                    diagnosticDetail = curlError.localizedDescription
                }
            } else {
                diagnosticDetail = error.localizedDescription
            }
            let diagnostic = """
            curl.md extraction failed at \(ISO8601DateFormatter().string(from: Date())).
            Loci continued with its best available local source.
            Error: \(diagnosticDetail)
            """
            write(diagnostic, to: rawURL.appendingPathComponent("curlmd-error.txt"))
            return nil
        }
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
        let localMetadata = try? decode(
            LocalWebsiteExtractionMetadata.self,
            from: rawURL.appendingPathComponent("local-extraction-meta.json")
        )
        let curlMetadata = try? decode(
            CurlMarkdownClient.Metadata.self,
            from: rawURL.appendingPathComponent("curlmd-meta.json")
        )
        let metaSummary: String
        if let curlMetadata {
            let cache = curlMetadata.cache.map { ", cache: \($0)" } ?? ""
            let tokens = curlMetadata.tokenCount.map { ", tokens: \($0)" } ?? ""
            metaSummary = "Extractor: curl.md, fetched: \(curlMetadata.fetchedAt)\(cache)\(tokens)"
        } else if let localMetadata {
            metaSummary = "Extractor: loci-webkit, quality: \(format(localMetadata.qualityScore)), selected: \(localMetadata.selectedElement), words: \(localMetadata.wordCount)"
        } else if FileManager.default.fileExists(atPath: rawURL.appendingPathComponent("article.md").path) {
            metaSummary = "Extractor: browser article Markdown"
        } else if let data = try? Data(contentsOf: rawURL.appendingPathComponent("extract-meta.json")),
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

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
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
        let baseURL = browserPayload.url.flatMap { URL(string: $0) }
        var seen = Set<String>()
        return urls.compactMap { value in
            URL(string: value, relativeTo: baseURL)?.absoluteURL
        }
        .filter { seen.insert($0.absoluteString).inserted }
    }

    private static func downloadImages(from urls: [URL], into directory: URL) async -> Int {
        guard !urls.isEmpty else { return 0 }
        createDirectoryIfNeeded(directory)
        let maxImageBytes: Int64 = 10 * 1_024 * 1_024
        let candidates = Array(urls.prefix(12))
        var downloadCount = 0
        for batchStart in stride(from: 0, to: candidates.count, by: 4) {
            let batchEnd = min(batchStart + 4, candidates.count)
            let batch = candidates[batchStart..<batchEnd].enumerated()
            let batchDownloads = await withTaskGroup(of: WebsiteImageDownload?.self) { group in
                for (batchOffset, url) in batch {
                    let sourceIndex = batchStart + batchOffset
                    group.addTask {
                        await downloadImage(from: url, sourceIndex: sourceIndex, maxImageBytes: maxImageBytes)
                    }
                }
                var values: [WebsiteImageDownload] = []
                for await value in group {
                    if let value { values.append(value) }
                }
                return values
            }
            for download in batchDownloads.sorted(by: { $0.sourceIndex < $1.sourceIndex }) {
                let ext = preferredImageExtension(url: download.url, mimeType: download.mimeType)
                let baseName = download.url.deletingPathExtension().lastPathComponent.isEmpty
                    ? download.url.host() ?? "image"
                    : download.url.deletingPathExtension().lastPathComponent
                let name = "\(slugify(baseName)).\(ext)"
                write(download.data, to: uniqueURL(directory.appendingPathComponent(name)))
                downloadCount += 1
            }
        }
        return downloadCount
    }

    private struct WebsiteImageDownload: Sendable {
        var sourceIndex: Int
        var url: URL
        var data: Data
        var mimeType: String?
    }

    private static func downloadImage(
        from url: URL,
        sourceIndex: Int,
        maxImageBytes: Int64
    ) async -> WebsiteImageDownload? {
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil,
                  url.user == nil,
                  url.password == nil else { return nil }
            var headRequest = URLRequest(url: url)
            headRequest.httpMethod = "HEAD"
            headRequest.timeoutInterval = 8
            if let (_, headResponse) = try? await URLSession.shared.download(for: headRequest),
               let httpResponse = headResponse as? HTTPURLResponse,
               let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let bytes = Int64(contentLength), bytes > maxImageBytes {
                return nil
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            guard let (downloadURL, response) = try? await URLSession.shared.download(for: request),
                  let fileSize = (try? downloadURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  fileSize > 0,
                  Int64(fileSize) <= maxImageBytes,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  response.mimeType?.lowercased().hasPrefix("image/") == true,
                  let data = try? Data(contentsOf: downloadURL, options: .mappedIfSafe) else { return nil }
            return WebsiteImageDownload(
                sourceIndex: sourceIndex,
                url: url,
                data: data,
                mimeType: response.mimeType
            )
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
            .replacingOccurrences(
                of: #"<(script|style)[\s\S]*?</\1>"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
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
