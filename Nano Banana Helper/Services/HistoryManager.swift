import Foundation

/// Manages history entries for completed image edits
@Observable
class HistoryManager {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    var entries: [HistoryEntry] = []
    var allGlobalEntries: [HistoryEntry] = []
    
    private var appSupportURL: URL { AppPaths.appSupportURL }
    
    private func historyURL(for projectId: UUID) -> URL {
        AppPaths.projectsDirectoryURL
            .appendingPathComponent(projectId.uuidString)
            .appendingPathComponent("history.json")
    }
    
    init() {
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
                let projectEntries = try decoder.decode([HistoryEntry].self, from: data)
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
        
        do {
            let data = try encoder.encode(entries)
            try data.write(to: url)
        } catch {
            print("Failed to save history: \(error)")
        }
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
        if let index = entries.firstIndex(where: { $0.externalJobName == jobName }) {
            entries[index] = newEntry
            saveHistory(for: newEntry.projectId)
        } else {
            addEntry(newEntry)
        }
    }
    
    func clearHistory(for projectId: UUID) {
        entries.removeAll { $0.projectId == projectId }
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
}
