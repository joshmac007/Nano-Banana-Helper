import AppKit
import Charts
import SwiftUI

struct UsageDashboardView: View {
    @Environment(ProjectManager.self) private var projectManager
    @State private var selectedTimeFilter: TimeFilter = .allTime
    @State private var exportStatusMessage: String?
    @State private var showingAdjustmentSheet = false
    @State private var adjustmentDraft = UsageAdjustmentDraft()

    enum TimeFilter: String, CaseIterable {
        case today = "Today"
        case sevenDays = "7 Days"
        case thirtyDays = "30 Days"
        case allTime = "All Time"
    }

    private var filteredEntries: [UsageLedgerEntry] {
        let now = Date()
        switch selectedTimeFilter {
        case .today:
            return projectManager.ledger.filter { Calendar.current.isDateInToday($0.timestamp) }
        case .sevenDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
            return projectManager.ledger.filter { $0.timestamp >= cutoff }
        case .thirtyDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
            return projectManager.ledger.filter { $0.timestamp >= cutoff }
        case .allTime:
            return projectManager.ledger
        }
    }

    private var filteredCost: Double {
        filteredEntries.reduce(0) { $0 + $1.costDelta }
    }

    private var filteredImages: Int {
        filteredEntries.reduce(0) { $0 + $1.imageDelta }
    }

    private var filteredTokens: Int {
        filteredEntries.reduce(0) { $0 + $1.tokenDelta }
    }

    private var filteredInputTokens: Int {
        filteredEntries.reduce(0) { $0 + $1.inputTokenDelta }
    }

    private var filteredOutputTokens: Int {
        filteredEntries.reduce(0) { $0 + $1.outputTokenDelta }
    }

    private var costByModel: [UsageCategoryPoint] {
        groupedCostPoints { $0.modelName }
    }

    private var costByResolution: [UsageCategoryPoint] {
        groupedCostPoints { $0.resolution }
    }

