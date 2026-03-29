import SwiftUI

struct UsageDashboardView: View {
    @Environment(ProjectManager.self) private var projectManager
    @Environment(HistoryManager.self) private var historyManager
    @State private var selectedTimeFilter: TimeFilter = .allTime

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

    var body: some View {
        VStack(spacing: 16) {
            // Time Filter
            Picker("Time Range", selection: $selectedTimeFilter) {
                ForEach(TimeFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            ScrollView {
                VStack(spacing: 16) {
                    // Session Card
                    sessionCard

                    // Filtered Summary Card
                    filteredSummaryCard

                    // Token Breakdown (from CostSummary)
                    if projectManager.costSummary.totalTokens > 0 {
                        tokenBreakdownCard
                    }

                    // Cost Breakdown by Model
                    if !projectManager.costSummary.byModel.isEmpty {
                        costByModelCard
                    }

                    // Cost Breakdown by Resolution
                    if !projectManager.costSummary.byResolution.isEmpty {
                        costByResolutionCard
                    }

                    // Export Button
                    exportButton

                    // Disclaimer
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
                VStack {
                    Text("$\(projectManager.sessionCost, specifier: "%.2f")")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)
                    Text("Cost")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if projectManager.sessionTokens > 0 {
                    VStack {
                        Text(projectManager.sessionTokens.formatted())
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Tokens")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack {
                    Text("\(projectManager.sessionImageCount)")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Images")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
                VStack {
                    Text("$\(filteredCost, specifier: "%.2f")")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)
                    Text("Cost")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text("\(filteredEntries.count)")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Images")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if filteredTokens > 0 {
                    VStack {
                        Text(filteredTokens.formatted())
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Tokens")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary)
        .cornerRadius(12)
    }

    private var tokenBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token Breakdown")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 24) {
                VStack {
                    Text(projectManager.costSummary.inputTokens.formatted())
                        .font(.headline)
                        .foregroundStyle(.blue)
                    Text("Input")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text(projectManager.costSummary.outputTokens.formatted())
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Output")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text(projectManager.costSummary.totalTokens.formatted())
                        .font(.headline)
                    Text("Total")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.background.secondary)
        .cornerRadius(12)
    }

    private var costByModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cost by Model")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(Array(projectManager.costSummary.byModel.keys.sorted()), id: \.self) { model in
                HStack {
                    Image(systemName: "cpu")
                        .foregroundStyle(.secondary)
                    Text(model)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Text("$\(projectManager.costSummary.byModel[model] ?? 0, specifier: "%.2f")")
                        .font(.subheadline)
                        .fontWeight(.medium)
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

    private var costByResolutionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cost by Resolution")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(Array(projectManager.costSummary.byResolution.keys.sorted()), id: \.self) { resolution in
                HStack {
                    Text(resolution)
                        .font(.subheadline)
                    Spacer()
                    Text("$\(projectManager.costSummary.byResolution[resolution] ?? 0, specifier: "%.2f")")
                        .font(.subheadline)
                        .fontWeight(.medium)
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

    private var exportButton: some View {
        Button(action: exportReport) {
            Label("Export CSV Report", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    private var disclaimerText: some View {
        Text("Usage data is based on app tracking only. Actual billing is determined by your Google Cloud billing account.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    private func exportReport() {
        if let url = projectManager.exportCostReportCSV(entries: filteredEntries) {
            NSWorkspace.shared.open(url)
        }
    }
}
