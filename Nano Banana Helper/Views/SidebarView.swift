import SwiftUI

struct SidebarView: View {
    @Bindable var projectManager: ProjectManager
    var onSelectProject: ((Project) -> Void)?
    var onOpenSettings: (() -> Void)?
    
    @State private var showingNewProject = false
    @State private var showingCostReport = false
    @State private var newProjectName = ""
    @State private var newProjectDirectory = ""
    @State private var newProjectDirectoryBookmark: Data?
    
    // MARK: - Rename State
    @State private var projectToRename: Project?
    @State private var renameText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Projects")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showingNewProject = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding()
            
            // Project List replacement
            List(selection: Binding(
                get: { projectManager.currentProject?.id },
                set: { id in
                    if let id, let project = projectManager.projects.first(where: { $0.id == id }) {
                        projectManager.selectProject(project)
                        onSelectProject?(project)
                    }
                }
            )) {
                Section("Active") {
                    ForEach(projectManager.projects.filter { !$0.isArchived }) { project in
                        NavigationLink(value: project.id) {
                            HStack {
                                Image(systemName: "folder.fill")
                                Text(project.name)
                            }
                        }
                        .contextMenu {
                            Button("Rename...") {
                                renameText = project.name
                                projectToRename = project
                            }
                            Button("Open Output Folder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.outputDirectory)
                            }
                            Divider()
                            Button("Delete Project", role: .destructive) {
                                projectManager.deleteProject(project)
                            }
                            .disabled(projectManager.projects.count <= 1)
                        }
                    }
                }
                
                if projectManager.projects.contains(where: { $0.isArchived }) {
                    Section("Archive") {
                        ForEach(projectManager.projects.filter { $0.isArchived }) { project in
                            NavigationLink(value: project.id) {
                                HStack {
                                    Image(systemName: "archivebox")
                                        .foregroundStyle(.secondary)
                                    Text(project.name)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu {
                                Button("Rename...") {
                                    renameText = project.name
                                    projectToRename = project
                                }
                                Button("Unarchive") {
                                    projectManager.unarchiveProject(project)
                                }
                                Divider()
                                Button("Delete Project", role: .destructive) {
                                    projectManager.deleteProject(project)
                                }
                                .disabled(projectManager.projects.count <= 1)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            
            Spacer()
            
            // System Links (Bottom)
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                
                // Cost Summary Mini (Clickable)
                Button(action: { showingCostReport = true }) {
                    HStack {
                        Image(systemName: "dollarsign.circle.fill")
                            .foregroundStyle(.green)
                        Text("Spent: \(formatCurrency(projectManager.costSummary.totalSpent))")
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .contentShape(Rectangle()) // Make full width clickable
                }
                .buttonStyle(.plain)
                
                // Settings Link
                Button(action: { onOpenSettings?() }) {
                    Label("Settings", systemImage: "gearshape")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
        }
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(
                projectName: $newProjectName,
                projectDirectory: $newProjectDirectory,
                projectDirectoryBookmark: $newProjectDirectoryBookmark,
                onCreate: createProject,
                onCancel: { showingNewProject = false }
            )
        }
        .sheet(isPresented: $showingCostReport) {
            CostReportView(costSummary: projectManager.costSummary, projects: projectManager.projects)
        }
        .alert("Rename Project", isPresented: Binding(
            get: { projectToRename != nil },
            set: { if !$0 { projectToRename = nil } }
        )) {
            TextField("Project name", text: $renameText)
            Button("Cancel", role: .cancel) {
                projectToRename = nil
                renameText = ""
            }
            Button("Rename") {
                if let project = projectToRename {
                    projectManager.renameProject(project, to: renameText)
                }
                projectToRename = nil
                renameText = ""
            }
            .disabled(renameText.isEmpty)
        } message: {
            Text("Enter a new name for this project.")
        }
    }
    
    private func createProject() {
        guard !newProjectName.isEmpty, !newProjectDirectory.isEmpty else { return }
        
        let project = projectManager.createProject(
            name: newProjectName,
            outputDirectory: newProjectDirectory,
            outputDirectoryBookmark: newProjectDirectoryBookmark
        )
        projectManager.selectProject(project)
        onSelectProject?(project)
        
        newProjectName = ""
        newProjectDirectory = ""
        newProjectDirectoryBookmark = nil
        showingNewProject = false
    }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}
