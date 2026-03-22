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
    
    private var inputCostPerImage: Double { isBatchTier ? 0.0006 : 0.0011 }
    
    private var outputCostPerImage: Double {
        guard let size = ImageSize(rawValue: imageSize) else {
            return isBatchTier ? 0.067 : 0.134 // fallback to 1K pricing
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
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                switch generationMode {
                case .image:
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
                case .text:
                    Text("\(imageCount) image\(imageCount == 1 ? "" : "s") @ \(imageSize)")
                        .font(.subheadline)
                    Text("$\(outputCostPerImage, specifier: "%.3f")/output (text-to-image)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("≈ $\(totalCost, specifier: "%.2f")")
                .font(.headline)
                .foregroundStyle(.green)
        }
    }
}
