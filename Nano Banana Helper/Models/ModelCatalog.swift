import Foundation

struct ModelCatalogEntry: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let isDeprecated: Bool
    let isSelectable: Bool

    var statusLabel: String? {
        if !isSelectable { return nil }
        if isDeprecated { return "Legacy" }
        return nil
    }

    var pickerLabel: String {
        guard let statusLabel else { return displayName }
        return "\(displayName) (\(statusLabel))"
    }
}

enum CuratedModelCatalog {
    struct Definition: Sendable {
        let id: String
        let displayName: String
        let isDeprecated: Bool
    }

    static let definitions: [Definition] = [
        Definition(
            id: "gemini-3.1-flash-image-preview",
            displayName: "Nano Banana 2",
            isDeprecated: false
        ),
        Definition(
            id: "gemini-3-pro-image-preview",
            displayName: "Nano Banana Pro",
            isDeprecated: false
        ),
        Definition(
            id: "gemini-2.5-flash-image",
            displayName: "Nano Banana",
            isDeprecated: true
        )
    ]

    private static var selectableDefinitions: [Definition] {
        definitions.filter { !$0.isDeprecated }
    }

    static func fallbackEntries(selectedModelID: String? = nil) -> [ModelCatalogEntry] {
        mergeLegacySelection(
            into: selectableDefinitions.map {
                ModelCatalogEntry(
                    id: $0.id,
                    displayName: $0.displayName,
                    isDeprecated: $0.isDeprecated,
                    isSelectable: true
                )
            },
            selectedModelID: selectedModelID
        )
    }

    static func entries(from responseData: Data, selectedModelID: String?) throws -> [ModelCatalogEntry] {
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

        let entries: [ModelCatalogEntry] = selectableDefinitions.compactMap { definition in
            guard supportedIDs.contains(definition.id) else { return nil }
            return ModelCatalogEntry(
                id: definition.id,
                displayName: definition.displayName,
                isDeprecated: definition.isDeprecated,
                isSelectable: true
            )
        }

        return mergeLegacySelection(into: entries, selectedModelID: selectedModelID)
    }

    private static func mergeLegacySelection(
        into entries: [ModelCatalogEntry],
        selectedModelID: String?
    ) -> [ModelCatalogEntry] {
        guard let selectedModelID, !selectedModelID.isEmpty else { return entries }
        guard entries.contains(where: { $0.id == selectedModelID }) == false else { return entries }

        return [
            ModelCatalogEntry(
                id: selectedModelID,
                displayName: "Legacy: \(selectedModelID)",
                isDeprecated: true,
                isSelectable: false
            )
        ] + entries
    }
}
