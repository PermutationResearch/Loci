import SwiftUI

struct PatternLibraryView: View {
    @Bindable var store: LibraryStore
    @State private var selectedPattern: PromptPattern?
    @State private var selectedCategory: PatternCategory?
    @State private var customInput = ""
    @State private var result = ""
    @State private var isRunning = false

    var body: some View {
        HStack(spacing: 0) {
            patternSidebar
                .frame(width: 260)
                .background(Color(red: 0.98, green: 0.98, blue: 0.97))

            Divider().opacity(0.3)

            patternDetail
        }
        .background(Color.white)
    }

    private var patternSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PATTERNS")
                        .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                        .tracking(0.35)
                        .foregroundStyle(.black.opacity(0.40))
                    Text("\(PromptLibrary.patterns.count) prompt templates")
                        .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(.black.opacity(0.48))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    categoryPill(nil, label: "All")
                    ForEach(PatternCategory.allCases) { cat in
                        categoryPill(cat, label: cat.rawValue)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 10)

            Divider().opacity(0.2)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredPatterns) { pattern in
                        patternRow(pattern)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 88)
            }
        }
    }

    private func categoryPill(_ category: PatternCategory?, label: String) -> some View {
        Button {
            selectedCategory = category
        } label: {
            Text(label)
                .lociFont(size: 9, weight: selectedCategory == category ? .semibold : .medium, relativeTo: .caption2)
                .foregroundStyle(selectedCategory == category ? .black.opacity(0.82) : .black.opacity(0.46))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background {
                    Capsule()
                        .fill(selectedCategory == category ? Color.black.opacity(0.055) : Color.clear)
                }
        }
        .buttonStyle(.plain)
    }

    private func patternRow(_ pattern: PromptPattern) -> some View {
        Button {
            selectedPattern = pattern
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pattern.icon)
                    .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.38))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pattern.name)
                        .lociFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(.black.opacity(0.72))
                    Text(pattern.description)
                        .lociFont(size: 9, weight: .medium, relativeTo: .caption2)
                        .foregroundStyle(.black.opacity(0.38))
                        .lineLimit(1)
                }
                Spacer()
                Text(pattern.category.rawValue)
                    .lociFont(size: 7.5, weight: .bold, design: .rounded, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.28))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedPattern?.id == pattern.id ? Color.black.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var filteredPatterns: [PromptPattern] {
        if let cat = selectedCategory {
            return PromptLibrary.patterns(for: cat)
        }
        return PromptLibrary.patterns
    }

    private var patternDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pattern = selectedPattern {
                HStack(spacing: 8) {
                    Image(systemName: pattern.icon)
                        .lociFont(size: 18, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(.black.opacity(0.40))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pattern.name)
                            .lociFont(size: 16, weight: .semibold, relativeTo: .headline)
                            .foregroundStyle(.black.opacity(0.82))
                        Text(pattern.category.rawValue)
                            .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                            .foregroundStyle(.black.opacity(0.35))
                    }
                    Spacer()
                }

                Text(pattern.description)
                    .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.52))

                Divider().opacity(0.2)

                Text("SYSTEM PROMPT")
                    .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                    .tracking(0.3)
                    .foregroundStyle(.black.opacity(0.35))

                ScrollView {
                    Text(pattern.systemPrompt)
                        .lociFont(size: 10, design: .monospaced, relativeTo: .caption2)
                        .foregroundStyle(.black.opacity(0.58))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(10)
                .background(Color.black.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Divider().opacity(0.2)

                patternInputComposer(for: pattern)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "wand.and.stars")
                        .lociFont(size: 32, weight: .semibold, relativeTo: .title)
                        .foregroundStyle(.black.opacity(0.15))
                    Text("Select a pattern")
                        .lociFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.black.opacity(0.48))
                    Text("Choose a prompt template from the left to get started")
                        .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(.black.opacity(0.32))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
    }

    private var canSendPatternInput: Bool {
        !customInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func patternInputComposer(for pattern: PromptPattern) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INPUT")
                .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                .tracking(0.3)
                .foregroundStyle(.black.opacity(0.35))

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Add context, notes, or a source excerpt...",
                    text: $customInput,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lociFont(size: 12, relativeTo: .caption)
                .lineLimit(3...7)
                .foregroundStyle(.black.opacity(0.78))
                .tint(.black)
                .padding(.vertical, 8)

                Button {
                    sendToNotebook(pattern: pattern)
                } label: {
                    Image(systemName: "arrow.up")
                        .lociFont(size: 12, weight: .bold, relativeTo: .caption)
                        .foregroundStyle(.white)
                        .frame(width: 27, height: 27)
                        .background(canSendPatternInput ? Color.black.opacity(0.78) : Color.black.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSendPatternInput)
                .accessibilityLabel("Send to Notebook")
            }
            .padding(.leading, 14)
            .padding(.trailing, 9)
            .padding(.vertical, 8)
            .frame(minHeight: 82, alignment: .top)
            .background(Color(red: 0.985, green: 0.985, blue: 0.982), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.075), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 10, y: 5)
        }
    }

    private func sendToNotebook(pattern: PromptPattern) {
        store.selectedFilter = .chat
        customInput = ""
    }
}
