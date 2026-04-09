import AppKit
import SwiftUI

struct CostReportView: View {
    let costSummary: CostSummary
    let projects: [Project]
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.dismiss) var dismiss
    @State private var exportStatusMessage: String?

    var selectedModelName: String? {
        AppConfig.load().modelName
    }

    var pricingResolution: AppPricing.PricingResolution {
        AppPricing.pricing(for: selectedModelName)
    }

    var projectBreakdowns: [ProjectUsageBreakdown] {
        projectManager.projectUsageBreakdowns
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Estimated Cost Report")
                    .font(.headline)
                Spacer()

                Button(action: exportReport) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
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
            
            ScrollView {
                VStack(spacing: 20) {
                    // Total summary card
                    VStack(spacing: 12) {
                        Text("Estimated Spend")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Text(formatCurrency(costSummary.totalSpent))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                        
                        Text("\(costSummary.imageCount) images processed")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let exportStatusMessage {
                            Text(exportStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.quaternary)
                    .cornerRadius(12)
                    
                    // Breakdown by resolution
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By Resolution")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        ForEach(Array(costSummary.byResolution.keys.sorted()), id: \.self) { resolution in
                            HStack {
                                Text(resolution)
                                    .font(.subheadline)
                                
                                Spacer()
                                
                                Text(formatCurrency(costSummary.byResolution[resolution] ?? 0))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.5))
                            .cornerRadius(6)
                        }
                        
                        if costSummary.byResolution.isEmpty {
                            Text("No data yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                    .padding()
                    .background(.background.secondary)
                    .cornerRadius(12)
                    
                    // Breakdown by project
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By Project")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        ForEach(projectBreakdowns) { breakdown in
                            if breakdown.cost != 0 || breakdown.imageCount != 0 {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.secondary)
                                    
                                    Text(breakdown.name)
                                        .font(.subheadline)
                                    
                                    Spacer()
                                    
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(formatCurrency(breakdown.cost))
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        
                                        Text("\(breakdown.imageCount) images")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.quaternary.opacity(0.5))
                                .cornerRadius(6)
                            }
                        }
                        
                        if projectBreakdowns.isEmpty {
                            Text("No data yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                    .padding()
                    .background(.background.secondary)
                    .cornerRadius(12)

                    // Breakdown by model
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By Model")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        ForEach(Array(costSummary.byModel.keys.sorted()), id: \.self) { model in
                            HStack {
                                Image(systemName: "cpu")
                                    .foregroundStyle(.secondary)

                                Text(model)
                                    .font(.subheadline)
                                    .lineLimit(1)

                                Spacer()

                                Text(formatCurrency(costSummary.byModel[model] ?? 0))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.5))
                            .cornerRadius(6)
                        }

                        if costSummary.byModel.isEmpty {
                            Text("No model data yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                    .padding()
                    .background(.background.secondary)
                    .cornerRadius(12)

                    if costSummary.totalTokens > 0 {
                        VStack(spacing: 12) {
                            Text("Token Usage")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 24) {
                                VStack {
                                    Text("\(costSummary.totalTokens)")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                    Text("Total")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                VStack {
                                    Text("\(costSummary.inputTokens)")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.blue)
                                    Text("Input")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                VStack {
                                    Text("\(costSummary.outputTokens)")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.orange)
                                    Text("Output")
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

                    // Pricing reference
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Estimated Pricing Reference")
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
                    .padding()
                    .background(.background.secondary)
                    .cornerRadius(12)
                }
                .padding()
            }
        }
    }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    private func exportReport() {
        if let url = projectManager.exportCostReportCSV() {
            NSWorkspace.shared.open(url)
            exportStatusMessage = "CSV exported to Application Support."
        } else {
            exportStatusMessage = "CSV export failed."
        }
    }
}
