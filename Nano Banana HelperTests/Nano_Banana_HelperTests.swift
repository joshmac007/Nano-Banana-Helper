//
//  Nano_Banana_HelperTests.swift
//  Nano Banana HelperTests
//
//  Created by Josh McSwain on 2/2/26.
//

import Testing
import Foundation
@testable import Nano_Banana_Helper

struct Nano_Banana_HelperTests {

    @Test func modelCatalogSupportMatrix() throws {
        #expect(ModelCatalog.isAspectRatioSupported("21:9", for: ModelCatalog.proImageId))
        #expect(ModelCatalog.isAspectRatioSupported("2:3", for: ModelCatalog.proImageId))
        #expect(!ModelCatalog.isAspectRatioSupported("8:1", for: ModelCatalog.proImageId))
        #expect(!ModelCatalog.isAspectRatioSupported("3:1", for: ModelCatalog.proImageId))
        #expect(ModelCatalog.isAspectRatioSupported("21:9", for: ModelCatalog.flash31ImageId))
        #expect(ModelCatalog.isAspectRatioSupported("8:1", for: ModelCatalog.flash31ImageId))
        #expect(ModelCatalog.isAspectRatioSupported("1:3", for: ModelCatalog.flash31ImageId))
        #expect(ModelCatalog.isAspectRatioSupported("1:4", for: ModelCatalog.flash31ImageId))
        #expect(ModelCatalog.isAspectRatioSupported("1:8", for: ModelCatalog.flash31ImageId))
        #expect(ModelCatalog.supportedImageSizes(for: ModelCatalog.flash31ImageId).contains("0.5K"))
    }

    @Test func sanitizationForModelCapabilities() throws {
        let proRatio = ModelCatalog.sanitizeAspectRatio("8:1", for: ModelCatalog.proImageId)
        #expect(proRatio == "16:9")

        let flashRatio = ModelCatalog.sanitizeAspectRatio("8:1", for: ModelCatalog.flash31ImageId)
        #expect(flashRatio == "8:1")

        let proSize = ModelCatalog.sanitizeImageSize("0.5K", for: ModelCatalog.proImageId)
        #expect(proSize == "4K")

        let flashSize = ModelCatalog.sanitizeImageSize("0.5K", for: ModelCatalog.flash31ImageId)
        #expect(flashSize == "0.5K")
    }

    @Test func pricingEngineValues() throws {
        let proStandard = PricingEngine.estimate(
            modelName: ModelCatalog.proImageId,
            imageSize: "1K",
            isBatchTier: false,
            inputCount: 1,
            outputCount: 1
        )
        #expect(abs(proStandard.inputCost - 0.0011) < 0.000001)
        #expect(abs(proStandard.outputCost - 0.134) < 0.000001)
        #expect(abs(proStandard.total - 0.1351) < 0.000001)

        let flashStandard = PricingEngine.estimate(
            modelName: ModelCatalog.flash31ImageId,
            imageSize: "2K",
            isBatchTier: false,
            inputCount: 3,
            outputCount: 1
        )
        #expect(abs(flashStandard.inputCost - 0.0) < 0.000001)
        #expect(abs(flashStandard.outputCost - 0.101) < 0.000001)
        #expect(abs(flashStandard.total - 0.101) < 0.000001)

        let flashBatch = PricingEngine.estimate(
            modelName: ModelCatalog.flash31ImageId,
            imageSize: "4K",
            isBatchTier: true,
            inputCount: 5,
            outputCount: 2
        )
        #expect(abs(flashBatch.outputCost - 0.151) < 0.000001)
        #expect(abs(flashBatch.total - 0.151) < 0.000001)
    }

    @Test func costSummaryTracksByModel() throws {
        var summary = CostSummary()
        let projectId = UUID()
        summary.record(cost: 1.25, resolution: "1K", modelName: ModelCatalog.flash31ImageId, projectId: projectId)

        #expect(abs(summary.totalSpent - 1.25) < 0.000001)
        #expect(summary.imageCount == 1)
        #expect(abs((summary.byModel[ModelCatalog.flash31ImageId] ?? 0) - 1.25) < 0.000001)
        #expect(abs((summary.byResolution["1K"] ?? 0) - 1.25) < 0.000001)
        #expect(abs((summary.byProject[projectId.uuidString] ?? 0) - 1.25) < 0.000001)
    }

