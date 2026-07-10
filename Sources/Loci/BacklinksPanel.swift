import SwiftUI

struct BacklinksPanel: View {
    var slug: String
    var vaultRoot: URL
    @State private var backlinks: [BacklinksResult] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.40))
                Text("BACKLINKS")
                    .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                    .tracking(0.3)
                    .foregroundStyle(.black.opacity(0.40))
                Spacer()
                Text("\(backlinks.count)")
                    .lociFont(size: 9, weight: .semibold, design: .rounded, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.35))
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            } else if backlinks.isEmpty {
                Text("No backlinks yet")
                    .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.30))
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(backlinks) { link in
                            BacklinkRow(link: link)
                        }
                    }
                }
            }
        }
        .task(id: slug) {
            isLoading = true
            let slug = slug
            let root = vaultRoot
            backlinks = await Task.detached(priority: .userInitiated) {
                BacklinksEngine.backlinks(for: slug, vaultRoot: root)
            }.value
            isLoading = false
        }
    }
}

private struct BacklinkRow: View {
    var link: BacklinksResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.30))
                Text(link.sourceTitle)
                    .lociFont(size: 10, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.70))
                    .lineLimit(1)
            }
            if !link.contextSnippet.isEmpty {
                Text(link.contextSnippet)
                    .lociFont(size: 9, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.40))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.02), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
