import Foundation

struct ResolvedSecurityScopedPath {
    let url: URL
    let refreshedBookmarkData: Data?
    let wasStale: Bool
}

protocol SecurityScopedPathing {
    var launchID: String { get }

    func requiresSecurityScope(path: String) -> Bool
    func pathHash(for path: String) -> String
    func pathBasename(for path: String) -> String

    func bookmark(for url: URL, metadata: [String: String]) -> Data?
    func resolveBookmarkAccess(_ data: Data, metadata: [String: String]) -> ResolvedSecurityScopedPath?
    func startAccessing(_ url: URL, metadata: [String: String]) -> Bool
    func stopAccessing(_ url: URL, metadata: [String: String])
    func withResolvedBookmark<T>(_ data: Data, _ body: (URL) throws -> T) rethrows -> T?
    func resolveBookmarkToPath(_ data: Data) -> String?
}

struct LiveSecurityScopedPathing: SecurityScopedPathing {
    var launchID: String { AppPaths.launchID }

    func requiresSecurityScope(path: String) -> Bool {
        AppPaths.requiresSecurityScope(path: path)
    }

    func pathHash(for path: String) -> String {
        AppPaths.pathHash(for: path)
    }

    func pathBasename(for path: String) -> String {
        AppPaths.pathBasename(for: path)
    }

    func bookmark(for url: URL, metadata: [String: String]) -> Data? {
        AppPaths.bookmark(for: url, metadata: metadata)
    }

    func resolveBookmarkAccess(_ data: Data, metadata: [String: String]) -> ResolvedSecurityScopedPath? {
        guard let resolved = AppPaths.resolveBookmarkAccess(data, metadata: metadata) else {
            return nil
        }
        return ResolvedSecurityScopedPath(
            url: resolved.url,
            refreshedBookmarkData: resolved.refreshedBookmarkData,
            wasStale: resolved.wasStale
        )
    }

    func stopAccessing(_ url: URL, metadata: [String: String]) {
        AppPaths.stopAccessingSecurityScope(url: url, metadata: metadata)
    }

    func startAccessing(_ url: URL, metadata: [String: String]) -> Bool {
        AppPaths.startAccessingSecurityScope(url: url, metadata: metadata)
    }

    func withResolvedBookmark<T>(_ data: Data, _ body: (URL) throws -> T) rethrows -> T? {
        try AppPaths.withResolvedBookmark(data, body)
    }

    func resolveBookmarkToPath(_ data: Data) -> String? {
        AppPaths.resolveBookmarkToPath(data)
    }
}

enum SecurityScopedInputResolutionError: Error, Equatable {
    case missingBookmark(path: String)
    case bookmarkAccessFailed(path: String)
}

struct SecurityScopedInputResolution {
    let inputURLs: [URL]
    let scopedInputIndices: Set<Int>
    let bookmarkIndexByInputIndex: [Int: Int]
    let staleByInputIndex: [Int: Bool]
    let refreshedBookmarkByIndex: [Int: Data]

    func applyingRefreshes(to bookmarks: [Data]) -> [Data] {
        guard !refreshedBookmarkByIndex.isEmpty else { return bookmarks }
        var updated = bookmarks
        for (bookmarkIndex, refreshedData) in refreshedBookmarkByIndex where updated.indices.contains(bookmarkIndex) {
            updated[bookmarkIndex] = refreshedData
        }
        return updated
    }
}

