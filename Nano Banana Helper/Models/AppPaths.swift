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

    struct ResolvedBookmark {
        let url: URL
        let refreshedBookmarkData: Data?
    }

    struct ResolvedBookmarkPath {
        let path: String
        let refreshedBookmarkData: Data?
    }

    struct BookmarkResolutionDependencies {
        let resolveURL: (Data) throws -> (url: URL, isStale: Bool)
        let refreshBookmarkData: (URL) throws -> Data
        let startAccessing: (URL) -> Bool
        let stopAccessing: (URL) -> Void

        static let live = BookmarkResolutionDependencies(
            resolveURL: { data in
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return (url, isStale)
            },
            refreshBookmarkData: { url in
                try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            },
            startAccessing: { url in
                url.startAccessingSecurityScopedResource()
            },
            stopAccessing: { url in
                url.stopAccessingSecurityScopedResource()
            }
        )
    }
    
    /// Resolve a security scoped bookmark and start accessing the resource.
    /// - Important: The caller is responsible for calling `stopAccessingSecurityScopedResource()`
    ///   on the returned URL when done. Prefer `withResolvedBookmark` or `resolveBookmarkToPath`
    ///   for display-only use cases to avoid leaks.
    static func resolveBookmark(
        _ data: Data,
        dependencies: BookmarkResolutionDependencies = .live
    ) -> ResolvedBookmark? {
        do {
            let resolved = try dependencies.resolveURL(data)
            let url = resolved.url
            var refreshedBookmarkData: Data?
            
            if resolved.isStale {
                // Attempt to refresh the stale bookmark immediately.
                // If we can't, return nil to force the user to re-select the file —
                // a stale bookmark stored on disk will fail silently on next launch.
                do {
                    refreshedBookmarkData = try dependencies.refreshBookmarkData(url)
                    print("⚠️ Stale bookmark refreshed for \(url.path) — caller should persist the updated bookmark")
                } catch {
                    print("❌ Could not refresh stale bookmark for \(url.path): \(error). User must re-select the file.")
                    return nil
                }
            }
            
            if dependencies.startAccessing(url) {
                return ResolvedBookmark(url: url, refreshedBookmarkData: refreshedBookmarkData)
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
    static func withResolvedBookmark<T>(
        _ data: Data,
        dependencies: BookmarkResolutionDependencies = .live,
        _ body: (URL) throws -> T
    ) rethrows -> T? {
        guard let resolved = resolveBookmark(data, dependencies: dependencies) else { return nil }
        defer { dependencies.stopAccessing(resolved.url) }
        return try body(resolved.url)
    }
    
    /// Resolves a bookmark, captures the file-system path, then immediately stops access.
    /// Safe for display-only use (labels, Finder reveals, FileManager checks) where a live
    /// security scope is not required.
    static func resolveBookmarkToPath(
        _ data: Data,
        dependencies: BookmarkResolutionDependencies = .live
    ) -> ResolvedBookmarkPath? {
        guard let resolved = resolveBookmark(data, dependencies: dependencies) else { return nil }
        defer { dependencies.stopAccessing(resolved.url) }
        return ResolvedBookmarkPath(
            path: resolved.url.path,
            refreshedBookmarkData: resolved.refreshedBookmarkData
        )
    }
}
