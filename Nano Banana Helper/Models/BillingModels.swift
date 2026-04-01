import Foundation

nonisolated struct TokenUsage: Codable, Sendable, Hashable {
    let promptTokenCount: Int
    let candidatesTokenCount: Int
    let totalTokenCount: Int
}
