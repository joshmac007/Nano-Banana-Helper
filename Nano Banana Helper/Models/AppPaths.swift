import Foundation

/// Centralized management of application storage paths and data migration
struct AppPaths {
    struct ResolvedSecurityScopedBookmark {
        let url: URL
        let refreshedBookmarkData: Data?
    }

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
    
    /// Resolve a security scoped bookmark and start accessing the resource.
    /// - Important: The caller is responsible for calling `stopAccessingSecurityScopedResource()`
    ///   on the returned URL when done. Prefer `withResolvedBookmark` or `resolveBookmarkToPath`
    ///   for display-only use cases to avoid leaks.
    static func resolveBookmark(_ data: Data) -> URL? {
        resolveBookmarkAccess(data)?.url
    }

    /// Resolve a bookmark, start accessing it, and return any refreshed bookmark data when stale.
    /// - Important: Caller must stop accessing `url` when done.
    static func resolveBookmarkAccess(_ data: Data) -> ResolvedSecurityScopedBookmark? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            var refreshedBookmarkData: Data?
            if isStale {
                // Attempt to refresh the stale bookmark immediately.
                // If we can't, return nil to force the user to re-select the file —
                // a stale bookmark stored on disk will fail silently on next launch.
                do {
                    refreshedBookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    print("⚠️ Stale bookmark refreshed for \(url.path) — caller should persist the updated bookmark")
                } catch {
                    print("❌ Could not refresh stale bookmark for \(url.path): \(error). User must re-select the file.")
                    return nil
                }
            }
            
            if url.startAccessingSecurityScopedResource() {
                return ResolvedSecurityScopedBookmark(
                    url: url,
                    refreshedBookmarkData: refreshedBookmarkData
                )
            } else {
                print("Failed to access security scoped resource: \(url.path)")
                return nil
            }
        } catch {
            print("Failed to resolve bookmark: \(error)")
            return nil
        }
    }
    
    /// Resolves a bookmark, executes a closure with the scoped URL, then immediately stops access.
    /// Use this for short-lived operations (reading file data, loading an image, etc.).
    @discardableResult
    static func withResolvedBookmark<T>(_ data: Data, _ body: (URL) throws -> T) rethrows -> T? {
        guard let url = resolveBookmark(data) else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }
    
    /// Resolves a bookmark, captures the file-system path, then immediately stops access.
    /// Safe for display-only use (labels, Finder reveals, FileManager checks) where a live
    /// security scope is not required.
    static func resolveBookmarkToPath(_ data: Data) -> String? {
        var result: String?
        withResolvedBookmark(data) { url in
            result = url.path
        }
        return result
    }
}
