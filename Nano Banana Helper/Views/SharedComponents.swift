import SwiftUI

// MARK: - Visual Effect View (macOS Blur)
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Cost Estimator
struct CostEstimatorView: View {
    let stagedImageCount: Int
    let variationCount: Int
    let outputCount: Int
    let imageSize: String
    let isBatchTier: Bool
    let isMultiInput: Bool
    let generationMode: GenerationMode
    let modelName: String?
    
    var pricingResolution: AppPricing.PricingResolution {
        AppPricing.pricing(for: modelName)
    }

    var inputCostPerImage: Double {
        AppPricing.inputRate(modelName: modelName, isBatchTier: isBatchTier)
    }
    
    var outputCostPerImage: Double {
        guard let size = ImageSize(rawValue: imageSize) else {
            return AppPricing.outputFallbackRate(modelName: modelName, isBatchTier: isBatchTier)
        }
        return size.cost(modelName: modelName, isBatchTier: isBatchTier)
    }
    
    private var billedInputCount: Int {
        switch generationMode {
        case .image:
            return stagedImageCount * variationCount
        case .text:
            return 0
        }
    }
    
    var totalCost: Double {
        switch generationMode {
        case .image:
            // Input cost: charged per input image
            let inputTotal = Double(billedInputCount) * inputCostPerImage
            let outputTotal = Double(outputCount) * outputCostPerImage
            return inputTotal + outputTotal
        case .text:
            // Text mode: no input cost, only output cost
            return Double(outputCount) * outputCostPerImage
        }
    }

    var inputTotalCost: Double {
        switch generationMode {
        case .image:
            return Double(billedInputCount) * inputCostPerImage
        case .text:
            return 0
        }
    }

    var outputTotalCost: Double {
        switch generationMode {
        case .image:
            return Double(outputCount) * outputCostPerImage
        case .text:
            return Double(outputCount) * outputCostPerImage
        }
    }

    var pricingNote: String? {
        pricingResolution.note
    }

    private var projectedCostHelpText: String? {
        var notes: [String] = []
        if pricingResolution.pricingMode == .tokenBased {
            notes.append("Token-based pricing uses provider-reported usage details after completion.")
        }
        if let pricingNote {
            notes.append(pricingNote)
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 4) {
                        Text("Projected Cost")
                            .font(.system(size: 11, weight: .bold))
                            .textCase(.uppercase)
                        if let projectedCostHelpText {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .help(projectedCostHelpText)
                                .accessibilityLabel("Projected cost details")
                                .accessibilityHint(Text(projectedCostHelpText))
                        }
                    }
                    Text("Estimated only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(pricingResolution.pricingMode == .tokenBased ? "After completion" : "≈ $\(totalCost, specifier: "%.2f")")
                    .font(.headline)
                    .foregroundStyle(.green)
            }

            switch generationMode {
            case .image:
                if isMultiInput && variationCount > 1 {
                    Text("\(stagedImageCount) inputs × \(variationCount) variations → \(outputCount) outputs @ \(imageSize)")
                        .font(.subheadline)
                } else if isMultiInput {
                    Text("\(stagedImageCount) inputs → \(outputCount) outputs @ \(imageSize)")
                        .font(.subheadline)
                } else if variationCount > 1 {
                    Text("\(stagedImageCount) images × \(variationCount) variations → \(outputCount) outputs @ \(imageSize)")
                        .font(.subheadline)
                } else if outputCount != stagedImageCount {
                    Text("\(stagedImageCount) images → \(outputCount) outputs @ \(imageSize)")
                        .font(.subheadline)
                } else {
                    Text("\(stagedImageCount) images @ \(imageSize)")
                        .font(.subheadline)
                }
            case .text:
                Text("\(outputCount) image\(outputCount == 1 ? "" : "s") @ \(imageSize)")
                    .font(.subheadline)
            }

            if pricingResolution.pricingMode != .tokenBased {
                HStack(spacing: 12) {
                    if generationMode == .image {
                        estimatorMetric(
                            title: "Inputs",
                            detail: String(format: "$%.4f each", inputCostPerImage),
                            total: inputTotalCost
                        )
                    }

                    estimatorMetric(
                        title: "Outputs",
                        detail: String(format: "$%.3f each", outputCostPerImage),
                        total: outputTotalCost
                    )

                    estimatorMetric(
                        title: "Total",
                        detail: isBatchTier ? "Batch tier" : "Standard tier",
                        total: totalCost
                    )
                }
            }

            if let modelName {
                Text(modelName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func estimatorMetric(title: String, detail: String, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("$\(total, specifier: "%.2f")")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
