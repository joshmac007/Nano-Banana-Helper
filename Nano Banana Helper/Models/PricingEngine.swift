import Foundation

struct CostEstimate: Sendable {
    let modelName: String
    let imageSize: String
    let isBatchTier: Bool
    let inputCount: Int
    let outputCount: Int
    let inputCost: Double
    let outputCost: Double

    var total: Double {
        inputCost + outputCost
    }
}

enum PricingEngine {
    static func estimate(
        modelName: String,
        imageSize: String,
        isBatchTier: Bool,
        inputCount: Int,
        outputCount: Int
    ) -> CostEstimate {
        let definition = ModelCatalog.definition(for: modelName)
        let normalizedSize = ModelCatalog.sanitizeImageSize(imageSize, for: definition.id)
        let pricing = definition.pricing

        let outputMap = isBatchTier ? pricing.outputPricePerImageBatch : pricing.outputPricePerImageStandard
        let outputRate = outputMap[normalizedSize] ?? outputMap["1K"] ?? outputMap.values.first ?? 0

        let inputRate: Double
        if isBatchTier {
            inputRate = pricing.inputPricePerImageBatch ?? 0
        } else {
            inputRate = pricing.inputPricePerImageStandard ?? 0
        }

        return CostEstimate(
            modelName: definition.id,
            imageSize: normalizedSize,
            isBatchTier: isBatchTier,
            inputCount: inputCount,
            outputCount: outputCount,
            inputCost: Double(max(0, inputCount)) * inputRate,
            outputCost: Double(max(0, outputCount)) * outputRate
        )
    }

    static func outputPricePerImage(modelName: String, imageSize: String, isBatchTier: Bool) -> Double {
        estimate(
            modelName: modelName,
            imageSize: imageSize,
            isBatchTier: isBatchTier,
            inputCount: 0,
            outputCount: 1
        ).outputCost
    }
}
