import AppKit
import Charts
import SwiftUI

struct UsageDashboardView: View {
    @Environment(ProjectManager.self) private var projectManager
    @Environment(HistoryManager.self) private var historyManager
    @State private var selectedTimeFilter: TimeFilter = .allTime
    @State private var exportStatusMessage: String?

    enum TimeFilter: String, CaseIterable {
        case today = "Today"
        case sevenDays = "7 Days"
        case thirtyDays = "30 Days"
        case allTime = "All Time"
    }

    private var filteredEntries: [HistoryEntry] {
        let now = Date()
        switch selectedTimeFilter {
        case .today:
            return historyManager.allGlobalEntries.filter { Calendar.current.isDateInToday($0.timestamp) }
        case .sevenDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
            return historyManager.allGlobalEntries.filter { $0.timestamp >= cutoff }
        case .thirtyDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
            return historyManager.allGlobalEntries.filter { $0.timestamp >= cutoff }
        case .allTime:
            return historyManager.allGlobalEntries
        }
    }

    private var filteredCost: Double {
        filteredEntries.reduce(0) { $0 + $1.cost }
    }

    private var filteredTokens: Int {
        filteredEntries.reduce(0) { $0 + ($1.tokenUsage?.totalTokenCount ?? 0) }
    }

    private var filteredInputTokens: Int {
        filteredEntries.reduce(0) { $0 + ($1.tokenUsage?.promptTokenCount ?? 0) }
    }

    private var filteredOutputTokens: Int {
        filteredEntries.reduce(0) { $0 + ($1.tokenUsage?.candidatesTokenCount ?? 0) }
    }

    private var costByModel: [UsageCategoryPoint] {
        groupedCostPoints { $0.modelName ?? "Unknown model" }
    }

    private var costByResolution: [UsageCategoryPoint] {
        groupedCostPoints { $0.imageSize }
    }

    private var dailySeries: [UsageTimelinePoint] {
        let grouped = Dictionary(grouping: filteredEntries) {
            Calendar.current.startOfDay(for: $0.timestamp)
        }

        return grouped.keys.sorted().map { day in
            let entries = grouped[day] ?? []
            return UsageTimelinePoint(
                date: day,
                cost: entries.reduce(0) { $0 + $1.cost },
                images: entries.count
            )
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker("Time Range", selection: $selectedTimeFilter) {
                ForEach(TimeFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            ScrollView {
                VStack(spacing: 16) {
                    sessionCard
                    filteredSummaryCard

                    if !dailySeries.isEmpty {
                        spendTrendCard
                        throughputTrendCard
                    }

                    if filteredTokens > 0 {
                        tokenBreakdownCard
                    }

                    if !costByModel.isEmpty {
                        costByModelCard
                    }

                    if !costByResolution.isEmpty {
                        costByResolutionCard
                    }

                    exportCard
                    disclaimerText
                }
                .padding(.horizontal)
            }
        }
    }

    private var sessionCard: some View {
        VStack(spacing: 10) {
            Text("Current Session")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                metricValue(title: "Estimated", value: formattedCurrency(projectManager.sessionCost), tint: .green)

                if projectManager.sessionTokens > 0 {
                    metricValue(title: "Tokens", value: projectManager.sessionTokens.formatted(), tint: .primary)
                }

                metricValue(title: "Images", value: "\(projectManager.sessionImageCount)", tint: .primary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary)
        .cornerRadius(12)
    }

    private var filteredSummaryCard: some View {
        VStack(spacing: 10) {
            Text("Selected Period (\(selectedTimeFilter.rawValue))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                metricValue(title: "Projected", value: formattedCurrency(filteredCost), tint: .green)
                metricValue(title: "Images", value: "\(filteredEntries.count)", tint: .primary)

                if filteredTokens > 0 {
                    metricValue(title: "Tokens", value: filteredTokens.formatted(), tint: .primary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary)
        .cornerRadius(12)
    }

    private var spendTrendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estimated Spend Over Time")
                .font(.subheadline)
                .fontWeight(.medium)

            Chart(dailySeries) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value("Estimated Spend", point.cost)
                )
                .foregroundStyle(.green)

                AreaMark(
                    x: .value("Day", point.date),
                    y: .value("Estimated Spend", point.cost)
                )
                .foregroundStyle(.green.opacity(0.15))
            }
            .frame(height: 180)
        }
        .padding()
        .background(.background.secondary)
        .cornerRadius(12)
    }

    private var throughputTrendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Images Over Time")
                .font(.subheadline)
                .fontWeight(.medium)

            Chart(dailySeries) { point in
                BarMark(
                    x: .value("Day", point.date),
                    y: .value("Images", point.images)
                )
                .foregroundStyle(.blue.gradient)
            }
            .frame(height: 180)
        }
        .padding()
        .background(.background.secondary)
        .cornerRadius(12)
    }

