import SwiftUI
import Observation

@Observable
class BatchStagingManager {
    struct RejectedFile: Sendable {
        let url: URL
        let reason: String
    }

    struct AddFilesResult: Sendable {
        let acceptedURLs: [URL]
        let rejectedURLsWithReason: [RejectedFile]

        var rejectedFiles: [RejectedFile] { rejectedURLsWithReason }
        var rejectedCount: Int { rejectedURLsWithReason.count }
        var hasRejections: Bool { !rejectedURLsWithReason.isEmpty }
    }

    // Staged Items
    var stagedFiles: [URL] = []
    
    // Security-scoped bookmarks keyed by URL, for files selected via file picker
    var stagedBookmarks: [URL: Data] = [:]
    
    struct DrawingPath: Identifiable, Sendable {
        let id = UUID()
        // Normalized points in the rendered image coordinate space (0...1).
        var points: [CGPoint]
        // Normalized brush size as a fraction of min(canvasWidth, canvasHeight).
        var size: CGFloat
        var isEraser: Bool = false
    }
    
    struct StagedMaskEdit: Sendable {
        let maskData: Data
        let prompt: String
        let paths: [DrawingPath]
    }
    
    // Saved mask edits keyed by URL
    var stagedMaskEdits: [URL: StagedMaskEdit] = [:]
    
    // Cached file sizes for oversized payload estimation
    private var cachedFileSizes: [URL: Int] = [:]
    
    // Batch Configuration (Synced with Inspector)
    var prompt: String = ""
    var systemPrompt: String = "" // New System Prompt
    var selectedModelName: String = ModelCatalog.defaultModelId {
        didSet {
            sanitizeSelectionsForCurrentModel()
        }
    }
    var aspectRatio: String = "Auto" // Changed to Auto
    var imageSize: String = "4K"
    var isBatchTier: Bool = false
    var isMultiInput: Bool = false
    var generationCount: Int = 1 {
        didSet {
            let clamped = Self.clampedGenerationCount(generationCount)
            if generationCount != clamped {
                generationCount = clamped
            }
        }
    }
    
    // Derived Properties
    var isEmpty: Bool { stagedFiles.isEmpty }
    var count: Int { stagedFiles.isEmpty ? generationCount : stagedFiles.count }
    var estimatedRequestCount: Int {
        if stagedFiles.isEmpty {
            return generationCount
        }
        if isMultiInput {
            return generationCount
        }
        return stagedFiles.count * generationCount
    }
    var estimatedInputCountForCost: Int {
        if stagedFiles.isEmpty {
            return 0
        }
        if isMultiInput {
            return stagedFiles.count * generationCount
        }
        return stagedFiles.count * generationCount
    }
    var estimatedOutputCountForCost: Int {
        estimatedRequestCount
    }
    var hasAnyRegionEdits: Bool {
        stagedFiles.contains { stagedMaskEdits[$0] != nil }
    }
    var availableAspectRatios: [String] {
        ModelCatalog.supportedAspectRatios(for: selectedModelName)
    }
    var availableImageSizes: [String] {
        ModelCatalog.supportedImageSizes(for: selectedModelName)
    }
    
    var hasSufficientPrompts: Bool {
        if isMultiInput && hasAnyRegionEdits { return false }
        if !prompt.isEmpty { return true }
        if stagedFiles.isEmpty { return false } // Text-to-image requires a prompt
        
        if isMultiInput {
            // In multi-input, we just need at least one mask edit with a prompt
            return stagedFiles.contains { url in
                stagedMaskEdits[url]?.prompt.isEmpty == false
            }
        } else {
            // In standard mode, EVERY image without its own mask prompt needs the global prompt
            // Thus if global prompt is empty, EVERY file must have a mask prompt
            return stagedFiles.allSatisfy { url in
                stagedMaskEdits[url]?.prompt.isEmpty == false
            }
        }
    }
    
    var canStartBatch: Bool {
        let hasValidInput = !stagedFiles.isEmpty || (generationCount > 0 && aspectRatio != "Auto")
        return hasValidInput && hasSufficientPrompts && startBlockReason == nil
    }

    var batchPayloadPreflightWarning: String? {
        guard isBatchTier else { return nil }
        guard let oversized = firstOversizedBatchPayloadEstimate else { return nil }
        let estimatedMB = Double(oversized.estimatedBytes) / Double(1024 * 1024)
        return String(
            format: "Estimated inline batch payload (%.1fMB) exceeds the 20MB limit. Use smaller images or fewer images per batch.",
            estimatedMB
        )
    }

