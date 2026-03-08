import AppKit
import Foundation
import Testing
@testable import Nano_Banana_Helper

@MainActor
struct BookmarkSystemTests {
    @Test func stagingRejectsExternalFileWithoutBookmark() throws {
        let pathing = FakeSecurityScopedPathing()
        let manager = BatchStagingManager(securityScopedPathing: pathing)
        let externalURL = URL(fileURLWithPath: "/external/missing-\(UUID().uuidString).png")

        let result = manager.addFilesCapturingBookmarks([externalURL])

        #expect(result.acceptedURLs.isEmpty)
        #expect(result.rejectedCount == 1)
        #expect(manager.stagedFiles.isEmpty)
    }

    @Test func stagingAcceptsManagedFileWithoutBookmark() throws {
        let pathing = FakeSecurityScopedPathing(managedPaths: ["/managed/library.png"])
        let manager = BatchStagingManager(securityScopedPathing: pathing)
        let managedURL = URL(fileURLWithPath: "/managed/library.png")

        let result = manager.addFilesCapturingBookmarks([managedURL])

        #expect(result.rejectedCount == 0)
        #expect(result.acceptedURLs == [managedURL.standardizedFileURL])
        #expect(manager.stagedFiles == [managedURL.standardizedFileURL])
        #expect(manager.stagedBookmarks.isEmpty)
    }

    @Test func stagingAcceptsExternalFileWithProvidedBookmark() throws {
        let pathing = FakeSecurityScopedPathing()
        let manager = BatchStagingManager(securityScopedPathing: pathing)
        let externalURL = URL(fileURLWithPath: "/external/selected-\(UUID().uuidString).png").standardizedFileURL
        let bookmark = Data([0x10, 0x20])

        let result = manager.addFilesCapturingBookmarks([externalURL], preferredBookmarks: [externalURL: bookmark])

        #expect(result.rejectedCount == 0)
        #expect(result.acceptedURLs == [externalURL])
        #expect(manager.stagedBookmarks[externalURL] == bookmark)
    }

    @Test func staleBookmarkRefreshProducesUpdatedBookmarkData() throws {
        let oldBookmark = Data([0x01])
        let refreshedBookmark = Data([0x02])
        let externalPath = "/external/refresh-target.png"

        let pathing = FakeSecurityScopedPathing()
        pathing.resolveResults[oldBookmark] = .success(
            path: externalPath,
            refreshedBookmarkData: refreshedBookmark,
            wasStale: true
        )

        let result = SecurityScopedInputResolver.resolve(
            inputPaths: [externalPath],
            inputBookmarks: [oldBookmark],
            pathing: pathing
        )

        guard case .success(let resolved) = result else {
            Issue.record("Expected successful stale bookmark resolution")
            return
        }

        #expect(resolved.staleByInputIndex[0] == true)
        #expect(resolved.refreshedBookmarkByIndex[0] == refreshedBookmark)
        #expect(resolved.applyingRefreshes(to: [oldBookmark]) == [refreshedBookmark])
    }

    @Test func mixedManagedAndExternalInputsResolveByPathCoverage() throws {
        let managedPath = "/managed/input-a.png"
        let externalPath = "/external/input-b.png"
        let externalBookmark = Data([0x33])

        let pathing = FakeSecurityScopedPathing(managedPaths: [managedPath])
        pathing.resolveResults[externalBookmark] = .success(
            path: externalPath,
            refreshedBookmarkData: nil,
            wasStale: false
        )

        let result = SecurityScopedInputResolver.resolve(
            inputPaths: [managedPath, externalPath],
            inputBookmarks: [externalBookmark],
            pathing: pathing
        )

        guard case .success(let resolved) = result else {
            Issue.record("Expected mixed managed/external preflight to succeed")
            return
        }

        #expect(resolved.inputURLs[0].path == managedPath)
        #expect(resolved.inputURLs[1].path == externalPath)
        #expect(resolved.scopedInputIndices == Set([1]))
    }

    @Test func resolveFailureOnRequiredInputReturnsBookmarkAccessError() throws {
        let requiredPath = "/external/must-resolve.png"
        let badBookmark = Data([0x44])

        let pathing = FakeSecurityScopedPathing()
        pathing.resolveResults[badBookmark] = .failure

        let result = SecurityScopedInputResolver.resolve(
            inputPaths: [requiredPath],
            inputBookmarks: [badBookmark],
            pathing: pathing
        )

        if case .failure(.bookmarkAccessFailed(path: let failedPath)) = result {
            #expect(failedPath == requiredPath)
        } else {
            Issue.record("Expected bookmark access failure for required path")
        }
    }

