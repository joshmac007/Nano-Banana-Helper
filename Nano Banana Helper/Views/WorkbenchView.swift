import SwiftUI

struct WorkbenchView: View {
    @Bindable var stagingManager: BatchStagingManager
    var historyManager: HistoryManager
    var projectManager: ProjectManager
    @Environment(BatchOrchestrator.self) private var orchestrator
    
    @State private var selectedTab: WorkbenchTab = .staging
    
    enum WorkbenchTab: String, CaseIterable {
        case staging = "Staging"
        case results = "Results" 
        case history = "History"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab Bar
            HStack {
                Picker("", selection: $selectedTab) {
                    ForEach(WorkbenchTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                
                Spacer()
                
                // Clear button only for Staging
                if selectedTab == .staging && !stagingManager.isEmpty {
                     Button("Clear All") {
                         withAnimation {
                             stagingManager.clearAll()
                         }
                     }
                     .buttonStyle(.borderless)
                     .font(.caption)
                }
            }
            .padding(12)
            .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
            
            Divider()
            
            // Content Area
            ZStack {
                switch selectedTab {
                case .staging:
                    StagingView(stagingManager: stagingManager)
                case .results:
                    ResultsView(
                        historyManager: historyManager,
                        projectManager: projectManager,
                        onReuse: reuseEntry
                    )
                case .history:
                    HistoryView(
                        entries: historyManager.allGlobalEntries,
                        historyManager: historyManager,
                        projectManager: projectManager,
                        projects: projectManager.projects,
                        initialProjectId: projectManager.currentProject?.id,
                        activeJobIDs: Set(orchestrator.processingJobs.compactMap { $0.externalJobName }),
                        onDelete: { entry in
                            historyManager.deleteEntry(entry)
                        },
                        onReuse: reuseEntry,
                        onResumePolling: { entry in
                            orchestrator.resumePollingFromHistory(for: entry)
                        }
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Refresh history if switch to tab
            if selectedTab == .history {
                historyManager.loadGlobalHistory(allProjects: projectManager.projects)
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .history {
                historyManager.loadGlobalHistory(allProjects: projectManager.projects)
            }
        }
    }

    private func reuseEntry(_ entry: HistoryEntry) {
        stagingManager.restore(from: entry)
        selectedTab = .staging
    }
}
