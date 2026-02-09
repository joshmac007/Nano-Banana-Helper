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
            costSummary.record(cost: entry.cost, resolution: entry.imageSize, projectId: entry.projectId)
        }
        
        saveCostSummary()
    }
    
    // MARK: - Export
    
    func exportCostReportCSV() -> URL? {
        var csv = "Date,Project,Resolution,Cost\n"
        
        // We'd need history entries for full detail
        // For now, export summary
        csv += "Summary,All Projects,All Resolutions,\(costSummary.totalSpent)\n"
        
        for (resolution, cost) in costSummary.byResolution.sorted(by: { $0.key < $1.key }) {
            csv += "Summary,All Projects,\(resolution),\(cost)\n"
        }
        
        for (projectId, cost) in costSummary.byProject {
            let projectName = projects.first { $0.id.uuidString == projectId }?.name ?? "Unknown"
            csv += "Summary,\(projectName),All Resolutions,\(cost)\n"
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
