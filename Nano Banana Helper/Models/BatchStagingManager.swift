import SwiftUI
import Observation

// MARK: - Generation Mode

/// Mode of operation for batch processing
enum GenerationMode: String, CaseIterable, Identifiable, Sendable {
    case image = "Image"
    case text = "Text"
    
    var id: String { rawValue }
    var displayName: String { rawValue }
    var icon: String {
        switch self {
        case .image: return "photo.on.rectangle.angled"
        case .text: return "text.bubble"
        }
    }
}

@Observable
class BatchStagingManager {
    // MARK: - Generation Mode
    var generationMode: GenerationMode = .image

    /// Number of output images to generate per image input set (1-4).
    var imageVariationCount: Int = 1
    
    /// Number of generation requests to issue in text mode (1-4).
    /// Clamping is handled at the call site (InspectorView buttons have .disabled guards).
    /// Property observers (willSet/didSet) cannot safely re-assign an @Observable property
    /// — the macro-generated computed setter routes through ObservationRegistrar, which
    /// re-enters the observer, causing infinite recursion.
    var textImageCount: Int = 1
    
    // MARK: - Provider Selection
    var provider: ModelProvider
    var modelName: String

    // MARK: - Staged Items
    var stagedFiles: [URL] = []
    
    // Security-scoped bookmarks keyed by URL, for files selected via file picker
    var stagedBookmarks: [URL: Data] = [:]
    var maskFile: URL?
    var maskBookmark: Data?
    
    // MARK: - Batch Configuration (Synced with Inspector)
    var prompt: String = ""
    var systemPrompt: String = ""
    var aspectRatio: String = "Auto"
    var imageSize: String = "4K"
    var isBatchTier: Bool = false
    var isMultiInput: Bool = false

    // MARK: - OpenAI Advanced Parameters
    var openAIOutputFormat: OpenAIOutputFormat = .png
    var openAIBackground: OpenAIBackground = .auto
    var openAIInputFidelity: OpenAIInputFidelity = .high
    var openAIOutputCompression: Int = 100
    var openAINCount: Int = 1
    
    init() {
        let config = AppConfig.load()
        let activeProvider = config.provider
        provider = activeProvider
        modelName = config.modelName(for: activeProvider) ?? AppPricing.defaultModelName(for: activeProvider)
    }
    
    // MARK: - Derived Properties
    var isEmpty: Bool { stagedFiles.isEmpty }
    var count: Int { stagedFiles.count }
    var hasMask: Bool { maskFile != nil }
    var containsPNGInputs: Bool {
        stagedFiles.contains { $0.pathExtension.lowercased() == "png" }
    }
    
    /// Number of queue tasks that will be created (files for image mode, request count for text mode).
    var effectiveTaskCount: Int {
        switch generationMode {
        case .image:
            guard !stagedFiles.isEmpty else { return 0 }
            return isMultiInput ? imageVariationCount : stagedFiles.count * imageVariationCount
        case .text:
            return textImageCount
        }
    }

    var expectedOutputCount: Int {
        let baseTaskCount = effectiveTaskCount
        guard provider == .openAI, baseTaskCount > 0 else { return baseTaskCount }
        return baseTaskCount * openAINCount
    }

    /// Number of input-image charges implied by the current staging configuration.
    var effectiveInputCount: Int {
        switch generationMode {
        case .image:
            return stagedFiles.count * imageVariationCount
        case .text:
            return 0
        }
    }
    
    /// Whether the staging area is ready to start generation
    var isReadyForGeneration: Bool {
        guard !prompt.isEmpty else { return false }
        switch generationMode {
        case .image:
            return !stagedFiles.isEmpty
        case .text:
            return true
        }
    }
    
    // MARK: - Actions
    func refreshProviderSelection() {
        let config = AppConfig.load()
        provider = config.provider
        modelName = config.modelName(for: provider) ?? AppPricing.defaultModelName(for: provider)
        if provider != .openAI {
            clearMask()
        }
    }

    func applyProviderSelection(_ provider: ModelProvider, modelName: String? = nil) {
        self.provider = provider
        self.modelName = modelName ?? AppPricing.defaultModelName(for: provider)
        if provider != .openAI {
            clearMask()
        }
    }

    func addFiles(_ urls: [URL], bookmarks: [URL: Data] = [:]) {
        let newFiles = urls.filter { url in
            !stagedFiles.contains(url)
        }
        stagedFiles.append(contentsOf: newFiles)
        
        for (url, bookmark) in bookmarks {
            stagedBookmarks[url] = bookmark
        }
    }
    
    func removeFile(_ url: URL) {
        stagedFiles.removeAll { $0 == url }
        stagedBookmarks.removeValue(forKey: url)
    }

    func setMaskFile(_ url: URL?, bookmark: Data? = nil) {
        maskFile = url
        if let bookmark {
            maskBookmark = bookmark
        } else if url == nil {
            maskBookmark = nil
        }
    }

    func clearMask() {
        maskFile = nil
        maskBookmark = nil
    }