    private var costByProject: [UsageCategoryPoint] {
        let grouped = Dictionary(grouping: filteredEntries.filter { $0.projectId != nil || $0.projectNameSnapshot != nil }) {
            $0.projectId?.uuidString ?? "snapshot:\($0.projectNameSnapshot ?? "deleted")"
        }

        return grouped.map { key, entries in
            let firstEntry = entries.first
            return UsageCategoryPoint(
                label: projectManager.projectDisplayName(
                    for: firstEntry?.projectId,
                    projectNameSnapshot: firstEntry?.projectNameSnapshot
                ),
                value: entries.reduce(0) { $0 + $1.costDelta },
                secondaryValue: entries.reduce(0) { $0 + $1.imageDelta },
                id: key
            )
        }
        .sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.label < rhs.label
            }
            return lhs.value > rhs.value
        }
    }

    private var dailySeries: [UsageTimelinePoint] {
        let grouped = Dictionary(grouping: filteredEntries) {
            Calendar.current.startOfDay(for: $0.timestamp)
        }

        return grouped.keys.sorted().map { day in
            let entries = grouped[day] ?? []
            return UsageTimelinePoint(
                date: day,
                cost: entries.reduce(0) { $0 + $1.costDelta },
                images: entries.reduce(0) { $0 + $1.imageDelta }
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
                    managementCard

                    if !dailySeries.isEmpty {
                        spendTrendCard
                        throughputTrendCard
                    }

                    if filteredTokens != 0 {
                        tokenBreakdownCard
                    }

                    if !costByProject.isEmpty {
                        costByProjectCard
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
        .sheet(isPresented: $showingAdjustmentSheet) {
            UsageAdjustmentSheet(
                draft: $adjustmentDraft,
                onCancel: {
                    adjustmentDraft = UsageAdjustmentDraft()
                    showingAdjustmentSheet = false
                },
                onCreate: addAdjustment
            )
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
                metricValue(title: "Estimated", value: formattedCurrency(filteredCost), tint: .green)
                metricValue(title: "Images", value: "\(filteredImages)", tint: .primary)

                if filteredTokens != 0 {
                    metricValue(title: "Tokens", value: filteredTokens.formatted(), tint: .primary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary)
        .cornerRadius(12)
    }

    private var managementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage Management")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                Button("Add Adjustment…") {
                    adjustmentDraft = UsageAdjustmentDraft()
                    showingAdjustmentSheet = true
                }
                .buttonStyle(.bordered)

                Button("Reset Usage…") {
                    resetUsage()
                }
                .buttonStyle(.bordered)
                .disabled(projectManager.costSummary.totalSpent == 0 &&
                          projectManager.costSummary.imageCount == 0 &&
                          projectManager.costSummary.totalTokens == 0)
            }

            Text("History deletion does not change usage totals. Use adjustments or reset to correct tracked spend.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary)
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

    private var costByProjectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estimated Spend by Project")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(costByProject) { point in
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(point.label)
                        .font(.subheadline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formattedCurrency(point.value))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("\(point.secondaryValue) images")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5))
                .cornerRadius(6)
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

    private func addAdjustment() {
        let inputTokens = Int(adjustmentDraft.inputTokens) ?? 0
        let outputTokens = Int(adjustmentDraft.outputTokens) ?? 0
        let imageDelta = Int(adjustmentDraft.images) ?? 0
        let costDelta = Double(adjustmentDraft.cost) ?? 0
        let note = adjustmentDraft.note.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !note.isEmpty else { return }

        projectManager.appendLedgerEntry(
            UsageLedgerEntry(
                kind: .adjustment,
                projectId: nil,
                projectNameSnapshot: nil,
                costDelta: costDelta,
                imageDelta: imageDelta,
                tokenDelta: inputTokens + outputTokens,
                inputTokenDelta: inputTokens,
                outputTokenDelta: outputTokens,
                resolution: nil,
                modelName: nil,
                relatedHistoryEntryId: nil,
                note: note
            )
        )

        adjustmentDraft = UsageAdjustmentDraft()
        showingAdjustmentSheet = false
    }

    private func resetUsage() {
        let summary = projectManager.costSummary
        projectManager.appendLedgerEntry(
            UsageLedgerEntry(
                kind: .adjustment,
                projectId: nil,
                projectNameSnapshot: nil,
                costDelta: -summary.totalSpent,
                imageDelta: -summary.imageCount,
                tokenDelta: -summary.totalTokens,
                inputTokenDelta: -summary.inputTokens,
                outputTokenDelta: -summary.outputTokens,
                resolution: nil,
                modelName: nil,
                relatedHistoryEntryId: nil,
                note: "Manual reset on \(Date().formatted(date: .abbreviated, time: .shortened))"
            )
        )
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
            Text(formattedCurrency(value))
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
        .cornerRadius(6)
    }

    private func groupedCostPoints(label: (UsageLedgerEntry) -> String?) -> [UsageCategoryPoint] {
        let grouped = Dictionary(grouping: filteredEntries.compactMap { entry -> (String, Double)? in
            guard let label = label(entry) else { return nil }
            return (label, entry.costDelta)
        }, by: \.0)
        return grouped
            .map { key, values in
                UsageCategoryPoint(label: key, value: values.reduce(0) { $0 + $1.1 })
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

private struct UsageAdjustmentDraft {
    var note = ""
    var cost = ""
    var images = ""
    var inputTokens = ""
    var outputTokens = ""

    var hasNonZeroChange: Bool {
        (Double(cost) ?? 0) != 0 ||
        (Int(images) ?? 0) != 0 ||
        (Int(inputTokens) ?? 0) != 0 ||
        (Int(outputTokens) ?? 0) != 0
    }
}

private struct UsageAdjustmentSheet: View {
    @Binding var draft: UsageAdjustmentDraft
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Usage Adjustment")
                .font(.headline)

            TextField("Reason", text: $draft.note)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Cost delta", text: $draft.cost)
                    .textFieldStyle(.roundedBorder)
                TextField("Image delta", text: $draft.images)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                TextField("Input tokens", text: $draft.inputTokens)
                    .textFieldStyle(.roundedBorder)
                TextField("Output tokens", text: $draft.outputTokens)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Adjustment", action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.hasNonZeroChange)
            }
        }
        .padding()
        .frame(width: 420)
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
    var secondaryValue: Int = 0
    private let rawID: String

    init(label: String, value: Double, secondaryValue: Int = 0, id: String? = nil) {
        self.label = label
        self.value = value
        self.secondaryValue = secondaryValue
        self.rawID = id ?? label
    }

    var id: String { rawID }
}
