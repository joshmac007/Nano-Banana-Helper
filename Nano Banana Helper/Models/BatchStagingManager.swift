import SwiftUI
import Observation

@Observable
class BatchStagingManager {
    // Staged Items
    var stagedFiles: [URL] = []
    
    // Security-scoped bookmarks keyed by URL, for files selected via file picker
    var stagedBookmarks: [URL: Data] = [:]
    
    // Batch Configuration (Synced with Inspector)
    var prompt: String = ""
    var systemPrompt: String = "" // New System Prompt
    var aspectRatio: String = "Auto" // Changed to Auto
    var imageSize: String = "4K"
    var isBatchTier: Bool = false
    var isMultiInput: Bool = false
    
    // Derived Properties
    var isEmpty: Bool { stagedFiles.isEmpty }
    var count: Int { stagedFiles.count }
    
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
    
    func removeFile(_ url: URL) {
        stagedFiles.removeAll { $0 == url }
        stagedBookmarks.removeValue(forKey: url)
    }
    
    func clearAll() {
        stagedFiles.removeAll()
        stagedBookmarks.removeAll()
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
