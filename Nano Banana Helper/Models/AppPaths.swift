import Foundation

/// Centralized management of application storage paths and data migration
struct AppPaths {
    /// The primary application support directory for the current app version
    static let appSupportURL: URL = {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("NanoBananaProAssistant", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    /// Path to the legacy data directory for migration
    static let legacyAppSupportURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("NanoBananaPro", isDirectory: true)
    }()
    
    /// Path to the API configuration file
    static var configURL: URL {
        appSupportURL.appendingPathComponent("config.json")
    }
    
    /// Path to the saved prompts file
    static var promptsURL: URL {
        appSupportURL.appendingPathComponent("saved_prompts.json")
    }
    
    /// Path to the projects list file
    static var projectsURL: URL {
        appSupportURL.appendingPathComponent("projects.json")
    }
    
    /// Path to the global cost summary file
    static var costSummaryURL: URL {
        appSupportURL.appendingPathComponent("cost_summary.json")
    }
    
    /// Path to the currently active batch job for persistence across restarts
    static var activeBatchURL: URL {
        appSupportURL.appendingPathComponent("active_batch.json")
    }
    
    /// Subdirectory for individual project data
    static var projectsDirectoryURL: URL {
        let url = appSupportURL.appendingPathComponent("projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    /// Default output directory for images when not specified (~/Documents/NanoBananaPro)
    static var defaultOutputDirectory: URL {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = documentsURL.appendingPathComponent("NanoBananaPro", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    /// Checks for legacy data and migrates it to the new directory if needed
    static func migrateIfNeeded() {
        let fileManager = FileManager.default
        
        // Only migrate if legacy directory exists AND new directory hasn't been fully initialized 
        // (or we can just copy missing items)
        guard fileManager.fileExists(atPath: legacyAppSupportURL.path) else { return }
        
        do {
            let items = try fileManager.contentsOfDirectory(at: legacyAppSupportURL, includingPropertiesForKeys: nil)
            
            for sourceURL in items {
                let destinationURL = appSupportURL.appendingPathComponent(sourceURL.lastPathComponent)
                
                // Don't overwrite existing data in the new location
                if !fileManager.fileExists(atPath: destinationURL.path) {
                    print("🍌 Migrating \(sourceURL.lastPathComponent) to new storage...")
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                }
            }
            
            // Optionally remove the old directory if it's empty now
            let remainingItems = try fileManager.contentsOfDirectory(at: legacyAppSupportURL, includingPropertiesForKeys: nil)
            if remainingItems.isEmpty {
                try fileManager.removeItem(at: legacyAppSupportURL)
                print("🍌 Legacy storage removed.")
            }
            
        } catch {
            print("⚠️ Migration error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Security Scoped Bookmarks
    
    /// Create a security scoped bookmark for a URL
    static func bookmark(for url: URL) -> Data? {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return data
        } catch {
            print("Failed to create bookmark for \(url.path): \(error)")
            return nil
        }
    }
    
    /// Resolve a security scoped bookmark and start accessing the resource
    static func resolveBookmark(_ data: Data) -> URL? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                print("Bookmark is stale for \(url.path)")
                // In a perfect world we'd regenerate it here, but we need the original URL context
            }
            
            if url.startAccessingSecurityScopedResource() {
                return url
            } else {
                print("Failed to access security scoped resource: \(url.path)")
                return nil
            }
        } catch {
            print("Failed to resolve bookmark: \(error)")
            return nil
        }
    }
}
