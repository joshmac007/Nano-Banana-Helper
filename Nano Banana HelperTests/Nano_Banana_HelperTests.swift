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
    private let floatingPointTolerance = 0.000_000_1

    private func usageDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 12,
        minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)!
    }

    private func makeUsageLedgerEntry(
        timestamp: Date,
        kind: UsageLedgerKind = .jobCompletion,
        projectId: UUID? = nil,
        projectNameSnapshot: String? = nil,
        costDelta: Double,
        imageDelta: Int,
        tokenDelta: Int = 0,
        inputTokenDelta: Int = 0,
        outputTokenDelta: Int = 0,
        resolution: String? = "2K",
        modelName: String? = "gemini-test",
        note: String? = nil
    ) -> UsageLedgerEntry {
        UsageLedgerEntry(
            timestamp: timestamp,
            kind: kind,
            projectId: projectId,
            projectNameSnapshot: projectNameSnapshot,
            costDelta: costDelta,
            imageDelta: imageDelta,
            tokenDelta: tokenDelta,
            inputTokenDelta: inputTokenDelta,
            outputTokenDelta: outputTokenDelta,
            resolution: resolution,
            modelName: modelName,
            relatedHistoryEntryId: nil,
            note: note
        )
    }

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

    private func makeTemporaryFile(in directory: URL, named name: String, contents: Data = Data()) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private func makeTransparentPNGData() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4////fwAJ+wP9KobjigAAAABJRU5ErkJggg==")!
    }

    private func makeRestoreEntry(
        projectId: UUID = UUID(),
        sourceImagePaths: [String],
        sourceImageBookmarks: [Data]? = nil,
        prompt: String = "prompt",
        systemPrompt: String? = "system",
        aspectRatio: String = "16:9",
        imageSize: String = "2K",
        usedBatchTier: Bool = false
    ) -> HistoryEntry {
        HistoryEntry(
            projectId: projectId,
            sourceImagePaths: sourceImagePaths,
            outputImagePath: "/tmp/output.png",
            prompt: prompt,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            usedBatchTier: usedBatchTier,
            cost: 1,
            sourceImageBookmarks: sourceImageBookmarks,
            systemPrompt: systemPrompt
        )
    }

    @MainActor
    private func persistQueueState(_ state: PersistedQueueState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: url)
    }

    private func loadPersistedQueueState(from url: URL) throws -> PersistedQueueState {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedQueueState.self, from: data)
    }

    private func loadPersistedUsageLedger(from url: URL) throws -> [UsageLedgerEntry] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([UsageLedgerEntry].self, from: data)
    }

    @MainActor
    private func withStoredModelName<T>(
        _ modelName: String?,
        perform: () async throws -> T
    ) async rethrows -> T {
        let fileManager = FileManager.default
        let configURL = AppConfig.fileURL
        let originalData = try? Data(contentsOf: configURL)

        try? fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = AppConfig.load()
        config.modelName = modelName
        config.save()

        defer {
            if let originalData {
                try? originalData.write(to: configURL)
            } else {
                try? fileManager.removeItem(at: configURL)
            }
        }

        return try await perform()
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

    @MainActor @Test func historyEntryBackwardCompatibility() throws {
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

    @MainActor @Test func historyEntryWithTokenData() throws {
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

    @Test func appPricingResolvesKnownAliasAndFallbackModels() {
        let pro = AppPricing.pricing(for: "gemini-3-pro-image-preview")
        #expect(pro.pricingModelName == "gemini-3-pro-image-preview")
        #expect(pro.pricingDisplayName == "Nano Banana Pro")
        #expect(pro.isFallback == false)

        let alias = AppPricing.pricing(for: "gemini-3.1-flash-image-preview")
        #expect(alias.pricingModelName == "gemini-2.5-flash-image")
        #expect(alias.pricingDisplayName == "Nano Banana")
        #expect(alias.isFallback == false)

        let unknown = AppPricing.pricing(for: "legacy-image-model")
        #expect(unknown.pricingModelName == "gemini-2.5-flash-image")
        #expect(unknown.isFallback)

        let missing = AppPricing.pricing(for: nil)
        #expect(missing.pricingModelName == "gemini-2.5-flash-image")
        #expect(missing.isFallback)
    }

    @Test func appPricingUsesModelAwareRates() {
        #expect(AppPricing.inputRate(modelName: "gemini-3-pro-image-preview", isBatchTier: false) == 0.0011)
        #expect(AppPricing.inputRate(modelName: "gemini-3-pro-image-preview", isBatchTier: true) == 0.0006)
        #expect(AppPricing.outputRate(for: .size4K, modelName: "gemini-3-pro-image-preview", isBatchTier: false) == 0.24)
        #expect(AppPricing.outputRate(for: .size2K, modelName: "gemini-3-pro-image-preview", isBatchTier: true) == 0.067)

        #expect(AppPricing.inputRate(modelName: "gemini-2.5-flash-image", isBatchTier: false) == 0.000168)
        #expect(AppPricing.inputRate(modelName: "gemini-2.5-flash-image", isBatchTier: true) == 0.000084)
        #expect(AppPricing.outputRate(for: .size1K, modelName: "gemini-2.5-flash-image", isBatchTier: false) == 0.039)
        #expect(AppPricing.outputRate(for: .size1K, modelName: "gemini-2.5-flash-image", isBatchTier: true) == 0.0195)

        #expect(AppPricing.outputFallbackRate(modelName: "legacy-image-model", isBatchTier: false) == 0.039)
    }

    @Test func imageSizeCostCalculationsUseSelectedModelRates() {
        let proImageCost = ImageSize.calculateCost(
            imageSize: "2K",
            inputCount: 2,
            isBatchTier: false,
            modelName: "gemini-3-pro-image-preview"
        )
        let flashImageCost = ImageSize.calculateCost(
            imageSize: "2K",
            inputCount: 2,
            isBatchTier: false,
            modelName: "gemini-2.5-flash-image"
        )
        let flashTextCost = ImageSize.calculateTextModeCost(
            imageSize: "1K",
            outputCount: 3,
            isBatchTier: true,
            modelName: "gemini-2.5-flash-image"
        )

        #expect(abs(proImageCost - 0.1362) < floatingPointTolerance)
        #expect(abs(flashImageCost - 0.078336) < floatingPointTolerance)
        #expect(abs(flashTextCost - 0.0585) < floatingPointTolerance)
        #expect(proImageCost > flashImageCost)
    }

    @Test func batchJobBackwardCompatibilityDecodesMissingModelName() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000011",
            "createdAt": "2026-01-15T10:00:00Z",
            "projectId": "00000000-0000-0000-0000-000000000022",
            "prompt": "test prompt",
            "systemPrompt": "system",
            "aspectRatio": "16:9",
            "imageSize": "2K",
            "outputDirectory": "/tmp",
            "useBatchTier": true,
            "status": "pending",
            "tasks": [],
            "isTextMode": false
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let batch = try decoder.decode(BatchJob.self, from: json)

        #expect(batch.modelName == nil)
        #expect(batch.imageSize == "2K")
        #expect(batch.useBatchTier)
    }

    @Test func batchJobRoundTripsModelName() throws {
        let batch = BatchJob(
            prompt: "prompt",
            systemPrompt: "system",
            aspectRatio: "1:1",
            imageSize: "4K",
            outputDirectory: "/tmp",
            useBatchTier: true,
            projectId: UUID(),
            modelName: "gemini-3-pro-image-preview"
        )
        batch.isTextMode = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(batch)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BatchJob.self, from: data)

        #expect(decoded.modelName == "gemini-3-pro-image-preview")
        #expect(decoded.isTextMode)
        #expect(decoded.systemPrompt == "system")
    }

    @Test func imageTaskFilenameUsesGeneratedFallbackForTextOnlyTasks() {
        let task = ImageTask(inputPaths: [])

        #expect(task.filename.hasPrefix("Generated Image "))
        #expect(task.filename != "Data")
    }

    @Test func imageTaskFilenameUsesStableFallbackForGenericImportedNames() {
        let task = ImageTask(inputPaths: ["/tmp/Data"])

        #expect(task.filename.hasPrefix("Image "))
        #expect(task.filename != "Data")
    }

    @Test func inferBatchJobStateTreatsDoneCancelledErrorAsCancelled() {
        let error: [String: Any] = [
            "status": "CANCELLED",
            "message": "Operation was cancelled by the user."
        ]

        #expect(
            NanoBananaService.inferBatchJobState(done: true, metadataState: nil, error: error) ==
            "JOB_STATE_CANCELLED"
        )
    }

    @Test func inferBatchJobStateNormalizesBatchStateCancelledToJobStateCancelled() {
        #expect(
            NanoBananaService.inferBatchJobState(
                done: true,
                metadataState: "BATCH_STATE_CANCELLED",
                error: nil
            ) == "JOB_STATE_CANCELLED"
        )
    }

    @Test func inferBatchJobStateTreatsDoneErrorsWithoutCancelAsFailed() {
        let error: [String: Any] = [
            "status": "INTERNAL",
            "message": "Batch processing failed."
        ]

        #expect(
            NanoBananaService.inferBatchJobState(done: true, metadataState: nil, error: error) ==
            "JOB_STATE_FAILED"
        )
    }

    @Test func resolveTerminalBatchResolutionTreatsDoneCancelledPayloadAsCancelled() {
        let error: [String: Any] = [
            "status": "CANCELLED",
            "message": "Operation was cancelled by the user."
        ]

        do {
            _ = try NanoBananaService.resolveTerminalBatchResolution(
                done: true,
                metadataState: nil,
                response: nil,
                dest: nil,
                error: error
            )
            Issue.record("Expected cancelled terminal payload to throw jobCancelled")
        } catch NanoBananaError.jobCancelled {
            // Expected path.
        } catch {
            Issue.record("Expected jobCancelled but got \(error)")
        }
    }

    @Test func resolveTerminalBatchResolutionKeepsSucceededPayloadWithoutImageAsNoImageError() {
        do {
            _ = try NanoBananaService.resolveTerminalBatchResolution(
                done: true,
                metadataState: "JOB_STATE_SUCCEEDED",
                response: nil,
                dest: nil,
                error: nil
            )
            Issue.record("Expected succeeded terminal payload without output to throw noImageInResponse")
        } catch NanoBananaError.noImageInResponse {
            // Expected path.
        } catch {
            Issue.record("Expected noImageInResponse but got \(error)")
        }
    }

    @Test func canonicalBatchStateConvertsBatchPrefixToJobPrefix() {
        #expect(NanoBananaService.canonicalBatchState("BATCH_STATE_CANCELLED") == "JOB_STATE_CANCELLED")
        #expect(NanoBananaService.canonicalBatchState(" job_state_failed ") == "JOB_STATE_FAILED")
    }

    @MainActor @Test func stagingRestoreImageEntryRestoresImageModeSettingsAndFiles() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = try makeTemporaryFile(in: directory, named: "input.png")
        let bookmark = Data("bookmark-a".utf8)
        let entry = makeRestoreEntry(
            sourceImagePaths: [sourceURL.path],
            sourceImageBookmarks: [bookmark],
            prompt: "new prompt",
            systemPrompt: "new system",
            aspectRatio: "Auto",
            imageSize: "4K",
            usedBatchTier: true
        )

        let manager = BatchStagingManager()
        manager.generationMode = .text
        manager.textImageCount = 4
        manager.prompt = "old prompt"
        manager.stagedFiles = [URL(fileURLWithPath: "/tmp/stale.png")]
        manager.stagedBookmarks = [URL(fileURLWithPath: "/tmp/stale.png"): Data("stale".utf8)]

        manager.restore(from: entry)

        #expect(manager.generationMode == .image)
        #expect(manager.prompt == "new prompt")
        #expect(manager.systemPrompt == "new system")
        #expect(manager.aspectRatio == "Auto")
        #expect(manager.imageSize == "4K")
        #expect(manager.isBatchTier)
        #expect(manager.textImageCount == 1)
        #expect(manager.stagedFiles == [sourceURL])
        #expect(manager.stagedBookmarks[sourceURL] == bookmark)
        #expect(manager.isMultiInput == false)
    }

    @MainActor @Test func stagingRestoreImageEntryEnablesMultiInputForMultipleSources() throws {
        let directory = try makeTemporaryDirectory()
        let firstURL = try makeTemporaryFile(in: directory, named: "first.png")
        let secondURL = try makeTemporaryFile(in: directory, named: "second.png")
        let entry = makeRestoreEntry(sourceImagePaths: [firstURL.path, secondURL.path])

        let manager = BatchStagingManager()
        manager.restore(from: entry)

        #expect(manager.generationMode == .image)
        #expect(manager.stagedFiles == [firstURL, secondURL])
        #expect(manager.isMultiInput)
    }

    @MainActor @Test func stagingRestoreTextEntryClearsFilesAndSwitchesToTextMode() {
        let manager = BatchStagingManager()
        let staleURL = URL(fileURLWithPath: "/tmp/stale.png")
        manager.generationMode = .image
        manager.textImageCount = 3
        manager.isMultiInput = true
        manager.stagedFiles = [staleURL]
        manager.stagedBookmarks = [staleURL: Data("stale".utf8)]

        manager.restore(from: makeRestoreEntry(sourceImagePaths: [], prompt: "text prompt"))

        #expect(manager.generationMode == .text)
        #expect(manager.prompt == "text prompt")
        #expect(manager.stagedFiles.isEmpty)
        #expect(manager.stagedBookmarks.isEmpty)
        #expect(manager.isMultiInput == false)
        #expect(manager.textImageCount == 1)
    }

    @MainActor @Test func stagingRestoreReplacesPreviousStagedStateInsteadOfAppending() throws {
        let directory = try makeTemporaryDirectory()
        let restoredURL = try makeTemporaryFile(in: directory, named: "restored.png")
        let entry = makeRestoreEntry(sourceImagePaths: [restoredURL.path])

        let manager = BatchStagingManager()
        let staleURL = URL(fileURLWithPath: "/tmp/stale.png")
        manager.stagedFiles = [staleURL]
        manager.stagedBookmarks = [staleURL: Data("stale".utf8)]

        manager.restore(from: entry)

        #expect(manager.stagedFiles == [restoredURL])
        #expect(manager.stagedBookmarks[staleURL] == nil)
        #expect(manager.stagedBookmarks.count == 0)
    }

    @MainActor @Test func stagingRestoreMissingImageSourcesStillRestoresSettings() {
        let entry = makeRestoreEntry(
            sourceImagePaths: ["/tmp/does-not-exist.png"],
            prompt: "restored prompt",
            systemPrompt: "restored system",
            aspectRatio: "1:1",
            imageSize: "1K",
            usedBatchTier: true
        )

        let manager = BatchStagingManager()
        manager.restore(from: entry)

        #expect(manager.generationMode == .image)
        #expect(manager.prompt == "restored prompt")
        #expect(manager.systemPrompt == "restored system")
        #expect(manager.aspectRatio == "1:1")
        #expect(manager.imageSize == "1K")
        #expect(manager.isBatchTier)
        #expect(manager.stagedFiles.isEmpty)
        #expect(manager.isMultiInput == false)
    }

    @MainActor @Test func stagingRestoreAlignsBookmarksBySourceIndex() throws {
        let directory = try makeTemporaryDirectory()
        let restoredURL = try makeTemporaryFile(in: directory, named: "second.png")
        let firstBookmark = Data("bookmark-a".utf8)
        let secondBookmark = Data("bookmark-b".utf8)
        let entry = makeRestoreEntry(
            sourceImagePaths: ["/tmp/missing-first.png", restoredURL.path],
            sourceImageBookmarks: [firstBookmark, secondBookmark]
        )

        let manager = BatchStagingManager()
        manager.restore(from: entry)

        #expect(manager.stagedFiles == [restoredURL])
        #expect(manager.stagedBookmarks[restoredURL] == secondBookmark)
        #expect(manager.stagedBookmarks[restoredURL] != firstBookmark)
    }

    @MainActor @Test func imageModeSingleInputVariationsCreateRepeatedTasks() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = try makeTemporaryFile(in: directory, named: "source.png")

        let manager = BatchStagingManager()
        manager.generationMode = .image
        manager.imageVariationCount = 3
        manager.addFiles([sourceURL])

        let tasks = manager.makeImageTasks()

        #expect(tasks.count == 3)
        #expect(tasks.allSatisfy { $0.inputPaths == [sourceURL.path] })
        #expect(tasks.map(\.variationIndex) == [1, 2, 3])
        #expect(tasks.allSatisfy { $0.variationTotal == 3 })
    }

    @MainActor @Test func imageModeMultipleInputsVariationsExpandPerSource() throws {
        let directory = try makeTemporaryDirectory()
        let firstURL = try makeTemporaryFile(in: directory, named: "one.png")
        let secondURL = try makeTemporaryFile(in: directory, named: "two.png")
        let thirdURL = try makeTemporaryFile(in: directory, named: "three.png")

        let manager = BatchStagingManager()
        manager.generationMode = .image
        manager.imageVariationCount = 2
        manager.addFiles([firstURL, secondURL, thirdURL])

        let tasks = manager.makeImageTasks()

        #expect(tasks.count == 6)
        #expect(tasks.filter { $0.inputPaths == [firstURL.path] }.map(\.variationIndex) == [1, 2])
        #expect(tasks.filter { $0.inputPaths == [secondURL.path] }.map(\.variationIndex) == [1, 2])
        #expect(tasks.filter { $0.inputPaths == [thirdURL.path] }.map(\.variationIndex) == [1, 2])
    }

    @MainActor @Test func multiInputVariationsCreateRepeatedMergedTasks() throws {
        let directory = try makeTemporaryDirectory()
        let firstURL = try makeTemporaryFile(in: directory, named: "one.png")
        let secondURL = try makeTemporaryFile(in: directory, named: "two.png")
        let thirdURL = try makeTemporaryFile(in: directory, named: "three.png")

        let manager = BatchStagingManager()
        manager.generationMode = .image
        manager.isMultiInput = true
        manager.imageVariationCount = 4
        manager.addFiles([firstURL, secondURL, thirdURL])

        let tasks = manager.makeImageTasks()

        #expect(tasks.count == 4)
        #expect(tasks.allSatisfy { $0.inputPaths == [firstURL.path, secondURL.path, thirdURL.path] })
        #expect(tasks.map(\.variationIndex) == [1, 2, 3, 4])
        #expect(tasks.allSatisfy { $0.variationTotal == 4 })
    }

    @MainActor @Test func stagingEffectiveCountsReflectImageVariations() throws {
        let directory = try makeTemporaryDirectory()
        let firstURL = try makeTemporaryFile(in: directory, named: "one.png")
        let secondURL = try makeTemporaryFile(in: directory, named: "two.png")

        let manager = BatchStagingManager()
        manager.generationMode = .image
        manager.imageVariationCount = 3
        manager.addFiles([firstURL, secondURL])

        #expect(manager.effectiveTaskCount == 6)
        #expect(manager.effectiveInputCount == 6)

        manager.isMultiInput = true

        #expect(manager.effectiveTaskCount == 3)
        #expect(manager.effectiveInputCount == 6)
    }

    @Test func costEstimatorUsesVariationAwareCounts() {
        let standard = CostEstimatorView(
            stagedImageCount: 3,
            variationCount: 2,
            outputCount: 6,
            imageSize: "1K",
            isBatchTier: false,
            isMultiInput: false,
            generationMode: .image,
            modelName: "gemini-2.5-flash-image"
        )
        let multiInput = CostEstimatorView(
            stagedImageCount: 3,
            variationCount: 4,
            outputCount: 4,
            imageSize: "1K",
            isBatchTier: false,
            isMultiInput: true,
            generationMode: .image,
            modelName: "gemini-2.5-flash-image"
        )

        #expect(abs(standard.inputTotalCost - (6 * 0.000168)) < floatingPointTolerance)
        #expect(abs(standard.outputTotalCost - (6 * 0.039)) < floatingPointTolerance)
        #expect(abs(multiInput.inputTotalCost - (12 * 0.000168)) < floatingPointTolerance)
        #expect(abs(multiInput.outputTotalCost - (4 * 0.039)) < floatingPointTolerance)
    }

    @MainActor @Test func imageTaskBackwardCompatibilityDecodesMissingVariationMetadata() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000100",
            "inputPaths": ["/tmp/input.png"],
            "status": "pending",
            "phase": "pending",
            "pollCount": 0
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(ImageTask.self, from: json)

        #expect(task.variationIndex == nil)
        #expect(task.variationTotal == nil)
    }

    @MainActor @Test func imageTaskRoundTripsVariationMetadata() throws {
        let task = ImageTask(
            inputPath: "/tmp/input.png",
            variationIndex: 2,
            variationTotal: 4
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(ImageTask.self, from: data)

        #expect(decoded.variationIndex == 2)
        #expect(decoded.variationTotal == 4)
        #expect(decoded.filename.contains("Variation 2/4"))
    }

    @MainActor @Test func pngPreflightNormalizesToJPEGAndUsesNormalizedByteCount() async throws {
        let directory = try makeTemporaryDirectory()
        let originalPNG = makeTransparentPNGData()
        let fileURL = try makeTemporaryFile(in: directory, named: "alpha.png", contents: originalPNG)
        let service = NanoBananaService()
        let request = ImageEditRequest(
            inputImageURLs: [fileURL],
            prompt: "test prompt",
            systemInstruction: nil,
            aspectRatio: "1:1",
            imageSize: "1K",
            useBatchTier: true
        )

        let prepared = try await service.prepareInlineImages(for: [fileURL])
        let diagnostics = try await service.buildRequestDiagnostics(for: request)
        let preparedSourceMimeType = prepared[0].sourceMimeType
        let preparedPayloadMimeType = prepared[0].payloadMimeType
        let preparedPayloadByteCount = prepared[0].payloadByteCount
        let preparedOriginalByteCount = prepared[0].originalByteCount
        let totalInlineBytes = diagnostics.totalInlineBytes

        #expect(prepared.count == 1)
        #expect(preparedSourceMimeType == "image/png")
        #expect(preparedPayloadMimeType == "image/jpeg")
        #expect(totalInlineBytes == preparedPayloadByteCount)
        #expect(totalInlineBytes != preparedOriginalByteCount)
        #expect(try Data(contentsOf: fileURL) == originalPNG)
    }

    @Test func parseResponseSurfacesMalformedFunctionCallFinishMessage() async throws {
        let response = """
        {
          "candidates": [
            {
              "finishReason": "MALFORMED_FUNCTION_CALL",
              "finishMessage": "Malformed function call: call:mage_image_0.png"
            }
          ]
        }
        """.data(using: .utf8)!
        let service = NanoBananaService()

        do {
            _ = try await service.parseResponse(response)
            Issue.record("Expected modelFinishedWithoutImage error")
        } catch NanoBananaError.modelFinishedWithoutImage(let finishReason, let message) {
            #expect(finishReason == "MALFORMED_FUNCTION_CALL")
            #expect(message == "Malformed function call: call:mage_image_0.png")
        } catch {
            Issue.record("Expected modelFinishedWithoutImage but got \(error)")
        }
    }

    @MainActor @Test func requestLogSummaryRedactsInlineData() {
        let base64 = String(repeating: "A", count: 512)
        let diagnostics = RequestBuildDiagnostics(
            promptCharacterCount: 12,
            inputCount: 1,
            totalInlineBytes: 1234,
            preflightDuration: 0.05,
            preparedInputs: [
                PreparedInlineImage(
                    filename: "alpha.png",
                    sourceMimeType: "image/png",
                    payloadMimeType: "image/jpeg",
                    originalByteCount: 2048,
                    payloadByteCount: 1234,
                    data: Data(base64.utf8)
                )
            ]
        )

        let summary = NanoBananaService.requestLogSummary(
            endpoint: "generateContent",
            modelName: "gemini-3.1-flash-image-preview",
            diagnostics: diagnostics,
            bodyByteCount: 4567,
            serializationDuration: 0.02
        )

        #expect(summary.contains("alpha.png"))
        #expect(summary.contains("image/png->image/jpeg"))
        #expect(summary.contains("inlineBytes=1234"))
        #expect(summary.contains(base64) == false)
    }

    @MainActor @Test func costSummaryBackwardCompatibility() throws {
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

    @MainActor @Test func costSummaryRecordWithTokens() throws {
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

    @MainActor @Test func costSummaryRoundTrip() throws {
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

    @Test func curatedModelCatalogFallbackEntriesExcludeDeprecatedDefaultsAndInjectLegacySelection() throws {
        let fallbackEntries = CuratedModelCatalog.fallbackEntries()
        #expect(fallbackEntries.map { $0.id } == ["gemini-3.1-flash-image-preview", "gemini-3-pro-image-preview"])
        #expect(fallbackEntries.allSatisfy { $0.isSelectable })

        let legacyEntries = CuratedModelCatalog.fallbackEntries(selectedModelID: "gemini-2.5-flash-image")
        #expect(legacyEntries.first?.id == "gemini-2.5-flash-image")
        #expect(legacyEntries.first?.displayName == "Legacy: gemini-2.5-flash-image")
        #expect(legacyEntries.first?.isSelectable == false)
        #expect(legacyEntries.dropFirst().map { $0.id } == ["gemini-3.1-flash-image-preview", "gemini-3-pro-image-preview"])

        let selectedCurrentEntries = CuratedModelCatalog.fallbackEntries(selectedModelID: "gemini-3.1-flash-image-preview")
        #expect(selectedCurrentEntries.map { $0.id } == ["gemini-3.1-flash-image-preview", "gemini-3-pro-image-preview"])
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
        initialManager.allGlobalEntries = [
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

        #expect(loadedManager.allGlobalEntries.count == 1)
        #expect(loadedManager.allGlobalEntries[0].sourceImageBookmarks == [newSourceBookmark])
        #expect(loadedManager.allGlobalEntries[0].outputImageBookmark == newOutputBookmark)

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
        manager.allGlobalEntries = [entry]
        manager.saveHistory(for: projectId)

        manager.updateBookmarks(
            for: entry.id,
            outputBookmark: outputBookmark,
            sourceBookmarks: sourceBookmarks
        )

        #expect(manager.allGlobalEntries.first?.outputImageBookmark == outputBookmark)
        #expect(manager.allGlobalEntries.first?.sourceImageBookmarks == sourceBookmarks)
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

        manager.allGlobalEntries = [currentEntry]
        manager.saveHistory(for: currentProject)
        manager.allGlobalEntries = [targetEntry]
        manager.saveHistory(for: targetProject)
        manager.allGlobalEntries = [currentEntry]
        manager.allGlobalEntries = [targetEntry, currentEntry]

        manager.updateBookmarks(
            for: targetEntry.id,
            outputBookmark: outputBookmark,
            sourceBookmarks: sourceBookmarks
        )

        #expect(manager.allGlobalEntries.first?.id == currentEntry.id)
        #expect(manager.allGlobalEntries.first?.outputImageBookmark == nil)

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

    @MainActor @Test func reauthorizeOutputFolderReturnsWrongFolderSelectedAndShowsError() throws {
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

        manager.allGlobalEntries = [entry]
        manager.saveHistory(for: projectId)
        manager.loadHistory(for: projectId)
        manager.loadGlobalHistory(allProjects: [project])

        manager.clearHistory(for: projectId)

        #expect(manager.allGlobalEntries.isEmpty)
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

    @MainActor @Test func appendLedgerEntryPersistsUsageAndDerivesProjectTotals() throws {
        let tempAppSupportURL = try makeTemporaryDirectory()
        let projectsListURL = tempAppSupportURL.appendingPathComponent("projects.json")
        let costSummaryURL = tempAppSupportURL.appendingPathComponent("cost_summary.json")
        let usageLedgerURL = tempAppSupportURL.appendingPathComponent("usage_ledger.json")
        let projectsDirectoryURL = tempAppSupportURL.appendingPathComponent("projects", isDirectory: true)
        let manager = ProjectManager(
            appSupportURL: tempAppSupportURL,
            projectsListURL: projectsListURL,
            costSummaryURL: costSummaryURL,
            usageLedgerURL: usageLedgerURL,
            projectsDirectoryURL: projectsDirectoryURL
        )
        let projectId = manager.projects.first!.id

        manager.appendLedgerEntry(
            UsageLedgerEntry(
                kind: .jobCompletion,
                projectId: projectId,
                projectNameSnapshot: manager.projects.first?.name,
                costDelta: 0.5,
                imageDelta: 1,
                tokenDelta: 15,
                inputTokenDelta: 10,
                outputTokenDelta: 5,
                resolution: "4K",
                modelName: "gemini-test",
                relatedHistoryEntryId: UUID(),
                note: nil
            )
        )
        manager.recordSessionUsage(
            cost: 0.5,
            tokens: TokenUsage(promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15)
        )

        let ledger = try loadPersistedUsageLedger(from: usageLedgerURL)
        let summary = manager.costSummary

        #expect(ledger.count == 1)
        #expect(summary.totalSpent == 0.5)
        #expect(summary.imageCount == 1)
        #expect(summary.byModel["gemini-test"] == 0.5)
        #expect(manager.projects.first?.totalCost == 0.5)
        #expect(manager.projects.first?.imageCount == 1)
        #expect(manager.sessionCost == 0.5)
        #expect(manager.sessionTokens == 15)
        #expect(manager.sessionImageCount == 1)
    }

    @Test func usageSnapshotFiltersExpectedRanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = usageDate(year: 2026, month: 4, day: 9, hour: 18, calendar: calendar)
        let projectId = UUID()

        let entries = [
            makeUsageLedgerEntry(
                timestamp: usageDate(year: 2026, month: 4, day: 1, calendar: calendar),
                projectId: projectId,
                projectNameSnapshot: "Alpha",
                costDelta: 1.0,
                imageDelta: 1
            ),
            makeUsageLedgerEntry(
                timestamp: usageDate(year: 2026, month: 4, day: 4, calendar: calendar),
                projectId: projectId,
                projectNameSnapshot: "Alpha",
                costDelta: 2.0,
                imageDelta: 2
            ),
            makeUsageLedgerEntry(
                timestamp: usageDate(year: 2026, month: 4, day: 8, calendar: calendar),
                projectId: projectId,
                projectNameSnapshot: "Alpha",
                costDelta: 3.0,
                imageDelta: 3
            ),
            makeUsageLedgerEntry(
                timestamp: usageDate(year: 2026, month: 4, day: 9, calendar: calendar),
                projectId: projectId,
                projectNameSnapshot: "Alpha",
                costDelta: 4.0,
                imageDelta: 4
            )
        ]

        let today = UsageSnapshotBuilder.makeSnapshot(
            entries: entries,
            filter: .today,
            now: now,
            calendar: calendar,
            projectDisplayName: { _, snapshot in snapshot ?? "Unknown" }
        )
        let sevenDays = UsageSnapshotBuilder.makeSnapshot(
            entries: entries,
            filter: .sevenDays,
            now: now,
            calendar: calendar,
            projectDisplayName: { _, snapshot in snapshot ?? "Unknown" }
        )
        let thirtyDays = UsageSnapshotBuilder.makeSnapshot(
            entries: entries,
            filter: .thirtyDays,
            now: now,
            calendar: calendar,
            projectDisplayName: { _, snapshot in snapshot ?? "Unknown" }
        )
        let allTime = UsageSnapshotBuilder.makeSnapshot(
            entries: entries,
            filter: .allTime,
            now: now,
            calendar: calendar,
            projectDisplayName: { _, snapshot in snapshot ?? "Unknown" }
        )

        #expect(today.totals.cost == 4.0)
        #expect(today.dayBuckets.count == 1)
        #expect(today.filteredEntries.count == 1)

        #expect(sevenDays.totals.cost == 9.0)
        #expect(sevenDays.dayBuckets.count == 7)
        #expect(sevenDays.filteredEntries.count == 3)

        #expect(thirtyDays.totals.cost == 10.0)
        #expect(thirtyDays.dayBuckets.count == 30)
        #expect(thirtyDays.filteredEntries.count == 4)

        #expect(allTime.totals.cost == 10.0)
        #expect(allTime.dayBuckets.count == 9)
        #expect(allTime.filteredEntries.count == 4)
    }

    @Test func usageSnapshotZeroFillsDailyBucketsAndExcludesAdjustmentsAndLegacyImportsFromCharts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = usageDate(year: 2026, month: 4, day: 9, hour: 18, calendar: calendar)
        let projectId = UUID()

        let entries = [
            makeUsageLedgerEntry(
                timestamp: usageDate(year: 2026, month: 4, day: 7, calendar: calendar),
                projectId: projectId,
                projectNameSnapshot: "Alpha",
                costDelta: 2.0,
                imageDelta: 1
            ),
            makeUsageLedgerEntry(
                timestamp: usageDate(year: 2026, month: 4, day: 8, calendar: calendar),
                kind: .adjustment,
                costDelta: 1.0,
                imageDelta: 5,
                note: "Fixed overcount"
            ),
            makeUsageLedgerEntry(
                timestamp: usageDate(year: 2026, month: 4, day: 9, calendar: calendar),
                kind: .legacyImport,
                costDelta: 10.0,
                imageDelta: 10,
                note: "Imported legacy usage totals"
            )
        ]

        let snapshot = UsageSnapshotBuilder.makeSnapshot(
            entries: entries,
            filter: .sevenDays,
            now: now,
            calendar: calendar,
            projectDisplayName: { _, snapshot in snapshot ?? "Unknown" }
        )

        #expect(snapshot.totals.cost == 13.0)
        #expect(snapshot.totals.images == 16)
        #expect(snapshot.dayBuckets.count == 7)
        #expect(snapshot.dayBuckets.reduce(0) { $0 + $1.cost } == 2.0)
        #expect(snapshot.dayBuckets.reduce(0) { $0 + $1.images } == 1)
        #expect(snapshot.recentActivity.map(\.title).contains("Manual correction"))
        #expect(snapshot.recentActivity.map(\.title).contains("Imported total"))
    }

    @Test func usageSnapshotHandlesEmptyLedger() {
        let snapshot = UsageSnapshotBuilder.makeSnapshot(
            entries: [],
            filter: .allTime,
            projectDisplayName: { _, snapshot in snapshot ?? "Unknown" }
        )

        #expect(snapshot.hasEntries == false)
        #expect(snapshot.dayBuckets.isEmpty)
        #expect(snapshot.rangeLabel == "No tracked usage yet")
    }

    @MainActor @Test func exportCostReportUsesSelectedRangeEntries() throws {
        let tempAppSupportURL = try makeTemporaryDirectory()
        let projectsListURL = tempAppSupportURL.appendingPathComponent("projects.json")
        let costSummaryURL = tempAppSupportURL.appendingPathComponent("cost_summary.json")
        let usageLedgerURL = tempAppSupportURL.appendingPathComponent("usage_ledger.json")
        let projectsDirectoryURL = tempAppSupportURL.appendingPathComponent("projects", isDirectory: true)
        let manager = ProjectManager(
            appSupportURL: tempAppSupportURL,
            projectsListURL: projectsListURL,
            costSummaryURL: costSummaryURL,
            usageLedgerURL: usageLedgerURL,
            projectsDirectoryURL: projectsDirectoryURL
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = usageDate(year: 2026, month: 4, day: 9, hour: 18, calendar: calendar)
        let projectId = manager.projects.first!.id

        manager.appendLedgerEntry(
            makeUsageLedgerEntry(
                timestamp: usageDate(year: 2026, month: 4, day: 1, calendar: calendar),
                projectId: projectId,
                projectNameSnapshot: "Default Project",
                costDelta: 1.0,
                imageDelta: 1
            )
        )
        manager.appendLedgerEntry(
            makeUsageLedgerEntry(
                timestamp: usageDate(year: 2026, month: 4, day: 9, calendar: calendar),
                projectId: projectId,
                projectNameSnapshot: "Default Project",
                costDelta: 4.0,
                imageDelta: 2
            )
        )

        let snapshot = UsageSnapshotBuilder.makeSnapshot(
            entries: manager.ledger,
            filter: .today,
            now: now,
            calendar: calendar,
            projectDisplayName: manager.projectDisplayName(for:projectNameSnapshot:)
        )

        let exportURL = try #require(manager.exportCostReportCSV(entries: snapshot.filteredEntries))
        let csv = try String(contentsOf: exportURL, encoding: .utf8)

        #expect(csv.contains("2026-04-09T12:00:00Z"))
        #expect(csv.contains("2026-04-01T12:00:00Z") == false)
    }

    @Test func costEstimatorViewUsesModelAwareTotalsAndFallbackWarning() {
        let proEstimator = CostEstimatorView(
            stagedImageCount: 2,
            variationCount: 1,
            outputCount: 2,
            imageSize: "2K",
            isBatchTier: false,
            isMultiInput: false,
            generationMode: .image,
            modelName: "gemini-3-pro-image-preview"
        )
        let flashEstimator = CostEstimatorView(
            stagedImageCount: 2,
            variationCount: 1,
            outputCount: 2,
            imageSize: "2K",
            isBatchTier: false,
            isMultiInput: false,
            generationMode: .image,
            modelName: "gemini-2.5-flash-image"
        )
        let fallbackEstimator = CostEstimatorView(
            stagedImageCount: 0,
            variationCount: 1,
            outputCount: 1,
            imageSize: "1K",
            isBatchTier: true,
            isMultiInput: false,
            generationMode: .text,
            modelName: "legacy-image-model"
        )

        #expect(abs(proEstimator.totalCost - 0.2702) < floatingPointTolerance)
        #expect(abs(flashEstimator.totalCost - 0.156336) < floatingPointTolerance)
        #expect(proEstimator.totalCost > flashEstimator.totalCost)
        #expect(fallbackEstimator.fallbackPricingDescription == "Using Nano Banana pricing fallback.")
    }

    @MainActor @Test func enqueueTextGenerationLocksConfiguredModelName() async throws {
        try await withStoredModelName("gemini-3-pro-image-preview") {
            let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
            let orchestrator = BatchOrchestrator(
                activeBatchURL: activeBatchURL,
                autoStartEnqueuedBatches: false
            )

            orchestrator.enqueueTextGeneration(
                prompt: "prompt",
                aspectRatio: "16:9",
                imageSize: "2K",
                outputDirectory: "/tmp",
                useBatchTier: true,
                imageCount: 2,
                projectId: UUID()
            )

            let persistedState = try loadPersistedQueueState(from: activeBatchURL)
            #expect(persistedState.batches.count == 1)
            #expect(persistedState.batches.first?.modelName == "gemini-3-pro-image-preview")
            #expect(persistedState.batches.first?.isTextMode == true)
        }
    }

    @MainActor @Test func cancelUsesLockedBatchModelNameInsteadOfCurrentConfig() async throws {
        try await withStoredModelName("gemini-3-pro-image-preview") {
            let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
            let orchestrator = BatchOrchestrator(
                activeBatchURL: activeBatchURL,
                autoStartEnqueuedBatches: false
            )
            let projectId = UUID()
            let batch = BatchJob(
                prompt: "prompt",
                outputDirectory: "/tmp",
                projectId: projectId,
                modelName: AppConfig.load().modelName ?? AppPricing.defaultModelName
            )
            let task = ImageTask(inputPaths: ["/tmp/input.png"], projectId: projectId)
            batch.tasks = [task]

            var capturedEntry: HistoryEntry?
            orchestrator.onImageCompleted = { entry in
                capturedEntry = entry
            }

            orchestrator.enqueue(batch)

            var config = AppConfig.load()
            config.modelName = "gemini-2.5-flash-image"
            config.save()

            orchestrator.cancel(batch: batch)

            #expect(capturedEntry?.modelName == "gemini-3-pro-image-preview")
            #expect(capturedEntry?.status == "cancelled")
        }
    }

    @MainActor @Test func resumePollingFromHistoryPreservesSavedModelName() throws {
        let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
        let orchestrator = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false
        )
        let inputBookmark = Data("input-bookmark".utf8)
        let outputDirectoryBookmark = Data("directory-bookmark".utf8)
        let entry = HistoryEntry(
            projectId: UUID(),
            sourceImagePaths: ["/tmp/input.png"],
            outputImagePath: "/tmp/output.png",
            prompt: "prompt",
            aspectRatio: "16:9",
            imageSize: "2K",
            usedBatchTier: true,
            cost: 1,
            status: "processing",
            externalJobName: "batches/test-job",
            sourceImageBookmarks: [inputBookmark],
            outputDirectoryBookmark: outputDirectoryBookmark,
            modelName: "gemini-3-pro-image-preview"
        )

        orchestrator.resumePollingFromHistory(for: entry)

        let persistedState = try loadPersistedQueueState(from: activeBatchURL)
        #expect(persistedState.batches.first?.modelName == "gemini-3-pro-image-preview")
        #expect(persistedState.batches.first?.systemPrompt == nil)
        #expect(persistedState.batches.first?.outputDirectoryBookmark == outputDirectoryBookmark)
        #expect(persistedState.batches.first?.tasks.first?.inputBookmarks == [inputBookmark])
    }

    @MainActor @Test func resumePollingFromLegacyHistoryLeavesModelNameNil() throws {
        let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
        let orchestrator = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false
        )
        let entry = HistoryEntry(
            projectId: UUID(),
            sourceImagePaths: ["/tmp/input.png"],
            outputImagePath: "/tmp/output.png",
            prompt: "prompt",
            aspectRatio: "16:9",
            imageSize: "2K",
            usedBatchTier: false,
            cost: 1,
            status: "processing",
            externalJobName: "batches/test-job"
        )

        orchestrator.resumePollingFromHistory(for: entry)

        let persistedState = try loadPersistedQueueState(from: activeBatchURL)
        #expect(persistedState.batches.first?.modelName == nil)
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

        if batch.status != "processing" {
            Issue.record("Expected batch to stay active while cancellation is being reconciled")
        }
        if task.status != "processing" {
            Issue.record("Expected submitting task to remain processing while cancellation is pending")
        }
        if task.phase != .cancelRequested {
            Issue.record("Expected submitting task to move into cancelRequested phase")
        }
        if task.error != "Cancel requested. Waiting for final status." {
            Issue.record("Expected cancelRequested copy to be preserved on the task")
        }
    }

    @MainActor @Test func cancelPendingTaskMarksCancelledInsteadOfFailed() throws {
        let orchestrator = BatchOrchestrator(
            activeBatchURL: try makeTemporaryDirectory().appendingPathComponent("active_batch.json"),
            autoStartEnqueuedBatches: false
        )
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        let task = ImageTask(inputPaths: ["/tmp/input.png"])
        batch.tasks = [task]

        orchestrator.enqueue(batch)
        orchestrator.cancel(batch: batch)

        if task.status != "cancelled" {
            Issue.record("Expected pending task to be cancelled locally")
        }
        if task.phase != .cancelled {
            Issue.record("Expected pending task to move to cancelled phase")
        }
        if task.error != "Cancelled by user" {
            Issue.record("Expected pending task to retain the local cancellation message")
        }
    }

    @MainActor @Test func pausedQueueCancelTransitionsToCancellingAndMovesRemoteTaskToCancelRequested() async throws {
        let orchestrator = BatchOrchestrator(
            activeBatchURL: try makeTemporaryDirectory().appendingPathComponent("active_batch.json"),
            autoStartEnqueuedBatches: false,
            processQueueOverride: { _ in }
        )
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        batch.status = "processing"
        let task = ImageTask(inputPaths: ["/tmp/input.png"])
        task.status = "processing"
        task.phase = .pausedLocal
        task.externalJobName = "batches/test-job"
        batch.tasks = [task]

        orchestrator.enqueue(batch)
        orchestrator.controlState = .pausedLocal

        orchestrator.cancel()

        for _ in 0..<5 {
            await Task.yield()
        }

        #expect(orchestrator.controlState == .cancelling)
        #expect(orchestrator.hasCancellationInProgress)
        #expect(orchestrator.canResumeQueue == false)
        #expect(orchestrator.processingJobs.first?.phase == .cancelRequested)
        #expect(orchestrator.processingJobs.first?.error == "Cancel requested. Waiting for final status.")
    }

    @MainActor @Test func cancelledOnlyQueueFinishesWithCancellationCompleteStatus() async throws {
        let orchestrator = BatchOrchestrator(
            activeBatchURL: try makeTemporaryDirectory().appendingPathComponent("active_batch.json"),
            autoStartEnqueuedBatches: false
        )
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        batch.tasks = [ImageTask(inputPaths: ["/tmp/input.png"])]

        orchestrator.enqueue(batch)
        orchestrator.cancel()

        for _ in 0..<5 {
            await Task.yield()
        }

        #expect(orchestrator.controlState == .idle)
        #expect(orchestrator.statusMessage == "Cancellation complete")
        #expect(orchestrator.aggregateTone == .cancelled)
    }

    @MainActor @Test func cancelledTasksDoNotAppearInFailedJobs() async throws {
        let orchestrator = BatchOrchestrator(
            activeBatchURL: try makeTemporaryDirectory().appendingPathComponent("active_batch.json"),
            autoStartEnqueuedBatches: false
        )
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        batch.tasks = [ImageTask(inputPaths: ["/tmp/input.png"])]

        orchestrator.enqueue(batch)
        orchestrator.cancel()

        for _ in 0..<5 {
            await Task.yield()
        }

        #expect(orchestrator.cancelledJobs.count == 1)
        #expect(orchestrator.failedJobs.isEmpty)
        #expect(orchestrator.hasTrueFailures == false)
    }

    @MainActor @Test func failedTasksRemainInFailedJobs() throws {
        let orchestrator = BatchOrchestrator(
            activeBatchURL: try makeTemporaryDirectory().appendingPathComponent("active_batch.json"),
            autoStartEnqueuedBatches: false
        )
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        let task = ImageTask(inputPaths: ["/tmp/input.png"])
        task.status = "failed"
        task.phase = .failed
        task.error = "boom"
        batch.tasks = [task]

        orchestrator.enqueue(batch)

        #expect(orchestrator.failedJobs.count == 1)
        #expect(orchestrator.cancelledJobs.isEmpty)
        #expect(orchestrator.hasTrueFailures)
        #expect(orchestrator.aggregateTone == .issue)
    }

    @Test func headerActionsShowResumeBeforeCancelOnPausedQueue() {
        let actions = QueueHeaderActionVisibility(
            controlState: .pausedLocal,
            hasCancellationInProgress: false,
            hasActiveNonCancelledWork: true,
            canResumeQueue: true,
            hasOnlyCancelledTerminalJobs: false,
            hasNonTerminalWork: true
        )

        #expect(actions.showsPause == false)
        #expect(actions.showsResume)
        #expect(actions.showsCancel)
    }

    @Test func headerActionsHideResumeWhileCancellationIsInProgress() {
        let actions = QueueHeaderActionVisibility(
            controlState: .pausedLocal,
            hasCancellationInProgress: true,
            hasActiveNonCancelledWork: false,
            canResumeQueue: false,
            hasOnlyCancelledTerminalJobs: false,
            hasNonTerminalWork: true
        )

        #expect(actions.showsPause == false)
        #expect(actions.showsResume == false)
        #expect(actions.showsCancel)
    }

    @Test func headerActionsHideAllButtonsForCancelledOnlyTerminalQueue() {
        let actions = QueueHeaderActionVisibility(
            controlState: .idle,
            hasCancellationInProgress: false,
            hasActiveNonCancelledWork: false,
            canResumeQueue: false,
            hasOnlyCancelledTerminalJobs: true,
            hasNonTerminalWork: false
        )

        #expect(actions.showsPause == false)
        #expect(actions.showsResume == false)
        #expect(actions.showsCancel == false)
    }

    @Test func queueLayoutMetricsReserveSpaceForWorkbenchAndDock() {
        let bounds = QueueLayoutMetrics.heightBounds(for: 900)

        #expect(bounds.lowerBound == QueueLayoutMetrics.minimumQueueHeight)
        #expect(bounds.upperBound == 592)
        #expect(
            QueueLayoutMetrics.clampedHeight(1_000, availableHeight: 900)
            == bounds.upperBound
        )
        #expect(
            QueueLayoutMetrics.clampedHeight(120, availableHeight: 900)
            == bounds.lowerBound
        )
    }

    @MainActor @Test func pauseStatePersistsAcrossReload() throws {
        let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
        let orchestrator = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false
        )
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        batch.status = "processing"
        let task = ImageTask(inputPaths: ["/tmp/input.png"])
        task.status = "processing"
        task.phase = .polling
        task.externalJobName = "batches/test-job"
        batch.tasks = [task]

        orchestrator.enqueue(batch)
        orchestrator.controlState = .running
        orchestrator.pause()

        if orchestrator.controlState != .pausedLocal {
            Issue.record("Expected pause to update the queue control state")
        }
        if orchestrator.processingJobs.first?.phase != .pausedLocal {
            Issue.record("Expected active task to be persisted as pausedLocal")
        }

        let reloaded = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false
        )

        if reloaded.controlState != .pausedLocal {
            Issue.record("Expected paused queue control state to reload from disk")
        }
        if reloaded.processingJobs.first?.phase != .pausedLocal {
            Issue.record("Expected paused task phase to reload from disk")
        }
    }

    @MainActor @Test func pausedQueueDoesNotAutoResumeOnLaunchRecovery() async throws {
        let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        let task = ImageTask(inputPaths: ["/tmp/input.png"])
        task.status = "processing"
        task.phase = .pausedLocal
        task.externalJobName = "batches/test-job"
        batch.tasks = [task]
        batch.status = "processing"
        try persistQueueState(PersistedQueueState(controlState: .pausedLocal, batches: [batch]), to: activeBatchURL)

        let probe = BatchStartProbe()
        let orchestrator = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false,
            processQueueOverride: { batchID in
                await probe.recordStart(batchID)
            }
        )

        await orchestrator.recoverSavedQueueOnLaunchIfNeeded()

        if orchestrator.controlState != .pausedLocal {
            Issue.record("Expected persisted paused queue to remain paused after launch recovery")
        }
        if await probe.startedCount() != 0 {
            Issue.record("Expected launch recovery to leave manually paused work untouched")
        }
    }

    @MainActor @Test func launchRecoveryAutoStartsInterruptedPendingWorkOnce() async throws {
        let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        batch.tasks = [ImageTask(inputPaths: ["/tmp/input.png"])]
        try persistQueueState(PersistedQueueState(controlState: .running, batches: [batch]), to: activeBatchURL)

        let probe = BatchStartProbe()
        let orchestrator = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false,
            processQueueOverride: { batchID in
                await probe.recordStart(batchID)
            }
        )

        if orchestrator.controlState != .interrupted {
            Issue.record("Expected persisted running state to normalize to interrupted on reload")
        }

        await orchestrator.recoverSavedQueueOnLaunchIfNeeded()
        await orchestrator.recoverSavedQueueOnLaunchIfNeeded()

        if await probe.startedCount() != 1 {
            Issue.record("Expected launch recovery to auto-start interrupted saved work exactly once")
        }
    }

    @MainActor @Test func launchRecoveryResumesCancellingQueueWithoutNewLocalSubmissions() async throws {
        let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        let task = ImageTask(inputPaths: ["/tmp/input.png"])
        task.status = "processing"
        task.phase = .cancelRequested
        task.externalJobName = "batches/test-job"
        batch.tasks = [task]
        batch.status = "processing"
        try persistQueueState(PersistedQueueState(controlState: .cancelling, batches: [batch]), to: activeBatchURL)

        let probe = BatchStartProbe()
        let orchestrator = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false,
            processQueueOverride: { batchID in
                await probe.recordStart(batchID)
            }
        )

        if orchestrator.controlState != .cancelling {
            Issue.record("Expected persisted cancelling state to stay cancellation-oriented on reload")
        }
        if !orchestrator.pendingJobs.isEmpty {
            Issue.record("Expected cancelling recovery queue to avoid reintroducing pending work")
        }

        await orchestrator.recoverSavedQueueOnLaunchIfNeeded()

        if await probe.startedCount() != 1 {
            Issue.record("Expected launch recovery to reconcile cancelling work")
        }
    }

    @MainActor @Test func launchRecoveryAutoResumesRemotePollingStates() async throws {
        let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        let task = ImageTask(inputPaths: ["/tmp/input.png"])
        task.status = "processing"
        task.phase = .submittedRemote
        task.externalJobName = "batches/test-job"
        batch.tasks = [task]
        batch.status = "processing"
        try persistQueueState(PersistedQueueState(controlState: .interrupted, batches: [batch]), to: activeBatchURL)

        let probe = BatchStartProbe()
        let orchestrator = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false,
            processQueueOverride: { batchID in
                await probe.recordStart(batchID)
            }
        )

        await orchestrator.recoverSavedQueueOnLaunchIfNeeded()

        if await probe.startedCount() != 1 {
            Issue.record("Expected launch recovery to resume remote polling work")
        }
    }

    @MainActor @Test func launchRecoveryMarksOrphanedSubmittingTasksAsIssues() async throws {
        let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        let task = ImageTask(inputPaths: ["/tmp/input.png"])
        task.status = "processing"
        task.phase = .submitting
        batch.tasks = [task]
        batch.status = "processing"
        try persistQueueState(PersistedQueueState(controlState: .running, batches: [batch]), to: activeBatchURL)

        let probe = BatchStartProbe()
        let orchestrator = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false,
            processQueueOverride: { batchID in
                await probe.recordStart(batchID)
            }
        )

        await orchestrator.recoverSavedQueueOnLaunchIfNeeded()

        if orchestrator.failedJobs.count != 1 {
            Issue.record("Expected orphaned submitting task to be surfaced as a failed issue on reload")
        }
        if orchestrator.failedJobs.first?.error != "App closed before submission completed. Remote job id was not saved; retry manually to avoid duplicate jobs." {
            Issue.record("Expected orphaned submitting task to carry the duplicate-safe retry guidance")
        }
        if orchestrator.controlState != .idle {
            Issue.record("Expected queue with only orphaned submitting issues to stay idle after reload")
        }
        if await probe.startedCount() != 0 {
            Issue.record("Expected launch recovery to avoid auto-resubmitting ambiguous submitting work")
        }
    }

    @MainActor @Test func launchRecoveryIgnoresTerminalOnlySavedQueues() async throws {
        let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
        let batch = BatchJob(prompt: "prompt", outputDirectory: "/tmp")
        let task = ImageTask(inputPaths: ["/tmp/input.png"])
        task.status = "completed"
        task.phase = .completed
        batch.tasks = [task]
        batch.status = "completed"
        try persistQueueState(PersistedQueueState(controlState: .running, batches: [batch]), to: activeBatchURL)

        let probe = BatchStartProbe()
        let orchestrator = BatchOrchestrator(
            activeBatchURL: activeBatchURL,
            autoStartEnqueuedBatches: false,
            processQueueOverride: { batchID in
                await probe.recordStart(batchID)
            }
        )

        await orchestrator.recoverSavedQueueOnLaunchIfNeeded()

        if orchestrator.controlState != .idle {
            Issue.record("Expected terminal-only saved queues to remain idle on reload")
        }
        if await probe.startedCount() != 0 {
            Issue.record("Expected launch recovery to ignore terminal-only saved queues")
        }
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

        if startedCount != 2 {
            Issue.record("Expected startAll() to start both eligible batches")
        }
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
