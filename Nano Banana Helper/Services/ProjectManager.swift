import Foundation

struct ProjectUsageBreakdown: Identifiable, Hashable {
    let id: String
    let projectId: UUID?
    let name: String
    let cost: Double
    let imageCount: Int
}

/// Manages project creation, listing, usage accounting, and persistence.
@Observable
class ProjectManager {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let appSupportURL: URL
    private let projectsListURL: URL
    private let costSummaryURL: URL
    private let usageLedgerURL: URL
    private let projectsDirectoryURL: URL
    private let bookmarkDependencies: AppPaths.BookmarkResolutionDependencies

    var projects: [Project] = []
    var currentProject: Project?
    var costSummary = CostSummary()
    var ledger: [UsageLedgerEntry] = []
    var sessionCost: Double = 0
    var sessionTokens: Int = 0
    var sessionImageCount: Int = 0

    init(
        appSupportURL: URL = AppPaths.appSupportURL,
        projectsListURL: URL = AppPaths.projectsURL,
        costSummaryURL: URL = AppPaths.costSummaryURL,
        usageLedgerURL: URL? = nil,
        projectsDirectoryURL: URL = AppPaths.projectsDirectoryURL,
        bookmarkDependencies: AppPaths.BookmarkResolutionDependencies = .live
    ) {
        self.appSupportURL = appSupportURL
        self.projectsListURL = projectsListURL
        self.costSummaryURL = costSummaryURL
        self.usageLedgerURL = usageLedgerURL ?? appSupportURL.appendingPathComponent("usage_ledger.json")
        self.projectsDirectoryURL = projectsDirectoryURL
        self.bookmarkDependencies = bookmarkDependencies
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        AppPaths.migrateIfNeeded()
        ensureDirectoriesExist()
        loadProjects()
        loadOrMigrateLedger()
        deriveSummaryAndProjectTotals()

        if projects.isEmpty {
            let defaultProject = Project(
                name: "Default Project",
                outputDirectory: AppPaths.defaultOutputDirectory.path
            )
            projects.append(defaultProject)
            currentProject = defaultProject
            saveProjects()
        } else {
            currentProject = projects.first
        }
    }

    // MARK: - Directory Management

