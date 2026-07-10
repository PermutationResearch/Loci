import SwiftUI

struct TimelineView: View {
    @Bindable var store: LibraryStore
    @State private var timelineItems: [TimelineEntry] = []
    @State private var selectedPeriod: TimePeriod = .all

    enum TimePeriod: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "This Week"
        case month = "This Month"
        case all = "All Time"
        var id: String { rawValue }
    }

    struct TimelineEntry: Identifiable {
        var id: UUID
        var date: Date
        var title: String
        var subtitle: String
        var type: EntryType
        var itemID: ReferenceItem.ID?

        enum EntryType: String {
            case imported = "Imported"
            case compiled = "Compiled"
            case reviewed = "Reviewed"
            case shared = "Shared"
        }

        var icon: String {
            switch type {
            case .imported: "arrow.down.circle.fill"
            case .compiled: "sparkles"
            case .reviewed: "eye"
            case .shared: "square.and.arrow.up"
            }
        }

        var color: Color {
            switch type {
            case .imported: .blue
            case .compiled: .purple
            case .reviewed: .green
            case .shared: .orange
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            periodPicker
            Divider().opacity(0.2)
            timelineList
        }
        .background(Color.white)
        .task { buildTimeline() }
        .onChange(of: selectedPeriod) { _, _ in buildTimeline() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("TIMELINE")
                    .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                    .tracking(0.35)
                    .foregroundStyle(.black.opacity(0.40))
                Text("\(timelineItems.count) events")
                    .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.78))
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var periodPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(TimePeriod.allCases) { period in
                    Button {
                        selectedPeriod = period
                    } label: {
                        Text(period.rawValue)
                            .lociFont(size: 9.5, weight: selectedPeriod == period ? .semibold : .medium, relativeTo: .caption2)
                            .foregroundStyle(selectedPeriod == period ? .black.opacity(0.82) : .black.opacity(0.46))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background {
                                Capsule()
                                    .fill(selectedPeriod == period ? Color.black.opacity(0.055) : Color.clear)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 8)
    }

    private var timelineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let grouped = Dictionary(grouping: timelineItems) { Calendar.current.startOfDay(for: $0.date) }
                ForEach(grouped.keys.sorted().reversed(), id: \.self) { day in
                    dayHeader(day)
                    ForEach(grouped[day] ?? []) { entry in
                        timelineRow(entry)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 88)
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        HStack {
            Circle()
                .fill(Color.black.opacity(0.12))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(day.formatted(.dateTime.weekday(.wide).month().day()))
                .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                .foregroundStyle(.black.opacity(0.40))
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func timelineRow(_ entry: TimelineEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .fill(entry.color)
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .frame(width: 1)
            }
            .frame(width: 8)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: entry.icon)
                        .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(entry.color)
                    Text(entry.type.rawValue)
                        .lociFont(size: 8, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(entry.color)
                }
                Text(entry.title)
                    .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black.opacity(0.72))
                    .lineLimit(1)
                Text(entry.subtitle)
                    .lociFont(size: 9.5, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.40))
                    .lineLimit(1)
                Text(entry.date.formatted(.dateTime.hour().minute()))
                    .lociFont(size: 8, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(.black.opacity(0.55))
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
    }

    private func buildTimeline() {
        var entries: [TimelineEntry] = []

        for item in store.items where !item.isTrashed {
            entries.append(TimelineEntry(
                id: UUID(),
                date: Date().addingTimeInterval(-Double.random(in: 0...604800)),
                title: item.title,
                subtitle: item.fileName,
                type: .imported,
                itemID: item.id
            ))
        }

        let cutoff: Date
        switch selectedPeriod {
        case .today: cutoff = Calendar.current.startOfDay(for: Date())
        case .week: cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        case .month: cutoff = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        case .all: cutoff = Date.distantPast
        }

        timelineItems = entries.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
    }
}
