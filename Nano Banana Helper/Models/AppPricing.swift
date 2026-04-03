import Foundation

struct AppPricing {
    static let inputStandardRate = 0.0011
    static let inputBatchRate = 0.0006

    static let outputStandardRates: [ImageSize: Double] = [
        .size4K: 0.24,
        .size2K: 0.134,
        .size1K: 0.067,
        .size512: 0.034
    ]

    static func inputRate(isBatchTier: Bool) -> Double {
        isBatchTier ? inputBatchRate : inputStandardRate
    }

    static func outputRate(for imageSize: ImageSize, isBatchTier: Bool) -> Double {
        let standardRate = outputStandardRates[imageSize] ?? outputStandardRates[.size1K] ?? 0
        return isBatchTier ? standardRate / 2 : standardRate
    }

    static func outputFallbackRate(isBatchTier: Bool) -> Double {
        outputRate(for: .size1K, isBatchTier: isBatchTier)
    }
}
