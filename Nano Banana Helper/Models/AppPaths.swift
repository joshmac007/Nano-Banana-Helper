import Foundation
import CryptoKit

/// Centralized management of application storage paths and data migration
struct AppPaths {
    struct ResolvedSecurityScopedBookmark {
        let url: URL
        let refreshedBookmarkData: Data?
        let wasStale: Bool
    }

    nonisolated static let launchID: String = UUID().uuidString

    /// The primary application support directory for the current app version
    nonisolated static let appSupportURL: URL = {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("NanoBananaProAssistant", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    /// Path to the legacy data directory for migration
    nonisolated static let legacyAppSupportURL: URL = {
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

    /// Directory for local debug logs
    nonisolated static var debugLogsDirectoryURL: URL {
        let url = appSupportURL.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Primary debug log file used for local troubleshooting
    nonisolated static var debugLogURL: URL {
        debugLogsDirectoryURL.appendingPathComponent("debug.log")
    }

    /// Rotated debug log file (previous)
    nonisolated static var debugLogArchiveURL: URL {
        debugLogsDirectoryURL.appendingPathComponent("debug.previous.log")
    }

    /// Directory for per-incident forensic snapshots.
    nonisolated static var failureSnapshotsDirectoryURL: URL {
        let url = debugLogsDirectoryURL.appendingPathComponent("failures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    /// Returns whether a file-system path is managed internally by the app.
    /// Managed paths do not require external sandbox re-grants.
    static func isManagedPath(path: String) -> Bool {
        guard !path.isEmpty else { return true }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let managedRoots = [
            appSupportURL.standardizedFileURL.path,
            defaultOutputDirectory.standardizedFileURL.path,
            FileManager.default.temporaryDirectory.standardizedFileURL.path
        ]
        return managedRoots.contains { root in
            normalized == root || normalized.hasPrefix(root + "/")
        }
    }

    static func isManagedPath(url: URL) -> Bool {
        isManagedPath(path: url.path)
    }

    /// Returns true when the app must rely on a security-scoped bookmark
    /// to access a path under sandbox.
    static func requiresSecurityScope(path: String) -> Bool {
        !isManagedPath(path: path)
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

    /// Thread-safe tracker for security scope start/stop balance.
    /// A negative ref count means we called stopAccessing more times than startAccessing,
    /// which revokes sandbox access and causes the permission bug.
    enum ScopeRefCountTracker {
        private static var counts: [String: Int] = [:]
        private static let lock = NSLock()

        static func trackStart(path: String) {
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            lock.lock()
            counts[key, default: 0] += 1
            let count = counts[key]!
            lock.unlock()
            DebugLog.debug("security.refcount", "SCOPE START", metadata: [
                "path_hash": pathHash(for: path),
                "ref_count": String(count)
            ])
        }

        static func trackStop(path: String) {
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            lock.lock()
            counts[key, default: 0] -= 1
            let count = counts[key]!
            lock.unlock()
            if count < 0 {
                DebugLog.error("security.refcount", "⚠️ NEGATIVE REF COUNT — OVER-RELEASE DETECTED", metadata: [
                    "path_hash": pathHash(for: path),
                    "ref_count": String(count),
                    "launch_id": launchID
                ])
            } else {
                DebugLog.debug("security.refcount", "SCOPE STOP", metadata: [
                    "path_hash": pathHash(for: path),
                    "ref_count": String(count)
                ])
            }
        }

        static func currentCount(for path: String) -> Int {
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            lock.lock()
            let count = counts[key, default: 0]
            lock.unlock()
            return count
        }
    }

    static func pathHash(for path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func pathBasename(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static func scopeMetadata(path: String) -> [String: String] {
        [
            "path": path,
            "path_basename": pathBasename(for: path),
            "path_hash": pathHash(for: path),
            "launch_id": launchID
        ]
    }

    /// Create a security scoped bookmark for a URL
    static func bookmark(for url: URL, metadata: [String: String] = [:]) -> Data? {
        let baseMeta = mergeMetadata(scopeMetadata(path: url.path), metadata)
        DebugLog.debug("security.bookmark", "Bookmark create attempt", metadata: mergeMetadata(baseMeta, [
            "event": "security.bookmark.create.attempt"
        ]))
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            DebugLog.debug("security.bookmark", "Bookmark create succeeded", metadata: mergeMetadata(baseMeta, [
                "event": "security.bookmark.create.success",
                "bookmark_bytes": String(data.count)
            ]))
            return data
        } catch {
            DebugLog.error("security.bookmark", "Bookmark create failed", metadata: mergeMetadata(baseMeta, errorMetadata(error, event: "security.bookmark.create.failed")))
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
    static func resolveBookmarkAccess(_ data: Data, metadata: [String: String] = [:]) -> ResolvedSecurityScopedBookmark? {
        let baseMeta = mergeMetadata(metadata, [
            "bookmark_bytes": String(data.count),
            "launch_id": launchID
        ])
        DebugLog.debug("security.bookmark", "Bookmark resolve attempt", metadata: mergeMetadata(baseMeta, [
            "event": "security.bookmark.resolve.attempt"
        ]))
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            var contextualMeta = mergeMetadata(scopeMetadata(path: url.path), baseMeta)
            contextualMeta["bookmark_is_stale"] = String(isStale)
            DebugLog.debug("security.bookmark", "Bookmark resolve succeeded", metadata: mergeMetadata(contextualMeta, [
                "event": "security.bookmark.resolve.success"
            ]))

            var refreshedBookmarkData: Data?
            if isStale {
                DebugLog.info("security.bookmark", "Bookmark stale refresh attempt", metadata: mergeMetadata(contextualMeta, [
                    "event": "security.bookmark.refresh.attempt"
                ]))
                // Attempt to refresh the stale bookmark immediately.
                // If we can't, return nil to force the user to re-select the file —
                // a stale bookmark stored on disk will fail silently on next launch.
                do {
                    refreshedBookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    DebugLog.info("security.bookmark", "Bookmark stale refresh succeeded", metadata: mergeMetadata(contextualMeta, [
                        "event": "security.bookmark.refresh.success",
                        "refreshed_bookmark_bytes": String(refreshedBookmarkData?.count ?? 0)
                    ]))
                    print("⚠️ Stale bookmark refreshed for \(url.path) — caller should persist the updated bookmark")
                } catch {
                    DebugLog.error("security.bookmark", "Bookmark stale refresh failed", metadata: mergeMetadata(contextualMeta, errorMetadata(error, event: "security.bookmark.refresh.failed")))
                    print("❌ Could not refresh stale bookmark for \(url.path): \(error). User must re-select the file.")
                    return nil
                }
            }

            DebugLog.debug("security.bookmark", "Scope start attempt", metadata: mergeMetadata(contextualMeta, [
                "event": "security.scope.start.attempt"
            ]))
            if url.startAccessingSecurityScopedResource() {
                DebugLog.debug("security.bookmark", "Scope start succeeded", metadata: mergeMetadata(contextualMeta, [
                    "event": "security.scope.start.success"
                ]))
                ScopeRefCountTracker.trackStart(path: url.path)
                return ResolvedSecurityScopedBookmark(
                    url: url,
                    refreshedBookmarkData: refreshedBookmarkData,
                    wasStale: isStale
                )
            } else {
                DebugLog.error("security.bookmark", "Scope start failed", metadata: mergeMetadata(contextualMeta, [
                    "event": "security.scope.start.failed"
                ]))
                print("Failed to access security scoped resource: \(url.path)")
                return nil
            }
        } catch {
            DebugLog.error("security.bookmark", "Bookmark resolve failed", metadata: mergeMetadata(baseMeta, errorMetadata(error, event: "security.bookmark.resolve.failed")))
            print("Failed to resolve bookmark: \(error)")
            return nil
        }
    }

    static func startAccessingSecurityScope(url: URL, metadata: [String: String] = [:]) -> Bool {
        let baseMeta = mergeMetadata(scopeMetadata(path: url.path), metadata)
        DebugLog.debug("security.bookmark", "Scope start attempt", metadata: mergeMetadata(baseMeta, [
            "event": "security.scope.start.attempt"
        ]))
        
        let didStart = url.startAccessingSecurityScopedResource()
        
        if didStart {
            DebugLog.debug("security.bookmark", "Scope start succeeded", metadata: mergeMetadata(baseMeta, [
                "event": "security.scope.start.success"
            ]))
            ScopeRefCountTracker.trackStart(path: url.path)
        } else {
            DebugLog.error("security.bookmark", "Scope start failed", metadata: mergeMetadata(baseMeta, [
                "event": "security.scope.start.failed"
            ]))
        }
        return didStart
    }

    static func stopAccessingSecurityScope(url: URL, metadata: [String: String] = [:]) {
        ScopeRefCountTracker.trackStop(path: url.path)
        url.stopAccessingSecurityScopedResource()
        DebugLog.debug("security.bookmark", "Scope stop", metadata: mergeMetadata(scopeMetadata(path: url.path), mergeMetadata(metadata, [
            "event": "security.scope.stop",
            "launch_id": launchID
        ])))
    }
    
    /// Resolves a bookmark, executes a closure with the scoped URL, then immediately stops access.
    /// Use this for short-lived operations (reading file data, loading an image, etc.).
    @discardableResult
    static func withResolvedBookmark<T>(_ data: Data, _ body: (URL) throws -> T) rethrows -> T? {
        guard let url = resolveBookmark(data) else { return nil }
        defer {
            stopAccessingSecurityScope(url: url, metadata: [
                "event": "security.scope.stop.with_resolved_bookmark",
                "launch_id": launchID
            ])
        }
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

    private static func mergeMetadata(_ lhs: [String: String], _ rhs: [String: String]) -> [String: String] {
        lhs.merging(rhs) { _, new in new }
    }

    private static func errorMetadata(_ error: Error, event: String) -> [String: String] {
        let nsError = error as NSError
        var metadata: [String: String] = [
            "event": event,
            "error": String(describing: error),
            "error_domain": nsError.domain,
            "error_code": String(nsError.code)
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            metadata["underlying_error_domain"] = underlying.domain
            metadata["underlying_error_code"] = String(underlying.code)
        }
        return metadata
    }
}

enum DebugLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

actor DebugLogger {
    static let shared = DebugLogger()
    
    private let fileManager = FileManager.default
    private let maxFileBytes = 2_000_000
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    func log(
        level: DebugLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:],
        force: Bool = false
    ) async {
        let configEnabled = await MainActor.run { AppConfig.load().debugLoggingEnabled }
        let enabled = force || configEnabled
        guard enabled else { return }
        
        ensureLogFileExists()
        rotateIfNeeded()
        
        var line = "\(formatter.string(from: Date())) [\(level.rawValue)] [\(category)] \(message)"
        if !metadata.isEmpty {
            let metaString = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(Self.sanitize($0.value))" }
                .joined(separator: " ")
            line += " | \(metaString)"
        }
        line += "\n"
        append(line)
    }
    
    func clearLog() async {
        ensureLogFileExists()
        try? Data().write(to: AppPaths.debugLogURL)
        if fileManager.fileExists(atPath: AppPaths.debugLogArchiveURL.path) {
            try? fileManager.removeItem(at: AppPaths.debugLogArchiveURL)
        }
    }
    
    func logFileURL() -> URL {
        AppPaths.debugLogURL
    }
    
    private func ensureLogFileExists() {
        let dir = AppPaths.debugLogsDirectoryURL
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: AppPaths.debugLogURL.path) {
            _ = fileManager.createFile(atPath: AppPaths.debugLogURL.path, contents: nil)
        }
    }
    
    private func rotateIfNeeded() {
        guard
            let attrs = try? fileManager.attributesOfItem(atPath: AppPaths.debugLogURL.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue >= maxFileBytes
        else {
            return
        }
        
        if fileManager.fileExists(atPath: AppPaths.debugLogArchiveURL.path) {
            try? fileManager.removeItem(at: AppPaths.debugLogArchiveURL)
        }
        try? fileManager.moveItem(at: AppPaths.debugLogURL, to: AppPaths.debugLogArchiveURL)
        _ = fileManager.createFile(atPath: AppPaths.debugLogURL.path, contents: nil)
    }
    
    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        ensureLogFileExists()
        
        do {
            let handle = try FileHandle(forWritingTo: AppPaths.debugLogURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Avoid recursive logging failures; console only.
            print("Debug logger write failed: \(error)")
        }
    }
    
    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "\\n")
    }
}

enum DebugLog {
    static var fileURL: URL { AppPaths.debugLogURL }
    static var archiveURL: URL { AppPaths.debugLogArchiveURL }
    
    static func debug(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        write(.debug, category, message, metadata: metadata)
    }
    
    static func info(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        write(.info, category, message, metadata: metadata)
    }
    
    static func warning(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        write(.warning, category, message, metadata: metadata)
    }
    
    static func error(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        write(.error, category, message, metadata: metadata)
    }
    
    static func forceInfo(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        write(.info, category, message, metadata: metadata, force: true)
    }
    
    static func ensureLogFileExists() {
        let dir = AppPaths.debugLogsDirectoryURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: AppPaths.debugLogURL.path) {
            _ = FileManager.default.createFile(atPath: AppPaths.debugLogURL.path, contents: nil)
        }
    }
    
    static func clear() {
        Task { await DebugLogger.shared.clearLog() }
    }
    
    private static func write(
        _ level: DebugLogLevel,
        _ category: String,
        _ message: String,
        metadata: [String: String] = [:],
        force: Bool = false
    ) {
        Task {
            await DebugLogger.shared.log(
                level: level,
                category: category,
                message: message,
                metadata: metadata,
                force: force
            )
        }
    }
}
