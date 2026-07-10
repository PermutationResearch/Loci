import SwiftUI

struct ReviewQueueView: View {
    @Bindable var store: LibraryStore
    @State private var dueItems: [ReviewItem] = []
    @State private var stats = (due: 0, reviewedToday: 0, streak: 0)
    @State private var currentReview: ReviewItem?
    @State private var showAnswer = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if let current = currentReview {
                reviewCard(current)
            } else if dueItems.isEmpty {
                emptyState
            } else {
                dueList
            }
        }
        .background(LociColor.surface)
        .task { refresh() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("REVIEW QUEUE")
                    .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                    .tracking(0.35)
                    .foregroundStyle(.black.opacity(0.40))
                Text("\(stats.due) due · \(stats.reviewedToday) reviewed today")
                    .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.78))
            }
            Spacer()
            Button {
                if let first = dueItems.first {
                    currentReview = first
                    showAnswer = false
                }
            } label: {
                Text("START")
                    .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                    .tracking(0.2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.78), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(dueItems.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func reviewCard(_ item: ReviewItem) -> some View {
        VStack(spacing: 20) {
            Spacer()
            if let ref = store.items.first(where: { $0.id == item.referenceID }) {
                VStack(spacing: 8) {
                    Text(ref.title)
                        .lociFont(size: 16, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(.black.opacity(0.82))
                        .multilineTextAlignment(.center)
                    Text(ref.fileName)
                        .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(.black.opacity(0.42))
                }
                .padding(.horizontal, 24)

                if showAnswer {
                    VStack(spacing: 6) {
                        Text("Review #\(item.reviewCount + 1)")
                            .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                            .foregroundStyle(.black.opacity(0.35))
                        Text("Interval: \(Int(item.intervalDays)) days")
                            .lociFont(size: 10, weight: .medium, relativeTo: .caption2)
                            .foregroundStyle(.black.opacity(0.48))
                    }
                    .padding(.top, 8)

                    HStack(spacing: 12) {
                        reviewButton(quality: 1, label: "Again", color: .red)
                        reviewButton(quality: 3, label: "Hard", color: .orange)
                        reviewButton(quality: 4, label: "Good", color: .green)
                        reviewButton(quality: 5, label: "Easy", color: .blue)
                    }
                    .padding(.top, 12)
                } else {
                    Button {
                        showAnswer = true
                    } label: {
                        Text("Show Answer")
                            .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(.white)
                            .frame(maxWidth: 200)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }

    private func reviewButton(quality: Int, label: String, color: Color) -> some View {
        Button {
            if let current = currentReview {
                ReviewScheduler.recordReview(id: current.id, quality: quality)
                dueItems.removeAll { $0.id == current.id }
                currentReview = dueItems.first
                showAnswer = false
                refresh()
            }
        } label: {
            Text(label)
                .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(.white)
                .frame(width: 64, height: 36)
                .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .lociFont(size: 36, weight: .semibold, relativeTo: .title)
                .foregroundStyle(.green.opacity(0.4))
            Text("All caught up!")
                .lociFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(.black.opacity(0.62))
            Text("No documents due for review")
                .lociFont(size: 11, weight: .medium, relativeTo: .caption)
                .foregroundStyle(.black.opacity(0.38))
            Spacer()
        }
    }

    private var dueList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(dueItems) { item in
                    if let ref = store.items.first(where: { $0.id == item.referenceID }) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(item.intervalDays < 1 ? .red : item.intervalDays < 7 ? .orange : .green)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ref.title)
                                    .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                                    .foregroundStyle(.black.opacity(0.72))
                                    .lineLimit(1)
                                Text("Every \(Int(item.intervalDays)) days · \(item.reviewCount) reviews")
                                    .lociFont(size: 9, weight: .medium, relativeTo: .caption2)
                                    .foregroundStyle(.black.opacity(0.38))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 88)
        }
    }

    private func refresh() {
        dueItems = ReviewScheduler.dueItems()
        stats = ReviewScheduler.stats()
    }
}
