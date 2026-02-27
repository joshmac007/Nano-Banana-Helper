import Foundation

/// Manages project creation, listing, and persistence
@Observable
class ProjectManager {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    var projects: [Project] = []
    var currentProject: Project?
    var costSummary = CostSummary()
    
    private var appSupportURL: URL { AppPaths.appSupportURL }
    private var projectsListURL: URL { AppPaths.projectsURL }
    private var costSummaryURL: URL { AppPaths.costSummaryURL }
    
    init() {
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
        try? fileManager.createDirectory(at: appSupportURL.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }
    
    private func projectDirectory(for project: Project) -> URL {
        AppPaths.projectsDirectoryURL.appendingPathComponent(project.id.uuidString)
    }
    
    // MARK: - Project CRUD
    
    func createProject(name: String, outputDirectory: String, outputDirectoryBookmark: Data? = nil) -> Project {
        let project = Project(
            name: name,
            outputDirectory: outputDirectory,
            outputDirectoryBookmark: outputDirectoryBookmark
        )
        DebugLog.info("project", "Creating project", metadata: [
            "project_id": project.id.uuidString,
            "name": name,
            "output_directory": outputDirectory,
            "has_output_bookmark": String(outputDirectoryBookmark != nil)
        ])
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

    func refreshOutputDirectoryBookmark(projectId: UUID, bookmark: Data) {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        guard project.outputDirectoryBookmark != bookmark else { return }
        project.outputDirectoryBookmark = bookmark
        DebugLog.info("project", "Persisted refreshed output bookmark", metadata: [
            "project_id": projectId.uuidString,
            "output_directory": project.outputDirectory
        ])
        saveProjects()
        saveProjectMetadata(project)
    }

    
    // MARK: - Persistence
    
    private func loadProjects() {
        guard fileManager.fileExists(atPath: projectsListURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: projectsListURL)
            if let decoded = tryDecodeProjects(data: data) {
                projects = decoded.projects
                DebugLog.info("project.persistence", "Loaded projects list", metadata: [
                    "count": String(projects.count),
                    "bytes": String(data.count),
                    "decode_mode": decoded.mode,
                    "projects_with_output_bookmark": String(projects.filter { $0.outputDirectoryBookmark != nil }.count)
                ])
            } else {
                DebugLog.error("project.persistence", "Failed to decode projects list", metadata: [
                    "bytes": String(data.count)
                ])
            }
        } catch {
            DebugLog.error("project.persistence", "Failed to load projects list", metadata: [
                "error": String(describing: error)
            ])
            print("Failed to load projects: \(error)")
        }
    }
    
    func saveProjects() {
        do {
            let data = try encoder.encode(projects)
            try data.write(to: projectsListURL, options: .atomic)
            DebugLog.debug("project.persistence", "Saved projects list", metadata: [
                "count": String(projects.count),
                "bytes": String(data.count),
                "projects_with_output_bookmark": String(projects.filter { $0.outputDirectoryBookmark != nil }.count)
            ])
        } catch {
            DebugLog.error("project.persistence", "Failed to save projects list", metadata: [
                "error": String(describing: error)
            ])
            print("Failed to save projects: \(error)")
        }
    }

    private func tryDecodeProjects(data: Data) -> (projects: [Project], mode: String)? {
        if let projects = try? decoder.decode([Project].self, from: data) {
            return (projects, "array_iso8601")
        }

        // Backward compatibility for older saves that used the default Date strategy.
        let legacyDecoder = JSONDecoder()
        if let projects = try? legacyDecoder.decode([Project].self, from: data) {
            return (projects, "array_legacy_default")
        }

        return nil
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
            costSummary.record(cost: entry.cost, resolution: entry.imageSize, projectId: entry.projectId)
        }
        
        saveCostSummary()
    }
    
    // MARK: - Export
    
    func exportCostReportCSV(entries: [HistoryEntry] = []) -> URL? {
        var csv = "Date,Project,Prompt,Resolution,Tier,Cost,Status\n"
        
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
                csv += "\(date),\(project),\(prompt),\(entry.imageSize),\(tier),\(entry.cost),\(entry.status)\n"
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
}
