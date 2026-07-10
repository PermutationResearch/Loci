import Foundation

struct VaultChatSourceBundle: Hashable, Identifiable {
    var id: String { slug }
    var slug: String
    var title: String
    var rawPath: String
    var wikiPath: String?
    var excerpt: String
    var wordCount: Int
}

enum VaultChatContext {
  private static let defaultMaxSources = 8
  private static let defaultMaxCharsPerSource = 14_000

  static func bundles(
    for items: [ReferenceItem],
    rootURL: URL,
    question: String = "",
    maxSources: Int = defaultMaxSources,
    maxCharsPerSource: Int = defaultMaxCharsPerSource
  ) -> [VaultChatSourceBundle] {
    let active = items.filter { !$0.isTrashed }
    guard !active.isEmpty else { return [] }

    let terms = searchTerms(from: question)
    let scored = active.map { item -> (score: Int, bundle: VaultChatSourceBundle) in
      let bundle = bundle(for: item, rootURL: rootURL, maxChars: maxCharsPerSource)
      let score = terms.isEmpty
        ? bundle.wordCount
        : termScore(terms: terms, in: bundle.title + " " + bundle.excerpt)
      return (score, bundle)
    }
    .filter { $0.bundle.wordCount > 0 }

    if terms.isEmpty {
      return scored
        .sorted { $0.bundle.title.localizedStandardCompare($1.bundle.title) == .orderedAscending }
        .prefix(maxSources)
        .map(\.bundle)
    }

    return scored
      .sorted { $0.score > $1.score }
      .prefix(maxSources)
      .map(\.bundle)
  }

  static func buildContext(
    for items: [ReferenceItem],
    rootURL: URL,
    question: String,
    maxSources: Int = defaultMaxSources,
    maxCharsPerSource: Int = defaultMaxCharsPerSource
  ) -> String {
    let bundles = bundles(
      for: items,
      rootURL: rootURL,
      question: question,
      maxSources: maxSources,
      maxCharsPerSource: maxCharsPerSource
    )
    guard !bundles.isEmpty else {
      return "No extracted source text found. Import documents and run extraction first."
    }

  return bundles.map { bundle in
      var header = "## \(bundle.title)\nSlug: \(bundle.slug)\nRaw: \(bundle.rawPath)"
      if let wikiPath = bundle.wikiPath {
        header += "\nWiki: \(wikiPath)"
      }
      return "\(header)\n\n\(bundle.excerpt)"
    }
    .joined(separator: "\n\n---\n\n")
  }

  private static func bundle(for item: ReferenceItem, rootURL: URL, maxChars: Int) -> VaultChatSourceBundle {
    let slug = MarkdownVault.slug(for: item)
    let rawDir = rootURL.appendingPathComponent("raw/\(slug)", isDirectory: true)
    let rawPath = "raw/\(slug)/extracted.md"
    let text = readExtractedText(from: rawDir) ?? ""
    let wikiPath = "wiki/references/\(slug).md"
    let wikiURL = rootURL.appendingPathComponent(wikiPath)
    let wikiText = (try? String(contentsOf: wikiURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    let excerpt = String(text.prefix(maxChars))
    return VaultChatSourceBundle(
      slug: slug,
      title: item.title,
      rawPath: rawPath,
      wikiPath: wikiText == nil ? nil : wikiPath,
      excerpt: excerpt,
      wordCount: wordCount(in: text)
    )
  }

  private static func readExtractedText(from rawDir: URL) -> String? {
    let candidates = [
      rawDir.appendingPathComponent("extracted.md"),
      rawDir.appendingPathComponent("extracted.txt")
    ]
    for url in candidates {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    return nil
  }

  static func wordCount(in text: String) -> Int {
    text.split { $0.isWhitespace || $0.isNewline }.count
  }

  static func searchTerms(from question: String) -> [String] {
    question
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { $0.count > 2 }
  }

  static func termScore(terms: [String], in text: String) -> Int {
    let lower = text.lowercased()
    return terms.reduce(0) { total, term in
      total + lower.components(separatedBy: term).count - 1
    }
  }
}
