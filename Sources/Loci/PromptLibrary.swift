import Foundation

struct PromptPattern: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var category: PatternCategory
    var systemPrompt: String
    var description: String
    var icon: String
}

enum PatternCategory: String, CaseIterable, Identifiable {
    case analysis = "Analysis"
    case writing = "Writing"
    case research = "Research"
    case extraction = "Extraction"
    case creative = "Creative"
    case review = "Review"

    var id: String { rawValue }
}

enum PromptLibrary {
    static let patterns: [PromptPattern] = [
        PromptPattern(
            name: "Summarize",
            category: .analysis,
            systemPrompt: "Provide a clear, structured summary of the source material. Include: 1) Key thesis in one sentence, 2) 3-5 main points, 3) Notable evidence or data points, 4) Any limitations or caveats. Be concise but thorough.",
            description: "Create a structured summary with key points",
            icon: "doc.text.magnifyingglass"
        ),
        PromptPattern(
            name: "Extract Action Items",
            category: .extraction,
            systemPrompt: "Extract all action items, tasks, and todos from the source material. For each item, identify: 1) The action required, 2) Who it's assigned to (if specified), 3) Deadline or urgency, 4) Dependencies on other items. Format as a checklist.",
            description: "Pull out tasks and action items",
            icon: "checkmark.circle"
        ),
        PromptPattern(
            name: "Find Contradictions",
            category: .analysis,
            systemPrompt: "Analyze the source material for contradictions, inconsistencies, or tensions. For each contradiction found: 1) Quote the conflicting statements, 2) Explain the nature of the contradiction, 3) Suggest which claim has stronger evidence, 4) Note if the contradiction is fundamental or superficial.",
            description: "Identify conflicting claims and tensions",
            icon: "arrow.triangle.branch"
        ),
        PromptPattern(
            name: "Study Guide",
            category: .writing,
            systemPrompt: "Create a comprehensive study guide from this material. Include: 1) Key concepts with definitions, 2) Important relationships between concepts, 3) Potential exam questions (short answer and essay), 4) A quick-reference cheat sheet, 5) Suggested review schedule based on difficulty.",
            description: "Generate a study guide with Q&A",
            icon: "book"
        ),
        PromptPattern(
            name: "Rate Quality",
            category: .review,
            systemPrompt: "Rate this source material on these dimensions (1-10 scale): 1) Credibility (source authority, evidence quality), 2) Novelty (new information vs. common knowledge), 3) Actionability (how useful for practical decisions), 4) Clarity (writing quality, organization). Provide a brief justification for each score and an overall recommendation.",
            description: "Score credibility, novelty, and usefulness",
            icon: "star.fill"
        ),
        PromptPattern(
            name: "Compare Sources",
            category: .research,
            systemPrompt: "Compare and contrast the provided sources. For each source: 1) State its main argument, 2) Identify its unique contributions, 3) Note areas of agreement with other sources, 4) Highlight disagreements. End with a synthesis of what the combined sources tell us.",
            description: "Cross-reference multiple sources",
            icon: "arrow.left.arrow.right"
        ),
        PromptPattern(
            name: "Extract Key Quotes",
            category: .extraction,
            systemPrompt: "Extract the most important, quotable passages from this material. For each quote: 1) Provide the exact text, 2) Explain why it's significant, 3) Note the context it appears in, 4) Suggest how it could be used (in an essay, presentation, etc.). Select at most 5-7 quotes.",
            description: "Pull the best quotable passages",
            icon: "quote.bubble"
        ),
        PromptPattern(
            name: "Simplify",
            category: .writing,
            systemPrompt: "Rewrite this material for a general audience with no specialized knowledge. Use plain language, avoid jargon, explain technical terms, use analogies where helpful. Maintain accuracy while making the content accessible. Aim for a reading level suitable for a motivated high school student.",
            description: "Make complex content accessible",
            icon: "textformat.abc"
        ),
        PromptPattern(
            name: "Brainstorm Connections",
            category: .creative,
            systemPrompt: "Based on this material, brainstorm unexpected connections, applications, or ideas. For each connection: 1) State the idea, 2) Explain how the source material supports it, 3) Suggest how it could be developed further, 4) Rate its novelty (1-5). Aim for 5-8 creative connections.",
            description: "Generate novel connections and ideas",
            icon: "lightbulb"
        ),
        PromptPattern(
            name: "Create Flashcards",
            category: .review,
            systemPrompt: "Generate flashcards from this material for spaced repetition study. Create 10-20 cards covering the most important concepts. Each card should have: 1) A clear question on the front, 2) A concise answer on the back, 3) A difficulty rating (easy/medium/hard). Focus on concepts, not trivial details.",
            description: "Generate study flashcards",
            icon: "rectangle.stack"
        ),
        PromptPattern(
            name: "Argument Map",
            category: .analysis,
            systemPrompt: "Map out the argumentative structure of this material. Identify: 1) The central thesis/claim, 2) Supporting arguments (premises), 3) Evidence cited for each premise, 4) Any unstated assumptions, 5) Potential counterarguments. Present this as a structured argument map.",
            description: "Map thesis, premises, and evidence",
            icon: "point.3.connected.trianglepath.dotted"
        ),
        PromptPattern(
            name: "Timeline",
            category: .research,
            systemPrompt: "Extract all dates, time periods, and chronological events from this material. Present them as a structured timeline with: 1) Date/period, 2) Event or development, 3) Significance, 4) Related concepts. If dates are relative (e.g., 'last year'), note the assumed reference point.",
            description: "Extract chronological events",
            icon: "calendar"
        ),
    ]

    static func patterns(for category: PatternCategory) -> [PromptPattern] {
        patterns.filter { $0.category == category }
    }

    static func pattern(named name: String) -> PromptPattern? {
        patterns.first { $0.name == name }
    }

    static func allCategories() -> [PatternCategory] {
        PatternCategory.allCases
    }
}
