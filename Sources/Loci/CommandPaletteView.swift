import SwiftUI

private enum LociCommand: CaseIterable, Identifiable {
    case library
    case inbox
    case askLoci
    case rediscover
    case newThread
    case toggleInspector
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .library: "Open Library"
        case .inbox: "Open Inbox"
        case .askLoci: "Ask Loci"
        case .rediscover: "Open Rediscover"
        case .newThread: "New Creative Thread"
        case .toggleInspector: "Show or Hide Ask Loci"
        case .settings: "Open Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .library: "Browse every saved reference"
        case .inbox: "Process new captures"
        case .askLoci: "Ask grounded questions about your sources"
        case .rediscover: "Bring useful references back into rotation"
        case .newThread: "Start a project with a brief, board, and sources"
        case .toggleInspector: "Tailor the Ask Loci workspace"
        case .settings: "Models, privacy, integrations, and storage"
        }
    }

    var symbol: String {
        switch self {
        case .library: "square.grid.2x2"
        case .inbox: "tray"
        case .askLoci: "sparkles"
        case .rediscover: "clock.arrow.circlepath"
        case .newThread: "plus.circle"
        case .toggleInspector: "sidebar.right"
        case .settings: "gearshape"
        }
    }
}

struct CommandPaletteView: View {
    @Bindable var store: LibraryStore
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var commands: [LociCommand] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return LociCommand.allCases }
        return LociCommand.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(normalized)
                || $0.subtitle.localizedCaseInsensitiveContains(normalized)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(LociColor.inkSecondary)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(LociFont.body)
                    .focused($isSearchFocused)
                Text("⌘K")
                    .font(LociFont.badge)
                    .foregroundStyle(LociColor.inkTertiary)
            }
            .padding(LociSpacing.element)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(commands) { command in
                        Button { perform(command) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: command.symbol)
                                    .frame(width: 20)
                                    .foregroundStyle(LociColor.inkSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.title)
                                        .font(LociFont.headline)
                                        .foregroundStyle(LociColor.ink)
                                    Text(command.subtitle)
                                        .font(LociFont.caption)
                                        .foregroundStyle(LociColor.inkTertiary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, LociSpacing.element)
                            .padding(.vertical, 9)
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
        }
        .background(LociColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LociColor.hairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.16), radius: 28, y: 12)
        .onAppear { isSearchFocused = true }
        .onExitCommand { isPresented = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Palette")
    }

    private func perform(_ command: LociCommand) {
        switch command {
        case .library:
            store.selectedFilter = .all
        case .inbox:
            store.selectedFilter = .inbox
        case .askLoci:
            UserDefaults.standard.set(true, forKey: "LociNotebookInspectorVisible")
            store.selectedFilter = .chat
        case .rediscover:
            _ = ReviewScheduler.autoEnqueueForgottenReferences()
            store.selectedFilter = .review
        case .newThread:
            store.addCollection()
        case .toggleInspector:
            NotificationCenter.default.post(name: .lociToggleNotebookInspector, object: nil)
        case .settings:
            NSApp.sendAction(Selector(("openSettings")), to: nil, from: nil)
        }
        isPresented = false
    }
}
