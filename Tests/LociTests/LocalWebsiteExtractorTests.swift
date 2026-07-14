import Foundation
import Testing
@testable import Loci

@Suite("Local website extraction")
struct LocalWebsiteExtractorTests {
    @Test("Removes page chrome and preserves semantic article content as Markdown")
    @MainActor
    func extractsArticleMarkdown() async throws {
        let html = """
        <!doctype html>
        <html>
          <head>
            <title>Building a Local &amp; Research Library</title>
            <meta http-equiv="refresh" content="0;url=https://example.com/redirected">
          </head>
          <body>
            <script>document.title = 'Captured script executed'; document.body.innerHTML = 'unsafe';</script>
            <header class="site-header"><nav><a href="/home">Home</a><a href="/pricing">Pricing</a></nav></header>
            <div id="cookie-consent" style="position: fixed">We use cookies. Accept all cookies</div>
            <main>
              <article class="article-content">
                <header><h1>Building a Local &amp; Research Library</h1><p>By Ada Example · July 11, 2026</p></header>
                <p>A useful research library preserves source material before producing summaries. That separation gives every later claim a stable piece of evidence that a reader can inspect and challenge.</p>
                <h2>Keep the capture deterministic</h2>
                <p>Navigation, advertisements, consent dialogs, and recommendation rails add tokens without adding evidence. Removing them before analysis gives language models a smaller and more faithful context.</p>
                <ul><li>Keep headings and paragraphs.</li><li>Preserve links and code examples.</li><li>Record extraction quality.</li></ul>
                <p><a href="/docs/a_(b)?mode=full">Read [guide]</a>, <a href="data:text/html,payload">keep blocked destinations as plain text</a>, preserve literal &lt;literal-markup&gt;, and use <code>value `with` ticks</code> when needed.</p>
                <pre><code class="language-swift">let fence = "```"</code></pre>
                <table><tr><th>Signal</th><th>Purpose</th></tr><tr><td>Text density</td><td>Find the article body</td></tr></table>
                <p>The original HTML should remain available beside the cleaned Markdown. If the deterministic result is weak, the system can use a remote fallback without making that service mandatory.</p>
                <section class="comments"><p>Comment noise that should not become source evidence.</p></section>
              </article>
            </main>
            <div style="display: none">CSS-hidden navigation noise</div>
            <aside class="related-posts"><a href="/one">Related story one</a><a href="/two">Related story two</a></aside>
            <footer>Copyright and newsletter signup</footer>
          </body>
        </html>
        """

        let baseURL = try #require(URL(string: "https://example.com/research/local-library"))
        let extraction = try #require(await LocalWebsiteExtractor.extract(html: html, baseURL: baseURL))

        #expect(extraction.isUsable)
        #expect(extraction.sourceURL == baseURL.absoluteString)
        #expect(extraction.selectedElement.contains("article"))
        #expect(extraction.title == "Building a Local & Research Library")
        #expect(extraction.markdown.contains("# Building a Local &amp; Research Library"))
        #expect(extraction.markdown.components(separatedBy: "# Building a Local &amp; Research Library").count == 2)
        #expect(extraction.markdown.contains("## Keep the capture deterministic"))
        #expect(extraction.markdown.contains("- Keep headings and paragraphs."))
        #expect(extraction.markdown.contains("````swift"))
        #expect(extraction.markdown.contains("[Read \\[guide\\]](<https://example.com/docs/a_(b)?mode=full>)"))
        #expect(!extraction.markdown.contains("data:text/html"))
        #expect(extraction.markdown.contains("&lt;literal-markup&gt;"))
        #expect(!extraction.markdown.contains("<literal-markup>"))
        #expect(extraction.markdown.contains("``value `with` ticks``"))
        #expect(extraction.markdown.contains("| Signal | Purpose |"))
        #expect(extraction.markdown.contains("By Ada Example"))
        #expect(!extraction.markdown.localizedCaseInsensitiveContains("Accept all cookies"))
        #expect(!extraction.markdown.localizedCaseInsensitiveContains("Pricing"))
        #expect(!extraction.markdown.localizedCaseInsensitiveContains("Related story"))
        #expect(!extraction.markdown.localizedCaseInsensitiveContains("unsafe"))
        #expect(!extraction.markdown.localizedCaseInsensitiveContains("Comment noise"))
        #expect(!extraction.markdown.localizedCaseInsensitiveContains("CSS-hidden"))
        #expect(extraction.removedElementCount >= 3)
    }