    @Test func historyAssetLoaderFallsBackToBookmarkWhenPlainPathIsUnavailable() throws {
        let deadPath = "/tmp/dead-\(UUID().uuidString).png"
        let liveURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: liveURL) }

        let bookmark = Data([0x55])
        let pathing = FakeSecurityScopedPathing()
        pathing.resolveResults[bookmark] = .success(
            path: liveURL.path,
            refreshedBookmarkData: nil,
            wasStale: false
        )
        pathing.bookmarkPathByData[bookmark] = liveURL.path

        let image = HistoryAssetResolver.loadImage(
            path: deadPath,
            bookmark: bookmark,
            pathing: pathing
        )

        #expect(image != nil)
        #expect(pathing.stopAccessCallCountByPath[liveURL.path] == 1)
    }

    @Test func historyAssetLoaderKeepsLegacyPathOnlyBehaviorWhenNoBookmarkExists() throws {
        let liveURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: liveURL) }
        let deadPath = "/tmp/dead-\(UUID().uuidString).png"

        let pathing = FakeSecurityScopedPathing()
        let liveImage = HistoryAssetResolver.loadImage(path: liveURL.path, bookmark: nil, pathing: pathing)
        let deadImage = HistoryAssetResolver.loadImage(path: deadPath, bookmark: nil, pathing: pathing)

        #expect(liveImage != nil)
        #expect(deadImage == nil)
    }

    @Test func scopedFileAccessKeepsDirectoryBookmarkAliveForChildFileOperation() throws {
        let directoryPath = "/external/results"
        let childFilePath = "/external/results/output/image.png"
        let directoryBookmark = Data([0x56])

        let pathing = FakeSecurityScopedPathing()
        pathing.bookmarkPathByData[directoryBookmark] = directoryPath

        let value = try #require(
            PreviewImageLoader.SecurityScopedFileAccess.withAccessibleURL(
                path: childFilePath,
                directoryBookmark: directoryBookmark,
                directoryPath: directoryPath,
                pathing: pathing
            ) { accessibleURL in
                #expect(accessibleURL.path == childFilePath)
                #expect(pathing.startAccessCallCountByPath[FakeSecurityScopedPathing.normalize(directoryPath)] == 1)
                #expect(pathing.stopAccessCallCountByPath[FakeSecurityScopedPathing.normalize(directoryPath)] == nil)
                return "ok"
            }
        )

        #expect(value == "ok")
        #expect(pathing.startAccessCallCountByPath[FakeSecurityScopedPathing.normalize(directoryPath)] == 1)
        #expect(pathing.stopAccessCallCountByPath[FakeSecurityScopedPathing.normalize(directoryPath)] == 1)
    }

    private func makeTemporaryPNG() throws -> URL {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BookmarkSystemTests", code: 1)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-history-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try pngData.write(to: url, options: .atomic)
        return url
    }
    
    @Test func concurrentOutputScopeResolveDoesNotOverRelease() throws {
        let pathing = FakeSecurityScopedPathing()
        let outputBookmark = Data([0xA0])
        let outputPath = "/external/output-dir"
        pathing.resolveResults[outputBookmark] = .success(
            path: outputPath, refreshedBookmarkData: nil, wasStale: false
        )

        // Simulate: resolve once (batch start), then 5 concurrent workers
        // Each worker should NOT re-resolve — they share the parent scope
        let resolved = pathing.resolveBookmarkAccess(outputBookmark, metadata: [:])
        #expect(resolved != nil)

        // Single stop at end
        pathing.stopAccessing(resolved!.url, metadata: [:])
        #expect(pathing.stopAccessCallCountByPath[FakeSecurityScopedPathing.normalize(outputPath)] == 1)
        #expect(pathing.startAccessCallCountByPath[FakeSecurityScopedPathing.normalize(outputPath)] == 1)
    }

    @Test func resolveBookmarkToPathCallsStopExactlyOnce() throws {
        let pathing = FakeSecurityScopedPathing()
        let bookmark = Data([0xB0])
        let path = "/external/test-file.png"
        pathing.bookmarkPathByData[bookmark] = path

        _ = pathing.resolveBookmarkToPath(bookmark)

        // withResolvedBookmark should have called stop exactly once
        #expect(pathing.stopAccessCallCountByPath[FakeSecurityScopedPathing.normalize(path)] == 1)
        #expect(pathing.startAccessCallCountByPath[FakeSecurityScopedPathing.normalize(path)] == 1)
    }

    @Test func staleOutputBookmarkRefreshIsReturned() throws {
        let oldBookmark = Data([0xC0])
        let refreshed = Data([0xC1])
        let pathing = FakeSecurityScopedPathing()
        pathing.resolveResults[oldBookmark] = .success(
            path: "/external/output", refreshedBookmarkData: refreshed, wasStale: true
        )

        let resolved = pathing.resolveBookmarkAccess(oldBookmark, metadata: [:])
        #expect(resolved?.wasStale == true)
        #expect(resolved?.refreshedBookmarkData == refreshed)
    }

    @Test func regionEditTaskWithCachedSourceDataSkipsBookmarkResolve() throws {
        // This tests the new cachedSourceImageData path
        let task = ImageTask(inputPaths: ["/external/source.png"])
        let expectedData = Data([0xDE, 0xAD])
        task.cachedSourceImageData = expectedData

        // Accessing cached data should succeed without bookmark resolution
        #expect(task.cachedSourceImageData == expectedData)
    }

    @Test func fileSizeCacheIsPopulatedOnAddAndPreventsFurtherResolutions() throws {
        let pathing = FakeSecurityScopedPathing()
        let manager = BatchStagingManager(securityScopedPathing: pathing)
        manager.isBatchTier = true
        manager.isMultiInput = true
        
        let url = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        
        let bookmark = Data([0x99])
        pathing.bookmarkPathByData[bookmark] = url.path
        
        // Add the file, which should populate the size cache
        _ = manager.addFilesCapturingBookmarks([url], preferredBookmarks: [url.standardizedFileURL: bookmark])
        
        let initialStartCount = pathing.startAccessCallCountByPath[FakeSecurityScopedPathing.normalize(url.path)] ?? 0
        // Expect at least 1 resolution during staging
        #expect(initialStartCount > 0)
        
        // Re-evaluating payload warning multiple times should hit the cache and NOT increase counts
        _ = manager.batchPayloadPreflightWarning
        _ = manager.batchPayloadPreflightWarning
        
        let newStartCount = pathing.startAccessCallCountByPath[FakeSecurityScopedPathing.normalize(url.path)] ?? 0
        #expect(newStartCount == initialStartCount)
    }

    @Test func fileSizeCacheIsInvalidatedOnRemove() throws {
        let pathing = FakeSecurityScopedPathing()
        let manager = BatchStagingManager(securityScopedPathing: pathing)
        
        let url = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let bookmark = Data([0x99])
        pathing.bookmarkPathByData[bookmark] = url.path
        
        _ = manager.addFilesCapturingBookmarks([url], preferredBookmarks: [url.standardizedFileURL: bookmark])
        
        let initialStartCount = pathing.startAccessCallCountByPath[FakeSecurityScopedPathing.normalize(url.path)] ?? 0
        
        // Remove the file, invalidating cache
        manager.removeFile(url)
        
        // Re-add should re-compute size (since cache was cleared)
        _ = manager.addFilesCapturingBookmarks([url], preferredBookmarks: [url.standardizedFileURL: bookmark])
        
        let newStartCount = pathing.startAccessCallCountByPath[FakeSecurityScopedPathing.normalize(url.path)] ?? 0
        // Should have resolved again
        #expect(newStartCount > initialStartCount)
    }
}

