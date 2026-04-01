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
