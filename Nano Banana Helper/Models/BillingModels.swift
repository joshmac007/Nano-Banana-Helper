import Foundation

nonisolated struct TokenUsage: Codable, Sendable, Hashable {
    let promptTokenCount: Int
    let candidatesTokenCount: Int
    let totalTokenCount: Int
}

nonisolated enum UsageLedgerKind: String, Codable, Sendable {
    case jobCompletion
    case adjustment
    case legacyImport
}

nonisolated struct UsageLedgerEntry: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let timestamp: Date
    let kind: UsageLedgerKind
    let projectId: UUID?
    let projectNameSnapshot: String?
    let costDelta: Double
    let imageDelta: Int
    let tokenDelta: Int
    let inputTokenDelta: Int
    let outputTokenDelta: Int
    let resolution: String?
    let modelName: String?
    let relatedHistoryEntryId: UUID?
    let note: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: UsageLedgerKind,
        projectId: UUID?,
        projectNameSnapshot: String?,
        costDelta: Double,
        imageDelta: Int,
        tokenDelta: Int,
        inputTokenDelta: Int,
        outputTokenDelta: Int,
        resolution: String?,
        modelName: String?,
        relatedHistoryEntryId: UUID?,
        note: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.projectId = projectId
        self.projectNameSnapshot = projectNameSnapshot
        self.costDelta = costDelta
        self.imageDelta = imageDelta
        self.tokenDelta = tokenDelta
        self.inputTokenDelta = inputTokenDelta
        self.outputTokenDelta = outputTokenDelta
        self.resolution = resolution
        self.modelName = modelName
        self.relatedHistoryEntryId = relatedHistoryEntryId
        self.note = note
    }
}