    func moveFiles(fromOffsets: IndexSet, toOffset: Int) {
        stagedFiles.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func moveFile(_ source: URL, before target: URL) {
        guard source != target,
              let sourceIndex = stagedFiles.firstIndex(of: source),
              let targetIndex = stagedFiles.firstIndex(of: target) else {
            return
        }

        let item = stagedFiles.remove(at: sourceIndex)
        let adjustedTargetIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        stagedFiles.insert(item, at: adjustedTargetIndex)
    }
    
    /// Clear staged files and bookmarks, but preserve prompt and mode for UX continuity
    func clearAll() {
        stagedFiles.removeAll()
        stagedBookmarks.removeAll()
        clearMask()
    }
    
    /// Clear all state including mode (use when switching projects or explicit reset)
    func resetAll() {
        clearAll()
        prompt = ""
        systemPrompt = ""
        generationMode = .image
        imageVariationCount = 1
        textImageCount = 1
        isBatchTier = false
        isMultiInput = false
        openAIOutputFormat = .png
        openAIBackground = .auto
        openAIInputFidelity = .high
        openAIOutputCompression = 100
        openAINCount = 1
        refreshProviderSelection()
    }
    
    func bookmark(for url: URL) -> Data? {
        stagedBookmarks[url]
    }

    func restore(from entry: HistoryEntry) {
        clearAll()

        prompt = entry.prompt
        systemPrompt = entry.systemPrompt ?? ""
        aspectRatio = entry.aspectRatio
        imageSize = entry.imageSize
        isBatchTier = entry.usedBatchTier
        imageVariationCount = 1
        textImageCount = 1
        provider = entry.provider
        modelName = entry.modelName ?? AppPricing.defaultModelName(for: entry.provider)
        openAIOutputFormat = entry.openAIOutputFormat
        openAIBackground = entry.openAIBackground
        openAIInputFidelity = entry.openAIInputFidelity
        openAIOutputCompression = entry.openAIOutputCompression
        openAINCount = entry.openAINCount

        if let maskImagePath = entry.maskImagePath,
           !maskImagePath.isEmpty,
           FileManager.default.fileExists(atPath: maskImagePath) {
            maskFile = URL(fileURLWithPath: maskImagePath)
            maskBookmark = entry.maskImageBookmark
        }

        guard !entry.isTextToImage else {
            generationMode = .text
            isMultiInput = false
            return
        }

        generationMode = .image

        var restoredFiles: [URL] = []
        var restoredBookmarks: [URL: Data] = [:]
        let sourceBookmarks = entry.sourceImageBookmarks ?? []

        for (index, path) in entry.sourceImagePaths.enumerated() {
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
                continue
            }

            let url = URL(fileURLWithPath: path)
            restoredFiles.append(url)

            if sourceBookmarks.indices.contains(index) {
                restoredBookmarks[url] = sourceBookmarks[index]
            }
        }

        stagedFiles = restoredFiles
        stagedBookmarks = restoredBookmarks
        isMultiInput = restoredFiles.count > 1
    }

    func makeImageTasks() -> [ImageTask] {
        guard !stagedFiles.isEmpty else { return [] }

        if isMultiInput {
            let inputPaths = stagedFiles.map(\.path)
            let inputBookmarks = stagedFiles.compactMap { bookmark(for: $0) }
            return (0..<imageVariationCount).map { index in
                ImageTask(
                    inputPaths: inputPaths,
                    projectId: nil,
                    provider: provider,
                    inputBookmarks: inputBookmarks.isEmpty ? nil : inputBookmarks,
                    maskImagePath: maskFile?.path,
                    maskImageBookmark: maskBookmark,
                    variationIndex: index + 1,
                    variationTotal: imageVariationCount
                )
            }
        }

        return stagedFiles.flatMap { url in
            (0..<imageVariationCount).map { index in
                ImageTask(
                    inputPath: url.path,
                    projectId: nil,
                    provider: provider,
                    inputBookmark: bookmark(for: url),
                    maskImagePath: maskFile?.path,
                    maskImageBookmark: maskBookmark,
                    variationIndex: index + 1,
                    variationTotal: imageVariationCount
                )
            }
        }
    }
    
    func updateSettings(
        prompt: String? = nil,
        systemPrompt: String? = nil,
        ratio: String? = nil,
        size: String? = nil,
        batch: Bool? = nil,
        multiInput: Bool? = nil,
        provider: ModelProvider? = nil,
        modelName: String? = nil,
        openAIOutputFormat: OpenAIOutputFormat? = nil,
        openAIBackground: OpenAIBackground? = nil,
        openAIInputFidelity: OpenAIInputFidelity? = nil,
        openAIOutputCompression: Int? = nil,
        openAINCount: Int? = nil
    ) {
        if let p = prompt { self.prompt = p }
        if let sp = systemPrompt { self.systemPrompt = sp }
        if let r = ratio { self.aspectRatio = r }
        if let s = size { self.imageSize = s }
        if let b = batch { self.isBatchTier = b }
        if let m = multiInput { self.isMultiInput = m }
        if let provider { self.provider = provider }
        if let modelName { self.modelName = modelName }
        if let v = openAIOutputFormat { self.openAIOutputFormat = v }
        if let v = openAIBackground { self.openAIBackground = v }
        if let v = openAIInputFidelity { self.openAIInputFidelity = v }
        if let v = openAIOutputCompression { self.openAIOutputCompression = v }
        if let v = openAINCount { self.openAINCount = v }
    }
}