    var startBlockReason: String? {
        if isMultiInput && hasAnyRegionEdits {
            return "Region Edit is only available in standard batch mode (one output per input image). Turn off Multi-Input Mode to continue."
        }
        if let payloadWarning = batchPayloadPreflightWarning {
            return payloadWarning
        }
        return nil
    }

    private let securityScopedPathing: any SecurityScopedPathing

    init(securityScopedPathing: any SecurityScopedPathing = LiveSecurityScopedPathing()) {
        self.securityScopedPathing = securityScopedPathing
    }
    
    // Actions
    func addFiles(_ urls: [URL], bookmarks: [URL: Data] = [:]) {
        let normalizedURLs = urls.map { $0.standardizedFileURL }
        let normalizedBookmarks = bookmarks.reduce(into: [URL: Data]()) { partialResult, element in
            partialResult[element.key.standardizedFileURL] = element.value
        }

        // Filter for images and duplicates if needed
        let newFiles = normalizedURLs.filter { url in
            !stagedFiles.contains(url)
        }
        stagedFiles.append(contentsOf: newFiles)
        
        // Store any provided bookmarks
        for (url, bookmark) in normalizedBookmarks {
            stagedBookmarks[url] = bookmark
        }
        
        // Cache file sizes to avoid reading disk / resolving bookmarks on every UI render
        for url in newFiles {
            cachedFileSizes[url] = computeFileSizeBytes(for: url)
        }
    }

    /// Adds files and captures security-scoped bookmarks where available.
    /// Any provided bookmarks are preserved and preferred over newly generated ones.
    func addFilesCapturingBookmarks(_ urls: [URL], preferredBookmarks: [URL: Data] = [:]) -> AddFilesResult {
        let normalizedURLs = urls.map { $0.standardizedFileURL }
        var bookmarks = preferredBookmarks.reduce(into: [URL: Data]()) { partialResult, element in
            partialResult[element.key.standardizedFileURL] = element.value
        }

        var accepted: [URL] = []
        var rejected: [RejectedFile] = []

        for (index, url) in normalizedURLs.enumerated() {
            DebugLog.debug("security.input", "Input selected for staging", metadata: [
                "event": "security.input.selected",
                "input_index": String(index),
                "path": url.path,
                "path_hash": securityScopedPathing.pathHash(for: url.path),
                "path_basename": securityScopedPathing.pathBasename(for: url.path),
                "launch_id": securityScopedPathing.launchID
            ])
            if bookmarks[url] == nil {
                let didStart = securityScopedPathing.startAccessing(url, metadata: [
                    "event": "security.scope.start.attempt.staging",
                    "input_index": String(index)
                ])
                if let bookmark = securityScopedPathing.bookmark(for: url, metadata: [
                    "event": "security.bookmark.create.staging",
                    "input_index": String(index)
                ]) {
                    bookmarks[url] = bookmark
                }
                if didStart {
                    securityScopedPathing.stopAccessing(url, metadata: [
                        "input_index": String(index),
                        "event": "security.scope.stop.staging",
                        "launch_id": securityScopedPathing.launchID
                    ])
                }
            }

            if securityScopedPathing.requiresSecurityScope(path: url.path), bookmarks[url] == nil {
                let reason = "Sandbox bookmark could not be created. Re-select this file to grant access."
                rejected.append(RejectedFile(url: url, reason: reason))
                DebugLog.error("staging.permissions", "Rejected staged file due to missing bookmark", metadata: [
                    "path": url.path,
                    "reason": reason
                ])
                continue
            }

            accepted.append(url)
        }

        let acceptedBookmarks = bookmarks.filter { key, _ in accepted.contains(key) }
        addFiles(accepted, bookmarks: acceptedBookmarks)
        return AddFilesResult(acceptedURLs: accepted, rejectedURLsWithReason: rejected)
    }
    
    func removeFile(_ url: URL) {
        let normalized = url.standardizedFileURL
        stagedFiles.removeAll { $0 == normalized }
        stagedBookmarks.removeValue(forKey: normalized)
        stagedMaskEdits.removeValue(forKey: normalized)
        cachedFileSizes.removeValue(forKey: normalized)
    }
    
    func clearAll() {
        stagedFiles.removeAll()
        stagedBookmarks.removeAll()
        stagedMaskEdits.removeAll()
        cachedFileSizes.removeAll()
        // Do NOT clear system prompt on batch clear, it's persistent configuration
    }
    
    func bookmark(for url: URL) -> Data? {
        stagedBookmarks[url.standardizedFileURL]
    }
    
