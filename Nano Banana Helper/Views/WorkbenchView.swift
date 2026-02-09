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
                    ResultsView()
                case .history:
                    HistoryView(
                        entries: historyManager.allGlobalEntries,
                        projects: projectManager.projects,
                        initialProjectId: projectManager.currentProject?.id,
                        activeJobIDs: Set(orchestrator.processingJobs.compactMap { $0.externalJobName }),
                        onDelete: { entry in
                            historyManager.deleteEntry(entry)
                        },
                        onReuse: { entry in
                            // Reuse logic: Load prompt and settings back to staging
                            stagingManager.prompt = entry.prompt
                            stagingManager.aspectRatio = entry.aspectRatio
                            stagingManager.imageSize = entry.imageSize
                            stagingManager.isBatchTier = entry.usedBatchTier
                            
                            // Switch to Staging tab
                            selectedTab = .staging
                            
                            // Note: We can't easily restore file paths if they moved, 
                            // but we could try to add them if they exist.
                            for path in entry.sourceImagePaths {
                                let url = URL(fileURLWithPath: path)
                                if FileManager.default.fileExists(atPath: path) {
                                    stagingManager.addFiles([url])
                                }
                            }
                        },
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
}