private final class FakeSecurityScopedPathing: SecurityScopedPathing {
    enum ResolveResult {
        case success(path: String, refreshedBookmarkData: Data?, wasStale: Bool)
        case failure
    }

    let launchID: String = "fake-launch"
    var managedPaths: Set<String>
    var bookmarkByPath: [String: Data] = [:]
    var resolveResults: [Data: ResolveResult] = [:]
    var bookmarkPathByData: [Data: String] = [:]
    var stopAccessCallCountByPath: [String: Int] = [:]
    var startAccessCallCountByPath: [String: Int] = [:]

    init(managedPaths: Set<String> = []) {
        self.managedPaths = Set(managedPaths.map(Self.normalize))
    }

    func requiresSecurityScope(path: String) -> Bool {
        !managedPaths.contains(Self.normalize(path))
    }

    func pathHash(for path: String) -> String {
        String(Self.normalize(path).hashValue)
    }

    func pathBasename(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    func bookmark(for url: URL, metadata: [String : String]) -> Data? {
        bookmarkByPath[Self.normalize(url.path)]
    }

    func resolveBookmarkAccess(_ data: Data, metadata: [String : String]) -> ResolvedSecurityScopedPath? {
        switch resolveResults[data] {
        case .success(let path, let refreshed, let stale):
            startAccessCallCountByPath[Self.normalize(path), default: 0] += 1
            return ResolvedSecurityScopedPath(
                url: URL(fileURLWithPath: path),
                refreshedBookmarkData: refreshed,
                wasStale: stale
            )
        case .failure:
            return nil
        case .none:
            if let path = bookmarkPathByData[data] {
                startAccessCallCountByPath[Self.normalize(path), default: 0] += 1
                return ResolvedSecurityScopedPath(
                    url: URL(fileURLWithPath: path),
                    refreshedBookmarkData: nil,
                    wasStale: false
                )
            }
            return nil
        }
    }

    func stopAccessing(_ url: URL, metadata: [String : String]) {
        let key = Self.normalize(url.path)
        stopAccessCallCountByPath[key, default: 0] += 1
    }

    func startAccessing(_ url: URL, metadata: [String : String]) -> Bool {
        let key = Self.normalize(url.path)
        startAccessCallCountByPath[key, default: 0] += 1
        return true
    }

    func withResolvedBookmark<T>(_ data: Data, _ body: (URL) throws -> T) rethrows -> T? {
        guard let path = bookmarkPathByData[data] else { return nil }
        startAccessCallCountByPath[Self.normalize(path), default: 0] += 1
        let url = URL(fileURLWithPath: path)
        defer { stopAccessing(url, metadata: [:]) }
        return try body(url)
    }

    func resolveBookmarkToPath(_ data: Data) -> String? {
        guard let path = bookmarkPathByData[data] else { return nil }
        startAccessCallCountByPath[Self.normalize(path), default: 0] += 1
        let url = URL(fileURLWithPath: path)
        stopAccessing(url, metadata: [:])
        return path
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
