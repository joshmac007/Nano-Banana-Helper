import AppKit
import SwiftUI

struct CostReportView: View {
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTimeFilter: UsageTimeFilter = .allTime
    @State private var exportStatusMessage: String?

    private var selectedModelName: String? {
        AppConfig.load().modelName
    }

    private var pricingResolution: AppPricing.PricingResolution {
        AppPricing.pricing(for: selectedModelName)
    }

    private var snapshot: UsageSnapshot {
        UsageSnapshotBuilder.makeSnapshot(
            entries: projectManager.ledger,
            filter: selectedTimeFilter,
            projectDisplayName: projectManager.projectDisplayName(for:projectNameSnapshot:)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Usage & Spend")
                    .font(.headline)
                Spacer()

                Button(action: exportReport) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            VStack(spacing: 0) {
                UsageFilterPicker(filter: $selectedTimeFilter)
                    .padding()

                Divider()

                ScrollView {
                    VStack(spacing: 16) {
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

                        if let exportStatusMessage {
                            Text(exportStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        UsageDailyChartCard(metric: .spend, snapshot: snapshot, tint: .green)
                        UsageDailyChartCard(metric: .images, snapshot: snapshot, tint: .blue)

                        HStack(alignment: .top, spacing: 16) {
                            UsageBreakdownCard(
                                title: "Top Projects",
                                points: Array(snapshot.projectBreakdown.prefix(5)),
                                icon: "folder",
                                accent: .green
                            )

                            UsageBreakdownCard(
                                title: "Top Models",
                                points: Array(snapshot.modelBreakdown.prefix(5)),
                                icon: "cpu",
                                accent: .orange
                            )
                        }

                        pricingReferenceCard
                    }
                    .padding()
                }
            }
        }
        .frame(width: 560, height: 620)
    }

    private var pricingReferenceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pricing Reference")
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 4) {
                Text(selectedModelName ?? AppPricing.defaultModelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if pricingResolution.isFallback {
                    Text("Using \(pricingResolution.pricingDisplayName) pricing fallback.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Tier")
                        .fontWeight(.medium)
                    Text("Input")
                        .fontWeight(.medium)
                    Text("Output (4K)")
                        .fontWeight(.medium)
                    Text("Output (2K)")
                        .fontWeight(.medium)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                GridRow {
                    Text("Standard")
                    Text("$\(AppPricing.inputRate(modelName: selectedModelName, isBatchTier: false), specifier: "%.4f")")
                    Text("$\(ImageSize.size4K.cost(modelName: selectedModelName, isBatchTier: false), specifier: "%.3f")")
                    Text("$\(ImageSize.size2K.cost(modelName: selectedModelName, isBatchTier: false), specifier: "%.3f")")
                }
                .font(.caption)

                GridRow {
                    Text("Batch")
                    Text("$\(AppPricing.inputRate(modelName: selectedModelName, isBatchTier: true), specifier: "%.4f")")
                    Text("$\(ImageSize.size4K.cost(modelName: selectedModelName, isBatchTier: true), specifier: "%.3f")")
                    Text("$\(ImageSize.size2K.cost(modelName: selectedModelName, isBatchTier: true), specifier: "%.3f")")
                }
                .font(.caption)
            }

            Text("Usage data is based on app tracking only. These values are estimated and may differ from actual Google billing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func exportReport() {
        if let url = projectManager.exportCostReportCSV(entries: snapshot.filteredEntries) {
            NSWorkspace.shared.open(url)
            exportStatusMessage = "CSV exported for \(selectedTimeFilter.rawValue.lowercased())."
        } else {
            exportStatusMessage = "CSV export failed."
        }
    }
}
