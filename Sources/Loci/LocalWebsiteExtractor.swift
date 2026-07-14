import Foundation
import WebKit

struct LocalWebsiteExtraction: Codable, Sendable, Equatable {
    var markdown: String
    var title: String
    var sourceURL: String
    var extractedAt: String
    var selectedElement: String
    var wordCount: Int
    var paragraphCount: Int
    var linkDensity: Double
    var qualityScore: Double
    var removedElementCount: Int
    var warnings: [String]

    var isUsable: Bool {
        wordCount >= 50 && qualityScore >= 0.42 && markdown.count >= 280
    }

    var metadata: LocalWebsiteExtractionMetadata {
        LocalWebsiteExtractionMetadata(
            title: title,
            sourceURL: sourceURL,
            extractedAt: extractedAt,
            selectedElement: selectedElement,
            wordCount: wordCount,
            paragraphCount: paragraphCount,
            linkDensity: linkDensity,
            qualityScore: qualityScore,
            removedElementCount: removedElementCount,
            warnings: warnings
        )
    }
}

struct LocalWebsiteExtractionMetadata: Codable, Sendable, Equatable {
    var title: String
    var sourceURL: String
    var extractedAt: String
    var selectedElement: String
    var wordCount: Int
    var paragraphCount: Int
    var linkDensity: Double
    var qualityScore: Double
    var removedElementCount: Int
    var warnings: [String]
}

@MainActor
final class LocalWebsiteExtractor: NSObject, WKNavigationDelegate {
    private enum Source {
        case url(URL)
        case html(String, baseURL: URL)
    }

    private static var activeExtractors: [UUID: LocalWebsiteExtractor] = [:]

    private let id: UUID
    private let source: Source
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<LocalWebsiteExtraction?, Never>?
    private var hasFinished = false
    private var hasAllowedInitialCapturedHTMLNavigation = false

    static func extract(url: URL) async -> LocalWebsiteExtraction? {
        await run(source: .url(url))
    }

    static func extract(html: String, baseURL: URL) async -> LocalWebsiteExtraction? {
        await run(source: .html(html, baseURL: baseURL))
    }

