import SwiftUI

struct MainLayoutView: View {
    @State private var projectManager = ProjectManager()
    @State private var stagingManager = BatchStagingManager()
    @State private var historyManager = HistoryManager() // Add HistoryManager
    @Environment(BatchOrchestrator.self) private var orchestrator
    
    @State private var isQueueOpen: Bool = false
    @State private var promptLibrary = PromptLibrary() // Initialize PromptLibrary
    
    // Width Management
    @State private var sidebarWidth: CGFloat = 250
    @State private var inspectorWidth: CGFloat = 300
    
    @State private var showingSettings = false
    
    var body: some View {
        NavigationSplitView {
            SidebarView(
                projectManager: projectManager,
                onSelectProject: { project in
                    // Logic to load project-specific settings could go here
                },
                onOpenSettings: {
                    showingSettings = true
                }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            VStack(spacing: 0) {
                // Top Area: Workbench + Inspector
                HStack(spacing: 0) {
                    // Center Workbench
                    VStack(spacing: 0) {
                        WorkbenchView(
                            stagingManager: stagingManager,
                            historyManager: historyManager,
                            projectManager: projectManager
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        
                        if isQueueOpen {
                            Divider()
                            ProgressQueueView()
                                .frame(height: 300) // Increased height
                                .transition(.move(edge: .bottom))
                                .background(VisualEffectView(material: .popover, blendingMode: .withinWindow))
                        }

                        Divider()
                        
                        // Bottom Dock (Tucked inside workbench container for matching width)
                        BottomDockView(isQueueOpen: $isQueueOpen)
                    }
                    
                    Divider()
                    
                    // Right Inspector
                    InspectorView(
                        stagingManager: stagingManager, 
                        projectManager: projectManager,
                        promptLibrary: promptLibrary
                    )
                    .frame(width: inspectorWidth)
                }
            }
        }
        .navigationTitle(projectManager.currentProject?.name ?? "Nano Banana Pro")
        .frame(minWidth: 1000, minHeight: 600)
        .environment(projectManager)
        .onAppear {
             // Load saved prompts if needed
             promptLibrary.load()
             // Load global history
             historyManager.loadGlobalHistory(allProjects: projectManager.projects)
             
             // Rebuild updated cost summary from actual history
             projectManager.rebuildCostSummary(from: historyManager.allGlobalEntries)
             
             // Wire up Orchestrator Callbacks
             orchestrator.onImageCompleted = { entry in
                 historyManager.addEntry(entry)
             }
             
             orchestrator.onHistoryEntryUpdated = { jobName, entry in
                 historyManager.updateEntry(byExternalJobName: jobName, with: entry)
             }
             
             orchestrator.onCostIncurred = { cost, resolution, projectId in
                 projectManager.costSummary.record(cost: cost, resolution: resolution, projectId: projectId)
             }
        }
        .onDisappear {
            // Clear callbacks to prevent stale closures from firing if the view is re-created
            orchestrator.onImageCompleted = nil
            orchestrator.onHistoryEntryUpdated = nil
            orchestrator.onCostIncurred = nil
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environment(projectManager)
                .environment(promptLibrary)
        }     
    }
}
