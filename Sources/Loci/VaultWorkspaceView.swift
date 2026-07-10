import SwiftUI
import Dispatch

struct VaultWorkspaceView: View {
    @Bindable var store: LibraryStore
    @State private var selectedLayer = "wiki"
    @State private var query = ""
    @State private var snapshot = VaultWorkspaceSnapshot.empty
    @State private var fileMonitor: VaultFileMonitor?

    private let layers = ["raw", "wiki", "system", "outputs"]
    private let primaryText = Color.black.opacity(0.76)
    private let secondaryText = Color.black.opacity(0.48)

    var body: some View {
        ZStack {
            Color.white

            VStack(alignment: .leading, spacing: 14) {
                header
                stats
                controls
                content
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .foregroundStyle(.black.opacity(0.76))
        .task {
            reload()
            let monitor = VaultFileMonitor { Task { @MainActor in reload() } }
            monitor.start()
            fileMonitor = monitor
        }
        .onDisappear {
            fileMonitor?.stop()
            fileMonitor = nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CREATIVE MEMORY")
                    .lociFont(size: 10, weight: .bold, relativeTo: .caption2)
                    .tracking(0.35)
                    .foregroundStyle(.black.opacity(0.45))
                Text("Raw sources, compiled wiki, graph, outputs, and queue")
                    .lociFont(size: 12, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.48))
            }
            Spacer()
            Button {
                Task { await ImportCoordinator.shared.enqueueProcess() }
                reload()
            } label: {
                Label("Run Compiler", systemImage: "play.fill")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 10) {
            VaultStat(title: "Raw", value: "\(snapshot.rawCount)", symbol: "archivebox")
            VaultStat(title: "Wiki", value: "\(snapshot.wikiCount)", symbol: "doc.text")
            VaultStat(title: "Graph", value: "\(store.graphNodeCount)/\(store.graphEdgeCount)", symbol: "point.3.connected.trianglepath.dotted")
            VaultStat(title: "Queue", value: "\(store.storageStats.queuedImportCount)", symbol: "list.bullet.rectangle")
            VaultStat(title: "Outputs", value: "\(snapshot.outputCount)", symbol: "square.and.arrow.down")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerSegmentedControl(layers: layers, selectedLayer: $selectedLayer)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.black.opacity(0.35))
                    .accessibilityHidden(true)
                TextField("Search wiki and outputs", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(primaryText)
                    .tint(.black)
                    .onSubmit { reload() }
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(secondaryText)
                }
                .buttonStyle(.plain)
                .help("Refresh vault view")
                .accessibilityLabel("Refresh vault view")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            layerList
            queueList
        }
    }