    private func ensureDirectoriesExist() {
        try? fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: projectsDirectoryURL, withIntermediateDirectories: true)
    }

    private func projectDirectory(for project: Project) -> URL {
        projectsDirectoryURL.appendingPathComponent(project.id.uuidString)
    }

    // MARK: - Project CRUD

    func createProject(name: String, outputURL: URL, outputDirectoryBookmark: Data?) -> Project {
        let project = Project(
            name: name,
            outputDirectory: outputURL.path,
            outputDirectoryBookmark: outputDirectoryBookmark
        )
        projects.append(project)

        let projectDir = projectDirectory(for: project)
        try? fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

        saveProjects()
        saveProjectMetadata(project)

        return project
    }

    func createProject(name: String, outputDirectory: String) -> Project {
        createProject(
            name: name,
            outputURL: URL(fileURLWithPath: outputDirectory),
            outputDirectoryBookmark: nil
        )
    }

    func deleteProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }

        let projectDir = projectDirectory(for: project)
        try? fileManager.removeItem(at: projectDir)

        if currentProject?.id == project.id {
            currentProject = projects.first
        }

        saveProjects()
    }

    func selectProject(_ project: Project) {
        currentProject = project
    }

    func renameProject(_ project: Project, to newName: String) {
        project.name = newName
        saveProjects()
        saveProjectMetadata(project)
    }

    func archiveProject(_ project: Project) {
        project.isArchived = true
        saveProjects()
        saveProjectMetadata(project)
    }

    func unarchiveProject(_ project: Project) {
        project.isArchived = false
        saveProjects()
        saveProjectMetadata(project)
    }

    func updateProjectPresets(project: Project, prompt: String, aspectRatio: String, imageSize: String, useBatchTier: Bool) {
        project.defaultPrompt = prompt
        project.defaultAspectRatio = aspectRatio
        project.defaultImageSize = imageSize
        project.defaultUseBatchTier = useBatchTier
        saveProjects()
        saveProjectMetadata(project)
    }

    func refreshOutputBookmark(_ bookmark: Data, for projectId: UUID) {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        project.outputDirectoryBookmark = bookmark
        saveProjects()
        saveProjectMetadata(project)
    }

    // MARK: - Persistence

    private func loadProjects() {
        guard fileManager.fileExists(atPath: projectsListURL.path) else { return }

        do {
            let data = try Data(contentsOf: projectsListURL)
            projects = try decoder.decode([Project].self, from: data)
            if refreshProjectBookmarksIfNeeded() {
                saveProjects()
                for project in projects {
                    saveProjectMetadata(project)
                }
            }
        } catch {
            print("Failed to load projects: \(error)")
        }
    }

    func saveProjects() {
        do {
            let data = try encoder.encode(projects)
            try data.write(to: projectsListURL)
        } catch {
            print("Failed to save projects: \(error)")
        }
    }

    private func saveProjectMetadata(_ project: Project) {
        let projectDir = projectDirectory(for: project)
        let metadataURL = projectDir.appendingPathComponent("project.json")

        do {
            let data = try encoder.encode(project)
            try data.write(to: metadataURL)
        } catch {
            print("Failed to save project metadata: \(error)")
        }
    }

    private func loadOrMigrateLedger() {
        if fileManager.fileExists(atPath: usageLedgerURL.path) {
            do {
                let data = try Data(contentsOf: usageLedgerURL)
                ledger = try decoder.decode([UsageLedgerEntry].self, from: data)
            } catch {
                print("Failed to load usage ledger: \(error)")
                ledger = []
            }
            return
        }

        ledger = migrateLegacyLedger()
        persistLedger()
    }

    private func migrateLegacyLedger() -> [UsageLedgerEntry] {
        if let legacySummary = loadLegacyCostSummary(),
           legacySummary.totalSpent > 0 {
            return [
                UsageLedgerEntry(
                    kind: .legacyImport,
                    projectId: nil,
                    projectNameSnapshot: nil,
                    costDelta: legacySummary.totalSpent,
                    imageDelta: legacySummary.imageCount,
                    tokenDelta: legacySummary.totalTokens,
                    inputTokenDelta: legacySummary.inputTokens,
                    outputTokenDelta: legacySummary.outputTokens,
                    resolution: nil,
                    modelName: nil,
                    relatedHistoryEntryId: nil,
                    note: "Imported legacy usage totals"
                )
            ]
        }

        var migratedEntries: [UsageLedgerEntry] = []
        for project in projects {
            for entry in loadHistoryEntries(for: project.id) where entry.status == "completed" {
                let tokenUsage = entry.tokenUsage
                migratedEntries.append(
                    UsageLedgerEntry(
                        timestamp: entry.timestamp,
                        kind: .jobCompletion,
                        projectId: entry.projectId,
                        projectNameSnapshot: project.name,
                        costDelta: entry.cost,
                        imageDelta: 1,
                        tokenDelta: tokenUsage?.totalTokenCount ?? 0,
                        inputTokenDelta: tokenUsage?.promptTokenCount ?? 0,
                        outputTokenDelta: tokenUsage?.candidatesTokenCount ?? 0,
                        resolution: entry.imageSize,
                        modelName: entry.modelName,
                        relatedHistoryEntryId: entry.id,
                        note: nil
                    )
                )
            }
        }
        return migratedEntries.sorted(by: { $0.timestamp < $1.timestamp })
    }

    private func loadLegacyCostSummary() -> CostSummary? {
        guard fileManager.fileExists(atPath: costSummaryURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: costSummaryURL)
            return try decoder.decode(CostSummary.self, from: data)
        } catch {
            print("Failed to load legacy cost summary: \(error)")
            return nil
        }
    }

    private func loadHistoryEntries(for projectId: UUID) -> [HistoryEntry] {
        let url = projectsDirectoryURL
            .appendingPathComponent(projectId.uuidString)
            .appendingPathComponent("history.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            print("Failed to load history for ledger migration: \(error)")
            return []
        }
    }

    private func persistLedger() {
        do {
            let data = try encoder.encode(ledger)
            try data.write(to: usageLedgerURL)
        } catch {
            print("Failed to save usage ledger: \(error)")
        }
    }

    // MARK: - Usage Ledger

    func appendLedgerEntry(_ entry: UsageLedgerEntry) {
        ledger.append(entry)
        ledger.sort(by: { $0.timestamp < $1.timestamp })
        persistLedger()
        deriveSummaryAndProjectTotals()
        saveProjects()
    }

    func deriveSummaryAndProjectTotals() {
        costSummary = CostSummary()

        var projectIndexById: [UUID: Int] = [:]
        for index in projects.indices {
            projects[index].totalCost = 0
            projects[index].imageCount = 0
            projectIndexById[projects[index].id] = index
        }

        for entry in ledger {
            costSummary.totalSpent += entry.costDelta
            costSummary.imageCount += entry.imageDelta
            costSummary.totalTokens += entry.tokenDelta
            costSummary.inputTokens += entry.inputTokenDelta
            costSummary.outputTokens += entry.outputTokenDelta

            if let resolution = entry.resolution {
                costSummary.byResolution[resolution, default: 0] += entry.costDelta
            }
            if let modelName = entry.modelName {
                costSummary.byModel[modelName, default: 0] += entry.costDelta
            }
            if let projectId = entry.projectId {
                costSummary.byProject[projectId.uuidString, default: 0] += entry.costDelta
                if let index = projectIndexById[projectId] {
                    projects[index].totalCost += entry.costDelta
                    projects[index].imageCount += entry.imageDelta
                }
            }
        }
    }

    var projectUsageBreakdowns: [ProjectUsageBreakdown] {
        struct Aggregate {
            var projectId: UUID?
            var name: String
            var cost: Double
            var imageCount: Int
        }

        var aggregates: [String: Aggregate] = [:]
        for entry in ledger {
            guard entry.projectId != nil || entry.projectNameSnapshot != nil else { continue }
            let key = entry.projectId?.uuidString ?? "snapshot:\(entry.projectNameSnapshot ?? "deleted")"
            let currentName = projectDisplayName(for: entry.projectId, projectNameSnapshot: entry.projectNameSnapshot)
            if var aggregate = aggregates[key] {
                aggregate.cost += entry.costDelta
                aggregate.imageCount += entry.imageDelta
                aggregate.name = currentName
                aggregates[key] = aggregate
            } else {
                aggregates[key] = Aggregate(
                    projectId: entry.projectId,
                    name: currentName,
                    cost: entry.costDelta,
                    imageCount: entry.imageDelta
                )
            }
        }

        return aggregates.map { key, aggregate in
            ProjectUsageBreakdown(
                id: key,
                projectId: aggregate.projectId,
                name: aggregate.name,
                cost: aggregate.cost,
                imageCount: aggregate.imageCount
            )
        }
        .filter { $0.cost != 0 || $0.imageCount != 0 }
        .sorted { lhs, rhs in
            if lhs.cost == rhs.cost {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.cost > rhs.cost
        }
    }

    func projectDisplayName(for projectId: UUID?, projectNameSnapshot: String?) -> String {
        if let projectId,
           let liveProject = projects.first(where: { $0.id == projectId }) {
            return liveProject.name
        }
        return projectNameSnapshot ?? "Deleted Project"
    }

    // MARK: - Session Tracking

    func recordSessionUsage(cost: Double, tokens: TokenUsage?) {
        sessionCost += cost
        sessionTokens += (tokens?.totalTokenCount ?? 0)
        sessionImageCount += 1
    }

    // MARK: - Export

    func exportCostReportCSV(entries: [UsageLedgerEntry] = []) -> URL? {
        var csv = "Date,Project,Kind,Resolution,Model,Cost,Images,InputTokens,OutputTokens,Note\n"

        if entries.isEmpty {
            csv += "Summary,All Projects,Total,,,\(costSummary.totalSpent),\(costSummary.imageCount),\(costSummary.inputTokens),\(costSummary.outputTokens),\n"
            for (resolution, cost) in costSummary.byResolution.sorted(by: { $0.key < $1.key }) {
                csv += "Summary,All Projects,Resolution,\(resolution),,\(cost),0,0,0,\n"
            }
            for breakdown in projectUsageBreakdowns {
                csv += "Summary,\(sanitizeCSV(breakdown.name)),Project,,,\(breakdown.cost),\(breakdown.imageCount),0,0,\n"
            }
        } else {
            let sorted = entries.sorted(by: { $0.timestamp < $1.timestamp })
            for entry in sorted {
                let projectName = projectDisplayName(for: entry.projectId, projectNameSnapshot: entry.projectNameSnapshot)
                let note = sanitizeCSV(entry.note ?? "")
                csv += "\(entry.timestamp.ISO8601Format()),\(sanitizeCSV(projectName)),\(entry.kind.rawValue),\(entry.resolution ?? ""),\(entry.modelName ?? ""),\(entry.costDelta),\(entry.imageDelta),\(entry.inputTokenDelta),\(entry.outputTokenDelta),\(note)\n"
            }
        }

        let exportURL = appSupportURL.appendingPathComponent("cost_report_\(Date().ISO8601Format()).csv")

        do {
            try csv.write(to: exportURL, atomically: true, encoding: .utf8)
            return exportURL
        } catch {
            print("Failed to export CSV: \(error)")
            return nil
        }
    }

    private func sanitizeCSV(_ value: String) -> String {
        value
            .prefix(120)
            .replacingOccurrences(of: ",", with: ";")
            .replacingOccurrences(of: "\n", with: " ")
    }

    @discardableResult
    private func refreshProjectBookmarksIfNeeded() -> Bool {
        var didRefresh = false

        for project in projects {
            guard let bookmark = project.outputDirectoryBookmark,
                  let resolution = AppPaths.resolveBookmarkToPath(
                    bookmark,
                    dependencies: bookmarkDependencies
                  ),
                  let refreshedBookmark = resolution.refreshedBookmarkData else {
                continue
            }

            project.outputDirectoryBookmark = refreshedBookmark
            didRefresh = true
        }

        return didRefresh
    }
}
