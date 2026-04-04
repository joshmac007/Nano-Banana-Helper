import Foundation

struct AppPricing {
    static let defaultModelName = "gemini-3.1-flash-image-preview"

    struct PricingProfile: Equatable, Sendable {
        let modelName: String
        let displayName: String
        let inputStandardRate: Double
        let inputBatchRate: Double
        let outputStandardRates: [ImageSize: Double]
    }

    struct PricingResolution: Equatable, Sendable {
        let requestedModelName: String?
        let pricingModelName: String
        let pricingDisplayName: String
        let isFallback: Bool
    }

    private static let proImageProfile = PricingProfile(
        modelName: "gemini-3-pro-image-preview",
        displayName: "Nano Banana Pro",
        inputStandardRate: 0.0011,
        inputBatchRate: 0.0006,
        outputStandardRates: [
            .size4K: 0.24,
            .size2K: 0.134,
            .size1K: 0.067,
            .size512: 0.034
        ]
    )

    private static let flashImageProfile = PricingProfile(
        modelName: "gemini-2.5-flash-image",
        displayName: "Nano Banana",
        inputStandardRate: 0.000168,
        inputBatchRate: 0.000084,
        outputStandardRates: [
            .size4K: 0.14,
            .size2K: 0.078,
            .size1K: 0.039,
            .size512: 0.02
        ]
    )

    private static let profilesByModelName: [String: PricingProfile] = [
        proImageProfile.modelName: proImageProfile,
        flashImageProfile.modelName: flashImageProfile
    ]

    // `gemini-3.1-flash-image-preview` is treated as the current Nano Banana flash-family
    // selector and shares the published Flash Image rate card until Google publishes
    // a separate image pricing row for this preview identifier.
    private static let modelAliases: [String: String] = [
        defaultModelName: flashImageProfile.modelName
    ]

    static func pricing(for modelName: String?) -> PricingResolution {
        if let modelName, let profile = profilesByModelName[modelName] {
            return PricingResolution(
                requestedModelName: modelName,
                pricingModelName: profile.modelName,
                pricingDisplayName: profile.displayName,
                isFallback: false
            )
        }

        if let modelName, let alias = modelAliases[modelName], let profile = profilesByModelName[alias] {
            return PricingResolution(
                requestedModelName: modelName,
                pricingModelName: profile.modelName,
                pricingDisplayName: profile.displayName,
                isFallback: false
            )
        }

        let fallbackModelName = modelAliases[defaultModelName] ?? flashImageProfile.modelName
        let fallbackProfile = profilesByModelName[fallbackModelName] ?? flashImageProfile
        return PricingResolution(
            requestedModelName: modelName,
            pricingModelName: fallbackProfile.modelName,
            pricingDisplayName: fallbackProfile.displayName,
            isFallback: true
        )
    }

    static func inputRate(modelName: String?, isBatchTier: Bool) -> Double {
        let profile = profile(for: modelName)
        return isBatchTier ? profile.inputBatchRate : profile.inputStandardRate
    }

    static func outputRate(for imageSize: ImageSize, modelName: String?, isBatchTier: Bool) -> Double {
        let profile = profile(for: modelName)
        let standardRate = profile.outputStandardRates[imageSize] ?? profile.outputStandardRates[.size1K] ?? 0
        return isBatchTier ? standardRate / 2 : standardRate
    }

    static func outputFallbackRate(modelName: String?, isBatchTier: Bool) -> Double {
        outputRate(for: .size1K, modelName: modelName, isBatchTier: isBatchTier)
    }

    private static func profile(for modelName: String?) -> PricingProfile {
        let resolution = pricing(for: modelName)
        return profilesByModelName[resolution.pricingModelName] ?? flashImageProfile
    }
}
