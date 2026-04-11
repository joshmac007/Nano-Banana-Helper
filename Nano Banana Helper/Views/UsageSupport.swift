import Charts
import SwiftUI

nonisolated enum UsageTimeFilter: String, CaseIterable, Identifiable {
    case today = "Today"
    case sevenDays = "7 Days"
    case thirtyDays = "30 Days"
    case allTime = "All Time"

    var id: Self { self }

    var trailingDayCount: Int? {
        switch self {
        case .today:
            return 0
        case .sevenDays:
            return 6
        case .thirtyDays:
            return 29
        case .allTime:
            return nil
        }
    }
}

nonisolated struct UsageTotals {
    let cost: Double
    let images: Int
    let tokens: Int
    let inputTokens: Int
    let outputTokens: Int

    static let zero = UsageTotals(cost: 0, images: 0, tokens: 0, inputTokens: 0, outputTokens: 0)
}

nonisolated struct UsageDayBucket: Identifiable {
    let date: Date
    let cost: Double
    let images: Int

    var id: Date { date }
}

nonisolated struct UsageBreakdownPoint: Identifiable {
    let id: String
    let label: String
    let cost: Double
    let images: Int
}

nonisolated struct UsageActivityRow: Identifiable {
    let id: UUID
    let timestamp: Date
    let title: String
    let subtitle: String?
    let costDelta: Double
    let imageDelta: Int
}

nonisolated struct UsageSnapshot {
    let filter: UsageTimeFilter
    let totals: UsageTotals
    let filteredEntries: [UsageLedgerEntry]
    let dayBuckets: [UsageDayBucket]
    let projectBreakdown: [UsageBreakdownPoint]
    let modelBreakdown: [UsageBreakdownPoint]
    let resolutionBreakdown: [UsageBreakdownPoint]
    let recentActivity: [UsageActivityRow]
    let rangeLabel: String

    var hasEntries: Bool {
        !filteredEntries.isEmpty
    }

    var hasChartActivity: Bool {
        dayBuckets.contains { $0.cost != 0 || $0.images != 0 }
    }
}

enum UsageSnapshotBuilder {
    nonisolated static func makeSnapshot(
        entries: [UsageLedgerEntry],
        filter: UsageTimeFilter,
        now: Date = Date(),
        calendar: Calendar = .current,
        recentActivityLimit: Int = 8,
        projectDisplayName: (UUID?, String?) -> String
    ) -> UsageSnapshot {
        guard let bounds = dateBounds(for: entries, filter: filter, now: now, calendar: calendar) else {
            return UsageSnapshot(
                filter: filter,
                totals: .zero,
                filteredEntries: [],
                dayBuckets: [],
                projectBreakdown: [],
                modelBreakdown: [],
                resolutionBreakdown: [],
                recentActivity: [],
                rangeLabel: "No tracked usage yet"
            )
        }

        let filteredEntries = entries
            .filter { $0.timestamp >= bounds.start && $0.timestamp < bounds.endExclusive }
            .sorted { $0.timestamp < $1.timestamp }

        let totals = UsageTotals(
            cost: filteredEntries.reduce(0) { $0 + $1.costDelta },
            images: filteredEntries.reduce(0) { $0 + $1.imageDelta },
            tokens: filteredEntries.reduce(0) { $0 + $1.tokenDelta },
            inputTokens: filteredEntries.reduce(0) { $0 + $1.inputTokenDelta },
            outputTokens: filteredEntries.reduce(0) { $0 + $1.outputTokenDelta }
        )

        let chartEntries = filteredEntries.filter { entry in
            entry.kind != .adjustment && entry.kind != .legacyImport
        }
        let buckets = makeDayBuckets(
            entries: chartEntries,
            start: bounds.start,
            endInclusive: bounds.endInclusive,
            calendar: calendar
        )

        return UsageSnapshot(
            filter: filter,
            totals: totals,
            filteredEntries: filteredEntries,
            dayBuckets: buckets,
            projectBreakdown: groupedProjectBreakdown(filteredEntries, projectDisplayName: projectDisplayName),
            modelBreakdown: groupedBreakdown(filteredEntries, label: \.modelName),
            resolutionBreakdown: groupedBreakdown(filteredEntries, label: \.resolution),
            recentActivity: makeRecentActivity(
                filteredEntries: filteredEntries,
                limit: recentActivityLimit,
                projectDisplayName: projectDisplayName
            ),
            rangeLabel: rangeLabel(
                start: bounds.start,
                endInclusive: bounds.endInclusive,
                calendar: calendar
            )
        )
    }

    private struct DateBounds {
        let start: Date
        let endInclusive: Date
        let endExclusive: Date
    }

