//
//  Nano_Banana_HelperTests.swift
//  Nano Banana HelperTests
//
//  Created by Josh McSwain on 2/2/26.
//

import Foundation
import Testing
@testable import Nano_Banana_Helper

struct Nano_Banana_HelperTests {

    @Test func example() async throws {
        // Write your test here and use APIs like
        // APIs like `#expect(...)` to check expected conditions.
    }

    // MARK: - Billing Model Tests

    @Test func tokenUsageCodable() throws {
        let usage = TokenUsage(promptTokenCount: 100, candidatesTokenCount: 50, totalTokenCount: 150)

        let encoder = JSONEncoder()
        let data = try encoder.encode(usage)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TokenUsage.self, from: data)

        #expect(decoded.promptTokenCount == 100)
        #expect(decoded.candidatesTokenCount == 50)
        #expect(decoded.totalTokenCount == 150)
    }

    @Test func historyEntryBackwardCompatibility() throws {
        // JSON without tokenUsage/modelName fields — must decode without crashing
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "projectId": "00000000-0000-0000-0000-000000000002",
            "timestamp": "2026-01-15T10:00:00Z",
            "sourceImagePaths": ["/path/to/input.png"],
            "outputImagePath": "/path/to/output.png",
            "prompt": "test prompt",
            "aspectRatio": "16:9",
            "imageSize": "2K",
            "usedBatchTier": true,
            "cost": 0.067,
            "status": "completed"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(HistoryEntry.self, from: json)

        #expect(entry.tokenUsage == nil)
        #expect(entry.modelName == nil)
        #expect(entry.cost == 0.067)
    }

    @Test func historyEntryWithTokenData() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "projectId": "00000000-0000-0000-0000-000000000002",
            "timestamp": "2026-01-15T10:00:00Z",
            "sourceImagePaths": ["/path/to/input.png"],
            "outputImagePath": "/path/to/output.png",
            "prompt": "test prompt",
            "aspectRatio": "16:9",
            "imageSize": "2K",
            "usedBatchTier": true,
            "cost": 0.067,
            "status": "completed",
            "tokenUsage": {
                "promptTokenCount": 200,
                "candidatesTokenCount": 80,
                "totalTokenCount": 280
            },
            "modelName": "gemini-3.1-flash-image-preview"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(HistoryEntry.self, from: json)

        #expect(entry.tokenUsage != nil)
        #expect(entry.tokenUsage?.promptTokenCount == 200)
        #expect(entry.tokenUsage?.candidatesTokenCount == 80)
        #expect(entry.tokenUsage?.totalTokenCount == 280)
        #expect(entry.modelName == "gemini-3.1-flash-image-preview")
    }

    @Test func costSummaryBackwardCompatibility() throws {
        // JSON without token/model fields — must decode without crashing
        let json = """
        {
            "totalSpent": 1.34,
            "imageCount": 10,
            "byResolution": {"2K": 0.67, "4K": 0.67},
            "byProject": {"00000000-0000-0000-0000-000000000001": 1.34}
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let summary = try decoder.decode(CostSummary.self, from: json)

        #expect(summary.totalSpent == 1.34)
        #expect(summary.imageCount == 10)
        #expect(summary.totalTokens == 0)
        #expect(summary.inputTokens == 0)
        #expect(summary.outputTokens == 0)
        #expect(summary.byModel.isEmpty)
    }

    @Test func costSummaryRecordWithTokens() throws {
        var summary = CostSummary()
        let projectId = UUID()

        let usage = TokenUsage(promptTokenCount: 500, candidatesTokenCount: 200, totalTokenCount: 700)

        summary.record(cost: 0.134, resolution: "2K", projectId: projectId, tokens: usage, modelName: "gemini-2.5-flash")
        summary.record(cost: 0.067, resolution: "1K", projectId: projectId, tokens: nil, modelName: "gemini-3.1-flash")

        #expect(summary.totalSpent == 0.201)
        #expect(summary.imageCount == 2)
        #expect(summary.totalTokens == 700)
        #expect(summary.inputTokens == 500)
        #expect(summary.outputTokens == 200)
        #expect(summary.byModel["gemini-2.5-flash"] == 0.134)
        #expect(summary.byModel["gemini-3.1-flash"] == 0.067)
        #expect(summary.byResolution["2K"] == 0.134)
        #expect(summary.byResolution["1K"] == 0.067)
    }

    @Test func costSummaryRoundTrip() throws {
        var summary = CostSummary()
        let projectId = UUID()
        let usage = TokenUsage(promptTokenCount: 100, candidatesTokenCount: 50, totalTokenCount: 150)

        summary.record(cost: 0.50, resolution: "4K", projectId: projectId, tokens: usage, modelName: "gemini-3-pro")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CostSummary.self, from: data)

        #expect(decoded.totalSpent == 0.50)
        #expect(decoded.totalTokens == 150)
        #expect(decoded.inputTokens == 100)
        #expect(decoded.outputTokens == 50)
        #expect(decoded.byModel["gemini-3-pro"] == 0.50)
    }
}
