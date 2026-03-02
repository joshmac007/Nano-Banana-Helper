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
    let modelName: String
    let stagedInputCount: Int
    let generationCount: Int
    let inputCount: Int
    let outputCount: Int
    let imageSize: String
    let isBatchTier: Bool
    let isMultiInput: Bool

    private var estimate: CostEstimate {
        PricingEngine.estimate(
            modelName: modelName,
            imageSize: imageSize,
            isBatchTier: isBatchTier,
            inputCount: inputCount,
            outputCount: outputCount
        )
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                if stagedInputCount == 0 {
                    Text("\(generationCount) generated output\(generationCount == 1 ? "" : "s") @ \(imageSize)")
                        .font(.subheadline)
                } else if isMultiInput {
                    Text("\(stagedInputCount) inputs x \(generationCount) generation\(generationCount == 1 ? "" : "s") -> \(outputCount) output\(outputCount == 1 ? "" : "s") @ \(imageSize)")
                        .font(.subheadline)
                } else {
                    Text("\(stagedInputCount) inputs x \(generationCount) generation\(generationCount == 1 ? "" : "s") -> \(outputCount) output\(outputCount == 1 ? "" : "s") @ \(imageSize)")
                        .font(.subheadline)
                }
                Text(ModelCatalog.displayName(for: modelName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if estimate.inputCost > 0 {
                    let inputRate = estimate.inputCost / Double(max(1, estimate.inputCount))
                    let outputRate = estimate.outputCost / Double(max(1, estimate.outputCount))
                    Text("$\(inputRate, specifier: "%.4f")/input + $\(outputRate, specifier: "%.4f")/output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let outputRate = estimate.outputCost / Double(max(1, estimate.outputCount))
                    Text("$\(outputRate, specifier: "%.4f")/output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("≈ $\(estimate.total, specifier: "%.2f")")
                .font(.headline)
                .foregroundStyle(.green)
        }
    }
}
