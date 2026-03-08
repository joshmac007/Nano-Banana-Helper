import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                            projectManager.rebuildCostSummary(from: historyManager.allGlobalEntries)
                        },
                        onReuse: { entry in
                            reuseHistoryEntry(entry)
                        },
                        onResumePolling: { entry in
                            orchestrator.resumePollingFromHistory(for: entry)
                        },
                        onRegrantAccess: { entry in
                            regrantAccessAndRetry(entry)
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

    private func reuseHistoryEntry(_ entry: HistoryEntry) {
        stagingManager.prompt = entry.prompt
        stagingManager.selectedModelName = entry.modelName
        stagingManager.aspectRatio = entry.aspectRatio
        stagingManager.imageSize = entry.imageSize
        stagingManager.isBatchTier = entry.usedBatchTier
        stagingManager.sanitizeSelectionsForCurrentModel()

        selectedTab = .staging

        var reusableURLs: [URL] = []
        var reusableBookmarks: [URL: Data] = [:]
        let sourceBookmarks = entry.sourceImageBookmarks ?? []
        for (index, path) in entry.sourceImagePaths.enumerated() {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if FileManager.default.fileExists(atPath: path) {
                reusableURLs.append(url)
                if sourceBookmarks.indices.contains(index) {
                    reusableBookmarks[url] = sourceBookmarks[index]
                }
                if let maskData = entry.maskImageData {
                    stagingManager.saveMaskEdit(for: url, maskData: maskData, prompt: entry.prompt, paths: [])
                }
            }
        }
        if !reusableURLs.isEmpty {
            _ = stagingManager.addFilesCapturingBookmarks(reusableURLs, preferredBookmarks: reusableBookmarks)
        }
    }

    private func regrantAccessAndRetry(_ entry: HistoryEntry) {
        reuseHistoryEntry(entry)

        if isOutputPermissionFailure(entry),
           let project = projectManager.projects.first(where: { $0.id == entry.projectId }) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.message = "Re-select the output folder for this project."
            panel.prompt = "Grant Output Access"
            panel.directoryURL = URL(fileURLWithPath: project.outputDirectory).deletingLastPathComponent()
            if panel.runModal() == .OK, let url = panel.url, let bookmark = AppPaths.bookmark(for: url) {
                project.outputDirectory = url.path
                project.outputDirectoryBookmark = bookmark
                projectManager.saveProjects()
            }
        }

        guard !entry.sourceImagePaths.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Re-select source files so Nano Banana Helper can access them."
        panel.prompt = "Grant File Access"
        panel.directoryURL = URL(fileURLWithPath: entry.sourceImagePaths[0]).deletingLastPathComponent()
        guard panel.runModal() == .OK else { return }

        stagingManager.clearAll()
        reuseHistoryEntry(entry)
        let result = stagingManager.addFilesCapturingBookmarks(panel.urls)
        if result.hasRejections {
            DebugLog.warning("history.permissions", "Regrant flow still has rejected files", metadata: [
                "entry_id": entry.id.uuidString,
                "rejected_count": String(result.rejectedCount)
            ])
        }
    }

    private func isOutputPermissionFailure(_ entry: HistoryEntry) -> Bool {
        guard let error = entry.error?.lowercased() else { return false }
        return error.contains("output folder") || error.contains("output location")
    }
}
