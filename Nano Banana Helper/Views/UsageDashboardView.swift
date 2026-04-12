import AppKit
import SwiftUI

struct UsageDashboardView: View {
    @Environment(ProjectManager.self) private var projectManager

    @State private var selectedTimeFilter: UsageTimeFilter = .allTime
    @State private var exportStatusMessage: String?
    @State private var showingAdjustmentSheet = false
    @State private var showingResetConfirmation = false
    @State private var adjustmentDraft = UsageAdjustmentDraft()

    private var snapshot: UsageSnapshot {
        UsageSnapshotBuilder.makeSnapshot(
            entries: projectManager.ledger,
            filter: selectedTimeFilter,
            projectDisplayName: projectManager.projectDisplayName(for:projectNameSnapshot:)
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            UsageFilterPicker(filter: $selectedTimeFilter)
                .padding(.horizontal)

            ScrollView {
                VStack(spacing: 16) {
                    summarySection
                    chartsSection
                    breakdownSection
                    UsageRecentActivityCard(rows: snapshot.recentActivity)
                    correctionsCard
                    exportCard
                    disclaimerText
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .sheet(isPresented: $showingAdjustmentSheet) {
            UsageAdjustmentSheet(
                draft: $adjustmentDraft,
                onCancel: {
                    adjustmentDraft = UsageAdjustmentDraft()
                    showingAdjustmentSheet = false
                },
                onSave: saveAdjustment
            )
        }
        .alert("Reset tracked totals?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive, action: resetUsage)
        } message: {
            Text("This adds a correction entry that zeroes the current tracked totals without deleting history.")
        }
    }

    private var summarySection: some View {
        VStack(spacing: 16) {
            UsageSummaryCard(
                title: "Current Session",
                subtitle: "Only tracks usage from this app launch.",
                metrics: [
                    UsageSummaryMetric(title: "Estimated", value: projectManager.sessionCost.usageCurrency(), tint: .green),
                    UsageSummaryMetric(title: "Images", value: projectManager.sessionImageCount.formatted()),
                    UsageSummaryMetric(title: "Tokens", value: projectManager.sessionTokens.formatted())
                ]
            )

            UsageSummaryCard(
                title: "Tracked Usage",
                subtitle: snapshot.rangeLabel,
                metrics: [
                    UsageSummaryMetric(title: "Estimated", value: snapshot.totals.cost.usageCurrency(), tint: .green),
                    UsageSummaryMetric(title: "Images", value: snapshot.totals.images.formatted()),
                    UsageSummaryMetric(
                        title: "Tokens",
                        value: snapshot.totals.tokens.formatted(),
                        detail: snapshot.totals.tokens == 0 ? nil : "In \(snapshot.totals.inputTokens.formatted()) / Out \(snapshot.totals.outputTokens.formatted())"
                    )
                ]
            )
        }
    }

    private var chartsSection: some View {
        VStack(spacing: 16) {
            UsageDailyChartCard(metric: .spend, snapshot: snapshot, tint: .green)
            UsageDailyChartCard(metric: .images, snapshot: snapshot, tint: .blue)
        }
    }

    private var breakdownSection: some View {
        VStack(spacing: 16) {
            UsageBreakdownCard(
                title: "Top Projects",
                points: snapshot.projectBreakdown,
                icon: "folder",
                accent: .green
            )

            HStack(alignment: .top, spacing: 16) {
                UsageBreakdownCard(
                    title: "Top Models",
                    points: snapshot.modelBreakdown,
                    icon: "cpu",
                    accent: .orange
                )

                UsageBreakdownCard(
                    title: "Resolutions",
                    points: snapshot.resolutionBreakdown,
                    icon: "rectangle.expand.vertical",
                    accent: .mint
                )
            }
        }
    }

    private var correctionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tracked Usage Corrections")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("Corrections change tracked totals without editing image history.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Record Correction…") {
                    adjustmentDraft = UsageAdjustmentDraft()
                    showingAdjustmentSheet = true
                }
                .buttonStyle(.bordered)

                Button("Reset Tracked Totals…") {
                    showingResetConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(projectManager.costSummary.totalSpent == 0 &&
                          projectManager.costSummary.imageCount == 0 &&
                          projectManager.costSummary.totalTokens == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: exportReport) {
                Label("Export Selected Range", systemImage: "square.and.arrow.up")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var disclaimerText: some View {
        Text("Usage data is based on app tracking only. All cost values are estimated and may differ from actual Google billing.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    private func exportReport() {
        if let url = projectManager.exportCostReportCSV(entries: snapshot.filteredEntries) {
            NSWorkspace.shared.open(url)
            exportStatusMessage = "CSV exported for \(selectedTimeFilter.rawValue.lowercased())."
        } else {
            exportStatusMessage = "CSV export failed."
        }
    }

    private func saveAdjustment() {
        let preview = adjustmentDraft.previewValues
        guard !adjustmentDraft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              preview.hasAnyChange
        else {
            return
        }

        projectManager.appendLedgerEntry(
            UsageLedgerEntry(
                kind: .adjustment,
                projectId: nil,
                projectNameSnapshot: nil,
                costDelta: preview.costDelta,
                imageDelta: preview.imageDelta,
                tokenDelta: preview.inputTokenDelta + preview.outputTokenDelta,
                inputTokenDelta: preview.inputTokenDelta,
                outputTokenDelta: preview.outputTokenDelta,
                resolution: nil,
                modelName: nil,
                relatedHistoryEntryId: nil,
                note: adjustmentDraft.note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )

        exportStatusMessage = nil
        adjustmentDraft = UsageAdjustmentDraft()
        showingAdjustmentSheet = false
    }

    private func resetUsage() {
        let summary = projectManager.costSummary
        guard summary.totalSpent != 0 ||
                summary.imageCount != 0 ||
                summary.totalTokens != 0
        else {
            return
        }

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
}

private enum UsageAdjustmentMode: String, CaseIterable, Identifiable {
    case add = "Add Missing Usage"
    case remove = "Remove Overcount"

    var id: Self { self }

    var multiplier: Int {
        switch self {
        case .add:
            return 1
        case .remove:
            return -1
        }
    }
}

private struct UsageAdjustmentDraft {
    var mode: UsageAdjustmentMode = .add
    var note = ""
    var cost = ""
    var images = ""
    var inputTokens = ""
    var outputTokens = ""

    var previewValues: UsageAdjustmentPreview {
        let multiplier = mode.multiplier
        let costMagnitude = abs(Double(cost) ?? 0)
        let imageMagnitude = abs(Int(images) ?? 0)
        let inputMagnitude = abs(Int(inputTokens) ?? 0)
        let outputMagnitude = abs(Int(outputTokens) ?? 0)

        return UsageAdjustmentPreview(
            costDelta: Double(multiplier) * costMagnitude,
            imageDelta: multiplier * imageMagnitude,
            inputTokenDelta: multiplier * inputMagnitude,
            outputTokenDelta: multiplier * outputMagnitude
        )
    }
}

private struct UsageAdjustmentPreview {
    let costDelta: Double
    let imageDelta: Int
    let inputTokenDelta: Int
    let outputTokenDelta: Int

    var hasAnyChange: Bool {
        costDelta != 0 || imageDelta != 0 || inputTokenDelta != 0 || outputTokenDelta != 0
    }
}

private struct UsageAdjustmentSheet: View {
    @Binding var draft: UsageAdjustmentDraft
    let onCancel: () -> Void
    let onSave: () -> Void

    private var previewText: String {
        let preview = draft.previewValues
        return "This will \(preview.costDelta >= 0 ? "add" : "subtract") \(abs(preview.costDelta).usageCurrency()), \(abs(preview.imageDelta)) image\(abs(preview.imageDelta) == 1 ? "" : "s"), \(abs(preview.inputTokenDelta)) input tokens, and \(abs(preview.outputTokenDelta)) output tokens."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adjust Tracked Usage")
                .font(.headline)

            Picker("Mode", selection: $draft.mode) {
                ForEach(UsageAdjustmentMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            TextField("Reason", text: $draft.note)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Estimated spend", text: $draft.cost)
                    .textFieldStyle(.roundedBorder)
                TextField("Images", text: $draft.images)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                TextField("Input tokens", text: $draft.inputTokens)
                    .textFieldStyle(.roundedBorder)
                TextField("Output tokens", text: $draft.outputTokens)
                    .textFieldStyle(.roundedBorder)
            }

            Text(previewText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Correction", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.previewValues.hasAnyChange)
            }
        }
        .padding()
        .frame(width: 460)
    }
}
