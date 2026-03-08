import Foundation

struct ModelCapabilities: Sendable {
    let allowedAspectRatios: [String]
    let allowedImageSizes: [String]
    let maxInputImages: Int?
}

struct ModelPricing: Sendable {
    let inputPricePerImageStandard: Double?
    let inputPricePerImageBatch: Double?
    let outputPricePerImageStandard: [String: Double]
    let outputPricePerImageBatch: [String: Double]

    // Informational metadata from docs; not used directly for pricing math.
    let inputPricePerMillionTokens: Double?
    let outputPricePerMillionTokens: Double?
    let outputImagePricePerMillionImages: Double?
}

struct ModelDefinition: Identifiable, Sendable {
    let id: String
    let displayName: String
    let capabilities: ModelCapabilities
    let pricing: ModelPricing
}

enum ModelCatalog {
    nonisolated static let proImageId = "gemini-3-pro-image-preview"
    nonisolated static let flash31ImageId = "gemini-3.1-flash-image-preview"

    private nonisolated static let proRatios = [
        "1:1",
        "2:3",
        "3:2",
        "3:4",
        "4:3",
        "4:5",
        "5:4",
        "9:16",
        "16:9",
        "21:9"
    ]
    private nonisolated static let flashRatios = [
        "1:1",
        "2:3",
        "3:2",
        "3:4",
        "4:3",
        "4:5",
        "5:4",
        "9:16",
        "16:9",
        "21:9",
        "3:1",
        "1:3",
        "4:1",
        "1:4",
        "8:1",
        "1:8"
    ]

    private nonisolated static let proSizes = ["1K", "2K", "4K"]
    private nonisolated static let flashSizes = ["0.5K", "1K", "2K", "4K"]

    nonisolated static let all: [ModelDefinition] = [
        ModelDefinition(
            id: proImageId,
            displayName: "Nano Banana Pro",
            capabilities: ModelCapabilities(
                allowedAspectRatios: proRatios,
                allowedImageSizes: proSizes,
                maxInputImages: 14
            ),
            pricing: ModelPricing(
                inputPricePerImageStandard: 0.0011,
                inputPricePerImageBatch: 0.0006,
                outputPricePerImageStandard: ["1K": 0.134, "2K": 0.134, "4K": 0.24],
                outputPricePerImageBatch: ["1K": 0.067, "2K": 0.067, "4K": 0.12],
                inputPricePerMillionTokens: nil,
                outputPricePerMillionTokens: nil,
                outputImagePricePerMillionImages: nil
            )
        ),
        ModelDefinition(
            id: flash31ImageId,
            displayName: "Nano Banana 2 (Flash)",
            capabilities: ModelCapabilities(
                allowedAspectRatios: flashRatios,
                allowedImageSizes: flashSizes,
                maxInputImages: 14
            ),
            pricing: ModelPricing(
                inputPricePerImageStandard: nil,
                inputPricePerImageBatch: nil,
                outputPricePerImageStandard: ["0.5K": 0.045, "1K": 0.067, "2K": 0.101, "4K": 0.151],
                outputPricePerImageBatch: ["0.5K": 0.0225, "1K": 0.0335, "2K": 0.0505, "4K": 0.0755],
                inputPricePerMillionTokens: 0.25,
                outputPricePerMillionTokens: 1.50,
                outputImagePricePerMillionImages: 60.00
            )
        )
    ]

    nonisolated static var defaultModelId: String { proImageId }

    nonisolated static func definition(for modelName: String) -> ModelDefinition {
        all.first(where: { $0.id == modelName }) ?? all[0]
    }

    nonisolated static func displayName(for modelName: String) -> String {
        definition(for: modelName).displayName
    }

    nonisolated static func supportedAspectRatios(for modelName: String) -> [String] {
        definition(for: modelName).capabilities.allowedAspectRatios
    }

    nonisolated static func supportedImageSizes(for modelName: String) -> [String] {
        definition(for: modelName).capabilities.allowedImageSizes
    }

    nonisolated static func isAspectRatioSupported(_ ratio: String, for modelName: String) -> Bool {
        ratio == "Auto" || supportedAspectRatios(for: modelName).contains(ratio)
    }

    nonisolated static func isImageSizeSupported(_ size: String, for modelName: String) -> Bool {
        supportedImageSizes(for: modelName).contains(size)
    }

    nonisolated static func sanitizeAspectRatio(_ ratio: String, for modelName: String) -> String {
        if ratio == "Auto" { return ratio }
        let allowed = supportedAspectRatios(for: modelName)
        if allowed.contains(ratio) {
            return ratio
        }
        if allowed.contains("16:9") {
            return "16:9"
        }
        return allowed.first ?? "16:9"
    }

    nonisolated static func sanitizeImageSize(_ size: String, for modelName: String) -> String {
        let allowed = supportedImageSizes(for: modelName)
        guard !allowed.isEmpty else { return size }
        if allowed.contains(size) {
            return size
        }

        let fallback = preferredDefaultSize(for: modelName)
        if allowed.contains(fallback) {
            return fallback
        }

        return allowed.last ?? allowed[0]
    }

    nonisolated static func preferredDefaultSize(for modelName: String) -> String {
        let allowed = supportedImageSizes(for: modelName)
        if allowed.contains("4K") { return "4K" }
        if allowed.contains("2K") { return "2K" }
        if allowed.contains("1K") { return "1K" }
        return allowed.first ?? "1K"
    }
}
