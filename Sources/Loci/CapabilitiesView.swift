import AppKit
import SwiftUI

enum CapabilityStatus: Equatable {
    case active
    case ready
    case needsSetup
    case selectionNeeded

    var title: String {
        switch self {
        case .active:
            "Active"
        case .ready:
            "Ready"
        case .needsSetup:
            "Needs setup"
        case .selectionNeeded:
            "Select item"
        }
    }

    var foreground: Color {
        switch self {
        case .active:
            Color(red: 0.02, green: 0.42, blue: 0.20)
        case .ready:
            Color.black.opacity(0.64)
        case .needsSetup:
            Color(red: 0.58, green: 0.35, blue: 0.05)
        case .selectionNeeded:
            Color.black.opacity(0.44)
        }
    }

    var background: Color {
        switch self {
        case .active:
            Color(red: 0.90, green: 0.97, blue: 0.92)
        case .ready:
            Color.black.opacity(0.045)
        case .needsSetup:
            Color(red: 1.00, green: 0.95, blue: 0.84)
        case .selectionNeeded:
            Color.black.opacity(0.028)
        }
    }
}

enum CapabilityAction: Hashable {
    case paste
    case screenshot
    case filter(CollectionFilter)
    case mode(ViewMode)
    case addCollection
    case generateVariation
    case xSettings
    case none
}

struct LociCapability: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let group: String
    let symbol: String
    let actionTitle: String
    let action: CapabilityAction

    static let all: [LociCapability] = [
        .init(
            id: "capture",
            title: "Drag, paste, screenshot",
            detail: "Clipboard and screenshot capture are wired into the import system.",
            group: "Capture",
            symbol: "square.and.arrow.down.on.square",
            actionTitle: "Paste",
            action: .paste
        ),
        .init(
            id: "x-bookmark-sync",
            title: "X bookmark sync",
            detail: "Connect X with OAuth, import bookmarks, and tag saved posts automatically.",
            group: "Capture",
            symbol: "bookmark.fill",
            actionTitle: "Setup",
            action: .xSettings
        ),
        .init(
            id: "visual-search",
            title: "AI visual search",
            detail: "Local Vision feature prints are available for finding similar references.",
            group: "Search",
            symbol: "sparkle.magnifyingglass",
            actionTitle: "Search",
            action: .filter(.all)
        ),
        .init(
            id: "color-search",
            title: "Search by color",
            detail: "Dominant color extraction is available for hue-based discovery.",
            group: "Search",
            symbol: "eyedropper.halffull",
            actionTitle: "Search",
            action: .filter(.all)
        ),
        .init(
            id: "infinite-spaces",
            title: "Infinite spaces",
            detail: "Switch from the grid into an open spatial workspace.",
            group: "Space",
            symbol: "infinity",
            actionTitle: "Open",
            action: .mode(.infinity)
        ),
        .init(
            id: "local-first",
            title: "Local-first library",
            detail: "Originals, thumbnails, extracted text, and vault output stay on this Mac.",
            group: "Library",
            symbol: "externaldrive.fill",
            actionTitle: "Files",
            action: .filter(.files)
        ),
        .init(
            id: "libraries",
            title: "Unlimited libraries",
            detail: "Create separate spaces for client work, research, archives, and references.",
            group: "Library",
            symbol: "rectangle.stack.fill",
            actionTitle: "New",
            action: .addCollection
        ),
        .init(
            id: "auto-tagging",
            title: "Auto-tagging",
            detail: "Rules can organize imports by source, type, and recurring patterns.",
            group: "Organize",
            symbol: "tag.fill",
            actionTitle: "Rules",
            action: .filter(.rules)
        ),
        .init(
            id: "variations",
            title: "Generate variations",
            detail: "Create color-shifted, cropped, flipped, and adjusted versions from a selection.",
            group: "Create",
            symbol: "wand.and.stars",
            actionTitle: "Create",
            action: .generateVariation
        ),
        .init(
            id: "rediscover",
            title: "Rediscover mode",
            detail: "Review due references and bring older material back into rotation.",
            group: "Organize",
            symbol: "clock.arrow.circlepath",
            actionTitle: "Review",
            action: .filter(.review)
        )
    ]
}

struct CapabilitiesView: View {
    @Bindable var store: LibraryStore
    @Environment(\.undoManager) private var undoManager
    @StateObject private var xOAuth = XOAuthManager.shared

    private let groups = ["Capture", "Search", "Space", "Library", "Organize", "Create"]