    private static func run(source: Source) async -> LocalWebsiteExtraction? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let extractor = LocalWebsiteExtractor(id: id, source: source, continuation: continuation)
                activeExtractors[id] = extractor
                extractor.start()
            }
        } onCancel: {
            Task { @MainActor in
                activeExtractors[id]?.finish(with: nil)
            }
        }
    }

    private init(
        id: UUID,
        source: Source,
        continuation: CheckedContinuation<LocalWebsiteExtraction?, Never>
    ) {
        self.id = id
        self.source = source
        self.continuation = continuation
        super.init()
    }

    private func start() {
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.finish(with: nil)
        }

        let configuration: WKWebViewConfiguration
        switch source {
        case .url:
            configuration = LociWebSession.configuration(suppressesIncrementalRendering: false)
            startWebView(configuration: configuration)
        case .html:
            configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            // Browser-captured HTML is evidence, not permission to fetch every resource it
            // references. Block subresources; relative URLs still resolve during Markdown
            // conversion because the document retains its original base URL.
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "LociCapturedHTMLNoSubresourcesV1",
                encodedContentRuleList: Self.capturedHTMLContentRules
            ) { [weak self] ruleList, _ in
                Task { @MainActor in
                    guard let self, !self.hasFinished else { return }
                    // Fail closed: a captured page must not gain network access merely because
                    // WebKit could not install the subresource blocker.
                    guard let ruleList else {
                        self.finish(with: nil)
                        return
                    }
                    configuration.userContentController.add(ruleList)
                    self.startWebView(configuration: configuration)
                }
            }
        }
    }

    private func startWebView(configuration: WKWebViewConfiguration) {
        guard !hasFinished else { return }
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
            configuration: configuration
        )
        webView.customUserAgent = LociWebSession.userAgent
        webView.navigationDelegate = self
        self.webView = webView

        switch source {
        case .url(let url):
            webView.load(LociWebSession.request(for: url, timeoutInterval: 14))
        case .html(let html, let baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard case .html = source else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true,
           !hasAllowedInitialCapturedHTMLNavigation {
            hasAllowedInitialCapturedHTMLNavigation = true
            decisionHandler(.allow)
        } else {
            // Blocks iframe loads and meta-refresh redirects embedded in an untrusted capture.
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            // Give client-rendered pages a short, bounded settling window.
            try? await Task.sleep(for: .milliseconds(850))
            self?.evaluateExtraction()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    private func evaluateExtraction() {
        guard let webView else {
            finish(with: nil)
            return
        }
        webView.callAsyncJavaScript(
            "return \(Self.extractionScript)",
            arguments: [:],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            Task { @MainActor in
                guard case .success(let value) = result else {
                    self?.finish(with: nil)
                    return
                }
                guard let json = value as? String,
                      let data = json.data(using: .utf8),
                      let extraction = try? JSONDecoder().decode(LocalWebsiteExtraction.self, from: data) else {
                    self?.finish(with: nil)
                    return
                }
                self?.finish(with: extraction)
            }
        }
    }

    private func finish(with extraction: LocalWebsiteExtraction?) {
        guard !hasFinished else { return }
        hasFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation?.resume(returning: extraction)
        continuation = nil
        Self.activeExtractors[id] = nil
    }

    // Deterministic extraction is intentionally performed before any LLM sees the page.
    // The original document is cloned so cleanup never mutates the visible browsing session.
    private static let capturedHTMLContentRules = #"""
    [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","svg-document","raw","popup"]},"action":{"type":"block"}}]
    """#

    private static let extractionScript = #"""
    (() => {
      const root = document.documentElement.cloneNode(true)
      let removedElementCount = 0
      const warnings = []
      const primarySelector = 'main,article,[role="main"],[itemprop="articleBody"],.article-body,.article-content,.post-content,.entry-content,.story-body,.markdown-body,.documentation,.docs-content'

      const remove = (element) => {
        if (!element || !element.parentNode) return
        element.remove()
        removedElementCount += 1
      }
      const text = (element) => (element?.textContent || '').replace(/\s+/g, ' ').trim()
      const linkDensity = (element) => {
        const total = Math.max(1, text(element).length)
        const linked = Array.from(element.querySelectorAll('a')).reduce(
          (sum, link) => sum + text(link).length,
          0,
        )
        return linked / total
      }

      // Attribute-only cleanup misses CSS-hidden menus and fixed overlays. Inspect the rendered
      // document, then mark the corresponding nodes in the clone before removing anything.
      const originalElements = Array.from(document.documentElement.querySelectorAll('*'))
      const clonedElements = Array.from(root.querySelectorAll('*'))
      const styleInspectionLimit = 12000
      const styleInspectionCount = Math.min(originalElements.length, clonedElements.length, styleInspectionLimit)
      if (originalElements.length > styleInspectionLimit) {
        warnings.push(`Rendered-style inspection was capped at ${styleInspectionLimit} elements.`)
      }
      for (let index = 0; index < styleInspectionCount; index += 1) {
        const original = originalElements[index]
        const clone = clonedElements[index]
        try {
          const style = window.getComputedStyle(original)
          const opacity = Number.parseFloat(style.opacity || '1')
          if (style.display === 'none' || style.visibility === 'hidden' || opacity <= 0.01) {
            clone.setAttribute('data-loci-render-hidden', 'true')
          }
          if ((style.position === 'fixed' || style.position === 'sticky') && text(original).length < 1800) {
            clone.setAttribute('data-loci-render-overlay', 'true')
          }
        } catch {}
      }

      root.querySelectorAll(
        'script,style,noscript,template,svg,canvas,iframe,object,embed,form,input,button,select,textarea,' +
        'nav,dialog,[hidden],[inert],[aria-hidden="true"],[data-loci-render-hidden="true"],[data-loci-render-overlay="true"],' +
        '[role="navigation"],[role="banner"],[role="contentinfo"],[role="complementary"],[role="dialog"],[role="alert"]',
      ).forEach(remove)

      const strongNoise = /(?:^|[-_\s])(cookie|consent|gdpr|cmp|modal|popup|pop-over|newsletter|subscribe|paywall|advert|advertisement|sponsored|social-share|share-tools|login-wall|signup-wall)(?:$|[-_\s])/i
      const structuralNoise = /(?:^|[-_\s])(header|footer|sidebar|rail|breadcrumb|pagination|related|recommend|comments?|community|promo|marketing|toolbar|menu|navigation|share|social)(?:$|[-_\s])/i
      const cookieLanguage = /\b(accept all cookies|cookie preferences|manage consent|privacy choices)\b/i

      Array.from(root.querySelectorAll('*')).forEach((element) => {
        const tag = element.tagName.toLowerCase()
        if (tag === 'html' || tag === 'body') return
        const signature = `${tag} ${element.id || ''} ${element.className || ''}`
        const content = text(element)
        const inlineStyle = (element.getAttribute('style') || '').toLowerCase()
        const inlineHidden = /display\s*:\s*none|visibility\s*:\s*hidden|opacity\s*:\s*0(?:\D|$)/.test(inlineStyle)
        const overlay = /position\s*:\s*(fixed|sticky)/.test(inlineStyle) && content.length < 1800
        if (inlineHidden || overlay || (strongNoise.test(signature) && content.length < 2400) || (content.length < 1200 && cookieLanguage.test(content))) {
          remove(element)
          return
        }
        const insidePrimaryContent = Boolean(element.parentElement?.closest(primarySelector))
        const protectedArticleStructure = insidePrimaryContent && /(?:^|[-_\s])(header|footer|byline|author|meta|citation|footnotes?)(?:$|[-_\s])/i.test(signature)
        if (!protectedArticleStructure && structuralNoise.test(signature) && (content.length < 900 || linkDensity(element) > 0.34)) {
          remove(element)
        }
      })

      const body = root.querySelector('body') || root
      const candidateSet = new Set([
        body,
        ...root.querySelectorAll(primarySelector),
      ])

      const scoreCandidate = (element) => {
        const content = text(element)
        const words = content.split(/\s+/).filter(Boolean).length
        const paragraphs = Array.from(element.querySelectorAll('p')).filter((p) => text(p).length >= 40).length
        const headings = element.querySelectorAll('h1,h2,h3').length
        const lists = element.querySelectorAll('li').length
        const code = element.querySelectorAll('pre,code').length
        const semantic = element.matches('article,[itemprop="articleBody"]')
          ? 680
          : element.matches('main,[role="main"]')
            ? 500
            : element.matches('.article-body,.article-content,.post-content,.entry-content,.story-body,.markdown-body,.documentation,.docs-content')
              ? 360
              : 0
        const densityPenalty = Math.round(linkDensity(element) * Math.max(400, content.length))
        return words * 2 + paragraphs * 85 + headings * 110 + Math.min(lists, 20) * 18 + Math.min(code, 12) * 35 + semantic - densityPenalty
      }

      const candidates = Array.from(candidateSet).filter(Boolean)
      candidates.sort((a, b) => scoreCandidate(b) - scoreCandidate(a))
      let selected = candidates[0] || body
      if (text(selected).length < 240) {
        selected = body
        warnings.push('No strong main-content candidate; used cleaned document body.')
      }

      const escapeHTML = (value) => value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      const escapeText = (value) => escapeHTML(value)
        .replace(/\\/g, '\\\\')
        .replace(/([\[\]*_`])/g, '\\$1')
      const escapeTable = (value) => escapeHTML(value).replace(/\|/g, '\\|').replace(/\s+/g, ' ').trim()
      const codeFence = (value, minimum) => {
        const runs = value.match(/`+/g) || []
        const longest = runs.reduce((length, run) => Math.max(length, run.length), 0)
        return '`'.repeat(Math.max(minimum, longest + 1))
      }
      const inlineCode = (value) => {
        const fence = codeFence(value, 1)
        const padding = /^\s|\s$|^`|`$/.test(value) ? ' ' : ''
        return `${fence}${padding}${value}${padding}${fence}`
      }
      const markdownDestination = (value) => `<${value.replace(/</g, '%3C').replace(/>/g, '%3E')}>`
      const children = (node, context = {}) => Array.from(node.childNodes)
        .map((child) => render(child, context))
        .join('')

      const render = (node, context = {}) => {
        if (node.nodeType === Node.TEXT_NODE) return escapeText((node.nodeValue || '').replace(/\s+/g, ' '))
        if (node.nodeType !== Node.ELEMENT_NODE) return ''
        const tag = node.tagName.toLowerCase()
        if (['script', 'style', 'noscript', 'template'].includes(tag)) return ''
        if (/^h[1-6]$/.test(tag)) return `\n\n${'#'.repeat(Number(tag[1]))} ${children(node).trim()}\n\n`
        if (tag === 'p') return `\n\n${children(node).trim()}\n\n`
        if (tag === 'br') return '  \n'
        if (tag === 'hr') return '\n\n---\n\n'
        if (tag === 'strong' || tag === 'b') return `**${children(node).trim()}**`
        if (tag === 'em' || tag === 'i') return `*${children(node).trim()}*`
        if (tag === 'del' || tag === 's') return `~~${children(node).trim()}~~`
        if (tag === 'code' && node.parentElement?.tagName.toLowerCase() !== 'pre') return inlineCode((node.textContent || '').trim())
        if (tag === 'pre') {
          const codeNode = node.querySelector('code')
          const language = (codeNode?.className || '').match(/(?:language-|lang-)([\w+-]+)/)?.[1] || ''
          const content = (node.textContent || '').replace(/^\n+|\n+$/g, '')
          const fence = codeFence(content, 3)
          return `\n\n${fence}${language}\n${content}\n${fence}\n\n`
        }
        if (tag === 'blockquote') {
          const quote = children(node).trim().split('\n').map((line) => `> ${line}`).join('\n')
          return `\n\n${quote}\n\n`
        }
        if (tag === 'a') {
          const label = children(node).trim() || text(node)
          const href = node.getAttribute('href') || ''
          if (!label || !href || href.startsWith('#') || /^javascript:/i.test(href)) return label
          try {
            const resolved = new URL(href, document.baseURI)
            if (!['http:', 'https:', 'mailto:'].includes(resolved.protocol) || resolved.username || resolved.password) return label
            return `[${label}](${markdownDestination(resolved.href)})`
          } catch { return label }
        }
        if (tag === 'img') {
          const alt = (node.getAttribute('alt') || '').trim()
          const src = node.getAttribute('src') || ''
          if (!alt || !src || src.startsWith('data:')) return ''
          try {
            const resolved = new URL(src, document.baseURI)
            if (!['http:', 'https:'].includes(resolved.protocol) || resolved.username || resolved.password) return ''
            return `\n\n![${escapeText(alt)}](${markdownDestination(resolved.href)})\n\n`
          } catch { return '' }
        }
        if (tag === 'ul' || tag === 'ol') {
          const ordered = tag === 'ol'
          const items = Array.from(node.children).filter((child) => child.tagName.toLowerCase() === 'li')
          const lines = items.map((item, index) => {
            const value = children(item, { list: true }).trim().replace(/\n{3,}/g, '\n\n')
            const prefix = ordered ? `${index + 1}. ` : '- '
            return prefix + value.replace(/\n/g, '\n  ')
          })
          return `\n\n${lines.join('\n')}\n\n`
        }
        if (tag === 'li') return children(node, context)
        if (tag === 'table') {
          const rows = Array.from(node.querySelectorAll('tr')).map((row) =>
            Array.from(row.querySelectorAll(':scope > th,:scope > td')).map((cell) => escapeTable(text(cell))),
          ).filter((row) => row.length)
          if (!rows.length) return ''
          const width = Math.max(...rows.map((row) => row.length))
          const normalized = rows.map((row) => [...row, ...Array(Math.max(0, width - row.length)).fill('')])
          const header = normalized[0]
          const bodyRows = normalized.slice(1)
          return `\n\n| ${header.join(' | ')} |\n| ${header.map(() => '---').join(' | ')} |\n${bodyRows.map((row) => `| ${row.join(' | ')} |`).join('\n')}\n\n`
        }
        const value = children(node, context)
        if (['div', 'section', 'article', 'main', 'header', 'figure', 'figcaption', 'details', 'summary', 'dl', 'dt', 'dd'].includes(tag)) {
          return `\n\n${value.trim()}\n\n`
        }
        return value
      }

      const title = (document.querySelector('meta[property="og:title"]')?.content || document.title || '').trim()
      let markdown = render(selected)
        .replace(/[ \t]+\n/g, '\n')
        .replace(/\n[ \t]+/g, '\n')
        .replace(/\n{3,}/g, '\n\n')
        .trim()
      const normalizedTitle = title.replace(/\s+/g, ' ').trim()
      const selectedH1 = text(selected.querySelector('h1')).replace(/\s+/g, ' ').trim()
      if (normalizedTitle && selectedH1.toLowerCase() !== normalizedTitle.toLowerCase()) {
        markdown = `# ${escapeText(normalizedTitle)}\n\n${markdown}`
      }
      if (markdown.length > 750000) {
        const blockBoundary = markdown.lastIndexOf('\n\n', 750000)
        let truncationIndex = blockBoundary >= 700000 ? blockBoundary : 750000
        const previousCodeUnit = markdown.charCodeAt(truncationIndex - 1)
        const nextCodeUnit = markdown.charCodeAt(truncationIndex)
        if (previousCodeUnit >= 0xd800 && previousCodeUnit <= 0xdbff && nextCodeUnit >= 0xdc00 && nextCodeUnit <= 0xdfff) {
          truncationIndex -= 1
        }
        let truncated = markdown.slice(0, truncationIndex).trimEnd()
        let openFence = null
        truncated.split('\n').forEach((line) => {
          const match = line.match(/^(`{3,})(?:[\w+-]+)?\s*$/)
          if (!match) return
          if (openFence && match[1].length >= openFence.length) {
            openFence = null
          } else if (!openFence) {
            openFence = match[1]
          }
        })
        if (openFence) truncated += `\n${openFence}`
        markdown = `${truncated}\n\n<!-- Loci local extraction truncated at 750,000 characters. -->`
        warnings.push('Clean Markdown exceeded 750,000 characters and was truncated; preserved HTML remains available.')
      }

      const selectedText = text(selected)
      const words = selectedText.split(/\s+/).filter(Boolean)
      const paragraphs = Array.from(selected.querySelectorAll('p')).filter((p) => text(p).length >= 40).length
      const density = linkDensity(selected)
      const hasSemanticRoot = selected.matches('main,article,[role="main"],[itemprop="articleBody"]')
      let quality = 0.08
      quality += Math.min(0.34, words.length / 1800)
      quality += Math.min(0.22, paragraphs / 28)
      quality += Math.min(0.10, selected.querySelectorAll('h1,h2,h3').length / 30)
      quality += hasSemanticRoot ? 0.16 : 0.04
      quality += density < 0.25 ? 0.10 : density < 0.40 ? 0.04 : -0.16
      if (words.length < 50) quality -= 0.24
      if (markdown.length < 280) quality -= 0.16
      quality = Math.max(0, Math.min(1, quality))
      if (density >= 0.4) warnings.push('Selected content has high link density.')
      if (words.length < 50) warnings.push('Selected content is unusually short.')

      const descriptor = selected.tagName.toLowerCase()
        + (selected.id ? `#${selected.id}` : '')
        + (selected.classList.length ? `.${Array.from(selected.classList).slice(0, 3).join('.')}` : '')

      return JSON.stringify({
        markdown,
        title: normalizedTitle,
        sourceURL: document.location.href,
        extractedAt: new Date().toISOString(),
        selectedElement: descriptor,
        wordCount: words.length,
        paragraphCount: paragraphs,
        linkDensity: density,
        qualityScore: quality,
        removedElementCount,
        warnings,
      })
    })()
    """#
}