enum SecurityScopedInputResolver {
    static func resolve(
        inputPaths: [String],
        inputBookmarks: [Data]?,
        pathing: any SecurityScopedPathing,
        metadataForBookmark: (Int, String) -> [String: String] = { _, _ in [:] }
    ) -> Result<SecurityScopedInputResolution, SecurityScopedInputResolutionError> {
        let requiredInputIndices = inputPaths.indices.filter { index in
            pathing.requiresSecurityScope(path: inputPaths[index])
        }

        let plainInputURLs = inputPaths.map { URL(fileURLWithPath: $0) }
        guard !requiredInputIndices.isEmpty else {
            return .success(
                SecurityScopedInputResolution(
                    inputURLs: plainInputURLs,
                    scopedInputIndices: [],
                    bookmarkIndexByInputIndex: [:],
                    staleByInputIndex: [:],
                    refreshedBookmarkByIndex: [:]
                )
            )
        }

        guard let bookmarks = inputBookmarks, !bookmarks.isEmpty else {
            let missingPath = inputPaths[requiredInputIndices[0]]
            return .failure(.missingBookmark(path: missingPath))
        }

        let normalizedInputPaths = inputPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var mutableInputURLs = plainInputURLs
        var scopedInputIndices = Set<Int>()
        var bookmarkIndexByInputIndex: [Int: Int] = [:]
        var staleByInputIndex: [Int: Bool] = [:]
        var refreshedBookmarkByIndex: [Int: Data] = [:]
        var activeScopedURLs: [URL] = []

        for (bookmarkIndex, bookmarkData) in bookmarks.enumerated() {
            let expectedPath = inputPaths.indices.contains(bookmarkIndex) ? inputPaths[bookmarkIndex] : ""
            let metadata = metadataForBookmark(bookmarkIndex, expectedPath)

            guard let resolved = pathing.resolveBookmarkAccess(bookmarkData, metadata: metadata) else {
                if inputPaths.indices.contains(bookmarkIndex),
                   pathing.requiresSecurityScope(path: inputPaths[bookmarkIndex]) {
                    stopScopedAccess(urls: activeScopedURLs, pathing: pathing)
                    return .failure(.bookmarkAccessFailed(path: inputPaths[bookmarkIndex]))
                }
                continue
            }

            let normalizedResolvedPath = resolved.url.standardizedFileURL.path
            var matchedRequiredIndices = normalizedInputPaths.indices.filter { index in
                normalizedInputPaths[index] == normalizedResolvedPath &&
                pathing.requiresSecurityScope(path: inputPaths[index])
            }

            // Backward-compatibility fallback for old index-aligned bookmark arrays.
            if matchedRequiredIndices.isEmpty,
               inputPaths.indices.contains(bookmarkIndex),
               pathing.requiresSecurityScope(path: inputPaths[bookmarkIndex]) {
                matchedRequiredIndices = [bookmarkIndex]
            }

            guard !matchedRequiredIndices.isEmpty else {
                pathing.stopAccessing(resolved.url, metadata: metadata)
                continue
            }

            activeScopedURLs.append(resolved.url)
            if let refreshedData = resolved.refreshedBookmarkData {
                refreshedBookmarkByIndex[bookmarkIndex] = refreshedData
            }

            for inputIndex in matchedRequiredIndices {
                mutableInputURLs[inputIndex] = resolved.url
                scopedInputIndices.insert(inputIndex)
                bookmarkIndexByInputIndex[inputIndex] = bookmarkIndex
                staleByInputIndex[inputIndex] = resolved.wasStale
            }
        }

        for inputIndex in requiredInputIndices where scopedInputIndices.contains(inputIndex) == false {
            stopScopedAccess(urls: activeScopedURLs, pathing: pathing)
            return .failure(.missingBookmark(path: inputPaths[inputIndex]))
        }

        return .success(
            SecurityScopedInputResolution(
                inputURLs: mutableInputURLs,
                scopedInputIndices: scopedInputIndices,
                bookmarkIndexByInputIndex: bookmarkIndexByInputIndex,
                staleByInputIndex: staleByInputIndex,
                refreshedBookmarkByIndex: refreshedBookmarkByIndex
            )
        )
    }

    private static func stopScopedAccess(urls: [URL], pathing: any SecurityScopedPathing) {
        var stopped = Set<String>()
        for url in urls {
            let normalized = url.standardizedFileURL.path
            guard stopped.insert(normalized).inserted else { continue }
            pathing.stopAccessing(url, metadata: [:])
        }
    }
}
