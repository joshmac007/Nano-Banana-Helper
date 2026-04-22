import Foundation

nonisolated struct TokenUsage: Codable, Sendable, Hashable {
    let promptTokenCount: Int
    let candidatesTokenCount: Int
    let totalTokenCount: Int
    let promptImageTokenCount: Int?
    let promptTextTokenCount: Int?
    let candidateImageTokenCount: Int?
    let candidateTextTokenCount: Int?

    init(
        promptTokenCount: Int,
        candidatesTokenCount: Int,
        totalTokenCount: Int,
        promptImageTokenCount: Int? = nil,
        promptTextTokenCount: Int? = nil,
        candidateImageTokenCount: Int? = nil,
        candidateTextTokenCount: Int? = nil
    ) {
        self.promptTokenCount = promptTokenCount
        self.candidatesTokenCount = candidatesTokenCount
        self.totalTokenCount = totalTokenCount
        self.promptImageTokenCount = promptImageTokenCount
        self.promptTextTokenCount = promptTextTokenCount
        self.candidateImageTokenCount = candidateImageTokenCount
        self.candidateTextTokenCount = candidateTextTokenCount
    }

    enum CodingKeys: String, CodingKey {
        case promptTokenCount, candidatesTokenCount, totalTokenCount
        case promptImageTokenCount, promptTextTokenCount
        case candidateImageTokenCount, candidateTextTokenCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokenCount = try container.decode(Int.self, forKey: .promptTokenCount)
        candidatesTokenCount = try container.decode(Int.self, forKey: .candidatesTokenCount)
        totalTokenCount = try container.decode(Int.self, forKey: .totalTokenCount)
        promptImageTokenCount = try container.decodeIfPresent(Int.self, forKey: .promptImageTokenCount)
        promptTextTokenCount = try container.decodeIfPresent(Int.self, forKey: .promptTextTokenCount)
        candidateImageTokenCount = try container.decodeIfPresent(Int.self, forKey: .candidateImageTokenCount)
        candidateTextTokenCount = try container.decodeIfPresent(Int.self, forKey: .candidateTextTokenCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(promptTokenCount, forKey: .promptTokenCount)
        try container.encode(candidatesTokenCount, forKey: .candidatesTokenCount)
        try container.encode(totalTokenCount, forKey: .totalTokenCount)
        try container.encodeIfPresent(promptImageTokenCount, forKey: .promptImageTokenCount)
        try container.encodeIfPresent(promptTextTokenCount, forKey: .promptTextTokenCount)
        try container.encodeIfPresent(candidateImageTokenCount, forKey: .candidateImageTokenCount)
        try container.encodeIfPresent(candidateTextTokenCount, forKey: .candidateTextTokenCount)
    }
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