    private var layerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedLayer.uppercased())
                .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                .tracking(0.3)
                .foregroundStyle(.black.opacity(0.42))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    let rows = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? snapshot.files(for: selectedLayer)
                        : snapshot.searchRows
                    ForEach(rows, id: \.self) { row in
                        VaultFileRow(
                            row: row,
                            canReview: selectedLayer == "wiki" || row.contains("/wiki/"),
                            onApprove: {
                                MarkdownVault.markWikiPageReviewed(relativePath: relativePath(from: row))
                                reload()
                            },
                            onPromote: {
                                MarkdownVault.promoteWikiPage(relativePath: relativePath(from: row))
                                reload()
                            }
                        )
                    }
                    if rows.isEmpty {
                        Text("No files yet.")
                            .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                            .foregroundStyle(secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 8) {
            graphPanel

            Text("COMPILE QUEUE")
                .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                .tracking(0.3)
                .foregroundStyle(.black.opacity(0.42))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.importJobs.prefix(18)) { job in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(color(for: job.status))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(job.source.rawValue) · \(job.status.rawValue)")
                                    .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                                    .foregroundStyle(.black.opacity(0.72))
                                Text(job.payload)
                                    .lociFont(size: 9, weight: .medium, relativeTo: .caption2)
                                    .lineLimit(2)
                                    .foregroundStyle(.black.opacity(0.40))
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
    }

    private var graphPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BACKLINKS / GRAPH")
                .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                .tracking(0.3)
                .foregroundStyle(.black.opacity(0.42))

            VStack(alignment: .leading, spacing: 6) {
                if snapshot.graphRows.isEmpty {
                    Text("No graph links yet.")
                        .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                        .foregroundStyle(secondaryText)
                } else {
                    VaultGraphCanvas(rows: snapshot.graphRows)
                        .frame(height: 120)

                    ForEach(snapshot.graphRows.prefix(6), id: \.self) { row in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right")
                                .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                                .foregroundStyle(.black.opacity(0.34))
                            Text(row)
                                .lociFont(size: 9, weight: .medium, relativeTo: .caption2)
                                .lineLimit(1)
                                .foregroundStyle(.black.opacity(0.48))
                        }
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.028), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func color(for status: ImportJobStatus) -> Color {
        switch status {
        case .queued: .orange
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .gray
        }
    }

    private func reload() {
        let query = query
        Task.detached(priority: .userInitiated) {
            let newSnapshot = VaultWorkspaceSnapshot.load(query: query)
            await MainActor.run {
                snapshot = newSnapshot
            }
        }
    }

    private func relativePath(from row: String) -> String {
        let path = row.components(separatedBy: "\t").last ?? row
        let rootPrefix = MarkdownVault.defaultVaultURL().path + "/"
        if path.hasPrefix(rootPrefix) {
            return String(path.dropFirst(rootPrefix.count))
        }
        return path
    }
}

private struct VaultStat: View {
    var title: String
    var value: String
    var symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(.black.opacity(0.48))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .lociFont(size: 15, weight: .bold, design: .rounded, relativeTo: .headline)
                    .monospacedDigit()
                    .foregroundStyle(.black.opacity(0.78))
                Text(title)
                    .lociFont(size: 9, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.44))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct VaultGraphCanvas: View {
    let rows: [String]

    private var edges: [(source: String, target: String)] {
        rows.compactMap { row in
            let parts = row.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (source: parts[0], target: parts[1])
        }
    }

    private var nodes: [String] {
        Array(Set(edges.flatMap { [$0.source, $0.target] }))
            .sorted()
            .prefix(10)
            .map { $0 }
    }

    var body: some View {
        GeometryReader { proxy in
            let positions = positions(in: proxy.size)
            ZStack {
                ForEach(Array(edges.enumerated()), id: \.offset) { _, edge in
                    if let start = positions[edge.source], let end = positions[edge.target] {
                        Path { path in
                            path.move(to: start)
                            path.addLine(to: end)
                        }
                        .stroke(Color.black.opacity(0.14), lineWidth: 1)
                    }
                }

                ForEach(nodes, id: \.self) { node in
                    if let point = positions[node] {
                        VStack(spacing: 3) {
                            Circle()
                                .fill(Color.black.opacity(0.68))
                                .frame(width: 8, height: 8)
                            Text(shortName(node))
                                .lociFont(size: 7, weight: .semibold, relativeTo: .caption2)
                                .lineLimit(1)
                                .foregroundStyle(.black.opacity(0.52))
                                .frame(width: 58)
                        }
                        .position(point)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(8)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private func positions(in size: CGSize) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radiusX = max(32, size.width * 0.36)
        let radiusY = max(24, size.height * 0.28)
        var result: [String: CGPoint] = [:]
        let count = max(1, nodes.count)
        for (index, node) in nodes.enumerated() {
            let angle = (Double(index) / Double(count)) * Double.pi * 2 - Double.pi / 2
            result[node] = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radiusX,
                y: center.y + CGFloat(sin(angle)) * radiusY
            )
        }
        return result
    }

    private func shortName(_ value: String) -> String {
        let trimmed = value.replacingOccurrences(of: "-", with: " ")
        return String(trimmed.prefix(18))
    }
}

private struct LayerSegmentedControl: View {
    let layers: [String]
    @Binding var selectedLayer: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(layers, id: \.self) { layer in
                Button {
                    selectedLayer = layer
                } label: {
                    Text(layer)
                        .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(selectedLayer == layer ? Color.white : Color.black.opacity(0.58))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selectedLayer == layer ? Color.black.opacity(0.72) : Color.clear)
                )
                .help(layer)
            }
        }
        .padding(3)
        .frame(height: 38)
        .background(Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct VaultFileRow: View {
    var row: String
    var canReview: Bool = false
    var onApprove: () -> Void = {}
    var onPromote: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                .foregroundStyle(.black.opacity(0.34))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.74))
                    .lineLimit(1)
                Text(detail)
                    .lociFont(size: 9, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.40))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if canReview {
                Button(action: onApprove) {
                    Image(systemName: "checkmark.seal")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black.opacity(0.42))
                .help("Mark reviewed")
                .accessibilityLabel("Mark reviewed")

                Button(action: onPromote) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black.opacity(0.42))
                .help("Promote to outputs")
                .accessibilityLabel("Promote to outputs")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.028), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var title: String {
        row.components(separatedBy: "\t").dropFirst().first ?? URL(fileURLWithPath: row).lastPathComponent
    }

    private var detail: String {
        row.components(separatedBy: "\t").last ?? row
    }

    private var icon: String {
        if row.contains("/raw/") { return "archivebox" }
        if row.contains("/outputs/") { return "square.and.arrow.down" }
        if row.contains("/system/") { return "gearshape" }
        return "doc.text"
    }
}

