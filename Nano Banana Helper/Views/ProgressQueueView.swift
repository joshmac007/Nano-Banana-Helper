import SwiftUI

struct QueueHeaderActionVisibility: Equatable {
    let showsPause: Bool
    let showsResume: Bool
    let showsCancel: Bool

    init(
        controlState: QueueControlState,
        hasCancellationInProgress: Bool,
        hasActiveNonCancelledWork: Bool,
        canResumeQueue: Bool,
        hasOnlyCancelledTerminalJobs: Bool,
        hasNonTerminalWork: Bool
    ) {
        if hasOnlyCancelledTerminalJobs {
            showsPause = false
            showsResume = false
            showsCancel = false
            return
        }

        if hasCancellationInProgress {
            showsPause = false
            showsResume = false
            showsCancel = hasNonTerminalWork
            return
        }

        switch controlState {
        case .running, .resuming:
            showsPause = hasActiveNonCancelledWork
            showsResume = false
            showsCancel = hasNonTerminalWork
        case .pausedLocal, .interrupted:
            showsPause = false
            showsResume = canResumeQueue
            showsCancel = hasNonTerminalWork
        case .idle, .cancelling:
            showsPause = false
            showsResume = false
            showsCancel = false
        }
    }
}

/// The "Banana Peel" - visual progress queue
struct ProgressQueueView: View {
    let historyManager: HistoryManager
    let projectManager: ProjectManager
    let queueHeight: CGFloat
    @Environment(BatchOrchestrator.self) private var orchestrator
    @State private var logManager = LogManager.shared
    @State private var isLogVisible: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Drawer Header with Controls
            VStack(spacing: 4) {
                HStack {
                    Text("Queue")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: { withAnimation { isLogVisible.toggle() } }) {
                        Label(isLogVisible ? "Hide Logs" : "Show Logs", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(isLogVisible ? .primary : .secondary)
                    .help("View raw API logs")

                    if !orchestrator.completedJobs.isEmpty {
                        Divider()
                            .frame(height: 16)

                        Button(action: openOutputFolder) {
                            Label("Open Output", systemImage: "folder")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                        .help("Open output folder in Finder")
                    }

                    Divider()
                        .frame(height: 16)

                    if headerActions.showsPause {
                        Button(action: { orchestrator.pause() }) {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if headerActions.showsResume {
                        Button(action: { Task { await orchestrator.startAll() } }) {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                    }

                    if headerActions.showsCancel {
                        Button(role: .destructive, action: { orchestrator.cancel() }) {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if !headerSubtitle.isEmpty {
                    HStack {
                        Text(headerSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(.background.secondary)
            
            Divider()
            
            // Queue list
            if allTasks.isEmpty {
                VStack {
                    ContentUnavailableView {
                        Image(systemName: "tray")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Processing
                    if !orchestrator.processingJobs.isEmpty {
                        Section {
                            ForEach(orchestrator.processingJobs, id: \.id) { task in
                                TaskRowView(task: task)
                            }
                        } header: {
                            QueueSectionHeader(
                                title: "Processing (\(orchestrator.processingJobs.count))"
                            )
                        }
                    }
                    
                    // Pending
                    if !orchestrator.pendingJobs.isEmpty {
                        let count = orchestrator.pendingJobs.count
                        Section {
                            ForEach(orchestrator.pendingJobs, id: \.id) { task in
                                TaskRowView(task: task)
                            }
                            .onDelete(perform: orchestrator.removePendingTasks)
                        } header: {
                            QueueSectionHeader(
                                title: "Pending (\(count) task\(count == 1 ? "" : "s"))",
                                clearAction: {
                                    clearAll(orchestrator.pendingJobs) { orchestrator.removePendingTasks(at: $0) }
                                }
                            )
                        }
                    }
                    
                    // Completed
                    if !orchestrator.completedJobs.isEmpty {
                        let count = orchestrator.completedJobs.count
                        Section {
                            ForEach(orchestrator.completedJobs, id: \.id) { task in
                                TaskRowView(task: task)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            if let index = orchestrator.completedJobs.firstIndex(where: { $0.id == task.id }) {
                                                orchestrator.removeCompletedTasks(at: IndexSet(integer: index))
                                            }
                                        } label: {
                                            Text("Dismiss")
                                        }
                                    }
                            }
                        } header: {
                            QueueSectionHeader(
                                title: "Completed (\(count))",
                                clearAction: {
                                    clearAll(orchestrator.completedJobs) { orchestrator.removeCompletedTasks(at: $0) }
                                }
                            )
                        }
                    }
                    
                    // Cancelled
                    if !orchestrator.cancelledJobs.isEmpty {
                        let count = orchestrator.cancelledJobs.count
                        Section {
                            ForEach(orchestrator.cancelledJobs, id: \.id) { task in
                                TaskRowView(task: task)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            if let index = orchestrator.cancelledJobs.firstIndex(where: { $0.id == task.id }) {
                                                orchestrator.removeCancelledTasks(at: IndexSet(integer: index))
                                            }
                                        } label: {
                                            Text("Dismiss")
                                        }
                                    }
                            }
                        } header: {
                            QueueSectionHeader(
                                title: "Cancelled (\(count))",
                                subtitle: "Logged in History",
                                clearAction: {
                                    clearAll(orchestrator.cancelledJobs) { orchestrator.removeCancelledTasks(at: $0) }
                                }
                            )
                        }
                    }

                    // Issues
                    if !orchestrator.failedJobs.isEmpty {
                        let count = orchestrator.failedJobs.count
                        Section {
                            ForEach(orchestrator.failedJobs, id: \.id) { task in
                                TaskRowView(task: task)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            if let index = orchestrator.failedJobs.firstIndex(where: { $0.id == task.id }) {
                                                orchestrator.removeFailedTasks(at: IndexSet(integer: index))
                                            }
                                        } label: {
                                            Text("Dismiss")
                                        }
                                    }
                            }
                        } header: {
                            QueueSectionHeader(
                                title: "Issues (\(count))",
                                clearAction: {
                                    clearAll(orchestrator.failedJobs) { orchestrator.removeFailedTasks(at: $0) }
                                }
                            )
                        }
                    }
                }
                .id(queueContentRefreshID)
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            
            // Raw API Logs Window (Collapsible)
            if isLogVisible {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Text("API Logs")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { logManager.clear() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.background.tertiary)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if logManager.entries.isEmpty {
                                HStack {
                                    Spacer()
                                    Text("No logs yet...")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding()
                                    Spacer()
                                }
                            } else {
                                ForEach(logManager.entries) { entry in
                                    LogEntryRow(entry: entry)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    .frame(height: apiLogHeight)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.1))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationSplitViewColumnWidth(min: 300, ideal: 350)
    }
    
    private var allTasks: [ImageTask] {
        orchestrator.pendingJobs + orchestrator.processingJobs + orchestrator.completedJobs + orchestrator.cancelledJobs + orchestrator.failedJobs
    }
    
    private var progressColor: Color {
        if orchestrator.controlState == .cancelling { return .orange }
        if orchestrator.isPaused { return .yellow }
        if !orchestrator.failedJobs.isEmpty { return .orange }
        return .accentColor
    }

    private var headerSubtitle: String {
        if orchestrator.hasCancellationInProgress {
            return "Cancelling remotely where possible and reconciling final job states."
        }

        if orchestrator.hasOnlyCancelledTerminalJobs {
            return "Cancellation complete. Cancelled jobs remain visible until you clear them."
        }

        switch orchestrator.controlState {
        case .pausedLocal:
            return "Paused locally. Gemini may still finish already-submitted work remotely."
        case .cancelling:
            return "Cancelling remotely where possible and reconciling final job states."
        case .interrupted:
            return "Queue recovery required. Resume reconciles remote jobs before submitting new work."
        default:
            return ""
        }
    }

    private var headerActions: QueueHeaderActionVisibility {
        QueueHeaderActionVisibility(
            controlState: orchestrator.controlState,
            hasCancellationInProgress: orchestrator.hasCancellationInProgress,
            hasActiveNonCancelledWork: orchestrator.hasActiveNonCancelledWork,
            canResumeQueue: orchestrator.canResumeQueue,
            hasOnlyCancelledTerminalJobs: orchestrator.hasOnlyCancelledTerminalJobs,
            hasNonTerminalWork: orchestrator.hasNonTerminalWork
        )
    }
    
    private func openOutputFolder() {
        if let firstCompleted = orchestrator.completedJobs.first,
           let projectID = firstCompleted.projectId,
           let project = projectManager.projects.first(where: { $0.id == projectID }) {
            switch AppPaths.revealDirectory(
                bookmark: project.outputDirectoryBookmark,
                fallbackPath: project.outputDirectory
            ) {
            case let .success(_, refreshedBookmark):
                if let refreshedBookmark {
                    project.outputDirectoryBookmark = refreshedBookmark
                    projectManager.saveProjects()
                }
            case .fallbackUsed:
                break
            case .accessDenied:
                BookmarkReauthorization.reauthorizeOutputFolder(
                    for: project,
                    projectManager: projectManager,
                    historyManager: historyManager
                )
            }
        }
    }

    private func clearAll(_ tasks: [ImageTask], removal: (IndexSet) -> Void) {
        guard !tasks.isEmpty else { return }
        removal(IndexSet(integersIn: tasks.indices))
    }

    private var apiLogHeight: CGFloat {
        let scaledHeight = queueHeight * 0.5
        return min(max(180, scaledHeight), 360)
    }

    private var queueContentRefreshID: String {
        let allJobs = orchestrator.pendingJobs
            + orchestrator.processingJobs
            + orchestrator.completedJobs
            + orchestrator.cancelledJobs
            + orchestrator.failedJobs

        return allJobs
            .map { "\($0.id.uuidString)-\($0.status)-\($0.phase.rawValue)" }
            .joined(separator: "|")
    }
}

struct StatusIndicator: View {
    let controlState: QueueControlState
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay {
                    if controlState == .running || controlState == .resuming || controlState == .cancelling {
                        Circle()
                            .stroke(statusColor.opacity(0.5), lineWidth: 2)
                            .scaleEffect(1.5)
                            .opacity(0.5)
                            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: controlState)
                    }
                }
            
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    private var statusColor: Color {
        switch controlState {
        case .running: return .green
        case .resuming: return .orange
        case .cancelling: return .orange
        case .pausedLocal: return .yellow
        case .interrupted: return .orange
        case .idle: return .gray
        }
    }
    
    private var statusText: String {
        controlState.displayName
    }
}

struct QueueSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var clearAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if let clearAction {
                Button(action: clearAction) {
                    Text("Clear All")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Remove all items in this queue section")
            }
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }
}

struct TaskRowView: View {
    let task: ImageTask
    
    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(task.filename)
                        .font(.subheadline)
                        .lineLimit(1)
                    
                    if task.inputPaths.count > 1 {
                        Text(task.status == "completed" ? "1" : "\(task.inputPaths.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(task.status == "completed" ? Color.green : Color.accentColor)
                            .clipShape(Capsule())
                            .help(task.status == "completed" ? "Generated 1 image from multimodal input" : "Multimodal input with \(task.inputPaths.count) images")
                    }
                }
                
                if shouldShowPhaseMetadata {
                    HStack(spacing: 4) {
                        Text(task.phase.displayName)
                            .font(.caption)
                            .foregroundStyle(phaseColor)
                        
                        if pollStateSupported && task.pollCount > 0 {
                            Text("#\(task.pollCount)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.orange)
                        }

                        if let lastPollState = task.lastPollState,
                           pollStateSupported {
                            Text("• \(formattedPollState(lastPollState))")
                                .font(.caption)
                                .foregroundStyle(task.phase == .stalled ? .orange : .secondary)
                        }
                        
                        if let startedAt = task.startedAt {
                            Text("• \(elapsedTimeString(from: startedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let lastPollUpdatedAt = task.lastPollUpdatedAt {
                            Text("• updated \(relativeUpdateString(from: lastPollUpdatedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if task.phase == .stalled {
                        Text("Polling paused locally. Use Resume to continue.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if task.phase == .pausedLocal {
                        Text(task.hasRemoteJob ? "Paused locally. Resume to reconcile remote status." : "Paused locally. Resume to continue.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if task.phase == .cancelRequested {
                        Text("Cancel requested. Waiting for the final remote status.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else if task.phase == .stalled {
                    Text("Polling paused locally. Use Resume to continue.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if let error = task.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(errorColor)
                        .lineLimit(2)
                } else if let duration = task.duration {
                    Text(String(format: "%.1fs", duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Open output button for completed tasks
            if task.status == "completed", let outputPath = task.outputPath {
                Button(action: {
                    _ = AppPaths.openFile(bookmark: nil, fallbackPath: outputPath)
                }) {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open in Preview")
            }
        }
        .padding(.vertical, 4)
    }
    
    private func elapsedTimeString(from date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    private func relativeUpdateString(from date: Date) -> String {
        let elapsed = max(Int(Date().timeIntervalSince(date)), 0)
        if elapsed >= 60 {
            return "\(elapsed / 60)m ago"
        }
        return "\(elapsed)s ago"
    }

    private func formattedPollState(_ state: String) -> String {
        NanoBananaService.displayBatchState(state)
    }

    private var shouldShowPhaseMetadata: Bool {
        task.status == "processing" || task.phase == .pausedLocal || task.phase == .cancelRequested || task.phase == .stalled
    }

    private var pollStateSupported: Bool {
        task.phase == .polling || task.phase == .reconnecting || task.phase == .stalled || task.phase == .cancelRequested
    }

    private var phaseColor: Color {
        switch task.phase {
        case .pausedLocal, .stalled, .cancelRequested, .expired:
            return .orange
        case .cancelled:
            return .orange
        case .failed:
            return .red
        case .completed:
            return .green
        default:
            return .secondary
        }
    }

    private var errorColor: Color {
        switch task.status {
        case "cancelled", "expired":
            return .orange
        default:
            return .red
        }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch task.phase {
        case .pending:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.secondary)
        case .submitting:
            ProgressView()
                .scaleEffect(0.7)
        case .submittedRemote:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.orange)
        case .polling:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.orange)
        case .reconnecting:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.orange)
        case .pausedLocal:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.yellow)
        case .cancelRequested:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.orange)
        case .stalled:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.orange)
        case .downloading:
            ProgressView()
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.green)
        case .cancelled:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.orange)
        case .expired:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.red)
        }
    }
}
struct LogEntryRow: View {
    let entry: LogEntry
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.timestamp, style: .time)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Text(entry.type.rawValue.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(typeColor.opacity(0.2))
                    .foregroundStyle(typeColor)
                    .cornerRadius(3)
                
                Spacer()
                
                Button(isExpanded ? "Less" : "More") {
                    withAnimation { isExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)
            }
            
            if isExpanded {
                Text(entry.payload)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.black.opacity(0.2))
                    .cornerRadius(4)
            } else {
                Text(entry.payload)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .cornerRadius(6)
    }
    
    private var typeColor: Color {
        switch entry.type {
        case .request: return .blue
        case .response: return .green
        case .error: return .red
        }
    }
}
