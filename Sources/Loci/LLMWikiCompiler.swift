import Foundation

struct LLMWikiCompilerResult: Hashable {
    var summary: String
    var writeCount: Int
    var contradictionCount: Int
}

struct NotebookAnswer: Hashable {
    var answer: String
    var sources: [VaultChatSourceBundle]
    var usedLLM: Bool
}

struct NotebookAnswerFailure: Error, Hashable {
    var message: String
}

private struct ProviderAnswerFailure: Error {
    var message: String
}

enum LLMWikiCompiler {
    private static let allowedPrefixes = [
        "wiki/",
        "outputs/",
        "system/index.md",
        "system/log.md",
        "system/health.md",
        "system/graph.md",
        "system/search-index.tsv"
    ]

    static func compile(
        item: ReferenceItem,
        sourceText: String,
        heuristicSummary: String,
        heuristicConcepts: [String],
        heuristicContradictions: [String],
        rootURL: URL,
        rawURL: URL
    ) async -> LLMWikiCompilerResult? {
        guard sourceText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count >= 80 else {
            return nil
        }

        let userMessage = userPrompt(
            item: item,
            sourceText: sourceText,
            heuristicSummary: heuristicSummary,
            heuristicConcepts: heuristicConcepts,
            heuristicContradictions: heuristicContradictions,
            rootURL: rootURL,
            rawURL: rawURL
        )

        var selectedPlan: LLMCompilePlan?
        var selectedProvider: String?
        for provider in configuredProviders() {
            if let responseText = await send(provider: provider, userMessage: userMessage),
               let plan = decodePlan(from: responseText) {
                selectedPlan = plan
                selectedProvider = provider.label
                break
            }
        }

        guard let plan = selectedPlan,
              let provider = selectedProvider,
              let applied = apply(plan, rootURL: rootURL) else {
            LociTelemetry.recordLLMCompile(
                success: false,
                provider: selectedProvider,
                writeCount: 0,
                contradictionCount: heuristicContradictions.count
            )
            return nil
        }

        appendCompileLog(item: item, plan: plan, provider: provider, rootURL: rootURL)
        LociTelemetry.recordLLMCompile(
            success: true,
            provider: provider,
            writeCount: applied,
            contradictionCount: plan.contradictions?.count ?? heuristicContradictions.count
        )
        return LLMWikiCompilerResult(
            summary: plan.summary,
            writeCount: applied,
            contradictionCount: plan.contradictions?.count ?? heuristicContradictions.count
        )
    }

    private static func configuredProviders() -> [LLMProvider] {
        var providers: [LLMProvider] = []
        if let key = openRouterAPIKey() {
            providers.append(.openRouter(model: openRouterModel(), apiKey: key))
        }
        providers.append(contentsOf: ollamaModels().map { .ollama(model: $0) })
        return providers
    }

    private static func openRouterAPIKey() -> String? {
        LociEnvironment.value(for: [
            "OPENROUTER_API_KEY",
            "LOCI_OPENROUTER_API_KEY"
        ])
    }

    private static func openRouterModel() -> String {
        LociEnvironment.value(for: [
            "OPENROUTER_MODEL",
            "LOCI_OPENROUTER_MODEL"
        ]) ?? "openai/gpt-4o-mini"
    }

    private static func ollamaModels() -> [String] {
        var models: [String] = []
        if let value = LociEnvironment.value(for: ["LOCI_LLM_MODEL", "OLLAMA_MODEL"]) {
            models.append(value)
        }
        guard !models.isEmpty else { return [] }
        return Array(NSOrderedSet(array: models).compactMap { $0 as? String })
    }

