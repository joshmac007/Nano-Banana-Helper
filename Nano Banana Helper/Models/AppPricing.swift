import Foundation

struct AppPricing {
    static let defaultModelName = CuratedModelCatalog.defaultModelID(for: .gemini)

    enum PricingMode: Equatable, Sendable {
        case perImage
        case tokenBased
    }

    struct PricingProfile: Equatable, Sendable {
        let provider: ModelProvider
        let modelName: String
        let displayName: String
        let pricingMode: PricingMode
        let supportsBatchTier: Bool
        let inputStandardRate: Double
        let inputBatchRate: Double
        let outputStandardRates: [ImageSize: Double]
        let textInputTokenRate: Double?
        let textOutputTokenRate: Double?
        let imageInputTokenRate: Double?
        let imageOutputTokenRate: Double?
    }

    struct PricingResolution: Equatable, Sendable {
        let requestedModelName: String?
        let provider: ModelProvider
        let pricingModelName: String
        let pricingDisplayName: String
        let pricingMode: PricingMode
        let supportsBatchTier: Bool
        let isFallback: Bool
        let note: String?
    }

    private static let proImageProfile = PricingProfile(
        provider: .gemini,
        modelName: "gemini-3-pro-image-preview",
        displayName: "Nano Banana Pro",
        pricingMode: .perImage,
        supportsBatchTier: true,
        inputStandardRate: 0.0011,
        inputBatchRate: 0.0006,
        outputStandardRates: [
            .size4K: 0.24,
            .size2K: 0.134,
            .size1K: 0.067,
            .size512: 0.034
        ],
        textInputTokenRate: nil,
        textOutputTokenRate: nil,
        imageInputTokenRate: nil,
        imageOutputTokenRate: nil
    )

    private static let flashImageProfile = PricingProfile(
        provider: .gemini,
        modelName: "gemini-2.5-flash-image",
        displayName: "Nano Banana",
        pricingMode: .perImage,
        supportsBatchTier: true,
        inputStandardRate: 0.000168,
        inputBatchRate: 0.000084,
        outputStandardRates: [
            .size4K: 0.14,
            .size2K: 0.078,
            .size1K: 0.039,
            .size512: 0.02
        ],
        textInputTokenRate: nil,
        textOutputTokenRate: nil,
        imageInputTokenRate: nil,
        imageOutputTokenRate: nil
    )

    private static let openAIImageProfile = PricingProfile(
        provider: .openAI,
        modelName: "gpt-image-2",
        displayName: "GPT Image 2",
        pricingMode: .tokenBased,
        supportsBatchTier: true,
        inputStandardRate: 0,
        inputBatchRate: 0,
        outputStandardRates: [:],
        textInputTokenRate: 5.0 / 1_000_000.0,
        textOutputTokenRate: 10.0 / 1_000_000.0,
        imageInputTokenRate: 8.0 / 1_000_000.0,
        imageOutputTokenRate: 30.0 / 1_000_000.0
    )

    private static let profilesByModelName: [String: PricingProfile] = [
        proImageProfile.modelName: proImageProfile,
        flashImageProfile.modelName: flashImageProfile,
        openAIImageProfile.modelName: openAIImageProfile
    ]

    private static let modelAliases: [String: String] = [
        "gemini-3.1-flash-image-preview": flashImageProfile.modelName
    ]

    static func defaultModelName(for provider: ModelProvider) -> String {
        CuratedModelCatalog.defaultModelID(for: provider)
    }

    static func pricing(for modelName: String?, provider: ModelProvider? = nil) -> PricingResolution {
        let resolvedProvider = provider ?? inferProvider(for: modelName) ?? .gemini

        if let modelName, let profile = profilesByModelName[modelName], profile.provider == resolvedProvider {
            return resolution(for: profile, requestedModelName: modelName, isFallback: false)
        }

        if let modelName,
           let alias = modelAliases[modelName],
           let profile = profilesByModelName[alias],
           profile.provider == resolvedProvider {
            return resolution(for: profile, requestedModelName: modelName, isFallback: false)
        }

        let fallbackModelName = defaultModelName(for: resolvedProvider)
        let fallbackProfile = profilesByModelName[fallbackModelName]
            ?? (resolvedProvider == .openAI ? openAIImageProfile : flashImageProfile)

        return resolution(for: fallbackProfile, requestedModelName: modelName, isFallback: true)
    }

