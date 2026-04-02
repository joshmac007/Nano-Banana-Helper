import Foundation

/// Manages project creation, listing, and persistence
@Observable
class ProjectManager {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let appSupportURL: URL
    private let projectsListURL: URL
    private let costSummaryURL: URL
    private let projectsDirectoryURL: URL
    private let bookmarkDependencies: AppPaths.BookmarkResolutionDependencies
    
    var projects: [Project] = []
    var currentProject: Project?
    var costSummary = CostSummary()
    var sessionCost: Double = 0
    var sessionTokens: Int = 0
    var sessionImageCount: Int = 0
    
    init(
        appSupportURL: URL = AppPaths.appSupportURL,
        projectsListURL: URL = AppPaths.projectsURL,
        costSummaryURL: URL = AppPaths.costSummaryURL,
        projectsDirectoryURL: URL = AppPaths.projectsDirectoryURL,
        bookmarkDependencies: AppPaths.BookmarkResolutionDependencies = .live
    ) {
        self.appSupportURL = appSupportURL
        self.projectsListURL = projectsListURL
        self.costSummaryURL = costSummaryURL
        self.projectsDirectoryURL = projectsDirectoryURL
        self.bookmarkDependencies = bookmarkDependencies
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        
        AppPaths.migrateIfNeeded() // Move data from old NanoBananaPro folder if needed
        ensureDirectoriesExist()
        loadProjects()
        loadCostSummary()
        
        // Create default project if none exist
        if projects.isEmpty {
            let defaultProject = Project(
                name: "Default Project",
                outputDirectory: fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
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
    
    func createProject(name: String, outputDirectory: String) -> Project {
        let project = Project(name: name, outputDirectory: outputDirectory)
        projects.append(project)
        
        // Create project directory
        let projectDir = projectDirectory(for: project)
        try? fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        
        // Create output directory if needed
        try? fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        
        saveProjects()
        saveProjectMetadata(project)
        
        return project
    }
    
    func deleteProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        
        // Remove project directory
        let projectDir = projectDirectory(for: project)
        try? fileManager.removeItem(at: projectDir)
        
        // Update current project if deleted
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
    
    private func loadCostSummary() {
        guard fileManager.fileExists(atPath: costSummaryURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: costSummaryURL)
            costSummary = try decoder.decode(CostSummary.self, from: data)
        } catch {
            print("Failed to load cost summary: \(error)")
        }
    }
    
    func saveCostSummary() {
        do {
            let data = try encoder.encode(costSummary)
            try data.write(to: costSummaryURL)
        } catch {
            print("Failed to save cost summary: \(error)")
        }
    }
    
    // MARK: - Cost Tracking
    
    func recordCost(_ cost: Double, resolution: String, for project: Project) {
        project.totalCost += cost
        project.imageCount += 1
        costSummary.record(cost: cost, resolution: resolution, projectId: project.id)
        
        saveProjects()
        saveCostSummary()
    }
    
    func rebuildCostSummary(from entries: [HistoryEntry]) {
        // Reset summary
        costSummary = CostSummary()

        // Re-accumulate from all history
        for entry in entries {
            costSummary.record(cost: entry.cost, resolution: entry.imageSize, projectId: entry.projectId, tokens: entry.tokenUsage, modelName: entry.modelName)
        }

        saveCostSummary()
    }

    func recordSessionUsage(cost: Double, tokens: TokenUsage?) {
        sessionCost += cost
        sessionTokens += (tokens?.totalTokenCount ?? 0)
        sessionImageCount += 1
    }

    func recordCostIncurred(
        cost: Double,
        resolution: String,
        projectId: UUID,
        tokenUsage: TokenUsage?,
        modelName: String?
    ) {
        costSummary.record(
            cost: cost,
            resolution: resolution,
            projectId: projectId,
            tokens: tokenUsage,
            modelName: modelName
        )
        recordSessionUsage(cost: cost, tokens: tokenUsage)
        saveCostSummary()
    }
    
    // MARK: - Export
    
    func exportCostReportCSV(entries: [HistoryEntry] = []) -> URL? {
        var csv = "Date,Project,Prompt,Resolution,Tier,Model,Cost,InputTokens,OutputTokens,Status\n"
        
        if entries.isEmpty {
            // Fallback: summary rows only (no history entries provided)
            csv += "Summary,All Projects,All Resolutions,All Tiers,\(costSummary.totalSpent),\n"
            for (resolution, cost) in costSummary.byResolution.sorted(by: { $0.key < $1.key }) {
                csv += "Summary,All Projects,All Resolutions,\(resolution),,\(cost),\n"
            }
            for (projectId, cost) in costSummary.byProject {
                let projectName = projects.first { $0.id.uuidString == projectId }?.name ?? "Unknown"
                csv += "Summary,\(projectName),All Resolutions,All Tiers,,\(cost),\n"
            }
        } else {
            // Per-image detail rows
            let sorted = entries.sorted(by: { $0.timestamp < $1.timestamp })
            for entry in sorted {
                let project = projects.first { $0.id == entry.projectId }?.name ?? "Unknown"
                // Sanitize prompt: truncate, remove commas and newlines
                let prompt = entry.prompt
                    .prefix(60)
                    .replacingOccurrences(of: ",", with: ";")
                    .replacingOccurrences(of: "\n", with: " ")
                let tier = entry.usedBatchTier ? "Batch" : "Standard"
                let date = entry.timestamp.ISO8601Format()
                let model = entry.modelName ?? "unknown"
                let inTokens = entry.tokenUsage?.promptTokenCount ?? 0
                let outTokens = entry.tokenUsage?.candidatesTokenCount ?? 0
                csv += "\(date),\(project),\(prompt),\(entry.imageSize),\(tier),\(model),\(entry.cost),\(inTokens),\(outTokens),\(entry.status)\n"
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