    @Test("Marks navigation-only pages as weak instead of treating links as evidence")
    @MainActor
    func rejectsNavigationOnlyPage() async throws {
        let html = """
        <html><head><title>Directory</title></head><body>
          <nav><a href="/a">Alpha</a><a href="/b">Beta</a><a href="/c">Gamma</a></nav>
          <main><p>Choose a destination.</p></main>
          <div class="cookie-banner">Accept all cookies</div>
        </body></html>
        """
        let baseURL = try #require(URL(string: "https://example.com/directory"))
        let extraction = try #require(await LocalWebsiteExtractor.extract(html: html, baseURL: baseURL))

        #expect(!extraction.isUsable)
        #expect(extraction.wordCount < 50)
        #expect(!extraction.markdown.localizedCaseInsensitiveContains("Accept all cookies"))
        #expect(!extraction.markdown.contains("Alpha"))
    }

    @Test("Truncates oversized Markdown at a valid block boundary and closes code fences")
    @MainActor
    func truncatesOversizedMarkdownSafely() async throws {
        let oversizedCode = String(repeating: "evidence line with enough text\n\n", count: 28_000)
        let html = """
        <html><head><title>Oversized Evidence</title></head><body><article>
          <h1>Oversized Evidence</h1>
          <p>This deliberately large fixture verifies that extraction remains bounded without leaving malformed Markdown for downstream readers and language models.</p>
          <pre><code class="language-text">\(oversizedCode)</code></pre>
        </article></body></html>
        """
        let baseURL = try #require(URL(string: "https://example.com/oversized"))
        let extraction = try #require(await LocalWebsiteExtractor.extract(html: html, baseURL: baseURL))

        #expect(extraction.markdown.contains("Loci local extraction truncated"))
        #expect(extraction.markdown.count < 751_000)
        let fenceLines = extraction.markdown.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("```") }
        #expect(fenceLines.count.isMultiple(of: 2))
    }

    @Test("Wiki extraction stores captured HTML, local Markdown, and quality metadata")
    @MainActor
    func writesAuditableRawPackage() async throws {
        let html = """
        <html><head><title>Auditable Extraction</title></head><body>
          <nav><a href="/home">Home navigation</a></nav>
          <article>
            <h1>Auditable Extraction</h1>
            <p>Local extraction should preserve a durable source while producing clean Markdown for downstream analysis. The raw capture makes every removal reversible and lets a reviewer inspect the evidence.</p>
            <p>Quality metadata records the selected element, word count, paragraph count, link density, and warnings. This keeps weak results from silently becoming authoritative model context.</p>
            <p>When local extraction is strong, no remote service is required. When it is weak, an explicitly enabled fallback can try another extractor without replacing the original evidence.</p>
          </article>
          <div class="cookie-consent">Accept all cookies</div>
        </body></html>
        """
        let sourceURL = "https://example.com/auditable"
        let payload = BrowserExtensionReferencePayload(
            url: sourceURL,
            title: "Auditable Extraction",
            note: nil,
            selectedText: nil,
            pageHTML: html,
            articleMarkdown: nil,
            transcriptText: nil,
            imageURLs: nil,
            autoTags: nil,
            source: "test",
            faviconURL: nil,
            ogImageURL: nil,
            alsoBookmarkOnX: nil
        )
        let payloadData = try JSONEncoder().encode(payload)
        let payloadString = try #require(String(data: payloadData, encoding: .utf8))
        let item = ReferenceItem(
            id: UUID(),
            title: "Auditable Extraction",
            subtitle: sourceURL,
            fileName: "auditable.webloc",
            kind: .website,
            group: .website,
            theme: .paper,
            aspectRatio: 1.48,
            collectionID: nil,
            isInbox: true,
            isTrashed: false,
            canvasPosition: .zero,
            infinityPosition: .zero
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loci-local-extraction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        _ = await WikiCompiler.extract(
            item: item,
            source: .browserExtension,
            payload: payloadString,
            rootURL: rootURL
        )

        let rawURL = rootURL.appendingPathComponent("raw/\(MarkdownVault.slug(for: item))", isDirectory: true)
        let capturedHTML = try String(contentsOf: rawURL.appendingPathComponent("captured-page.html"), encoding: .utf8)
        let extracted = try String(contentsOf: rawURL.appendingPathComponent("extracted.md"), encoding: .utf8)
        let report = try String(contentsOf: rawURL.appendingPathComponent("extract-report.md"), encoding: .utf8)
        let metadataData = try Data(contentsOf: rawURL.appendingPathComponent("local-extraction-meta.json"))
        let metadata = try JSONDecoder().decode(LocalWebsiteExtractionMetadata.self, from: metadataData)

        #expect(capturedHTML.contains("cookie-consent"))
        #expect(extracted.contains("# Auditable Extraction"))
        #expect(!extracted.localizedCaseInsensitiveContains("Accept all cookies"))
        #expect(metadata.qualityScore >= 0.42)
        #expect(metadata.wordCount >= 50)
        #expect(metadata.selectedElement.contains("article"))
        #expect(report.contains("Extractor: loci-webkit"))
        #expect(report.contains("selected: article"))
    }

    @Test("Browser article Markdown becomes the compiler source instead of captured page HTML")
    @MainActor
    func prefersBrowserArticleMarkdown() async throws {
        let article = """
        # Clean Browser Article

        Browser-provided article Markdown is already scoped to the content the user captured. It should be preferred over a second extraction pass when it contains enough evidence for compilation.

        The compiler must persist this exact Markdown as its selected source. Otherwise a later job could accidentally read placeholder text or raw HTML full of navigation and consent controls.

        Keeping the selected source explicit also makes the pipeline reproducible. Reviewers can compare the article, the captured HTML, and the compiled page without guessing which input reached the language model.
        """
        let capturedHTML = """
        <html><body><nav>Navigation pollution</nav><div class="cookie-banner">Accept all cookies</div><main>Raw fallback body</main></body></html>
        """
        let sourceURL = "https://example.com/browser-article"
        let payload = BrowserExtensionReferencePayload(
            url: sourceURL,
            title: "Clean Browser Article",
            note: nil,
            selectedText: nil,
            pageHTML: capturedHTML,
            articleMarkdown: article,
            transcriptText: nil,
            imageURLs: nil,
            autoTags: nil,
            source: "test",
            faviconURL: nil,
            ogImageURL: nil,
            alsoBookmarkOnX: nil
        )
        let payloadString = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        let item = ReferenceItem(
            id: UUID(),
            title: "Clean Browser Article",
            subtitle: sourceURL,
            fileName: "browser-article.webloc",
            kind: .website,
            group: .website,
            theme: .paper,
            aspectRatio: 1.48,
            collectionID: nil,
            isInbox: true,
            isTrashed: false,
            canvasPosition: .zero,
            infinityPosition: .zero
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loci-browser-article-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        _ = await WikiCompiler.extract(
            item: item,
            source: .browserExtension,
            payload: payloadString,
            rootURL: rootURL
        )

        let rawURL = rootURL.appendingPathComponent("raw/\(MarkdownVault.slug(for: item))", isDirectory: true)
        let selectedSource = try String(contentsOf: rawURL.appendingPathComponent("extracted.md"), encoding: .utf8)
        let savedArticle = try String(contentsOf: rawURL.appendingPathComponent("article.md"), encoding: .utf8)
        let savedCapture = try String(contentsOf: rawURL.appendingPathComponent("captured-page.html"), encoding: .utf8)
        let report = try String(contentsOf: rawURL.appendingPathComponent("extract-report.md"), encoding: .utf8)

        #expect(savedArticle == article)
        #expect(savedCapture == capturedHTML)
        #expect(selectedSource.contains("# Clean Browser Article"))
        #expect(selectedSource.contains("pipeline reproducible"))
        #expect(!selectedSource.localizedCaseInsensitiveContains("Navigation pollution"))
        #expect(!selectedSource.localizedCaseInsensitiveContains("Accept all cookies"))
        #expect(!FileManager.default.fileExists(atPath: rawURL.appendingPathComponent("local-extraction-meta.json").path))
        #expect(report.contains("Extractor: browser article Markdown"))
    }

    @Test("Re-extraction removes stale browser and remote-extractor artifacts")
    @MainActor
    func removesStaleWebsiteArtifacts() async throws {
        let sourceURL = "https://example.com/refreshed"
        let oldPayload = BrowserExtensionReferencePayload(
            url: sourceURL,
            title: "Old Article",
            note: nil,
            selectedText: nil,
            pageHTML: "<html><body><main>Old capture</main></body></html>",
            articleMarkdown: String(repeating: "Old substantial browser article evidence. ", count: 20),
            transcriptText: "Old transcript",
            imageURLs: nil,
            autoTags: nil,
            source: "test",
            faviconURL: nil,
            ogImageURL: nil,
            alsoBookmarkOnX: nil
        )
        let freshHTML = """
        <html><head><title>Fresh Local Result</title></head><body><article>
          <h1>Fresh Local Result</h1>
          <p>A fresh extraction must replace old browser artifacts and stale remote metadata. Keeping those sidecars would make the audit report describe a source that was no longer selected.</p>
          <p>The current page contains enough substantive evidence to pass the local quality threshold. Its selected element, clean Markdown, and report should all agree on the active extraction path.</p>
          <p>Derived files can be regenerated safely, while original source packages remain preserved for later inspection and reprocessing by the user.</p>
        </article></body></html>
        """
        let freshPayload = BrowserExtensionReferencePayload(
            url: sourceURL,
            title: "Fresh Local Result",
            note: nil,
            selectedText: nil,
            pageHTML: freshHTML,
            articleMarkdown: nil,
            transcriptText: nil,
            imageURLs: nil,
            autoTags: nil,
            source: "test",
            faviconURL: nil,
            ogImageURL: nil,
            alsoBookmarkOnX: nil
        )
        let item = ReferenceItem(
            id: UUID(),
            title: "Fresh Local Result",
            subtitle: sourceURL,
            fileName: "refreshed.webloc",
            kind: .website,
            group: .website,
            theme: .paper,
            aspectRatio: 1.48,
            collectionID: nil,
            isInbox: true,
            isTrashed: false,
            canvasPosition: .zero,
            infinityPosition: .zero
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loci-refreshed-extraction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let oldString = try #require(String(data: JSONEncoder().encode(oldPayload), encoding: .utf8))
        _ = await WikiCompiler.extract(item: item, source: .browserExtension, payload: oldString, rootURL: rootURL)
        let rawURL = rootURL.appendingPathComponent("raw/\(MarkdownVault.slug(for: item))", isDirectory: true)
        try Data("{}".utf8).write(to: rawURL.appendingPathComponent("curlmd-meta.json"))
        try Data("{}".utf8).write(to: rawURL.appendingPathComponent("extract-meta.json"))
        try Data("stale extracted text".utf8).write(to: rawURL.appendingPathComponent("extracted.txt"))
        let staleImagesURL = rawURL.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: staleImagesURL, withIntermediateDirectories: true)
        try Data("stale image".utf8).write(to: staleImagesURL.appendingPathComponent("stale.jpg"))

        let freshString = try #require(String(data: JSONEncoder().encode(freshPayload), encoding: .utf8))
        _ = await WikiCompiler.extract(item: item, source: .browserExtension, payload: freshString, rootURL: rootURL)

        let report = try String(contentsOf: rawURL.appendingPathComponent("extract-report.md"), encoding: .utf8)
        let extracted = try String(contentsOf: rawURL.appendingPathComponent("extracted.md"), encoding: .utf8)
        #expect(report.contains("Extractor: loci-webkit"))
        #expect(extracted.contains("Fresh Local Result"))
        #expect(!FileManager.default.fileExists(atPath: rawURL.appendingPathComponent("article.md").path))
        #expect(!FileManager.default.fileExists(atPath: rawURL.appendingPathComponent("transcript.txt").path))
        #expect(!FileManager.default.fileExists(atPath: rawURL.appendingPathComponent("curlmd-meta.json").path))
        #expect(!FileManager.default.fileExists(atPath: rawURL.appendingPathComponent("extract-meta.json").path))
        #expect(!FileManager.default.fileExists(atPath: rawURL.appendingPathComponent("extracted.txt").path))
        #expect(!FileManager.default.fileExists(atPath: staleImagesURL.path))
    }

    @Test(
        "Extracts a live public URL through WebKit",
        .enabled(if: ProcessInfo.processInfo.environment["LOCI_LIVE_WEB_TESTS"] == "1")
    )
    @MainActor
    func extractsLiveURL() async throws {
        let url = try #require(URL(string: "https://example.com"))
        let extraction = try #require(await LocalWebsiteExtractor.extract(url: url))

        #expect(extraction.title == "Example Domain")
        #expect(extraction.markdown.contains("# Example Domain"))
        #expect(extraction.markdown.contains("documentation examples"))
        #expect(extraction.sourceURL.hasPrefix("https://example.com"))
    }
}
