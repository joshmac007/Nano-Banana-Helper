import SwiftUI

struct ProjectListView: View {
    @Bindable var projectManager: ProjectManager
    var onSelectProject: ((Project) -> Void)?
    
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var newProjectDirectory = ""
    @State private var projectToRename: Project?
    @State private var renameText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with add button
            HStack {
                Text("Projects")
                    .font(.headline)
                Spacer()
                Button(action: { showingNewProject = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // Project list
            List(projectManager.projects, selection: Binding(
                get: { projectManager.currentProject },
                set: { project in
                    if let project {
                        projectManager.selectProject(project)
                        onSelectProject?(project)
                    }
                }
            )) { project in
                ProjectRowView(project: project, isSelected: project.id == projectManager.currentProject?.id)
                    .tag(project)
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            
            Divider()
            
            // Total cost summary
            HStack {
                Text("Total Spent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatCurrency(projectManager.costSummary.totalSpent))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.green)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(
                projectName: $newProjectName,
                projectDirectory: $newProjectDirectory,
                onCreate: createProject,
                onCancel: { showingNewProject = false }
            )
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
            Text("Enter a new name for this project:")
        }
    }

    
    private func createProject() {
        guard !newProjectName.isEmpty, !newProjectDirectory.isEmpty else { return }
        
        let project = projectManager.createProject(name: newProjectName, outputDirectory: newProjectDirectory)
        projectManager.selectProject(project)
        onSelectProject?(project)
        
        newProjectName = ""
        newProjectDirectory = ""
        showingNewProject = false
    }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}

struct ProjectRowView: View {
    let project: Project
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

            
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .medium : .regular)
                
                HStack(spacing: 8) {
                    Text("\(project.imageCount) images")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    Text(formatCurrency(project.totalCost))
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}