    private var groupedCapabilities: [(String, [LociCapability])] {
        groups.compactMap { group in
            let items = LociCapability.all.filter { $0.group == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    private var activeCount: Int {
        LociCapability.all.filter { status(for: $0) == .active }.count
    }

    private var readyCount: Int {
        LociCapability.all.filter { status(for: $0) == .ready }.count
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header

                    VStack(spacing: 14) {
                        ForEach(groupedCapabilities, id: \.0) { group, capabilities in
                            CapabilitySection(
                                group: group,
                                capabilities: capabilities,
                                status: status,
                                metric: metric,
                                isEnabled: isEnabled,
                                perform: perform
                            )
                        }
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.top, 84)
                .padding(.horizontal, 38)
                .padding(.bottom, 112)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "checklist.checked")
                    .lociFont(size: 17, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(.black.opacity(0.56))
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Capabilities")
                        .lociFont(size: 22, weight: .semibold, relativeTo: .title)
                        .foregroundStyle(.black.opacity(0.86))

                    Text("What is wired, what is active, and what still needs setup.")
                        .lociFont(size: 12.5, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(.black.opacity(0.48))
                }

                Spacer(minLength: 16)
            }

            HStack(spacing: 8) {
                StatusSummaryPill(value: "\(LociCapability.all.count)", label: "features")
                StatusSummaryPill(value: "\(activeCount)", label: "active")
                StatusSummaryPill(value: "\(readyCount)", label: "ready")
                StatusSummaryPill(value: "\(store.count(for: .all))", label: "items")
            }
        }
    }

    private func status(for capability: LociCapability) -> CapabilityStatus {
        switch capability.id {
        case "capture", "visual-search", "color-search", "infinite-spaces", "libraries":
            .ready
        case "x-bookmark-sync":
            xOAuth.status.canSyncBookmarks ? .active : .needsSetup
        case "local-first":
            store.count(for: .all) > 0 ? .active : .ready
        case "auto-tagging":
            AutoRulesEngine.allRules().contains(where: \.isEnabled) ? .active : .ready
        case "variations":
            store.selectedItemIDs.isEmpty ? .selectionNeeded : .ready
        case "rediscover":
            ReviewScheduler.stats().due > 0 ? .active : .ready
        default:
            .ready
        }
    }

    private func metric(for capability: LociCapability) -> String {
        switch capability.id {
        case "capture":
            "\(store.count(for: .inbox)) inbox"
        case "x-bookmark-sync":
            "\(TagHierarchy.referencesForTag("x-bookmarked").count) tagged"
        case "visual-search", "color-search":
            "\(store.count(for: .all)) searchable"
        case "infinite-spaces":
            store.mode == .infinity ? "open" : "available"
        case "local-first":
            "\(store.count(for: .files)) files"
        case "libraries":
            "\(store.collections.count) libraries"
        case "auto-tagging":
            "\(AutoRulesEngine.allRules().count) rules"
        case "variations":
            "\(store.selectedItemIDs.count) selected"
        case "rediscover":
            "\(ReviewScheduler.stats().due) due"
        default:
            ""
        }
    }

    private func isEnabled(_ capability: LociCapability) -> Bool {
        switch capability.action {
        case .generateVariation:
            !store.selectedItemIDs.isEmpty
        case .none:
            false
        default:
            true
        }
    }

    private func perform(_ capability: LociCapability) {
        switch capability.action {
        case .paste:
            store.importPasteboard(undoManager: undoManager)
        case .screenshot:
            store.importScreenshot(undoManager: undoManager)
        case .filter(let filter):
            store.selectedFilter = filter
        case .mode(let mode):
            store.mode = mode
            store.selectedFilter = .all
        case .addCollection:
            store.addCollection(undoManager: undoManager)
        case .generateVariation:
            guard let item = store.items.first(where: { store.selectedItemIDs.contains($0.id) }) else { return }
            store.generateVariation(of: .colorShift, for: item, undoManager: undoManager)
        case .xSettings:
            NSApp.sendAction(Selector(("openSettings")), to: nil, from: nil)
        case .none:
            break
        }
    }
}

private struct CapabilitySection: View {
    let group: String
    let capabilities: [LociCapability]
    let status: (LociCapability) -> CapabilityStatus
    let metric: (LociCapability) -> String
    let isEnabled: (LociCapability) -> Bool
    let perform: (LociCapability) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(group.uppercased())
                .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                .tracking(0.5)
                .foregroundStyle(.black.opacity(0.36))

            VStack(spacing: 0) {
                ForEach(capabilities) { capability in
                    CapabilityRow(
                        capability: capability,
                        status: status(capability),
                        metric: metric(capability),
                        isEnabled: isEnabled(capability),
                        perform: { perform(capability) }
                    )

                    if capability.id != capabilities.last?.id {
                        Divider()
                            .overlay(Color.black.opacity(0.035))
                            .padding(.leading, 48)
                    }
                }
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
            }
        }
    }
}

private struct CapabilityRow: View {
    let capability: LociCapability
    let status: CapabilityStatus
    let metric: String
    let isEnabled: Bool
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: capability.symbol)
                .lociFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(.black.opacity(0.54))
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.028), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(capability.title)
                        .lociFont(size: 12.5, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.black.opacity(0.82))
                        .lineLimit(1)

                    Text(metric)
                        .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                        .foregroundStyle(.black.opacity(0.36))
                        .lineLimit(1)
                }

                Text(capability.detail)
                    .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.48))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            StatusChip(status: status)

            Button(action: perform) {
                Text(capability.actionTitle)
                    .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(isEnabled ? Color.black.opacity(0.74) : Color.black.opacity(0.28))
                    .frame(minWidth: 58)
            }
            .buttonStyle(.plain)
            .frame(height: 28)
            .padding(.horizontal, 9)
            .background(Color.black.opacity(isEnabled ? 0.04 : 0.02), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.black.opacity(isEnabled ? 0.07 : 0.035), lineWidth: 1)
            }
            .disabled(!isEnabled)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct StatusChip: View {
    let status: CapabilityStatus

    var body: some View {
        Text(status.title)
            .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
            .foregroundStyle(status.foreground)
            .lineLimit(1)
            .frame(minWidth: 66)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(status.background, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.black.opacity(0.045), lineWidth: 1)
            }
    }
}

private struct StatusSummaryPill: View {
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(value)
                .lociFont(size: 11, weight: .semibold, design: .rounded, relativeTo: .caption)
                .monospacedDigit()
                .foregroundStyle(.black.opacity(0.72))

            Text(label.uppercased())
                .lociFont(size: 7, weight: .bold, relativeTo: .caption2)
                .tracking(0.35)
                .foregroundStyle(.black.opacity(0.34))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.black.opacity(0.035), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.black.opacity(0.055), lineWidth: 1)
        }
    }
}