    private static func discoverOllamaModels() async -> [String] {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            struct TagsResponse: Decodable {
                struct Model: Decodable { var name: String }
                var models: [Model]
            }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            return decoded.models.map(\.name)
        } catch {
            return []
        }
    }

    private static func systemPrompt() -> String {
        """
        You are Loci's local wiki compiler. Your job is deep multi-source synthesis, not a generic summary.

        You read one immutable raw source package plus selected existing wiki context. Return only strict JSON matching this schema:
        {
          "summary": "one useful sentence",
          "evidenceQuality": "strong|mixed|thin",
          "reviewStatus": "compiled-needs-review",
          "entities": ["canonical people, brands, products, concepts, techniques"],
          "contradictions": ["specific tensions or conflicts, empty if none"],
          "thesisUpdate": "how this source changes the evolving thesis",
          "writes": [
            {"path":"wiki/references/source-slug.md","content":"complete markdown"},
            {"path":"wiki/concepts/canonical-concept.md","content":"complete markdown"},
            {"path":"wiki/summaries/evolving-thesis.md","content":"complete markdown"}
          ]
        }

        Requirements:
        - Use wiki links like [[concept-slug]] and [[source-slug]] for every meaningful entity or concept.
        - Merge entities by canonical meaning; do not create duplicates that differ only by casing or punctuation.
        - Call out contradictions, uncertainty, and taste/style judgments with evidence from the source.
        - Write complete Markdown files, not patches and not placeholder examples.
        - Preserve source provenance and cite raw files by relative path.
        - Never write inside raw/. Never use absolute paths. Never include ../ in paths.
        - Keep content compact, navigable, and human-editable.
        """
    }

    private static func userPrompt(
        item: ReferenceItem,
        sourceText: String,
        heuristicSummary: String,
        heuristicConcepts: [String],
        heuristicContradictions: [String],
        rootURL: URL,
        rawURL: URL
    ) -> String {
        let slug = MarkdownVault.slug(for: item)
        let context = wikiContext(rootURL: rootURL, terms: [item.title] + heuristicConcepts)
        return """
        Source slug: \(slug)
        Source title: \(item.title)
        Source kind: \(item.kind.rawValue)
        Source group: \(item.group.rawValue)
        Raw package path: raw/\(slug)/
        Extracted text path: raw/\(slug)/extracted.txt
        Heuristic summary: \(heuristicSummary)
        Heuristic concepts: \(heuristicConcepts.prefix(20).joined(separator: ", "))
        Heuristic contradiction signals: \(heuristicContradictions.prefix(12).joined(separator: " | "))

        Existing wiki context:
        \(context)

        Raw source text:
        \(sourceText.prefix(28000))
        """
    }

    private static func wikiContext(rootURL: URL, terms: [String]) -> String {
        let searchableTerms = terms
            .flatMap { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
            .filter { $0.count > 3 }
        guard !searchableTerms.isEmpty else { return "" }

        let indexURL = rootURL.appendingPathComponent("system/search-index.tsv")
        var scoredURLs: [(score: Int, path: String)] = []

        if let indexContent = try? String(contentsOf: indexURL, encoding: .utf8) {
            for row in indexContent.components(separatedBy: .newlines).filter({ !$0.isEmpty }) {
                let parts = row.components(separatedBy: "\t")
                guard parts.count >= 2 else { continue }
                let keywords = parts.count >= 3 ? parts[2] : ""
                let lower = keywords.lowercased() + " " + (parts.dropFirst().first ?? "").lowercased()
                let score = searchableTerms.reduce(0) { total, term in
                    total + lower.components(separatedBy: term).count - 1
                }
                if score > 0 {
                    scoredURLs.append((score, parts[1]))
                }
            }
        }

        let thesisURL = rootURL.appendingPathComponent("wiki/summaries/evolving-thesis.md").path
        if !scoredURLs.contains(where: { $0.path == thesisURL }) {
            scoredURLs.append((0, thesisURL))
        }

        let topPaths = scoredURLs
            .sorted { $0.score > $1.score }
            .prefix(8)
            .map(\.path)

        return topPaths.compactMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let relative = relativePath(for: url, rootURL: rootURL)
            return "## \(relative)\n\(content.prefix(5000))"
        }
        .joined(separator: "\n\n---\n\n")
    }

    private static func send(provider: LLMProvider, userMessage: String) async -> String? {
        switch provider {
        case .openRouter(let model, let apiKey):
            return await sendOpenRouter(model: model, apiKey: apiKey, userMessage: userMessage)
        case .ollama(let model):
            return await sendOllama(model: model, userMessage: userMessage)
        }
    }

    static func answer(question: String, rootURL: URL) async -> String? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let context = wikiContext(rootURL: rootURL, terms: [trimmed])
        let userMessage = """
        Question:
        \(trimmed)

        Vault context:
        \(context.isEmpty ? "No matching wiki context found." : context)

        Answer using only the vault context. Be concise, cite relevant [[wiki-links]] or relative paths, and say what is unknown instead of inventing facts.
        """

        for provider in configuredProviders() {
            if let answer = await sendConversation(provider: provider, system: vaultAnswerSystemPrompt(), history: [], userMessage: userMessage),
               !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return answer
            }
        }
        return nil
    }

    static func answerNotebook(
        question: String,
        items: [ReferenceItem],
        rootURL: URL,
        history: [(role: String, content: String)] = []
    ) async -> Result<NotebookAnswer, NotebookAnswerFailure> {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(NotebookAnswerFailure(message: "Enter a question first."))
        }

        let sources = VaultChatContext.bundles(for: items, rootURL: rootURL, question: trimmed)
        let extractContext = VaultChatContext.buildContext(for: items, rootURL: rootURL, question: trimmed)
        let wikiContext = wikiContext(rootURL: rootURL, terms: [trimmed] + items.map(\.title))

        guard !sources.isEmpty else {
            LociTelemetry.recordLLMNotebookAnswer(
                success: false,
                usedLLM: false,
                sourceCount: 0,
                historyTurns: history.count
            )
            return .failure(NotebookAnswerFailure(
                message: "No extracted text found for these documents. Open API Library and run the compiler, or re-import the files."
            ))
        }

        let userMessage = """
        Question:
        \(trimmed)

        Extracted source documents:
        \(extractContext)

        Related wiki pages:
        \(wikiContext.isEmpty ? "No matching wiki pages." : wikiContext)

        Answer using only the sources above. Cite document titles and paths like raw/<slug>/extracted.md. Say clearly when the sources do not contain enough information.
        """

        var providers = configuredProviders()
        if providers.isEmpty {
            let discovered = await discoverOllamaModels()
            if let first = discovered.first {
                providers = [.ollama(model: first)]
            }
        }

        var lastError = "No LLM configured."
        if providers.isEmpty {
            if let local = localNotebookAnswer(question: trimmed, sources: sources) {
                LociTelemetry.recordLLMNotebookAnswer(
                    success: true,
                    usedLLM: false,
                    sourceCount: sources.count,
                    historyTurns: history.count
                )
                return .success(NotebookAnswer(answer: local, sources: sources, usedLLM: false))
            }
            LociTelemetry.recordLLMNotebookAnswer(
                success: false,
                usedLLM: false,
                sourceCount: sources.count,
                historyTurns: history.count
            )
            return .failure(NotebookAnswerFailure(
                message: """
                No LLM configured. Add OPENROUTER_API_KEY to ~/Library/Application Support/Loci/loci.env, start Ollama, or set LOCI_LLM_MODEL. Local excerpt search also found nothing useful.
                """
            ))
        }

        for provider in providers {
            switch await sendConversationDetailed(
                provider: provider,
                system: notebookSystemPrompt(),
                history: history,
                userMessage: userMessage
            ) {
            case .success(let answer):
                let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedAnswer.isEmpty else { continue }
                LociTelemetry.recordLLMNotebookAnswer(
                    success: true,
                    usedLLM: true,
                    sourceCount: sources.count,
                    historyTurns: history.count
                )
                return .success(NotebookAnswer(answer: trimmedAnswer, sources: sources, usedLLM: true))
            case .failure(let error):
                lastError = error.message
            }
        }

        if let local = localNotebookAnswer(question: trimmed, sources: sources) {
            LociTelemetry.recordLLMNotebookAnswer(
                success: true,
                usedLLM: false,
                sourceCount: sources.count,
                historyTurns: history.count
            )
            return .success(
                NotebookAnswer(
                    answer: local + "\n\n(LLM unavailable: \(lastError))",
                    sources: sources,
                    usedLLM: false
                )
            )
        }

        LociTelemetry.recordLLMNotebookAnswer(
            success: false,
            usedLLM: false,
            sourceCount: sources.count,
            historyTurns: history.count
        )
        return .failure(NotebookAnswerFailure(message: lastError))
    }

    private static func localNotebookAnswer(question: String, sources: [VaultChatSourceBundle]) -> String? {
        let terms = question
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
        guard !terms.isEmpty else { return nil }

        var hits: [(score: Int, source: VaultChatSourceBundle, snippet: String)] = []
        for source in sources {
            let paragraphs = source.excerpt
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for paragraph in paragraphs {
                let lower = paragraph.lowercased()
                let score = terms.reduce(0) { $0 + lower.components(separatedBy: $1).count - 1 }
                if score > 0 {
                    hits.append((score, source, String(paragraph.prefix(600))))
                }
            }
        }

        let top = hits.sorted { $0.score > $1.score }.prefix(4)
        guard !top.isEmpty else { return nil }

        let body = top.map { hit in
            "**\(hit.source.title)** (`\(hit.source.rawPath)`)\n\(hit.snippet)"
        }.joined(separator: "\n\n")

        return """
        Here are the most relevant excerpts from your sources:

        \(body)
        """
    }

    private static func vaultAnswerSystemPrompt() -> String {
        "You answer questions over a local Markdown knowledge vault. Use only provided context and cite paths or wiki links."
    }

    private static func notebookSystemPrompt() -> String {
        """
        You are Loci Notebook — a grounded document assistant like NotebookLM.
        Use only the extracted source text and wiki context provided in each turn.
        Be clear, structured, and cite sources by title and raw/<slug>/ path.
        Never invent facts. When evidence is thin, say what is missing and what would be needed.
        """
    }

    private static func sendOpenRouter(model: String, apiKey: String, userMessage: String) async -> String? {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else { return nil }

        let requestBody = OpenRouterChatRequest(
            model: model,
            messages: [
                OpenRouterMessage(role: "system", content: systemPrompt()),
                OpenRouterMessage(role: "user", content: userMessage)
            ],
            temperature: 0.15,
            response_format: OpenRouterResponseFormat(type: "json_object")
        )
        guard let body = try? JSONEncoder().encode(requestBody) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(AppBrand.name, forHTTPHeaderField: "HTTP-Referer")
        request.setValue("\(AppBrand.name) Creative Memory", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 180
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
            return decoded.choices.first?.message.content
        } catch {
            return nil
        }
    }

    private static func sendConversation(
        provider: LLMProvider,
        system: String,
        history: [(role: String, content: String)],
        userMessage: String
    ) async -> String? {
        switch await sendConversationDetailed(provider: provider, system: system, history: history, userMessage: userMessage) {
        case .success(let answer): return answer
        case .failure: return nil
        }
    }

    private static func sendConversationDetailed(
        provider: LLMProvider,
        system: String,
        history: [(role: String, content: String)],
        userMessage: String
    ) async -> Result<String, ProviderAnswerFailure> {
        switch provider {
        case .openRouter(let model, let apiKey):
            return await sendOpenRouterConversationDetailed(
                model: model,
                apiKey: apiKey,
                system: system,
                history: history,
                userMessage: userMessage
            )
        case .ollama(let model):
            return await sendOllamaConversationDetailed(
                model: model,
                system: system,
                history: history,
                userMessage: userMessage
            )
        }
    }

    private static func sendOpenRouterConversation(
        model: String,
        apiKey: String,
        system: String,
        history: [(role: String, content: String)],
        userMessage: String
    ) async -> String? {
        switch await sendOpenRouterConversationDetailed(
            model: model,
            apiKey: apiKey,
            system: system,
            history: history,
            userMessage: userMessage
        ) {
        case .success(let answer): return answer
        case .failure: return nil
        }
    }

    private static func sendOpenRouterConversationDetailed(
        model: String,
        apiKey: String,
        system: String,
        history: [(role: String, content: String)],
        userMessage: String
    ) async -> Result<String, ProviderAnswerFailure> {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            return .failure(ProviderAnswerFailure(message: "Invalid OpenRouter URL."))
        }

        var messages = [OpenRouterMessage(role: "system", content: system)]
        for entry in history.suffix(8) {
            let role = entry.role == "assistant" ? "assistant" : "user"
            messages.append(OpenRouterMessage(role: role, content: entry.content))
        }
        messages.append(OpenRouterMessage(role: "user", content: userMessage))

        let requestBody = OpenRouterAnswerRequest(
            model: model,
            messages: messages,
            temperature: 0.1
        )
        guard let body = try? JSONEncoder().encode(requestBody) else {
            return .failure(ProviderAnswerFailure(message: "Could not encode OpenRouter request."))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(AppBrand.name, forHTTPHeaderField: "HTTP-Referer")
        request.setValue("\(AppBrand.name) Creative Memory", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 120
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(ProviderAnswerFailure(message: "OpenRouter returned no HTTP response."))
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .failure(ProviderAnswerFailure(message: "OpenRouter HTTP \(http.statusCode): \(bodyText.prefix(240))"))
            }
            let decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content else {
                return .failure(ProviderAnswerFailure(message: "OpenRouter returned an empty answer."))
            }
            return .success(content)
        } catch {
            return .failure(ProviderAnswerFailure(message: "OpenRouter request failed: \(error.localizedDescription)"))
        }
    }

    private static func sendOllamaConversation(
        model: String,
        system: String,
        history: [(role: String, content: String)],
        userMessage: String
    ) async -> String? {
        switch await sendOllamaConversationDetailed(
            model: model,
            system: system,
            history: history,
            userMessage: userMessage
        ) {
        case .success(let answer): return answer
        case .failure: return nil
        }
    }

    private static func sendOllamaConversationDetailed(
        model: String,
        system: String,
        history: [(role: String, content: String)],
        userMessage: String
    ) async -> Result<String, ProviderAnswerFailure> {
        guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else {
            return .failure(ProviderAnswerFailure(message: "Invalid Ollama URL."))
        }

        var messages = [OllamaMessage(role: "system", content: system)]
        for entry in history.suffix(8) {
            let role = entry.role == "assistant" ? "assistant" : "user"
            messages.append(OllamaMessage(role: role, content: entry.content))
        }
        messages.append(OllamaMessage(role: "user", content: userMessage))

        let requestBody = OllamaAnswerRequest(
            model: model,
            stream: false,
            messages: messages,
            options: OllamaOptions(temperature: 0.1, num_ctx: 16384)
        )
        guard let body = try? JSONEncoder().encode(requestBody) else {
            return .failure(ProviderAnswerFailure(message: "Could not encode Ollama request."))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(ProviderAnswerFailure(message: "Ollama returned no HTTP response."))
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .failure(ProviderAnswerFailure(message: "Ollama HTTP \(http.statusCode): \(bodyText.prefix(240))"))
            }
            let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            return .success(decoded.message.content)
        } catch {
            return .failure(ProviderAnswerFailure(message: "Ollama request failed. Is Ollama running on port 11434? (\(error.localizedDescription))"))
        }
    }

    private static func sendOllama(model: String, userMessage: String) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else { return nil }

        let requestBody = OllamaChatRequest(
            model: model,
            stream: false,
            messages: [
                OllamaMessage(role: "system", content: systemPrompt()),
                OllamaMessage(role: "user", content: userMessage)
            ],
            format: "json",
            options: OllamaOptions(temperature: 0.15, num_ctx: 16384)
        )
        guard let body = try? JSONEncoder().encode(requestBody) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            return decoded.message.content
        } catch {
            return nil
        }
    }

    private static func decodePlan(from text: String) -> LLMCompilePlan? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LLMCompilePlan.self, from: data)
    }

    private static func apply(_ plan: LLMCompilePlan, rootURL: URL) -> Int? {
        let writes = plan.writes.prefix(16)
        guard !writes.isEmpty else { return nil }

        var applied = 0
        for write in writes {
            guard let safePath = normalizedAllowedPath(write.path) else { continue }
            let content = write.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content.count <= 120_000 else { continue }
            let url = rootURL.appendingPathComponent(safePath)
            createDirectoryIfNeeded(url.deletingLastPathComponent())
            do {
                try (content + "\n").write(to: url, atomically: true, encoding: .utf8)
                applied += 1
            } catch {
                continue
            }
        }
        return applied > 0 ? applied : nil
    }

    private static func normalizedAllowedPath(_ path: String) -> String? {
        let cleaned = path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        guard !cleaned.isEmpty,
              !cleaned.contains(".."),
              !cleaned.hasPrefix("raw/"),
              !(cleaned as NSString).isAbsolutePath else {
            return nil
        }
        guard allowedPrefixes.contains(where: { prefix in
            prefix.hasSuffix(".md") || prefix.hasSuffix(".tsv") ? cleaned == prefix : cleaned.hasPrefix(prefix)
        }) else {
            return nil
        }
        guard cleaned.hasSuffix(".md") || cleaned.hasSuffix(".tsv") else { return nil }
        return cleaned
    }

    private static func appendCompileLog(item: ReferenceItem, plan: LLMCompilePlan, provider: String, rootURL: URL) {
        let url = rootURL.appendingPathComponent("system/log.md")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Loci Compile Log\n\n"
        let row = """

        - \(ISO8601DateFormatter().string(from: Date())) model-compiled [[\(MarkdownVault.slug(for: item))]] with `\(provider)`: \(plan.summary) (\(plan.writes.count) writes, evidence: \(plan.evidenceQuality))
        """
        try? (existing + row + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func markdownFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension.lowercased() == "md" else { return nil }
            return url
        }
    }

    private static func relativePath(for url: URL, rootURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return url.lastPathComponent }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func createDirectoryIfNeeded(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private enum LLMProvider {
    case openRouter(model: String, apiKey: String)
    case ollama(model: String)

    var label: String {
        switch self {
        case .openRouter(let model, _): return "openrouter/\(model)"
        case .ollama(let model): return "ollama/\(model)"
        }
    }
}

private struct OpenRouterChatRequest: Encodable {
    var model: String
    var messages: [OpenRouterMessage]
    var temperature: Double
    var response_format: OpenRouterResponseFormat
}

private struct OpenRouterAnswerRequest: Encodable {
    var model: String
    var messages: [OpenRouterMessage]
    var temperature: Double
}

private struct OpenRouterMessage: Codable {
    var role: String
    var content: String
}

private struct OpenRouterResponseFormat: Encodable {
    var type: String
}

private struct OpenRouterChatResponse: Decodable {
    var choices: [OpenRouterChoice]
}

private struct OpenRouterChoice: Decodable {
    var message: OpenRouterMessage
}

private struct OllamaChatRequest: Encodable {
    var model: String
    var stream: Bool
    var messages: [OllamaMessage]
    var format: String
    var options: OllamaOptions
}

private struct OllamaAnswerRequest: Encodable {
    var model: String
    var stream: Bool
    var messages: [OllamaMessage]
    var options: OllamaOptions
}

private struct OllamaMessage: Codable {
    var role: String
    var content: String
}

private struct OllamaOptions: Encodable {
    var temperature: Double
    var num_ctx: Int
}

private struct OllamaChatResponse: Decodable {
    var message: OllamaMessage
}

private struct LLMCompilePlan: Decodable {
    var summary: String
    var evidenceQuality: String
    var reviewStatus: String
    var entities: [String]?
    var contradictions: [String]?
    var thesisUpdate: String?
    var writes: [LLMCompileWrite]
}

private struct LLMCompileWrite: Decodable {
    var path: String
    var content: String
}