    @Test func historyEntryDecodeBackfillsModel() throws {
        let json = """
        {
          "id": "\(UUID())",
          "projectId": "\(UUID())",
          "timestamp": "2026-02-26T00:00:00Z",
          "sourceImagePaths": ["/tmp/in.png"],
          "outputImagePath": "/tmp/out.png",
          "prompt": "test",
          "aspectRatio": "16:9",
          "imageSize": "1K",
          "usedBatchTier": false,
          "cost": 0.1,
          "status": "completed"
        }
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(HistoryEntry.self, from: data)

        #expect(entry.modelName == ModelCatalog.defaultModelId)
    }

    @Test func batchJobDecodeBackfillsModel() throws {
        let json = """
        {
          "id": "\(UUID())",
          "createdAt": "2026-02-26T00:00:00Z",
          "projectId": "\(UUID())",
          "prompt": "test",
          "systemPrompt": null,
          "aspectRatio": "16:9",
          "imageSize": "1K",
          "outputDirectory": "/tmp",
          "outputDirectoryBookmark": null,
          "useBatchTier": false,
          "status": "pending",
          "tasks": []
        }
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let batch = try decoder.decode(BatchJob.self, from: data)

        #expect(batch.modelName == ModelCatalog.defaultModelId)
    }

    @Test func costSummaryDecodeBackfillsByModel() throws {
        let json = """
        {
          "totalSpent": 2.0,
          "imageCount": 2,
          "byResolution": {"1K": 2.0},
          "byProject": {"\(UUID())": 2.0}
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(CostSummary.self, from: data)
        #expect(decoded.byModel.isEmpty)
    }

    @Test func appPathsManagedScopeClassification() throws {
        let managedPath = AppPaths.appSupportURL
            .appendingPathComponent("projects")
            .appendingPathComponent("example.png")
            .path
        #expect(AppPaths.isManagedPath(path: managedPath))
        #expect(!AppPaths.requiresSecurityScope(path: managedPath))

        let externalPath = "/Users/Shared/example-\(UUID().uuidString).png"
        #expect(!AppPaths.isManagedPath(path: externalPath))
        #expect(AppPaths.requiresSecurityScope(path: externalPath))
    }

    @Test func stagingRejectsExternalFileWithoutBookmark() throws {
        let manager = BatchStagingManager()
        let missingExternalURL = URL(fileURLWithPath: "/Users/Shared/missing-\(UUID().uuidString).png")
        let result = manager.addFilesCapturingBookmarks([missingExternalURL])

        #expect(result.rejectedCount == 1)
        #expect(result.acceptedURLs.isEmpty)
        #expect(manager.stagedFiles.isEmpty)
    }

    @Test func generationCountClampsToAllowedRange() throws {
        let manager = BatchStagingManager()

        manager.generationCount = 0
        #expect(manager.generationCount == 1)

        manager.generationCount = 9
        #expect(manager.generationCount == 8)

        manager.generationCount = 5
        #expect(manager.generationCount == 5)
    }

    @Test func estimatedCountsForTextToImageUseGenerationCount() throws {
        let manager = BatchStagingManager()
        manager.generationCount = 4

        #expect(manager.stagedFiles.isEmpty)
        #expect(manager.estimatedRequestCount == 4)
        #expect(manager.estimatedInputCountForCost == 0)
        #expect(manager.estimatedOutputCountForCost == 4)
    }

    @Test func estimatedCountsForStandardModeMultiplyPerInput() throws {
        let manager = BatchStagingManager()
        manager.generationCount = 3
        manager.isMultiInput = false
        manager.stagedFiles = [
            URL(fileURLWithPath: "/tmp/one.png"),
            URL(fileURLWithPath: "/tmp/two.png")
        ]

        #expect(manager.estimatedRequestCount == 6)
        #expect(manager.estimatedInputCountForCost == 6)
        #expect(manager.estimatedOutputCountForCost == 6)
    }

    @Test func estimatedCountsForMultiInputModeScaleInputsPerGeneration() throws {
        let manager = BatchStagingManager()
        manager.generationCount = 4
        manager.isMultiInput = true
        manager.stagedFiles = [
            URL(fileURLWithPath: "/tmp/one.png"),
            URL(fileURLWithPath: "/tmp/two.png"),
            URL(fileURLWithPath: "/tmp/three.png")
        ]

        #expect(manager.estimatedRequestCount == 4)
        #expect(manager.estimatedInputCountForCost == 12)
        #expect(manager.estimatedOutputCountForCost == 4)
    }

    @Test func buildTasksReplicatesTextToImageRequests() throws {
        let manager = BatchStagingManager()
        manager.generationCount = 5

        let tasks = manager.buildTasksForCurrentConfiguration()
        #expect(tasks.count == 5)
        #expect(tasks.allSatisfy { $0.inputPaths.isEmpty })
    }

    @Test func buildTasksReplicatesStandardModePerInputAndCarriesMaskPrompt() throws {
        let manager = BatchStagingManager()
        manager.generationCount = 3
        manager.isMultiInput = false

        let firstURL = URL(fileURLWithPath: "/tmp/one.png").standardizedFileURL
        let secondURL = URL(fileURLWithPath: "/tmp/two.png").standardizedFileURL
        manager.stagedFiles = [firstURL, secondURL]
        manager.stagedBookmarks[firstURL] = Data([0x01])
        manager.stagedBookmarks[secondURL] = Data([0x02])
        manager.stagedMaskEdits[firstURL] = BatchStagingManager.StagedMaskEdit(
            maskData: Data([0xAA]),
            prompt: "only first",
            paths: []
        )

        let tasks = manager.buildTasksForCurrentConfiguration()
        #expect(tasks.count == 6)

        let firstTasks = tasks.filter { $0.inputPaths == [firstURL.path] }
        let secondTasks = tasks.filter { $0.inputPaths == [secondURL.path] }
        #expect(firstTasks.count == 3)
        #expect(secondTasks.count == 3)
        #expect(firstTasks.allSatisfy { $0.maskImageData == Data([0xAA]) })
        #expect(firstTasks.allSatisfy { $0.customPrompt == "only first" })
        #expect(secondTasks.allSatisfy { $0.maskImageData == nil })
        #expect(secondTasks.allSatisfy { $0.customPrompt == nil })
        #expect(firstTasks.allSatisfy { $0.inputBookmarks?.count == 1 })
        #expect(secondTasks.allSatisfy { $0.inputBookmarks?.count == 1 })
    }

    @Test func buildTasksReplicatesMultiInputRequestsWithAllInputs() throws {
        let manager = BatchStagingManager()
        manager.generationCount = 4
        manager.isMultiInput = true

        let urls = [
            URL(fileURLWithPath: "/tmp/one.png").standardizedFileURL,
            URL(fileURLWithPath: "/tmp/two.png").standardizedFileURL,
            URL(fileURLWithPath: "/tmp/three.png").standardizedFileURL
        ]
        manager.stagedFiles = urls
        manager.stagedBookmarks[urls[0]] = Data([0x01])
        manager.stagedBookmarks[urls[1]] = Data([0x02])
        manager.stagedBookmarks[urls[2]] = Data([0x03])

        let tasks = manager.buildTasksForCurrentConfiguration()
        #expect(tasks.count == 4)
        #expect(tasks.allSatisfy { $0.inputPaths == urls.map(\.path) })
        #expect(tasks.allSatisfy { $0.inputBookmarks?.count == 3 })
        #expect(tasks.allSatisfy { $0.maskImageData == nil })
        #expect(tasks.allSatisfy { $0.customPrompt == nil })
    }

    @Test func oversizedBatchTierPayloadIsBlockedBeforeStart() throws {
        let manager = BatchStagingManager()
        manager.isBatchTier = true
        manager.isMultiInput = true
        manager.prompt = "test prompt"

        let tempURLs = try makeTempFiles(count: 7, bytesPerFile: 3 * 1024 * 1024)
        defer { cleanupFiles(tempURLs) }

        manager.stagedFiles = tempURLs

        #expect(manager.batchPayloadPreflightWarning != nil)
        #expect(manager.startBlockReason != nil)
        #expect(!manager.canStartBatch)
    }

    @Test func payloadPreflightBlockClearsWhenBatchTierDisabled() throws {
        let manager = BatchStagingManager()
        manager.isBatchTier = false
        manager.isMultiInput = true
        manager.prompt = "test prompt"

        let tempURLs = try makeTempFiles(count: 7, bytesPerFile: 3 * 1024 * 1024)
        defer { cleanupFiles(tempURLs) }

        manager.stagedFiles = tempURLs

        #expect(manager.batchPayloadPreflightWarning == nil)
        #expect(manager.startBlockReason == nil)
        #expect(manager.canStartBatch)
    }

    private func makeTempFiles(count: Int, bytesPerFile: Int) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
        let data = Data(repeating: 0xFF, count: bytesPerFile)
        var urls: [URL] = []
        urls.reserveCapacity(count)
        for index in 0..<count {
            let url = directory.appendingPathComponent("nanobanana-test-\(UUID().uuidString)-\(index).png")
            try data.write(to: url, options: .atomic)
            urls.append(url.standardizedFileURL)
        }
        return urls
    }

    private func cleanupFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

}
