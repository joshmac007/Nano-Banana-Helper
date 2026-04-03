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
    
    /// Number of output images to generate in text mode (1-4).
    /// Clamping is handled at the call site (InspectorView buttons have .disabled guards).
    /// Property observers (willSet/didSet) cannot safely re-assign an @Observable property
    /// — the macro-generated computed setter routes through ObservationRegistrar, which
    /// re-enters the observer, causing infinite recursion.
    var textImageCount: Int = 1
    
    // MARK: - Staged Items
    var stagedFiles: [URL] = []
    
    // Security-scoped bookmarks keyed by URL, for files selected via file picker
    var stagedBookmarks: [URL: Data] = [:]
    
    // MARK: - Batch Configuration (Synced with Inspector)
    var prompt: String = ""
    var systemPrompt: String = "" // New System Prompt
    var aspectRatio: String = "Auto" // Changed to Auto
    var imageSize: String = "4K"
    var isBatchTier: Bool = false
    var isMultiInput: Bool = false
    
    // MARK: - Derived Properties
    var isEmpty: Bool { stagedFiles.isEmpty }
    var count: Int { stagedFiles.count }
    
    /// Number of tasks that will be created (files for image mode, count for text mode)
    var effectiveTaskCount: Int {
        switch generationMode {
        case .image: return stagedFiles.count
        case .text: return textImageCount
        }
    }
    
    /// Whether the staging area is ready to start generation
    var isReadyForGeneration: Bool {
        guard !prompt.isEmpty else { return false }
        switch generationMode {
        case .image: return !stagedFiles.isEmpty
        case .text: return true // No input files required
        }
    }
    
    // MARK: - Actions
    func addFiles(_ urls: [URL], bookmarks: [URL: Data] = [:]) {
        // Filter for images and duplicates if needed
        let newFiles = urls.filter { url in
            !stagedFiles.contains(url)
        }
        stagedFiles.append(contentsOf: newFiles)
        
        // Store any provided bookmarks
        for (url, bookmark) in bookmarks {
            stagedBookmarks[url] = bookmark
        }
    }
    
    func removeFile(_ url: URL) {
        stagedFiles.removeAll { $0 == url }
        stagedBookmarks.removeValue(forKey: url)
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
        // Note: Preserve generationMode, textImageCount, and prompt for UX continuity
    }
    
    /// Clear all state including mode (use when switching projects or explicit reset)
    func resetAll() {
        clearAll()
        prompt = ""
        systemPrompt = ""
        generationMode = .image
        textImageCount = 1
    }
    
    func bookmark(for url: URL) -> Data? {
        stagedBookmarks[url]
    }
    
    func updateSettings(prompt: String? = nil, systemPrompt: String? = nil, ratio: String? = nil, size: String? = nil, batch: Bool? = nil, multiInput: Bool? = nil) {
        if let p = prompt { self.prompt = p }
        if let sp = systemPrompt { self.systemPrompt = sp }
        if let r = ratio { self.aspectRatio = r }
        if let s = size { self.imageSize = s }
        if let b = batch { self.isBatchTier = b }
        if let m = multiInput { self.isMultiInput = m }
    }
}
