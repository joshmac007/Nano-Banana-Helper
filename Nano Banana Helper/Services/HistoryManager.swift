import Foundation

/// Manages history entries for completed image edits
@Observable
class HistoryManager {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let projectsDirectoryURL: URL
    private let bookmarkDependencies: AppPaths.BookmarkResolutionDependencies
    
    var entries: [HistoryEntry] = []
    var allGlobalEntries: [HistoryEntry] = []
    
    private func historyURL(for projectId: UUID) -> URL {
        projectsDirectoryURL
            .appendingPathComponent(projectId.uuidString)
            .appendingPathComponent("history.json")
    }
    
    init(
        projectsDirectoryURL: URL = AppPaths.projectsDirectoryURL,
        bookmarkDependencies: AppPaths.BookmarkResolutionDependencies = .live
    ) {
        self.projectsDirectoryURL = projectsDirectoryURL
        self.bookmarkDependencies = bookmarkDependencies
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }
    
    // MARK: - Load/Save
    
    func loadHistory(for projectId: UUID) {
        let url = historyURL(for: projectId)
        guard fileManager.fileExists(atPath: url.path) else {
            entries = []
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            entries = try decoder.decode([HistoryEntry].self, from: data)
            if refreshBookmarksIfNeeded(in: &entries) {
                saveHistory(for: projectId)
            }
        } catch {
            print("Failed to load history: \(error)")
            entries = []
        }
    }
    
    func loadGlobalHistory(allProjects: [Project]) {
        var allEntries: [HistoryEntry] = []
        
        for project in allProjects {
            let url = historyURL(for: project.id)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            
            do {
                let data = try Data(contentsOf: url)
                var projectEntries = try decoder.decode([HistoryEntry].self, from: data)
                if refreshBookmarksIfNeeded(in: &projectEntries) {
                    saveEntries(projectEntries, to: url)
                }
                allEntries.append(contentsOf: projectEntries)
            } catch {
                print("Failed to load history for project \(project.name): \(error)")
            }
        }
        
        // Sort globally by date (newest first)
        self.allGlobalEntries = allEntries.sorted(by: { $0.timestamp > $1.timestamp })
    }
    
    func saveHistory(for projectId: UUID) {
        let url = historyURL(for: projectId)
        
        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        saveEntries(entries, to: url)
    }
    
    // MARK: - Entry Management
    