    static func inputRate(modelName: String?, provider: ModelProvider? = nil, isBatchTier: Bool) -> Double {
        let profile = profile(for: modelName, provider: provider)
        guard profile.pricingMode == .perImage else { return 0 }
        return isBatchTier ? profile.inputBatchRate : profile.inputStandardRate
    }

    static func outputRate(for imageSize: ImageSize, modelName: String?, provider: ModelProvider? = nil, isBatchTier: Bool) -> Double {
        let profile = profile(for: modelName, provider: provider)
        guard profile.pricingMode == .perImage else { return 0 }
        let standardRate = profile.outputStandardRates[imageSize] ?? profile.outputStandardRates[.size1K] ?? 0
        return isBatchTier ? standardRate / 2 : standardRate
    }

    static func outputFallbackRate(modelName: String?, provider: ModelProvider? = nil, isBatchTier: Bool) -> Double {
        outputRate(for: .size1K, modelName: modelName, provider: provider, isBatchTier: isBatchTier)
    }

    static func usageCost(modelName: String?, provider: ModelProvider? = nil, tokenUsage: TokenUsage?, isBatchTier: Bool) -> Double? {
        guard let tokenUsage else { return nil }
        let profile = profile(for: modelName, provider: provider)

        switch profile.pricingMode {
        case .perImage:
            return nil
        case .tokenBased:
            guard let textInputRate = profile.textInputTokenRate,
                  let textOutputRate = profile.textOutputTokenRate,
                  let imageInputRate = profile.imageInputTokenRate,
                  let imageOutputRate = profile.imageOutputTokenRate else {
                return nil
            }

            let inputImageTokens = Double(tokenUsage.promptImageTokenCount ?? 0)
            let inputTextTokens = Double(
                tokenUsage.promptImageTokenCount == nil && tokenUsage.promptTextTokenCount == nil
                    ? tokenUsage.promptTokenCount
                    : tokenUsage.promptTextTokenCount ?? 0
            )
            let outputImageTokens = Double(
                tokenUsage.candidateImageTokenCount == nil && tokenUsage.candidateTextTokenCount == nil
                    ? tokenUsage.candidatesTokenCount
                    : tokenUsage.candidateImageTokenCount ?? 0
            )
            let outputTextTokens = Double(tokenUsage.candidateTextTokenCount ?? 0)

            let standardCost =
                (inputImageTokens * imageInputRate) +
                (inputTextTokens * textInputRate) +
                (outputImageTokens * imageOutputRate) +
                (outputTextTokens * textOutputRate)

            return isBatchTier ? standardCost / 2 : standardCost
        }
    }

    private static func profile(for modelName: String?, provider: ModelProvider? = nil) -> PricingProfile {
        let resolution = pricing(for: modelName, provider: provider)
        return profilesByModelName[resolution.pricingModelName]
            ?? (resolution.provider == .openAI ? openAIImageProfile : flashImageProfile)
    }

    private static func inferProvider(for modelName: String?) -> ModelProvider? {
        guard let modelName else { return nil }
        if let definition = CuratedModelCatalog.definitions.first(where: { $0.id == modelName }) {
            return definition.provider
        }
        if modelName.hasPrefix("gpt-image") { return .openAI }
        if modelName.hasPrefix("gemini") { return .gemini }
        return nil
    }

    private static func resolution(for profile: PricingProfile, requestedModelName: String?, isFallback: Bool) -> PricingResolution {
        PricingResolution(
            requestedModelName: requestedModelName,
            provider: profile.provider,
            pricingModelName: profile.modelName,
            pricingDisplayName: profile.displayName,
            pricingMode: profile.pricingMode,
            supportsBatchTier: profile.supportsBatchTier,
            isFallback: isFallback,
            note: pricingNote(for: profile, isFallback: isFallback)
        )
    }

    private static func pricingNote(for profile: PricingProfile, isFallback: Bool) -> String? {
        if profile.pricingMode == .tokenBased {
            return "OpenAI image costs are token-based. Projected costs are approximate until usage details are returned by the API."
        }
        if isFallback {
            return "Using \(profile.displayName) pricing fallback."
        }
        return nil
    }
}
