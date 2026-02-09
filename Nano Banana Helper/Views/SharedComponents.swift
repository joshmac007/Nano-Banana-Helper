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
    
    private var inputCostPerImage: Double { isBatchTier ? 0.0006 : 0.0011 }
    
    private var outputCostPerImage: Double {
        if isBatchTier {
            // Batch Tier: 50% cheaper
            switch imageSize {
            case "4K": return 0.12
            case "2K", "1K": return 0.067
            default: return 0.067
            }
        } else {
            // Standard Tier
            switch imageSize {
            case "4K": return 0.24
            case "2K", "1K": return 0.134
            default: return 0.134
            }
        }
    }
    
    /// Number of output images: 1 if Multi-Input, otherwise same as input count
    private var outputCount: Int {
        isMultiInput ? 1 : imageCount
    }
    
    private var totalCost: Double {
        // Input cost: charged per input image
        // Output cost: charged per output image (1 for Multi-Input, N otherwise)
        let inputTotal = Double(imageCount) * inputCostPerImage
        let outputTotal = Double(outputCount) * outputCostPerImage
        return inputTotal + outputTotal
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                if isMultiInput {
                    Text("\(imageCount) inputs → 1 output @ \(imageSize)")
                        .font(.subheadline)
                } else {
                    Text("\(imageCount) images @ \(imageSize)")
                        .font(.subheadline)
                }
                Text("$\(inputCostPerImage, specifier: "%.4f")/input + $\(outputCostPerImage, specifier: "%.3f")/output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("≈ $\(totalCost, specifier: "%.2f")")
                .font(.headline)
                .foregroundStyle(.green)
        }
    }
}
