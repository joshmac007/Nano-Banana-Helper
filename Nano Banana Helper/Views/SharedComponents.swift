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
    let imageCount: Int
    let imageSize: String
    let isBatchTier: Bool
    let isMultiInput: Bool
    let generationMode: GenerationMode
    let modelName: String?
    
    private var inputCostPerImage: Double { AppPricing.inputRate(isBatchTier: isBatchTier) }
    
    private var outputCostPerImage: Double {
        guard let size = ImageSize(rawValue: imageSize) else {
            return AppPricing.outputFallbackRate(isBatchTier: isBatchTier)
        }
        return size.cost(isBatchTier: isBatchTier)
    }
    
    /// Number of output images: 1 if Multi-Input, otherwise same as input count
    private var outputCount: Int {
        isMultiInput ? 1 : imageCount
    }
    
    private var totalCost: Double {
        switch generationMode {
        case .image:
            // Input cost: charged per input image
            // Output cost: charged per output image (1 for Multi-Input, N otherwise)
            let inputTotal = Double(imageCount) * inputCostPerImage
            let outputTotal = Double(outputCount) * outputCostPerImage
            return inputTotal + outputTotal
        case .text:
            // Text mode: no input cost, only output cost
            return Double(imageCount) * outputCostPerImage
        }
    }

    private var inputTotalCost: Double {
        switch generationMode {
        case .image:
            return Double(imageCount) * inputCostPerImage
        case .text:
            return 0
        }
    }

    private var outputTotalCost: Double {
        switch generationMode {
        case .image:
            return Double(outputCount) * outputCostPerImage
        case .text:
            return Double(imageCount) * outputCostPerImage
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Projected Cost")
                        .font(.system(size: 11, weight: .bold))
                        .textCase(.uppercase)
                    Text("Estimated only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("≈ $\(totalCost, specifier: "%.2f")")
                    .font(.headline)
                    .foregroundStyle(.green)
            }

            switch generationMode {
            case .image:
                if isMultiInput {
                    Text("\(imageCount) inputs → 1 output @ \(imageSize)")
                        .font(.subheadline)
                } else {
                    Text("\(imageCount) images @ \(imageSize)")
                        .font(.subheadline)
                }
            case .text:
                Text("\(imageCount) image\(imageCount == 1 ? "" : "s") @ \(imageSize)")
                    .font(.subheadline)
            }

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
