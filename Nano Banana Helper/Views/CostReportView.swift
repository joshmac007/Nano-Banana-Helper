import SwiftUI

struct CostReportView: View {
    let costSummary: CostSummary
    let projects: [Project]
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Cost Report")
                    .font(.headline)
                Spacer()
                
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
                        Text("Total Spent")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Text(formatCurrency(costSummary.totalSpent))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                        
                        Text("\(costSummary.imageCount) images processed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                    // Breakdown by model
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By Model")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        ForEach(Array(costSummary.byModel.keys.sorted()), id: \.self) { modelId in
                            HStack {
                                Text(ModelCatalog.displayName(for: modelId))
                                    .font(.subheadline)

                                Spacer()

                                Text(formatCurrency(costSummary.byModel[modelId] ?? 0))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.5))
                            .cornerRadius(6)
                        }

                        if costSummary.byModel.isEmpty {
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
                        
                        ForEach(projects) { project in
                            let cost = costSummary.byProject[project.id.uuidString] ?? 0
                            if cost > 0 {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.secondary)
                                    
                                    Text(project.name)
                                        .font(.subheadline)
                                    
                                    Spacer()
                                    
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(formatCurrency(cost))
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        
                                        Text("\(project.imageCount) images")
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
                        
                        if projects.allSatisfy({ (costSummary.byProject[$0.id.uuidString] ?? 0) == 0 }) {
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
                    
                    // Pricing reference
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pricing Reference")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow {
                                Text("Model")
                                    .fontWeight(.medium)
                                Text("Tier")
                                    .fontWeight(.medium)
                                Text("Input")
                                    .fontWeight(.medium)
                                Text("Output (1K)")
                                    .fontWeight(.medium)
                                Text("Output (2K)")
                                    .fontWeight(.medium)
                                Text("Output (4K)")
                                    .fontWeight(.medium)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            
                            GridRow {
                                Text("Gemini 3 Pro")
                                Text("Standard")
                                Text("$0.0011")
                                Text("$0.134")
                                Text("$0.134")
                                Text("$0.24")
                            }
                            .font(.caption)
                            
                            GridRow {
                                Text("Gemini 3 Pro")
                                Text("Batch")
                                Text("$0.0006")
                                Text("$0.067")
                                Text("$0.067")
                                Text("$0.12")
                            }
                            .font(.caption)

                            GridRow {
                                Text("Gemini 3.1 Flash")
                                Text("Standard")
                                Text("-")
                                Text("$0.067")
                                Text("$0.101")
                                Text("$0.151")
                            }
                            .font(.caption)

                            GridRow {
                                Text("Gemini 3.1 Flash")
                                Text("Batch")
                                Text("-")
                                Text("$0.0335")
                                Text("$0.0505")
                                Text("$0.0755")
                            }
                            .font(.caption)
                        }
                        Text("Gemini 3.1 Flash 0.5K: Standard $0.045, Batch $0.0225 per output image.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
}