    private var tokenBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token Breakdown")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 24) {
                metricValue(title: "Input", value: filteredInputTokens.formatted(), tint: .blue)
                metricValue(title: "Output", value: filteredOutputTokens.formatted(), tint: .orange)
                metricValue(title: "Total", value: filteredTokens.formatted(), tint: .primary)
            }
        }
        .padding()
        .background(.background.secondary)
        .cornerRadius(12)
    }

    private var costByModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estimated Spend by Model")
                .font(.subheadline)
                .fontWeight(.medium)

            Chart(costByModel) { point in
                BarMark(
                    x: .value("Model", point.label),
                    y: .value("Estimated Spend", point.value)
                )
                .foregroundStyle(.purple.gradient)
            }
            .frame(height: 180)

            ForEach(costByModel) { point in
                categoryRow(label: point.label, value: point.value, icon: "cpu")
            }
        }
        .padding()
        .background(.background.secondary)
        .cornerRadius(12)
    }

    private var costByResolutionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estimated Spend by Resolution")
                .font(.subheadline)
                .fontWeight(.medium)

            Chart(costByResolution) { point in
                BarMark(
                    x: .value("Resolution", point.label),
                    y: .value("Estimated Spend", point.value)
                )
                .foregroundStyle(.mint.gradient)
            }
            .frame(height: 180)

            ForEach(costByResolution) { point in
                categoryRow(label: point.label, value: point.value, icon: "rectangle.expand.vertical")
            }
        }
        .padding()
        .background(.background.secondary)
        .cornerRadius(12)
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: exportReport) {
                Label("Export CSV Report", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)

            if let exportStatusMessage {
                Text(exportStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.background.secondary)
        .cornerRadius(12)
    }

    private var disclaimerText: some View {
        Text("Usage data is based on app tracking only. All cost values are estimated and may differ from actual Google billing.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    private func exportReport() {
        if let url = projectManager.exportCostReportCSV(entries: filteredEntries) {
            NSWorkspace.shared.open(url)
            exportStatusMessage = "CSV exported successfully."
        } else {
            exportStatusMessage = "CSV export failed."
        }
    }

    private func metricValue(title: String, value: String, tint: Color) -> some View {
        VStack {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func categoryRow(label: String, value: Double, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Text("$\(value, specifier: "%.2f")")
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
        .cornerRadius(6)
    }

    private func groupedCostPoints(label: (HistoryEntry) -> String) -> [UsageCategoryPoint] {
        let grouped = Dictionary(grouping: filteredEntries, by: label)
        return grouped
            .map { key, entries in
                UsageCategoryPoint(label: key, value: entries.reduce(0) { $0 + $1.cost })
            }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.label < rhs.label
                }
                return lhs.value > rhs.value
            }
    }

    private func formattedCurrency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

private struct UsageTimelinePoint: Identifiable {
    let date: Date
    let cost: Double
    let images: Int

    var id: Date { date }
}

private struct UsageCategoryPoint: Identifiable {
    let label: String
    let value: Double

    var id: String { label }
}