    func addEntry(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)  // Most recent first in current view
        allGlobalEntries.insert(entry, at: 0) // Newest first in global
        allGlobalEntries.sort(by: { $0.timestamp > $1.timestamp })
        saveHistory(for: entry.projectId)
    }
    
    func deleteEntry(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        allGlobalEntries.removeAll { $0.id == entry.id }
        saveHistory(for: entry.projectId)
    }
    
    /// Updates an existing entry by matching externalJobName, or adds as new entry if not found
    func updateEntry(byExternalJobName jobName: String, with newEntry: HistoryEntry) {
        // Search current project's entries first (fast path)
        if let index = entries.firstIndex(where: { $0.externalJobName == jobName }) {
            entries[index] = newEntry
            // Also update allGlobalEntries
            if let globalIndex = allGlobalEntries.firstIndex(where: { $0.externalJobName == jobName }) {
                allGlobalEntries[globalIndex] = newEntry
            }
            saveHistory(for: newEntry.projectId)
            return
        }

        // The user may have switched projects while this job was polling.
        // Load the correct project's history file directly and update it there.
        let url = historyURL(for: newEntry.projectId)
        if fileManager.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           var projectEntries = try? decoder.decode([HistoryEntry].self, from: data),
           let index = projectEntries.firstIndex(where: { $0.externalJobName == jobName }) {
            projectEntries[index] = newEntry
            if let encoded = try? encoder.encode(projectEntries) {
                try? encoded.write(to: url)
            }
            // Keep allGlobalEntries in sync
            if let globalIndex = allGlobalEntries.firstIndex(where: { $0.externalJobName == jobName }) {
                allGlobalEntries[globalIndex] = newEntry
            }
            return
        }

        // Not found anywhere — add as a new entry
        addEntry(newEntry)
    }
    
    func clearHistory(for projectId: UUID) {
        entries.removeAll { $0.projectId == projectId }
        allGlobalEntries.removeAll { $0.projectId == projectId }
        saveHistory(for: projectId)
    }

    func updateBookmarks(
        for entryId: UUID,
        outputBookmark: Data?,
        sourceBookmarks: [Data]?
    ) {
        guard let projectId = projectID(for: entryId),
              var projectEntries = loadPersistedEntries(for: projectId),
              let index = projectEntries.firstIndex(where: { $0.id == entryId }) else {
            return
        }

        projectEntries[index].outputImageBookmark = outputBookmark
        projectEntries[index].sourceImageBookmarks = sourceBookmarks
        persistProjectEntries(projectEntries, for: projectId)
        syncCachedEntries(with: projectEntries, for: projectId)
    }

    func repairOutputBookmarksFromFolder(
        projectId: UUID,
        folderURL: URL,
        bookmarkCreator: (URL) -> Data? = AppPaths.bookmark(for:)
    ) {
        guard var projectEntries = loadPersistedEntries(for: projectId) else { return }

        var didRepair = false
        for index in projectEntries.indices {
            let outputURL = URL(fileURLWithPath: projectEntries[index].outputImagePath)
            guard outputURL.path.hasPrefix(folderURL.path),
                  fileManager.fileExists(atPath: outputURL.path),
                  let bookmark = bookmarkCreator(outputURL) else {
                continue
            }

            projectEntries[index].outputImageBookmark = bookmark
            didRepair = true
        }

        guard didRepair else { return }
        persistProjectEntries(projectEntries, for: projectId)
        syncCachedEntries(with: projectEntries, for: projectId)
    }

    func repairSourceBookmarksFromFolder(
        entryIds: Set<UUID>,
        folderURL: URL,
        bookmarkCreator: (URL) -> Data? = AppPaths.bookmark(for:)
    ) {
        guard !entryIds.isEmpty else { return }

        let groupedProjectIDs = Dictionary(
            grouping: allGlobalEntries.filter { entryIds.contains($0.id) },
            by: \.projectId
        )

        for (projectId, projectEntriesToRepair) in groupedProjectIDs {
            guard var persistedEntries = loadPersistedEntries(for: projectId) else { continue }
            let targetIDs = Set(projectEntriesToRepair.map(\.id))
            var didRepair = false

            for index in persistedEntries.indices where targetIDs.contains(persistedEntries[index].id) {
                let entry = persistedEntries[index]
                let repairedByIndex = repairedSourceBookmarksByIndex(
                    for: entry,
                    folderURL: folderURL,
                    bookmarkCreator: bookmarkCreator
                )
                guard !repairedByIndex.isEmpty else { continue }

                let updatedBookmarks: [Data]
                if let existingBookmarks = alignedSourceBookmarks(for: entry) {
                    var bookmarks = existingBookmarks
                    for (sourceIndex, bookmark) in repairedByIndex {
                        bookmarks[sourceIndex] = bookmark
                    }
                    updatedBookmarks = bookmarks
                } else {
                    guard repairedByIndex.count == entry.sourceImagePaths.count else { continue }
                    updatedBookmarks = entry.sourceImagePaths.indices.compactMap { repairedByIndex[$0] }
                    guard updatedBookmarks.count == entry.sourceImagePaths.count else { continue }
                }

                persistedEntries[index].sourceImageBookmarks = updatedBookmarks
                didRepair = true
            }

            guard didRepair else { continue }
            persistProjectEntries(persistedEntries, for: projectId)
            syncCachedEntries(with: persistedEntries, for: projectId)
        }
    }
    
    // MARK: - Filtering
    
    func entries(for projectId: UUID) -> [HistoryEntry] {
        entries.filter { $0.projectId == projectId }
    }
    
    func recentEntries(limit: Int = 20) -> [HistoryEntry] {
        Array(entries.prefix(limit))
    }
    
    // MARK: - Statistics
    
    func totalCost(for projectId: UUID) -> Double {
        entries(for: projectId).reduce(0) { $0 + $1.cost }
    }
    
    func imageCount(for projectId: UUID) -> Int {
        entries(for: projectId).count
    }

    private func saveEntries(_ entries: [HistoryEntry], to url: URL) {
        do {
            let data = try encoder.encode(entries)
            try data.write(to: url)
        } catch {
            print("Failed to save history: \(error)")
        }
    }

    private func loadPersistedEntries(for projectId: UUID) -> [HistoryEntry]? {
        let url = historyURL(for: projectId)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let projectEntries = try? decoder.decode([HistoryEntry].self, from: data) else {
            return nil
        }
        return projectEntries
    }

    private func persistProjectEntries(_ projectEntries: [HistoryEntry], for projectId: UUID) {
        let url = historyURL(for: projectId)
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        saveEntries(projectEntries, to: url)
    }

    private func syncCachedEntries(with projectEntries: [HistoryEntry], for projectId: UUID) {
        let updatedEntriesByID = Dictionary(uniqueKeysWithValues: projectEntries.map { ($0.id, $0) })

        for index in entries.indices {
            if let updatedEntry = updatedEntriesByID[entries[index].id] {
                entries[index] = updatedEntry
            }
        }

        for index in allGlobalEntries.indices {
            if let updatedEntry = updatedEntriesByID[allGlobalEntries[index].id] {
                allGlobalEntries[index] = updatedEntry
            }
        }

        allGlobalEntries.sort(by: { $0.timestamp > $1.timestamp })

        if !entries.isEmpty && entries.allSatisfy({ $0.projectId == projectId }) {
            entries = projectEntries
        }
    }

    private func projectID(for entryId: UUID) -> UUID? {
        if let entry = allGlobalEntries.first(where: { $0.id == entryId }) {
            return entry.projectId
        }
        if let entry = entries.first(where: { $0.id == entryId }) {
            return entry.projectId
        }
        return nil
    }

    private func alignedSourceBookmarks(for entry: HistoryEntry) -> [Data]? {
        guard let sourceBookmarks = entry.sourceImageBookmarks,
              sourceBookmarks.count == entry.sourceImagePaths.count else {
            return nil
        }
        return sourceBookmarks
    }

    private func repairedSourceBookmarksByIndex(
        for entry: HistoryEntry,
        folderURL: URL,
        bookmarkCreator: (URL) -> Data?
    ) -> [Int: Data] {
        var repairedByIndex: [Int: Data] = [:]

        for sourceIndex in entry.sourceImagePaths.indices {
            let sourceURL = URL(fileURLWithPath: entry.sourceImagePaths[sourceIndex])
            guard sourceURL.path.hasPrefix(folderURL.path),
                  fileManager.fileExists(atPath: sourceURL.path),
                  let bookmark = bookmarkCreator(sourceURL) else {
                continue
            }
            repairedByIndex[sourceIndex] = bookmark
        }

        return repairedByIndex
    }

    @discardableResult
    private func refreshBookmarksIfNeeded(in entries: inout [HistoryEntry]) -> Bool {
        var didRefresh = false

        for index in entries.indices {
            if let sourceBookmarks = entries[index].sourceImageBookmarks {
                var updatedBookmarks = sourceBookmarks

                for bookmarkIndex in sourceBookmarks.indices {
                    guard let resolution = AppPaths.resolveBookmarkToPath(
                        sourceBookmarks[bookmarkIndex],
                        dependencies: bookmarkDependencies
                    ),
                    let refreshedBookmark = resolution.refreshedBookmarkData else {
                        continue
                    }

                    updatedBookmarks[bookmarkIndex] = refreshedBookmark
                    didRefresh = true
                }

                if updatedBookmarks != sourceBookmarks {
                    entries[index].sourceImageBookmarks = updatedBookmarks
                }
            }

            if let outputBookmark = entries[index].outputImageBookmark,
               let resolution = AppPaths.resolveBookmarkToPath(
                outputBookmark,
                dependencies: bookmarkDependencies
               ),
               let refreshedBookmark = resolution.refreshedBookmarkData {
                entries[index].outputImageBookmark = refreshedBookmark
                didRefresh = true
            }
        }

        return didRefresh
    }
}
