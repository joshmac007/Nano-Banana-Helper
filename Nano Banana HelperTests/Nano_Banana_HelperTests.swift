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

    private func makeHistoryEntry(
        projectId: UUID,
        sourceImagePaths: [String] = ["/tmp/input.png"],
        outputImagePath: String = "/tmp/output.png",
        sourceImageBookmarks: [Data]? = nil,
        outputImageBookmark: Data? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            projectId: projectId,
            sourceImagePaths: sourceImagePaths,
            outputImagePath: outputImagePath,
            prompt: "prompt",
            aspectRatio: "16:9",
            imageSize: "2K",
            usedBatchTier: false,
            cost: 1,
            sourceImageBookmarks: sourceImageBookmarks,
            outputImageBookmark: outputImageBookmark
        )
    }

    private func loadPersistedHistoryEntries(from projectsDirectory: URL, projectId: UUID) throws -> [HistoryEntry] {
        let fileURL = projectsDirectory
            .appendingPathComponent(projectId.uuidString)
            .appendingPathComponent("history.json")
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([HistoryEntry].self, from: data)
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

    @Test func curatedModelCatalogRequiresBothGenerationMethodsAndIgnoresUncuratedModels() throws {
        let payload = """
        {
          "models": [
            {
              "name": "models/gemini-3.1-flash-image-preview",
              "supportedGenerationMethods": ["generateContent", "batchGenerateContent"]
            },
            {
              "name": "models/gemini-3-pro-image-preview",
              "supportedGenerationMethods": ["generateContent", "batchGenerateContent"]
            },
            {
              "name": "models/gemini-2.5-flash-image",
              "supportedGenerationMethods": ["generateContent"]
            },
            {
              "name": "models/not-approved-image-model",
              "supportedGenerationMethods": ["generateContent", "batchGenerateContent"]
            }
          ]
        }
        """.data(using: .utf8)!

        let entries = try CuratedModelCatalog.entries(
            from: payload,
            selectedModelID: "gemini-3-pro-image-preview"
        )

        #expect(entries.contains(where: { $0.id == "gemini-3.1-flash-image-preview" }))
        #expect(entries.contains(where: { $0.id == "gemini-3.1-flash-image-preview" && $0.isSelectable }))
        #expect(entries.contains(where: { $0.id == "gemini-3-pro-image-preview" && $0.isSelectable }))
        #expect(entries.contains(where: { $0.id == "gemini-2.5-flash-image" }) == false)
        #expect(entries.contains(where: { $0.id == "not-approved-image-model" }) == false)
    }

    @Test func curatedModelCatalogFallbackEntriesExcludeDeprecatedDefaultsAndInjectLegacySelection() {
        let fallbackEntries = CuratedModelCatalog.fallbackEntries()
        #expect(fallbackEntries.map(\.id) == ["gemini-3.1-flash-image-preview", "gemini-3-pro-image-preview"])
        #expect(fallbackEntries.allSatisfy(\.isSelectable))

        let legacyEntries = CuratedModelCatalog.fallbackEntries(selectedModelID: "gemini-2.5-flash-image")
        #expect(legacyEntries.first?.id == "gemini-2.5-flash-image")
        #expect(legacyEntries.first?.displayName == "Legacy: gemini-2.5-flash-image")
        #expect(legacyEntries.first?.isSelectable == false)
        #expect(legacyEntries.dropFirst().map(\.id) == ["gemini-3.1-flash-image-preview", "gemini-3-pro-image-preview"])

        let selectedCurrentEntries = CuratedModelCatalog.fallbackEntries(selectedModelID: "gemini-3.1-flash-image-preview")
        #expect(selectedCurrentEntries.map(\.id) == ["gemini-3.1-flash-image-preview", "gemini-3-pro-image-preview"])
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
            NanoBananaService.cancelBatchJobURL(jobName: jobName, apiKey: apiKey),
            NanoBananaService.listModelsURL(apiKey: apiKey, pageSize: 100)
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

    @Test func loadImageDataSucceedsWithValidBookmark() {
        let bookmark = Data("bookmark".utf8)
        let expectedData = Data("image-data".utf8)
        let expectedURL = URL(fileURLWithPath: "/tmp/image.png")
        let dependencies = AppPaths.BookmarkResolutionDependencies(
            resolveURL: { data in
                #expect(data == bookmark)
                return (expectedURL, false)
            },
            refreshBookmarkData: { _ in Data() },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )

        let result = AppPaths.loadImageData(
            bookmark: bookmark,
            fallbackPath: "/tmp/fallback.png",
            dependencies: dependencies,
            fileReader: { url in
                #expect(url == expectedURL)
                return expectedData
            }
        )

        switch result {
        case let .success(data, refreshedBookmark):
            #expect(data == expectedData)
            #expect(refreshedBookmark == nil)
        default:
            Issue.record("Expected bookmark-backed image load to succeed")
        }
    }

    @Test func loadImageDataRefreshesStaleBookmark() {
        let bookmark = Data("bookmark".utf8)
        let refreshedBookmark = Data("refreshed".utf8)
        let expectedData = Data("image-data".utf8)
        let expectedURL = URL(fileURLWithPath: "/tmp/image.png")
        let dependencies = AppPaths.BookmarkResolutionDependencies(
            resolveURL: { _ in (expectedURL, true) },
            refreshBookmarkData: { _ in refreshedBookmark },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )

        let result = AppPaths.loadImageData(
            bookmark: bookmark,
            fallbackPath: "/tmp/fallback.png",
            dependencies: dependencies,
            fileReader: { _ in expectedData }
        )

        switch result {
        case let .success(data, returnedBookmark):
            #expect(data == expectedData)
            #expect(returnedBookmark == refreshedBookmark)
        default:
            Issue.record("Expected stale bookmark load to succeed and return refreshed data")
        }
    }

    @Test func loadImageDataFallsBackToPathWhenNoBookmark() throws {
        let directory = try makeTemporaryDirectory()
        let fallbackURL = directory.appendingPathComponent("fallback.png")
        let expectedData = Data("fallback-data".utf8)
        try expectedData.write(to: fallbackURL)

        let result = AppPaths.loadImageData(
            bookmark: nil,
            fallbackPath: fallbackURL.path
        )

        switch result {
        case let .fallbackUsed(data):
            #expect(data == expectedData)
        default:
            Issue.record("Expected path-based fallback image load to succeed")
        }
    }

    @Test func loadImageDataReturnsDeniedWhenBothFail() {
        let bookmark = Data("bookmark".utf8)
        let dependencies = AppPaths.BookmarkResolutionDependencies(
            resolveURL: { _ in throw CocoaError(.fileNoSuchFile) },
            refreshBookmarkData: { _ in Data() },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )

        let result = AppPaths.loadImageData(
            bookmark: bookmark,
            fallbackPath: "/tmp/missing-image.png",
            dependencies: dependencies,
            fileReader: { _ in nil }
        )

        if case .accessDenied = result {
            return
        }
        Issue.record("Expected access denial when bookmark resolution and fallback both fail")
    }

    @Test func openFileUsesBookmarkResolvedURL() {
        let bookmark = Data("bookmark".utf8)
        let expectedURL = URL(fileURLWithPath: "/tmp/output.png")
        let dependencies = AppPaths.BookmarkResolutionDependencies(
            resolveURL: { _ in (expectedURL, false) },
            refreshBookmarkData: { _ in Data() },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        var openedURL: URL?

        let result = AppPaths.openFile(
            bookmark: bookmark,
            fallbackPath: "/tmp/fallback-output.png",
            dependencies: dependencies,
            opener: { url in
                openedURL = url
                return true
            }
        )

        #expect(openedURL == expectedURL)
        if case .success = result {
            return
        }
        Issue.record("Expected openFile to use the resolved bookmark URL")
    }

    @Test func openFileFallsBackToPathWhenNoBookmark() {
        let fallbackPath = "/tmp/fallback-output.png"
        var openedURL: URL?

        let result = AppPaths.openFile(
            bookmark: nil,
            fallbackPath: fallbackPath,
            opener: { url in
                openedURL = url
                return true
            }
        )

        #expect(openedURL?.path == fallbackPath)
        if case .fallbackUsed = result {
            return
        }
        Issue.record("Expected openFile to fall back to the path when no bookmark exists")
    }

    @Test func openFileReturnsDeniedWhenBothFail() {
        let fallbackPath = "/tmp/missing-output.png"

        let result = AppPaths.openFile(
            bookmark: nil,
            fallbackPath: fallbackPath,
            opener: { _ in false }
        )

        if case .accessDenied = result {
            return
        }
        Issue.record("Expected openFile to deny access when both bookmark and fallback fail")
    }

    @Test func revealInFinderUsesBookmarkResolvedURL() {
        let bookmark = Data("bookmark".utf8)
        let expectedURL = URL(fileURLWithPath: "/tmp/output.png")
        let dependencies = AppPaths.BookmarkResolutionDependencies(
            resolveURL: { _ in (expectedURL, false) },
            refreshBookmarkData: { _ in Data() },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        var revealedURLs: [URL] = []

        let result = AppPaths.revealInFinder(
            bookmark: bookmark,
            fallbackPath: "/tmp/fallback-output.png",
            dependencies: dependencies,
            revealer: { urls in revealedURLs = urls }
        )

        #expect(revealedURLs == [expectedURL])
        if case .success = result {
            return
        }
        Issue.record("Expected revealInFinder to use the resolved bookmark URL")
    }

    @Test func revealInFinderFallsBackToPath() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("output.png")
        try Data("image".utf8).write(to: fileURL)
        var revealedURLs: [URL] = []

        let result = AppPaths.revealInFinder(
            bookmark: nil,
            fallbackPath: fileURL.path,
            revealer: { urls in revealedURLs = urls }
        )

        #expect(revealedURLs == [fileURL])
        if case .fallbackUsed = result {
            return
        }
        Issue.record("Expected revealInFinder to fall back to the raw path")
    }

    @Test func revealDirectoryUsesBookmarkResolvedURL() {
        let bookmark = Data("bookmark".utf8)
        let expectedURL = URL(fileURLWithPath: "/tmp/output-folder")
        let dependencies = AppPaths.BookmarkResolutionDependencies(
            resolveURL: { _ in (expectedURL, false) },
            refreshBookmarkData: { _ in Data() },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        var revealedPath: String?

        let result = AppPaths.revealDirectory(
            bookmark: bookmark,
            fallbackPath: "/tmp/fallback-folder",
            dependencies: dependencies,
            revealer: { path in revealedPath = path }
        )

        #expect(revealedPath == expectedURL.path)
        if case .success = result {
            return
        }
        Issue.record("Expected revealDirectory to use the resolved bookmark path")
    }

    @Test func revealDirectoryReturnsDeniedWhenFallbackMissing() {
        var revealedPath: String?

        let result = AppPaths.revealDirectory(
            bookmark: nil,
            fallbackPath: "/tmp/missing-folder",
            revealer: { path in revealedPath = path },
            fileExists: { _ in false }
        )

        #expect(revealedPath == nil)
        if case .accessDenied = result {
            return
        }
        Issue.record("Expected revealDirectory to deny access when fallback path is missing")
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

    @Test func updateBookmarksUpdatesEntryInMemoryAndOnDisk() throws {
        let projectId = UUID()
        let tempProjectsDirectory = try makeTemporaryDirectory()
        let entry = makeHistoryEntry(projectId: projectId)
        let outputBookmark = Data("new-output".utf8)
        let sourceBookmarks = [Data("new-source".utf8)]
        let manager = HistoryManager(projectsDirectoryURL: tempProjectsDirectory)
        manager.entries = [entry]
        manager.allGlobalEntries = [entry]
        manager.saveHistory(for: projectId)

        manager.updateBookmarks(
            for: entry.id,
            outputBookmark: outputBookmark,
            sourceBookmarks: sourceBookmarks
        )

        #expect(manager.entries.first?.outputImageBookmark == outputBookmark)
        #expect(manager.entries.first?.sourceImageBookmarks == sourceBookmarks)
        #expect(manager.allGlobalEntries.first?.outputImageBookmark == outputBookmark)
        #expect(manager.allGlobalEntries.first?.sourceImageBookmarks == sourceBookmarks)

        let persistedEntries = try loadPersistedHistoryEntries(from: tempProjectsDirectory, projectId: projectId)
        #expect(persistedEntries.first?.outputImageBookmark == outputBookmark)
        #expect(persistedEntries.first?.sourceImageBookmarks == sourceBookmarks)
    }

    @Test func updateBookmarksPersistsNonCurrentProjectEntries() throws {
        let currentProject = UUID()
        let targetProject = UUID()
        let tempProjectsDirectory = try makeTemporaryDirectory()
        let currentEntry = makeHistoryEntry(projectId: currentProject, outputImagePath: "/tmp/current-output.png")
        let targetEntry = makeHistoryEntry(projectId: targetProject, outputImagePath: "/tmp/target-output.png")
        let outputBookmark = Data("target-output".utf8)
        let sourceBookmarks = [Data("target-source".utf8)]
        let manager = HistoryManager(projectsDirectoryURL: tempProjectsDirectory)

        manager.entries = [currentEntry]
        manager.saveHistory(for: currentProject)
        manager.entries = [targetEntry]
        manager.saveHistory(for: targetProject)
        manager.entries = [currentEntry]
        manager.allGlobalEntries = [targetEntry, currentEntry]

        manager.updateBookmarks(
            for: targetEntry.id,
            outputBookmark: outputBookmark,
            sourceBookmarks: sourceBookmarks
        )

        #expect(manager.entries.first?.id == currentEntry.id)
        #expect(manager.entries.first?.outputImageBookmark == nil)

        let persistedEntries = try loadPersistedHistoryEntries(from: tempProjectsDirectory, projectId: targetProject)
        #expect(persistedEntries.first?.outputImageBookmark == outputBookmark)
        #expect(persistedEntries.first?.sourceImageBookmarks == sourceBookmarks)
        #expect(manager.allGlobalEntries.first(where: { $0.id == targetEntry.id })?.outputImageBookmark == outputBookmark)
        #expect(manager.allGlobalEntries.first(where: { $0.id == targetEntry.id })?.sourceImageBookmarks == sourceBookmarks)
    }

    @Test func updateBookmarksNoOpForUnknownEntryId() throws {
        let projectId = UUID()
        let tempProjectsDirectory = try makeTemporaryDirectory()
        let entry = makeHistoryEntry(projectId: projectId)
        let manager = HistoryManager(projectsDirectoryURL: tempProjectsDirectory)
        manager.entries = [entry]
        manager.allGlobalEntries = [entry]
        manager.saveHistory(for: projectId)

        manager.updateBookmarks(
            for: UUID(),
            outputBookmark: Data("new-output".utf8),
            sourceBookmarks: [Data("new-source".utf8)]
        )

        let persistedEntries = try loadPersistedHistoryEntries(from: tempProjectsDirectory, projectId: projectId)
        #expect(persistedEntries.first?.outputImageBookmark == nil)
        #expect(persistedEntries.first?.sourceImageBookmarks == nil)
    }

    @Test func repairOutputBookmarksFromFolderUpdatesMatchingEntries() throws {
        let projectId = UUID()
        let tempProjectsDirectory = try makeTemporaryDirectory()
        let outputFolder = tempProjectsDirectory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let matchingOutputURL = outputFolder.appendingPathComponent("result.png")
        let outsideOutputURL = tempProjectsDirectory.appendingPathComponent("elsewhere/result.png")
        try FileManager.default.createDirectory(at: outsideOutputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("match".utf8).write(to: matchingOutputURL)
        try Data("outside".utf8).write(to: outsideOutputURL)

        let matchingEntry = makeHistoryEntry(projectId: projectId, outputImagePath: matchingOutputURL.path)
        let outsideEntry = makeHistoryEntry(projectId: projectId, outputImagePath: outsideOutputURL.path)
        let manager = HistoryManager(projectsDirectoryURL: tempProjectsDirectory)
        manager.entries = [matchingEntry, outsideEntry]
        manager.allGlobalEntries = [matchingEntry, outsideEntry]
        manager.saveHistory(for: projectId)

        manager.repairOutputBookmarksFromFolder(
            projectId: projectId,
            folderURL: outputFolder,
            bookmarkCreator: { url in Data(url.path.utf8) }
        )

        let persistedEntries = try loadPersistedHistoryEntries(from: tempProjectsDirectory, projectId: projectId)
        #expect(persistedEntries.first(where: { $0.id == matchingEntry.id })?.outputImageBookmark == Data(matchingOutputURL.path.utf8))
        #expect(persistedEntries.first(where: { $0.id == outsideEntry.id })?.outputImageBookmark == nil)
    }

    @Test func repairSourceBookmarksFromFolderUpdatesRequestedEntries() throws {
        let projectId = UUID()
        let tempProjectsDirectory = try makeTemporaryDirectory()
        let sourceFolder = tempProjectsDirectory.appendingPathComponent("sources", isDirectory: true)
        let otherFolder = tempProjectsDirectory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)

        let requestedSourceURL = sourceFolder.appendingPathComponent("input-a.png")
        let secondRequestedSourceURL = sourceFolder.appendingPathComponent("input-b.png")
        let outsideSourceURL = otherFolder.appendingPathComponent("input-c.png")
        try Data("a".utf8).write(to: requestedSourceURL)
        try Data("b".utf8).write(to: secondRequestedSourceURL)
        try Data("c".utf8).write(to: outsideSourceURL)

        let requestedEntry = makeHistoryEntry(
            projectId: projectId,
            sourceImagePaths: [requestedSourceURL.path, secondRequestedSourceURL.path],
            outputImagePath: "/tmp/requested-output.png"
        )
        let skippedEntry = makeHistoryEntry(
            projectId: projectId,
            sourceImagePaths: [outsideSourceURL.path],
            outputImagePath: "/tmp/skipped-output.png"
        )
        let manager = HistoryManager(projectsDirectoryURL: tempProjectsDirectory)
        manager.entries = [requestedEntry, skippedEntry]
        manager.allGlobalEntries = [requestedEntry, skippedEntry]
        manager.saveHistory(for: projectId)

        manager.repairSourceBookmarksFromFolder(
            entryIds: [requestedEntry.id],
            folderURL: sourceFolder,
            bookmarkCreator: { url in Data(url.path.utf8) }
        )

        let persistedEntries = try loadPersistedHistoryEntries(from: tempProjectsDirectory, projectId: projectId)
        #expect(
            persistedEntries.first(where: { $0.id == requestedEntry.id })?.sourceImageBookmarks ==
            [Data(requestedSourceURL.path.utf8), Data(secondRequestedSourceURL.path.utf8)]
        )
        #expect(persistedEntries.first(where: { $0.id == skippedEntry.id })?.sourceImageBookmarks == nil)
    }

    @Test func repairSourceBookmarksFromFolderPreservesBookmarkIndexAlignment() throws {
        let projectId = UUID()
        let tempProjectsDirectory = try makeTemporaryDirectory()
        let sourceFolder = tempProjectsDirectory.appendingPathComponent("sources", isDirectory: true)
        let outsideFolder = tempProjectsDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)

        let firstSourceURL = sourceFolder.appendingPathComponent("input-a.png")
        let secondSourceURL = outsideFolder.appendingPathComponent("input-b.png")
        let thirdSourceURL = sourceFolder.appendingPathComponent("input-c.png")
        try Data("a".utf8).write(to: firstSourceURL)
        try Data("b".utf8).write(to: secondSourceURL)
        try Data("c".utf8).write(to: thirdSourceURL)

        let oldFirstBookmark = Data("old-a".utf8)
        let oldSecondBookmark = Data("old-b".utf8)
        let oldThirdBookmark = Data("old-c".utf8)
        let entry = makeHistoryEntry(
            projectId: projectId,
            sourceImagePaths: [firstSourceURL.path, secondSourceURL.path, thirdSourceURL.path],
            outputImagePath: "/tmp/output.png",
            sourceImageBookmarks: [oldFirstBookmark, oldSecondBookmark, oldThirdBookmark]
        )
        let manager = HistoryManager(projectsDirectoryURL: tempProjectsDirectory)
        manager.entries = [entry]
        manager.allGlobalEntries = [entry]
        manager.saveHistory(for: projectId)

        manager.repairSourceBookmarksFromFolder(
            entryIds: [entry.id],
            folderURL: sourceFolder,
            bookmarkCreator: { url in Data("new:\(url.lastPathComponent)".utf8) }
        )

        let persistedEntries = try loadPersistedHistoryEntries(from: tempProjectsDirectory, projectId: projectId)
        #expect(
            persistedEntries.first?.sourceImageBookmarks ==
            [
                Data("new:input-a.png".utf8),
                oldSecondBookmark,
                Data("new:input-c.png".utf8)
            ]
        )
    }

    @Test func reauthorizeOutputFolderReturnsWrongFolderSelectedAndShowsError() throws {
        let tempAppSupportURL = try makeTemporaryDirectory()
        let projectsListURL = tempAppSupportURL.appendingPathComponent("projects.json")
        let costSummaryURL = tempAppSupportURL.appendingPathComponent("cost_summary.json")
        let projectsDirectoryURL = tempAppSupportURL.appendingPathComponent("projects", isDirectory: true)
        let projectManager = ProjectManager(
            appSupportURL: tempAppSupportURL,
            projectsListURL: projectsListURL,
            costSummaryURL: costSummaryURL,
            projectsDirectoryURL: projectsDirectoryURL
        )
        let historyManager = HistoryManager(projectsDirectoryURL: projectsDirectoryURL)
        let expectedFolder = tempAppSupportURL.appendingPathComponent("expected", isDirectory: true)
        let wrongFolder = tempAppSupportURL.appendingPathComponent("wrong", isDirectory: true)
        let project = Project(name: "Test Project", outputDirectory: expectedFolder.path)
        projectManager.projects = [project]
        projectManager.currentProject = project
        var shownError: String?

        let result = BookmarkReauthorization.reauthorizeOutputFolder(
            for: project,
            projectManager: projectManager,
            historyManager: historyManager,
            selectedURLOverride: wrongFolder,
            bookmarkCreator: { _ in
                Issue.record("Bookmark creation should not run for the wrong folder")
                return nil
            },
            showError: { message in shownError = message }
        )

        #expect(result == .wrongFolderSelected)
        #expect(shownError?.contains(expectedFolder.path) == true)
        #expect(project.outputDirectoryBookmark == nil)
    }

    @MainActor @Test func orchestratorResetRemovesPersistedActiveBatchFile() throws {
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

    @MainActor @Test func cancelHandlesSubmittingPhaseTasks() throws {
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

    @MainActor @Test func startAllStartsEligibleBatchesConcurrently() async throws {
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