private struct VaultWorkspaceSnapshot: Hashable {
    var rawCount: Int
    var wikiCount: Int
    var systemCount: Int
    var outputCount: Int
    var graphRows: [String]
    var rawFiles: [String]
    var wikiFiles: [String]
    var systemFiles: [String]
    var outputFiles: [String]
    var searchRows: [String]

    static let empty = VaultWorkspaceSnapshot(
        rawCount: 0,
        wikiCount: 0,
        systemCount: 0,
        outputCount: 0,
        graphRows: [],
        rawFiles: [],
        wikiFiles: [],
        systemFiles: [],
        outputFiles: [],
        searchRows: []
    )

    func files(for layer: String) -> [String] {
        switch layer {
        case "raw": rawFiles
        case "system": systemFiles
        case "outputs": outputFiles
        default: wikiFiles
        }
    }

    static func load(query: String) -> VaultWorkspaceSnapshot {
        let root = MarkdownVault.defaultVaultURL()
        let raw = rows(in: root.appendingPathComponent("raw", isDirectory: true))
        let wiki = rows(in: root.appendingPathComponent("wiki", isDirectory: true))
        let system = rows(in: root.appendingPathComponent("system", isDirectory: true))
        let outputs = rows(in: root.appendingPathComponent("outputs", isDirectory: true))
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return VaultWorkspaceSnapshot(
            rawCount: raw.count,
            wikiCount: wiki.count,
            systemCount: system.count,
            outputCount: outputs.count,
            graphRows: graphRows(root: root),
            rawFiles: raw,
            wikiFiles: wiki,
            systemFiles: system,
            outputFiles: outputs,
            searchRows: trimmed.isEmpty ? [] : WikiCompiler.search(query: trimmed)
        )
    }

    private static func rows(in directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> (Date, String)? in
            guard let url = item as? URL else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { return nil }
            let title = url.deletingPathExtension().lastPathComponent
            let relative = url.path.replacingOccurrences(of: MarkdownVault.defaultVaultURL().path + "/", with: "")
            return (values?.contentModificationDate ?? .distantPast, "1\t\(title)\t\(relative)")
        }
        .sorted { $0.0 > $1.0 }
        .prefix(80)
        .map(\.1)
    }

    private static func graphRows(root: URL) -> [String] {
        let graphURL = root.appendingPathComponent("system/graph.md")
        guard let content = try? String(contentsOf: graphURL, encoding: .utf8) else {
            return []
        }

        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("- ") && $0.contains("->") }
            .map { row in
                row
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "[[", with: "")
                    .replacingOccurrences(of: "]]", with: "")
            }
            .enumerated()
            .filter { $0.offset < 10 }
            .map { String($0.element) }
    }
}

private final class VaultFileMonitor {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let queue = DispatchQueue(label: "com.loci.vaultmonitor", qos: .utility)
    private var debounceWork: DispatchWorkItem?
    private let onChange: @MainActor @Sendable () -> Void

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        let vaultURL = MarkdownVault.defaultVaultURL()
        let dirs = ["raw", "wiki", "system", "outputs"].map { vaultURL.appendingPathComponent($0, isDirectory: true) }

        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.debouncedNotify()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }

    private func debouncedNotify() {
        debounceWork?.cancel()
        let handler = onChange
        let work = DispatchWorkItem {
            Task { @MainActor in
                handler()
            }
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
