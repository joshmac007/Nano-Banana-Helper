//
//  Nano_Banana_HelperTests.swift
//  Nano Banana HelperTests
//
//  Created by Josh McSwain on 2/2/26.
//

import Testing
import Foundation
import AppKit
import CoreGraphics
import ImageIO
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

    @Test func deletingGlobalHistoryEntryOnlyRemovesTargetedProjectRow() throws {
        let fileManager = FileManager.default
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        func makeEntry(id: UUID, projectId: UUID, timestamp: String, prompt: String, outputName: String) throws -> HistoryEntry {
            let json = """
            {
              "id": "\(id.uuidString)",
              "projectId": "\(projectId.uuidString)",
              "timestamp": "\(timestamp)",
              "sourceImagePaths": ["/tmp/in.png"],
              "outputImagePath": "/tmp/\(outputName)",
              "prompt": "\(prompt)",
              "modelName": "\(ModelCatalog.defaultModelId)",
              "aspectRatio": "16:9",
              "imageSize": "1K",
              "usedBatchTier": false,
              "cost": 0.1,
              "status": "completed"
            }
            """
            return try decoder.decode(HistoryEntry.self, from: Data(json.utf8))
        }

        func historyURL(for projectId: UUID) -> URL {
            AppPaths.projectsDirectoryURL
                .appendingPathComponent(projectId.uuidString)
                .appendingPathComponent("history.json")
        }

        let firstProjectId = UUID()
        let secondProjectId = UUID()
        let firstProjectDirectory = AppPaths.projectsDirectoryURL.appendingPathComponent(firstProjectId.uuidString)
        let secondProjectDirectory = AppPaths.projectsDirectoryURL.appendingPathComponent(secondProjectId.uuidString)

        defer {
            try? fileManager.removeItem(at: firstProjectDirectory)
            try? fileManager.removeItem(at: secondProjectDirectory)
        }

        let deletedEntry = try makeEntry(
            id: UUID(),
            projectId: firstProjectId,
            timestamp: "2026-03-01T00:00:00Z",
            prompt: "delete me",
            outputName: "delete.png"
        )
        let retainedSameProjectEntry = try makeEntry(
            id: UUID(),
            projectId: firstProjectId,
            timestamp: "2026-03-01T01:00:00Z",
            prompt: "keep me",
            outputName: "keep.png"
        )
        let otherProjectEntry = try makeEntry(
            id: UUID(),
            projectId: secondProjectId,
            timestamp: "2026-03-01T02:00:00Z",
            prompt: "other project",
            outputName: "other.png"
        )

        try fileManager.createDirectory(at: firstProjectDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondProjectDirectory, withIntermediateDirectories: true)
        try encoder.encode([deletedEntry, retainedSameProjectEntry]).write(to: historyURL(for: firstProjectId))
        try encoder.encode([otherProjectEntry]).write(to: historyURL(for: secondProjectId))

        let manager = HistoryManager()
        manager.entries = []
        manager.allGlobalEntries = [deletedEntry, retainedSameProjectEntry, otherProjectEntry]

        manager.deleteEntry(deletedEntry)

        let firstProjectHistory = try decoder.decode(
            [HistoryEntry].self,
            from: Data(contentsOf: historyURL(for: firstProjectId))
        )
        let secondProjectHistory = try decoder.decode(
            [HistoryEntry].self,
            from: Data(contentsOf: historyURL(for: secondProjectId))
        )
        let remainingGlobalIDs = manager.allGlobalEntries.map(\.id)

        #expect(firstProjectHistory.count == 1)
        #expect(firstProjectHistory.first?.id == retainedSameProjectEntry.id)
        #expect(secondProjectHistory.count == 1)
        #expect(secondProjectHistory.first?.id == otherProjectEntry.id)
        #expect(remainingGlobalIDs == [retainedSameProjectEntry.id, otherProjectEntry.id])
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

    @Test func historyEntryRoundTripsRegionEditMetadata() throws {
        let cropRect = CGRect(x: 12, y: 24, width: 48, height: 64)
        let entry = HistoryEntry(
            projectId: UUID(),
            sourceImagePaths: ["/tmp/in.png"],
            outputImagePath: "/tmp/out.png",
            prompt: "merged prompt",
            globalPrompt: "global prompt",
            customPrompt: "region prompt",
            modelName: ModelCatalog.defaultModelId,
            aspectRatio: "16:9",
            imageSize: "1K",
            usedBatchTier: false,
            cost: 0.1,
            sourceImageBookmarks: [Data([0x01])],
            outputImageBookmark: Data([0x02]),
            maskImageData: Data([0x03]),
            regionEditCropRect: cropRect,
            regionEditProcessingImageSize: "1K"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HistoryEntry.self, from: encoder.encode(entry))

        #expect(decoded.globalPrompt == "global prompt")
        #expect(decoded.customPrompt == "region prompt")
        #expect(decoded.maskImageData == Data([0x03]))
        #expect(decoded.regionEditCropRect == cropRect)
        #expect(decoded.regionEditProcessingImageSize == "1K")
    }

    @Test func mergedTaskPromptAppendsRegionClauseExactlyOnce() async throws {
        let orchestrator = await MainActor.run { BatchOrchestrator() }
        let prompt = await MainActor.run {
            orchestrator.mergedTaskPrompt(
                globalPrompt: "global",
                customPrompt: "region",
                isRegionEdit: true
            )
        }

        #expect(prompt.contains("Global instructions:\nglobal"))
        #expect(prompt.contains("Region edit instructions:\nregion"))
        #expect(prompt.components(separatedBy: "Only change the intended region in this cropped image.").count == 2)
    }

    @Test func regionEditRequestPayloadOmitsAspectRatioAndSendsSingleImagePart() async throws {
        let imageURL = try makeTempImageFile(width: 128, height: 128, background: .gray)
        defer { cleanupFiles([imageURL]) }

        let service = NanoBananaService()
        let request = ImageEditRequest(
            inputImageURLs: [imageURL],
            prompt: "test",
            systemInstruction: "system",
            modelName: ModelCatalog.defaultModelId,
            aspectRatio: "16:9",
            imageSize: "1K",
            useBatchTier: false,
            mode: .regionEdit
        )
        let payload = try await service.buildRequestPayload(request: request)

        let imageConfig = ((payload["generationConfig"] as? [String: Any])?["imageConfig"] as? [String: Any]) ?? [:]
        let parts = (((payload["contents"] as? [[String: Any]])?.first)?["parts"] as? [[String: Any]]) ?? []

        #expect(imageConfig["imageSize"] as? String == "1K")
        #expect(imageConfig["aspectRatio"] == nil)
        #expect(parts.count == 2)
        #expect(parts.dropFirst().count == 1)
        #expect((parts.dropFirst().first?["inlineData"] as? [String: Any])?["data"] as? String != nil)
    }

    @Test func regionEditProcessorRejectsEmptyMask() throws {
        let sourceData = try makePNG(width: 256, height: 256, background: .darkGray)
        let emptyMaskData = try makeMaskPNG(width: 256, height: 256, rects: [])

        #expect(throws: RegionEditProcessorError.self) {
            try RegionEditProcessor.prepareCrop(
                sourceImageData: sourceData,
                maskImageData: emptyMaskData,
                marginFraction: 0,
                minimumMarginPixels: 0
            )
        }
    }

    @Test func regionEditProcessorFindsSingleRegionBounds() throws {
        let sourceData = try makePNG(width: 256, height: 256, background: .darkGray)
        let rect = CGRect(x: 40, y: 50, width: 60, height: 70)
        let maskData = try makeMaskPNG(width: 256, height: 256, rects: [rect])

        let preparation = try RegionEditProcessor.prepareCrop(
            sourceImageData: sourceData,
            maskImageData: maskData,
            marginFraction: 0,
            minimumMarginPixels: 0
        )

        #expect(preparation.cropRect == rect.integral)
    }

    @Test func regionEditProcessorFindsUnionOfMultipleIslands() throws {
        let sourceData = try makePNG(width: 256, height: 256, background: .darkGray)
        let first = CGRect(x: 10, y: 20, width: 30, height: 40)
        let second = CGRect(x: 120, y: 140, width: 50, height: 30)
        let maskData = try makeMaskPNG(width: 256, height: 256, rects: [first, second])

        let preparation = try RegionEditProcessor.prepareCrop(
            sourceImageData: sourceData,
            maskImageData: maskData,
            marginFraction: 0,
            minimumMarginPixels: 0
        )

        #expect(preparation.cropRect == first.union(second).integral)
    }

    @Test func regionEditProcessorExpandsAndClampsCropNearEdges() throws {
        let sourceData = try makePNG(width: 200, height: 200, background: .darkGray)
        let rect = CGRect(x: 5, y: 6, width: 20, height: 18)
        let maskData = try makeMaskPNG(width: 200, height: 200, rects: [rect])

        let preparation = try RegionEditProcessor.prepareCrop(
            sourceImageData: sourceData,
            maskImageData: maskData,
            marginFraction: 0.5,
            minimumMarginPixels: 20
        )

        #expect(preparation.cropRect.minX == 0)
        #expect(preparation.cropRect.minY == 0)
        #expect(preparation.cropRect.maxX <= 200)
        #expect(preparation.cropRect.maxY <= 200)
    }

    @Test func regionEditCompositePreservesOriginalDimensions() throws {
        let sourceData = try makePNG(width: 256, height: 256, background: .darkGray)
        let maskRect = CGRect(x: 80, y: 80, width: 64, height: 64)
        let maskData = try makeMaskPNG(width: 256, height: 256, rects: [maskRect])
        let editedCropData = try makePNG(width: 64, height: 64, background: .red)

        let composite = try RegionEditProcessor.compositeEditedCrop(
            originalImageData: sourceData,
            editedCropImageData: editedCropData,
            maskImageData: maskData,
            cropRect: maskRect
        )

        #expect(ImageMaskEditorSupport.sourcePixelSize(from: composite.imageData) == CGSize(width: 256, height: 256))
    }

    @Test func normalizedGeometryIsStableAcrossPreviewSizes() throws {
        let point = CGPoint(x: 50, y: 40)
        let firstRect = CGRect(x: 0, y: 0, width: 100, height: 80)
        let secondRect = CGRect(x: 0, y: 0, width: 500, height: 400)

        let firstNormalized = ImageMaskEditorSupport.normalizePoint(point, in: firstRect)
        let secondNormalized = ImageMaskEditorSupport.normalizePoint(CGPoint(x: 250, y: 200), in: secondRect)

        #expect(firstNormalized == CGPoint(x: 0.5, y: 0.5))
        #expect(secondNormalized == firstNormalized)
    }

    @Test func renderedMaskUsesSourcePixelDimensions() async throws {
        let path = BatchStagingManager.DrawingPath(
            points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.75)],
            size: 0.1,
            isEraser: false
        )

        let pngData = await MainActor.run {
            ImageMaskEditorSupport.renderMaskPNG(
                sourcePixelSize: CGSize(width: 640, height: 320),
                priorMaskData: nil,
                drawingPaths: [path]
            )
        }

        #expect(pngData != nil)
        #expect(ImageMaskEditorSupport.sourcePixelSize(from: pngData ?? Data()) == CGSize(width: 640, height: 320))
    }

    @Test func regionEditCostPreviewUsesChosenProcessingSize() throws {
        let manager = BatchStagingManager()
        manager.selectedModelName = ModelCatalog.defaultModelId
        manager.imageSize = "4K"
        manager.generationCount = 1

        let imageURL = try makeTempImageFile(width: 1600, height: 1600, background: .darkGray)
        defer { cleanupFiles([imageURL]) }

        manager.stagedFiles = [imageURL]
        manager.stagedMaskEdits[imageURL] = BatchStagingManager.StagedMaskEdit(
            maskData: try makeMaskPNG(width: 1600, height: 1600, rects: [CGRect(x: 700, y: 700, width: 100, height: 100)]),
            prompt: "replace",
            paths: []
        )

        let preview = manager.costPreview
        let expected = PricingEngine.estimate(
            modelName: ModelCatalog.defaultModelId,
            imageSize: "1K",
            isBatchTier: false,
            inputCount: 1,
            outputCount: 1
        )

        #expect(preview.lineItems.count == 1)
        #expect(preview.lineItems.first?.imageSize == "1K")
        #expect(abs(preview.total - expected.total) < 0.000001)
    }

    @Test func multiInputRegionEditsRemainBlocked() throws {
        let manager = BatchStagingManager()
        let url = URL(fileURLWithPath: "/tmp/one.png").standardizedFileURL
        manager.stagedFiles = [url]
        manager.isMultiInput = true
        manager.stagedMaskEdits[url] = BatchStagingManager.StagedMaskEdit(
            maskData: Data([0x01]),
            prompt: "region",
            paths: []
        )

        #expect(manager.hasAnyRegionEdits)
        #expect(manager.startBlockReason?.contains("Region Edit is only available in standard batch mode") == true)
        #expect(!manager.canStartBatch)
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

    private func makeTempImageFile(width: Int, height: Int, background: NSColor) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanobanana-image-\(UUID().uuidString).png")
        try makePNG(width: width, height: height, background: background).write(to: url, options: .atomic)
        return url.standardizedFileURL
    }

    private func makeMaskPNG(width: Int, height: Int, rects: [CGRect]) throws -> Data {
        try makePNG(width: width, height: height, background: .black, rects: rects, rectColor: .white)
    }

    private func makePNG(
        width: Int,
        height: Int,
        background: NSColor,
        rects: [CGRect] = [],
        rectColor: NSColor = .white
    ) throws -> Data {
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.coderInvalidValue)
        }

        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(rectColor.cgColor)
        for rect in rects {
            let flippedRect = CGRect(
                x: rect.minX,
                y: CGFloat(height) - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            context.fill(flippedRect)
        }

        guard let cgImage = context.makeImage() else {
            throw CocoaError(.coderInvalidValue)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.coderInvalidValue)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.coderInvalidValue)
        }
        return data as Data
    }

}
