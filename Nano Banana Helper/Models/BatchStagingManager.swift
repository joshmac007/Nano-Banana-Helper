import SwiftUI
import Observation

@Observable
class BatchStagingManager {
    // Staged Items
    var stagedFiles: [URL] = []
    
    // Batch Configuration (Synced with Inspector)
    var prompt: String = ""
    var aspectRatio: String = "Auto" // Changed to Auto
    var imageSize: String = "4K"
    var isBatchTier: Bool = false
    var isMultiInput: Bool = false
    
    // Derived Properties
    var isEmpty: Bool { stagedFiles.isEmpty }
    var count: Int { stagedFiles.count }
    
    // Actions
    func addFiles(_ urls: [URL]) {
        // Filter for images and duplicates if needed
        let newFiles = urls.filter { url in
            !stagedFiles.contains(url)
        }
        stagedFiles.append(contentsOf: newFiles)
    }
    
    func removeFile(_ url: URL) {
        stagedFiles.removeAll { $0 == url }
    }
    
    func clearAll() {
        stagedFiles.removeAll()
    }
    
    func updateSettings(prompt: String? = nil, ratio: String? = nil, size: String? = nil, batch: Bool? = nil, multiInput: Bool? = nil) {
        if let p = prompt { self.prompt = p }
        if let r = ratio { self.aspectRatio = r }
        if let s = size { self.imageSize = s }
        if let b = batch { self.isBatchTier = b }
        if let m = multiInput { self.isMultiInput = m }
    }
}
