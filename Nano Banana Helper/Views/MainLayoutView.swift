import AppKit
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
    @State private var queueHeight: CGFloat = 300
    @State private var queueDragPreviewHeight: CGFloat?
    
    @State private var settingsSheet: SettingsView.SettingsTab? = nil
    
    var body: some View {
        NavigationSplitView {
            SidebarView(
                projectManager: projectManager,
                historyManager: historyManager,
                onSelectProject: { project in
                    projectManager.selectProject(project)
                    // Load default preset if set
                    if let presetID = project.defaultPresetID,
                       let preset = promptLibrary.preset(id: presetID) {
                        stagingManager.prompt = preset.userPrompt
                        stagingManager.systemPrompt = preset.systemPrompt ?? ""
                    }
                },
                onOpenSettings: {
                    settingsSheet = .api
                }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            GeometryReader { proxy in
                let queueBounds = QueueLayoutMetrics.heightBounds(for: proxy.size.height)
                let displayedQueueHeight = QueueLayoutMetrics.clampedHeight(
                    queueDragPreviewHeight ?? queueHeight,
                    availableHeight: proxy.size.height
                )

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
                            QueueResizeHandle(
                                currentHeight: displayedQueueHeight,
                                minHeight: queueBounds.lowerBound,
                                maxHeight: queueBounds.upperBound,
                                onHeightChanged: { queueDragPreviewHeight = $0 },
                                onHeightCommitted: { finalHeight in
                                    queueHeight = finalHeight
                                    queueDragPreviewHeight = nil
                                }
                            )
                            .padding(.top, 1)
                            .background(.background.secondary)

                            ProgressQueueView(
                                historyManager: historyManager,
                                projectManager: projectManager,
                                queueHeight: displayedQueueHeight
                            )
                            .frame(height: displayedQueueHeight)
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
                        historyManager: historyManager
                    )
                    .frame(width: inspectorWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle(projectManager.currentProject?.name ?? "Nano Banana Pro")
        .frame(minWidth: 1000, minHeight: 600)
        .environment(projectManager)
        .environment(promptLibrary)
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
             
             orchestrator.onCostIncurred = { cost, resolution, projectId, tokenUsage, modelName in
                 projectManager.recordCostIncurred(
                    cost: cost,
                    resolution: resolution,
                    projectId: projectId,
                    tokenUsage: tokenUsage,
                    modelName: modelName
                 )
             }
        }
        .onDisappear {
            // Clear callbacks to prevent stale closures from firing if the view is re-created
            orchestrator.onImageCompleted = nil
            orchestrator.onHistoryEntryUpdated = nil
            orchestrator.onCostIncurred = nil
        }
        .sheet(item: $settingsSheet) { tab in
            SettingsView(initialTab: tab)
                .environment(projectManager)
                .environment(promptLibrary)
                .environment(historyManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPromptSettings)) { _ in
            settingsSheet = .prompts
        }
    }

}

struct QueueLayoutMetrics {
    static let minimumQueueHeight: CGFloat = 180
    static let minimumWorkbenchHeight: CGFloat = 260
    static let bottomDockHeight: CGFloat = 34
    static let resizeHandleHeight: CGFloat = 13
    static let dividerHeight: CGFloat = 1

    static func clampedHeight(_ height: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let bounds = heightBounds(for: availableHeight)
        return min(max(height, bounds.lowerBound), bounds.upperBound)
    }

    static func heightBounds(for availableHeight: CGFloat) -> ClosedRange<CGFloat> {
        let reservedHeight = minimumWorkbenchHeight + bottomDockHeight + resizeHandleHeight + dividerHeight
        let maximumHeight = max(minimumQueueHeight, availableHeight - reservedHeight)
        return minimumQueueHeight...maximumHeight
    }
}

private struct QueueResizeHandle: View {
    let currentHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onHeightChanged: (CGFloat) -> Void
    let onHeightCommitted: (CGFloat) -> Void
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.6))
            .frame(width: 64, height: 4)
        .frame(height: 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = currentHeight
                    }
                    guard let dragStartHeight else { return }
                    let proposedHeight = dragStartHeight - value.translation.height
                    onHeightChanged(min(max(proposedHeight, minHeight), maxHeight))
                }
                .onEnded { value in
                    let startHeight = dragStartHeight ?? currentHeight
                    let proposedHeight = startHeight - value.translation.height
                    onHeightCommitted(min(max(proposedHeight, minHeight), maxHeight))
                    dragStartHeight = nil
                }
        )
        .accessibilityLabel("Resize queue")
        .accessibilityHint("Drag to change the queue height")
    }
}
