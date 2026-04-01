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
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeProject() -> Project {
        Project(name: "Test Project", outputDirectory: "/tmp")
    }

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

    @Test func serviceURLBuildersPercentEncodeAPIKeyAndDynamicValues() throws {
        let apiKey = "abc def✓&?"
        let modelName = "gemini model"
        let jobName = "batches/job 1"
        let fileName = "files/result set"

        let urls = try [
            NanoBananaService.generateContentURL(apiKey: apiKey, modelName: modelName),
            NanoBananaService.batchGenerateContentURL(apiKey: apiKey, modelName: modelName),
            NanoBananaService.batchOperationURL(jobName: jobName, apiKey: apiKey),
            NanoBananaService.downloadResultsURL(fileName: fileName, apiKey: apiKey),
            NanoBananaService.cancelBatchJobURL(jobName: jobName, apiKey: apiKey)
        ]

        for url in urls {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryKey = components?.queryItems?.first(where: { $0.name == "key" })?.value
            #expect(queryKey == apiKey)
            #expect(url.absoluteString.contains("%20"))
            #expect(url.absoluteString.contains("%E2%9C%93"))
            #expect(url.absoluteString.contains("%26"))
            #expect(url.absoluteString.contains("%3F"))
        }
    }

    @Test func pollRetryStateBacksOffAndResets() {
        var retryState = PollRetryState()

        let firstDelay = retryState.registerRetryableError()
        let secondDelay = retryState.registerRetryableError()

        #expect(secondDelay > firstDelay)
        #expect(retryState.consecutiveErrors == 2)

        retryState.reset()
        #expect(retryState.consecutiveErrors == 0)
        #expect(retryState.registerRetryableError() == firstDelay)
    }

    @Test func resolveBookmarkReturnsRefreshedBookmarkData() {
        let originalBookmark = Data("old".utf8)
        let refreshedBookmark = Data("new".utf8)
        let url = URL(fileURLWithPath: "/tmp/bookmark-test")
        let dependencies = AppPaths.BookmarkResolutionDependencies(
            resolveURL: { data in
                #expect(data == originalBookmark)
                return (url, true)
            },
            refreshBookmarkData: { refreshedURL in
                #expect(refreshedURL == url)
                return refreshedBookmark
            },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )

        let resolution = AppPaths.resolveBookmark(originalBookmark, dependencies: dependencies)

        #expect(resolution?.url == url)
        #expect(resolution?.refreshedBookmarkData == refreshedBookmark)
    }

    @Test func historyManagerPersistsRefreshedBookmarksOnLoad() throws {
        let projectId = UUID()
        let oldSourceBookmark = Data("old-source".utf8)
        let newSourceBookmark = Data("new-source".utf8)
        let oldOutputBookmark = Data("old-output".utf8)
        let newOutputBookmark = Data("new-output".utf8)
        let tempProjectsDirectory = try makeTemporaryDirectory()
        let dependencies = AppPaths.BookmarkResolutionDependencies(
            resolveURL: { data in
                let suffix = String(decoding: data, as: UTF8.self)
                return (URL(fileURLWithPath: "/tmp/\(suffix)"), true)
            },
            refreshBookmarkData: { url in
                if url.lastPathComponent == "old-source" {
                    return newSourceBookmark
                }
                return newOutputBookmark
            },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )

        let initialManager = HistoryManager(
            projectsDirectoryURL: tempProjectsDirectory,
            bookmarkDependencies: dependencies
        )
        initialManager.entries = [
            HistoryEntry(
                projectId: projectId,
                sourceImagePaths: ["/tmp/input.png"],
                outputImagePath: "/tmp/output.png",
                prompt: "prompt",
                aspectRatio: "16:9",
                imageSize: "2K",
                usedBatchTier: false,
                cost: 1,
                sourceImageBookmarks: [oldSourceBookmark],
                outputImageBookmark: oldOutputBookmark
            )
        ]
        initialManager.saveHistory(for: projectId)

        let loadedManager = HistoryManager(
            projectsDirectoryURL: tempProjectsDirectory,
            bookmarkDependencies: dependencies
        )
        loadedManager.loadHistory(for: projectId)

        #expect(loadedManager.entries.count == 1)
        #expect(loadedManager.entries[0].sourceImageBookmarks == [newSourceBookmark])
        #expect(loadedManager.entries[0].outputImageBookmark == newOutputBookmark)

        let fileURL = tempProjectsDirectory
            .appendingPathComponent(projectId.uuidString)
            .appendingPathComponent("history.json")
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persistedEntries = try decoder.decode([HistoryEntry].self, from: data)

        #expect(persistedEntries[0].sourceImageBookmarks == [newSourceBookmark])
        #expect(persistedEntries[0].outputImageBookmark == newOutputBookmark)
    }

    @Test func orchestratorResetRemovesPersistedActiveBatchFile() throws {
        let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
        let orchestrator = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false
        )
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        batch.tasks = [ImageTask(inputPaths: ["/tmp/input.png"])]

        orchestrator.enqueue(batch)
        #expect(FileManager.default.fileExists(atPath: activeBatchURL.path))

        orchestrator.reset()

        #expect(!FileManager.default.fileExists(atPath: activeBatchURL.path))
    }

    @Test func clearHistoryRemovesEntriesFromGlobalCacheAndDisk() throws {
        let project = makeProject()
        let projectId = project.id
        let tempProjectsDirectory = try makeTemporaryDirectory()
        let manager = HistoryManager(projectsDirectoryURL: tempProjectsDirectory)
        let entry = HistoryEntry(
            projectId: projectId,
            sourceImagePaths: ["/tmp/input.png"],
            outputImagePath: "/tmp/output.png",
            prompt: "prompt",
            aspectRatio: "16:9",
            imageSize: "2K",
            usedBatchTier: false,
            cost: 1
        )

        manager.entries = [entry]
        manager.saveHistory(for: projectId)
        manager.loadHistory(for: projectId)
        manager.loadGlobalHistory(allProjects: [project])

        manager.clearHistory(for: projectId)

        #expect(manager.entries.isEmpty)
        #expect(manager.allGlobalEntries.isEmpty)

        let fileURL = tempProjectsDirectory
            .appendingPathComponent(projectId.uuidString)
            .appendingPathComponent("history.json")
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persistedEntries = try decoder.decode([HistoryEntry].self, from: data)
        #expect(persistedEntries.isEmpty)
    }

    @Test func recordCostIncurredPersistsCostSummaryMidSession() throws {
        let tempAppSupportURL = try makeTemporaryDirectory()
        let projectsListURL = tempAppSupportURL.appendingPathComponent("projects.json")
        let costSummaryURL = tempAppSupportURL.appendingPathComponent("cost_summary.json")
        let projectsDirectoryURL = tempAppSupportURL.appendingPathComponent("projects", isDirectory: true)
        let manager = ProjectManager(
            appSupportURL: tempAppSupportURL,
            projectsListURL: projectsListURL,
            costSummaryURL: costSummaryURL,
            projectsDirectoryURL: projectsDirectoryURL
        )
        let usage = TokenUsage(promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15)
        let projectId = manager.projects.first!.id

        manager.recordCostIncurred(
            cost: 0.5,
            resolution: "4K",
            projectId: projectId,
            tokenUsage: usage,
            modelName: "gemini-test"
        )

        let data = try Data(contentsOf: costSummaryURL)
        let decoder = JSONDecoder()
        let summary = try decoder.decode(CostSummary.self, from: data)

        #expect(summary.totalSpent == 0.5)
        #expect(summary.imageCount == 1)
        #expect(summary.byModel["gemini-test"] == 0.5)
        #expect(manager.sessionCost == 0.5)
        #expect(manager.sessionTokens == 15)
        #expect(manager.sessionImageCount == 1)
    }

    @Test func cancelHandlesSubmittingPhaseTasks() throws {
        let orchestrator = BatchOrchestrator(
            activeBatchURL: try makeTemporaryDirectory().appendingPathComponent("active_batch.json"),
            autoStartEnqueuedBatches: false
        )
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        let task = ImageTask(inputPaths: ["/tmp/input.png"])
        task.status = "processing"
        task.phase = .submitting
        batch.tasks = [task]

        orchestrator.enqueue(batch)
        orchestrator.cancel(batch: batch)

        #expect(batch.status == "cancelled")
        #expect(task.status == "failed")
        #expect(task.phase == .failed)
        #expect(task.error == "Cancelled by user")
    }

    @Test func startAllStartsEligibleBatchesConcurrently() async throws {
        let probe = BatchStartProbe()
        let orchestrator = BatchOrchestrator(
            activeBatchURL: try makeTemporaryDirectory().appendingPathComponent("active_batch.json"),
            autoStartEnqueuedBatches: false,
            processQueueOverride: { batchID in
                await probe.recordStart(batchID)
                await probe.waitUntilReleased()
            }
        )
        let firstBatch = BatchJob(prompt: "one", outputDirectory: "/tmp")
        firstBatch.tasks = [ImageTask(inputPaths: ["/tmp/one.png"])]
        let secondBatch = BatchJob(prompt: "two", outputDirectory: "/tmp")
        secondBatch.tasks = [ImageTask(inputPaths: ["/tmp/two.png"])]
        orchestrator.enqueue(firstBatch)
        orchestrator.enqueue(secondBatch)

        let task = Task {
            await orchestrator.startAll()
        }

        var startedCount = 0
        for _ in 0..<30 {
            startedCount = await probe.startedCount()
            if startedCount == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        await probe.release()
        await task.value

        #expect(startedCount == 2)
    }
}

actor BatchStartProbe {
    private var startedBatchIDs: [UUID] = []
    private var isReleased = false

    func recordStart(_ id: UUID) {
        startedBatchIDs.append(id)
    }

    func startedCount() -> Int {
        startedBatchIDs.count
    }

    func waitUntilReleased() async {
        while !isReleased {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        isReleased = true
    }
}
