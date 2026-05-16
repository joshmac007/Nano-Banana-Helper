import Foundation

nonisolated struct ModelCatalogEntry: Identifiable, Equatable, Sendable {
    let id: String
    let provider: ModelProvider
    let displayName: String
    let supportsBatchTier: Bool
    let supportsMasking: Bool
    let isDeprecated: Bool
    let isSelectable: Bool

    var statusLabel: String? {
        if !isSelectable { return nil }
        if isDeprecated { return "Legacy" }
        if !supportsBatchTier { return "Standard only" }
        if supportsMasking { return "Masking" }
        return nil
    }

    var pickerLabel: String {
        guard let statusLabel else { return displayName }
        return "\(displayName) (\(statusLabel))"
    }
}

nonisolated enum CuratedModelCatalog {
    struct Definition: Sendable {
        let provider: ModelProvider
        let id: String
        let displayName: String
        let supportsBatchTier: Bool
        let supportsMasking: Bool
        let isDeprecated: Bool
    }

    static let definitions: [Definition] = [
        Definition(
            provider: .gemini,
            id: "gemini-3.1-flash-image-preview",
            displayName: "Nano Banana 2",
            supportsBatchTier: true,
            supportsMasking: false,
            isDeprecated: false
        ),
        Definition(
            provider: .gemini,
            id: "gemini-3-pro-image-preview",
            displayName: "Nano Banana Pro",
            supportsBatchTier: true,
            supportsMasking: false,
            isDeprecated: false
        ),
        Definition(
            provider: .gemini,
            id: "gemini-2.5-flash-image",
            displayName: "Nano Banana",
            supportsBatchTier: true,
            supportsMasking: false,
            isDeprecated: true
        ),
        Definition(
            provider: .openAI,
            id: "gpt-image-2",
            displayName: "GPT Image 2",
            supportsBatchTier: true,
            supportsMasking: true,
            isDeprecated: false
        )
    ]

    static func defaultModelID(for provider: ModelProvider) -> String {
        selectableDefinitions(for: provider).first?.id
            ?? definitions.first(where: { $0.provider == provider })?.id
            ?? "gemini-3.1-flash-image-preview"
    }

    static func fallbackEntries(selectedModelID: String? = nil) -> [ModelCatalogEntry] {
        fallbackEntries(for: .gemini, selectedModelID: selectedModelID)
    }

    private static func selectableDefinitions(for provider: ModelProvider) -> [Definition] {
        definitions.filter { $0.provider == provider && !$0.isDeprecated }
    }

    static func fallbackEntries(for provider: ModelProvider, selectedModelID: String? = nil) -> [ModelCatalogEntry] {
        mergeLegacySelection(
            into: selectableDefinitions(for: provider).map(entry(from:)),
            provider: provider,
            selectedModelID: selectedModelID
        )
    }

    static func entries(from responseData: Data, provider: ModelProvider, selectedModelID: String?) throws -> [ModelCatalogEntry] {
        switch provider {
        case .gemini:
            let payload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            let models = payload?["models"] as? [[String: Any]] ?? []

            let supportedIDs: Set<String> = Set(
                models.compactMap { model in
                    let rawName = model["name"] as? String ?? ""
                    let normalizedID = rawName.replacingOccurrences(of: "models/", with: "")
                    let methods = model["supportedGenerationMethods"] as? [String] ?? []
                    guard methods.contains("generateContent"),
                          methods.contains("batchGenerateContent") else { return nil }
                    return normalizedID
                }
            )

            let entries = selectableDefinitions(for: provider)
                .filter { supportedIDs.contains($0.id) }
                .map(entry(from:))

            return mergeLegacySelection(into: entries, provider: provider, selectedModelID: selectedModelID)
        case .openAI:
            return fallbackEntries(for: provider, selectedModelID: selectedModelID)
        }
    }

    static func entries(from responseData: Data, selectedModelID: String?) throws -> [ModelCatalogEntry] {
        try entries(from: responseData, provider: .gemini, selectedModelID: selectedModelID)
    }

    private static func entry(from definition: Definition) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: definition.id,
            provider: definition.provider,
            displayName: definition.displayName,
            supportsBatchTier: definition.supportsBatchTier,
            supportsMasking: definition.supportsMasking,
            isDeprecated: definition.isDeprecated,
            isSelectable: true
        )
    }

    private static func mergeLegacySelection(
        into entries: [ModelCatalogEntry],
        provider: ModelProvider,
        selectedModelID: String?
    ) -> [ModelCatalogEntry] {
        guard let selectedModelID, !selectedModelID.isEmpty else { return entries }
        guard entries.contains(where: { $0.id == selectedModelID }) == false else { return entries }

        return [
            ModelCatalogEntry(
                id: selectedModelID,
                provider: provider,
                displayName: "Legacy: \(selectedModelID)",
                supportsBatchTier: false,
                supportsMasking: provider == .openAI,
                isDeprecated: true,
                isSelectable: false
            )
        ] + entries
    }
}
