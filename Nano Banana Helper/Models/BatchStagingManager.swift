import SwiftUI
import Observation

@Observable
class BatchStagingManager {
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
    
    // Batch Configuration (Synced with Inspector)
    var prompt: String = ""
    var systemPrompt: String = "" // New System Prompt
    var aspectRatio: String = "Auto" // Changed to Auto
    var imageSize: String = "4K"
    var isBatchTier: Bool = false
    var isMultiInput: Bool = false
    var textToImageCount: Int = 1 // Support for generating without input images
    
    // Derived Properties
    var isEmpty: Bool { stagedFiles.isEmpty }
    var count: Int { stagedFiles.isEmpty ? textToImageCount : stagedFiles.count }
    var hasAnyRegionEdits: Bool {
        stagedFiles.contains { stagedMaskEdits[$0] != nil }
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
        let hasValidInput = !stagedFiles.isEmpty || (textToImageCount > 0 && aspectRatio != "Auto")
        return hasValidInput && hasSufficientPrompts
    }

    var startBlockReason: String? {
        if isMultiInput && hasAnyRegionEdits {
            return "Region Edit is only available in standard batch mode (one output per input image). Turn off Multi-Input Mode to continue."
        }
        return nil
    }
    
    // Actions
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

    /// Adds files and captures security-scoped bookmarks where available.
    /// Any provided bookmarks are preserved and preferred over newly generated ones.
    func addFilesCapturingBookmarks(_ urls: [URL], preferredBookmarks: [URL: Data] = [:]) {
        var bookmarks = preferredBookmarks

        for url in urls where bookmarks[url] == nil {
            let didStart = url.startAccessingSecurityScopedResource()
            if let bookmark = AppPaths.bookmark(for: url) {
                bookmarks[url] = bookmark
            }
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        addFiles(urls, bookmarks: bookmarks)
    }
    
    func removeFile(_ url: URL) {
        stagedFiles.removeAll { $0 == url }
        stagedBookmarks.removeValue(forKey: url)
        stagedMaskEdits.removeValue(forKey: url)
    }
    
    func clearAll() {
        stagedFiles.removeAll()
        stagedBookmarks.removeAll()
        stagedMaskEdits.removeAll()
        // Do NOT clear system prompt on batch clear, it's persistent configuration
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
    
    func saveMaskEdit(for url: URL, maskData: Data, prompt: String, paths: [DrawingPath]) {
        if isMultiInput {
            isMultiInput = false
        }
        stagedMaskEdits[url] = StagedMaskEdit(maskData: maskData, prompt: prompt, paths: paths)
    }
    
    func hasMaskEdit(for url: URL) -> Bool {
        return stagedMaskEdits[url] != nil
    }
}
