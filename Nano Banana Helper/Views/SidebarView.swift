import SwiftUI

struct SidebarView: View {
    @Bindable var projectManager: ProjectManager
    var onSelectProject: ((Project) -> Void)?
    var onOpenSettings: (() -> Void)?
    
    @State private var showingNewProject = false
    @State private var showingCostReport = false
    @State private var newProjectName = ""
    @State private var newProjectDirectory = ""
    
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
                onCreate: createProject,
                onCancel: { showingNewProject = false }
            )
        }
        .sheet(isPresented: $showingCostReport) {
            CostReportView(costSummary: projectManager.costSummary, projects: projectManager.projects)
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