    func updateSettings(prompt: String? = nil, systemPrompt: String? = nil, model: String? = nil, ratio: String? = nil, size: String? = nil, batch: Bool? = nil, multiInput: Bool? = nil) {
        if let p = prompt { self.prompt = p }
        if let sp = systemPrompt { self.systemPrompt = sp }
        if let model = model { self.selectedModelName = model }
        if let r = ratio { self.aspectRatio = r }
        if let s = size { self.imageSize = s }
        if let b = batch { self.isBatchTier = b }
        if let m = multiInput { self.isMultiInput = m }
        sanitizeSelectionsForCurrentModel()
    }

    func buildTasksForCurrentConfiguration() -> [ImageTask] {
        if stagedFiles.isEmpty {
            return (0..<generationCount).map { _ in
                ImageTask(inputPaths: [])
            }
        }

        if isMultiInput {
            let inputPaths = stagedFiles.map { $0.path }
            let inputBookmarks = stagedFiles.compactMap { bookmark(for: $0) }
            let taskBookmarks = inputBookmarks.isEmpty ? nil : inputBookmarks
            return (0..<generationCount).map { _ in
                ImageTask(
                    inputPaths: inputPaths,
                    inputBookmarks: taskBookmarks,
                    maskImageData: nil,
                    customPrompt: nil
                )
            }
        }

        var tasks: [ImageTask] = []
        tasks.reserveCapacity(stagedFiles.count * generationCount)
        for url in stagedFiles {
            let stagedEdit = stagedMaskEdits[url]
            for _ in 0..<generationCount {
                tasks.append(
                    ImageTask(
                        inputPath: url.path,
                        inputBookmark: bookmark(for: url),
                        maskImageData: stagedEdit?.maskData,
                        customPrompt: stagedEdit?.prompt
                    )
                )
            }
        }
        return tasks
    }
    
    func saveMaskEdit(for url: URL, maskData: Data, prompt: String, paths: [DrawingPath]) {
        if isMultiInput {
            isMultiInput = false
        }
        stagedMaskEdits[url.standardizedFileURL] = StagedMaskEdit(maskData: maskData, prompt: prompt, paths: paths)
    }
    
    func hasMaskEdit(for url: URL) -> Bool {
        return stagedMaskEdits[url.standardizedFileURL] != nil
    }

    func sanitizeSelectionsForCurrentModel() {
        let sanitizedRatio = ModelCatalog.sanitizeAspectRatio(aspectRatio, for: selectedModelName)
        if aspectRatio != sanitizedRatio {
            aspectRatio = sanitizedRatio
        }

        let sanitizedSize = ModelCatalog.sanitizeImageSize(imageSize, for: selectedModelName)
        if imageSize != sanitizedSize {
            imageSize = sanitizedSize
        }
    }

    private static func clampedGenerationCount(_ value: Int) -> Int {
        min(8, max(1, value))
    }

    private var firstOversizedBatchPayloadEstimate: (estimatedBytes: Int, limitBytes: Int)? {
        guard !stagedFiles.isEmpty else { return nil }
        let limit = NanoBananaService.maxInlineBatchPayloadBytes

        if isMultiInput {
            let rawBytes = stagedFiles.reduce(into: 0) { partialResult, fileURL in
                partialResult += fileSizeBytes(for: fileURL)
            }
            let estimated = NanoBananaService.estimateInlineBatchPayloadBytes(
                rawImageBytes: rawBytes,
                prompt: prompt,
                systemInstruction: systemPrompt
            )
            return estimated > limit ? (estimated, limit) : nil
        }

        for fileURL in stagedFiles {
            // Region-edit tasks are cropped before API submission, so full-file size
            // overestimates and can produce false positives in preflight.
            if stagedMaskEdits[fileURL.standardizedFileURL] != nil {
                continue
            }

            let estimated = NanoBananaService.estimateInlineBatchPayloadBytes(
                rawImageBytes: fileSizeBytes(for: fileURL),
                prompt: prompt,
                systemInstruction: systemPrompt
            )
            if estimated > limit {
                return (estimated, limit)
            }
        }
        return nil
    }

    private func fileSizeBytes(for url: URL) -> Int {
        let normalizedURL = url.standardizedFileURL
        if let cached = cachedFileSizes[normalizedURL] {
            return cached
        }
        return computeFileSizeBytes(for: normalizedURL)
    }

    private func computeFileSizeBytes(for normalizedURL: URL) -> Int {
        let path = normalizedURL.path

        if let bookmark = stagedBookmarks[normalizedURL], securityScopedPathing.requiresSecurityScope(path: path) {
            return securityScopedPathing.withResolvedBookmark(bookmark) { scopedURL in
                fileSizeBytes(atPath: scopedURL.path)
            } ?? fileSizeBytes(atPath: path)
        }

        return fileSizeBytes(atPath: path)
    }

    private func fileSizeBytes(atPath path: String) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber else {
            return 0
        }
        return sizeNumber.intValue
    }
}