    private nonisolated static func dateBounds(
        for entries: [UsageLedgerEntry],
        filter: UsageTimeFilter,
        now: Date,
        calendar: Calendar
    ) -> DateBounds? {
        let today = calendar.startOfDay(for: now)

        switch filter {
        case .today, .sevenDays, .thirtyDays:
            let trailingDays = filter.trailingDayCount ?? 0
            guard let start = calendar.date(byAdding: .day, value: -trailingDays, to: today),
                  let endExclusive = calendar.date(byAdding: .day, value: 1, to: today)
            else {
                return nil
            }
            return DateBounds(start: start, endInclusive: today, endExclusive: endExclusive)

        case .allTime:
            guard let firstTimestamp = entries.map(\.timestamp).min(),
                  let lastTimestamp = entries.map(\.timestamp).max()
            else {
                return nil
            }
            let start = calendar.startOfDay(for: firstTimestamp)
            let endInclusive = calendar.startOfDay(for: lastTimestamp)
            guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: endInclusive) else {
                return nil
            }
            return DateBounds(start: start, endInclusive: endInclusive, endExclusive: endExclusive)
        }
    }

    private nonisolated static func makeDayBuckets(
        entries: [UsageLedgerEntry],
        start: Date,
        endInclusive: Date,
        calendar: Calendar
    ) -> [UsageDayBucket] {
        let grouped = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.timestamp)
        }

        var points: [UsageDayBucket] = []
        var cursor = start
        while cursor <= endInclusive {
            let dayEntries = grouped[cursor] ?? []
            points.append(
                UsageDayBucket(
                    date: cursor,
                    cost: dayEntries.reduce(0) { $0 + $1.costDelta },
                    images: dayEntries.reduce(0) { $0 + $1.imageDelta }
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }
        return points
    }

    private nonisolated static func groupedProjectBreakdown(
        _ entries: [UsageLedgerEntry],
        projectDisplayName: (UUID?, String?) -> String
    ) -> [UsageBreakdownPoint] {
        let grouped = Dictionary(grouping: entries.filter { $0.projectId != nil || $0.projectNameSnapshot != nil }) {
            $0.projectId?.uuidString ?? "snapshot:\($0.projectNameSnapshot ?? "deleted")"
        }

        return grouped
            .map { key, values in
                let first = values.first
                return UsageBreakdownPoint(
                    id: key,
                    label: projectDisplayName(first?.projectId, first?.projectNameSnapshot),
                    cost: values.reduce(0) { $0 + $1.costDelta },
                    images: values.reduce(0) { $0 + $1.imageDelta }
                )
            }
            .filter { $0.cost != 0 || $0.images != 0 }
            .sorted(by: breakdownSort)
    }

    private nonisolated static func groupedBreakdown(
        _ entries: [UsageLedgerEntry],
        label: KeyPath<UsageLedgerEntry, String?>
    ) -> [UsageBreakdownPoint] {
        let grouped = Dictionary(grouping: entries.compactMap { entry -> (String, Double, Int)? in
            guard let key = entry[keyPath: label] else { return nil }
            return (key, entry.costDelta, entry.imageDelta)
        }, by: \.0)

        return grouped
            .map { key, values in
                UsageBreakdownPoint(
                    id: key,
                    label: key,
                    cost: values.reduce(0) { $0 + $1.1 },
                    images: values.reduce(0) { $0 + $1.2 }
                )
            }
            .filter { $0.cost != 0 || $0.images != 0 }
            .sorted(by: breakdownSort)
    }

    private nonisolated static func makeRecentActivity(
        filteredEntries: [UsageLedgerEntry],
        limit: Int,
        projectDisplayName: (UUID?, String?) -> String
    ) -> [UsageActivityRow] {
        filteredEntries
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { entry in
                let title: String
                let subtitle: String?

                switch entry.kind {
                case .adjustment:
                    title = "Manual correction"
                    subtitle = entry.note ?? "Tracked usage corrected"
                case .legacyImport:
                    title = "Imported total"
                    subtitle = entry.note ?? "Legacy tracked usage import"
                case .jobCompletion:
                    title = projectDisplayName(entry.projectId, entry.projectNameSnapshot)
                    subtitle = activityDetail(for: entry)
                }

                return UsageActivityRow(
                    id: entry.id,
                    timestamp: entry.timestamp,
                    title: title,
                    subtitle: subtitle,
                    costDelta: entry.costDelta,
                    imageDelta: entry.imageDelta
                )
            }
    }

    private nonisolated static func activityDetail(for entry: UsageLedgerEntry) -> String? {
        let pieces = [entry.resolution, entry.modelName].compactMap { $0 }
        return pieces.isEmpty ? entry.note : pieces.joined(separator: " / ")
    }

    private nonisolated static func rangeLabel(start: Date, endInclusive: Date, calendar: Calendar) -> String {
        if calendar.isDate(start, inSameDayAs: endInclusive) {
            return start.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(start.formatted(date: .abbreviated, time: .omitted)) - \(endInclusive.formatted(date: .abbreviated, time: .omitted))"
    }

    private nonisolated static func breakdownSort(lhs: UsageBreakdownPoint, rhs: UsageBreakdownPoint) -> Bool {
        if lhs.cost == rhs.cost {
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        return lhs.cost > rhs.cost
    }
}

struct UsageFilterPicker: View {
    @Binding var filter: UsageTimeFilter

    var body: some View {
        Picker("Time Range", selection: $filter) {
            ForEach(UsageTimeFilter.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }
}

struct UsageSummaryCard: View {
    let title: String
    let subtitle: String?
    let metrics: [UsageSummaryMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.value)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(metric.tint)
                        Text(metric.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let detail = metric.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct UsageSummaryMetric: Identifiable {
    let title: String
    let value: String
    var detail: String?
    var tint: Color = .primary

    var id: String { title }
}

struct UsageDailyChartCard: View {
    enum Metric {
        case spend
        case images

        var title: String {
            switch self {
            case .spend:
                return "Daily Spend"
            case .images:
                return "Images By Day"
            }
        }

        var emptyTitle: String {
            switch self {
            case .spend:
                return "No spend activity in this range."
            case .images:
                return "No image activity in this range."
            }
        }
    }

    let metric: Metric
    let snapshot: UsageSnapshot
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(metric.title)
                .font(.subheadline)
                .fontWeight(.medium)

            if snapshot.dayBuckets.isEmpty || !snapshot.hasChartActivity {
                Text(metric.emptyTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
            } else {
                Chart(snapshot.dayBuckets) { point in
                    BarMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value(metric == .spend ? "Spend" : "Images", metricValue(for: point))
                    )
                    .foregroundStyle(tint.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: axisValues) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXScale(domain: chartXDomain)
                .frame(height: 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var chartXDomain: ClosedRange<Date> {
        guard let first = snapshot.dayBuckets.first, let last = snapshot.dayBuckets.last else {
            return Date()...Date()
        }
        if snapshot.dayBuckets.count <= 1 {
            let cal = Calendar.current
            let lo = cal.date(byAdding: .day, value: -1, to: first.date) ?? first.date
            let hi = cal.date(byAdding: .day, value: 1, to: last.date) ?? last.date
            return lo...hi
        }
        return first.date...last.date
    }

    private var axisValues: [Date] {
        switch snapshot.filter {
        case .today:
            return snapshot.dayBuckets.map(\.date)
        case .sevenDays:
            return strideValues(maximumCount: 7)
        case .thirtyDays:
            return strideValues(maximumCount: 6)
        case .allTime:
            return strideValues(maximumCount: 7)
        }
    }

    private func strideValues(maximumCount: Int) -> [Date] {
        guard !snapshot.dayBuckets.isEmpty else { return [] }
        let stride = max(1, Int(ceil(Double(snapshot.dayBuckets.count) / Double(maximumCount))))
        return snapshot.dayBuckets.enumerated().compactMap { index, point in
            index.isMultiple(of: stride) || index == snapshot.dayBuckets.count - 1 ? point.date : nil
        }
    }

    private func metricValue(for point: UsageDayBucket) -> Double {
        switch metric {
        case .spend:
            return point.cost
        case .images:
            return Double(point.images)
        }
    }
}

struct UsageBreakdownCard: View {
    let title: String
    let points: [UsageBreakdownPoint]
    let icon: String
    let accent: Color

    private var maxCost: Double {
        points.map(\.cost).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)

            if points.isEmpty {
                Text("No data in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(points) { point in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon)
                                .foregroundStyle(.secondary)
                            Text(point.label)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(point.cost.usageCurrency())
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if point.images != 0 {
                                    Text("\(point.images) images")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(accent.opacity(0.15))
                                Capsule()
                                    .fill(accent.gradient)
                                    .frame(width: proxy.size.width * widthRatio(for: point.cost))
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func widthRatio(for cost: Double) -> CGFloat {
        guard maxCost > 0 else { return 0 }
        return CGFloat(cost / maxCost)
    }
}

struct UsageRecentActivityCard: View {
    let rows: [UsageActivityRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.subheadline)
                .fontWeight(.medium)

            if rows.isEmpty {
                Text("No tracked usage in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(row.title)
                                .font(.subheadline)
                            if let subtitle = row.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.costDelta.usageSignedCurrency())
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(row.costDelta >= 0 ? .green : .orange)
                            if row.imageDelta != 0 {
                                Text(row.imageDelta.usageSignedImageCount())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

extension Double {
    func usageCurrency() -> String {
        formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }

    func usageSignedCurrency() -> String {
        let absolute = abs(self).formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
        return self >= 0 ? "+\(absolute)" : "-\(absolute)"
    }
}

extension Int {
    func usageSignedImageCount() -> String {
        let prefix = self >= 0 ? "+" : "-"
        let magnitude = abs(self)
        return "\(prefix)\(magnitude) image\(magnitude == 1 ? "" : "s")"
    }
}
