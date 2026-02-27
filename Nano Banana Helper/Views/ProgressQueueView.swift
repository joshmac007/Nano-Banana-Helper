import SwiftUI

/// The "Banana Peel" - visual progress queue
struct ProgressQueueView: View {
    @Environment(BatchOrchestrator.self) private var orchestrator
    @State private var logManager = LogManager.shared
    @State private var isLogVisible: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Drawer Header with Controls
            HStack {
                Text("Queue")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if orchestrator.hasInterruptedJobs {
                    Button("Resume Batch") {
                        Task { await orchestrator.resumeInterruptedJobs() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                }
                
                // Logs Toggle
                Button(action: { withAnimation { isLogVisible.toggle() } }) {
                    Label(isLogVisible ? "Hide Logs" : "Show Logs", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(isLogVisible ? .primary : .secondary)
                .help("View raw API logs")
                
                Divider()
                    .frame(height: 16)
                
                if orchestrator.isPaused {
                    Button(action: { Task { await orchestrator.startAll() } }) {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    
                    Button(role: .destructive, action: { orchestrator.cancel() }) {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if orchestrator.isRunning {
                    Button(action: { orchestrator.pause() }) {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button(role: .destructive, action: { orchestrator.cancel() }) {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(.background.secondary)
            
            Divider()
            
            // Queue list
            if allTasks.isEmpty {
                VStack {
                    ContentUnavailableView {
                        Label("No Tasks", systemImage: "tray")
                    } description: {
                        Text("Add images and start a batch to see progress here.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Processing
                    if !orchestrator.processingJobs.isEmpty {
                        Section("Processing (\(orchestrator.processingJobs.count))") {
                            ForEach(orchestrator.processingJobs, id: \.id) { task in
                                TaskRowView(task: task)
                            }
                        }
                    }
                    
                    // Pending
                    if !orchestrator.pendingJobs.isEmpty {
                        let count = orchestrator.pendingJobs.count
                        Section("Pending (\(count) task\(count == 1 ? "" : "s"))") {
                            ForEach(orchestrator.pendingJobs, id: \.id) { task in
                                TaskRowView(task: task)
                            }
                            .onDelete(perform: orchestrator.removePendingTasks)
                        }
                    }
                    
                    // Completed
                    if !orchestrator.completedJobs.isEmpty {
                        let count = orchestrator.completedJobs.count
                        Section("Completed (\(count) output\(count == 1 ? "" : "s"))") {
                            ForEach(orchestrator.completedJobs, id: \.id) { task in
                                TaskRowView(task: task)
                            }
                            .onDelete(perform: orchestrator.removeCompletedTasks)
                        }
                    }
                    
                    // Failed
                    if !orchestrator.failedJobs.isEmpty {
                        let count = orchestrator.failedJobs.count
                        Section("Failed (\(count) error\(count == 1 ? "" : "s"))") {
                            ForEach(orchestrator.failedJobs, id: \.id) { task in
                                TaskRowView(task: task)
                            }
                            .onDelete(perform: orchestrator.removeFailedTasks)
                        }
                    }
                }
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
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.1))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            Divider()
            

        }
        .navigationSplitViewColumnWidth(min: 300, ideal: 350)
    }
    
    private var allTasks: [ImageTask] {
        orchestrator.pendingJobs + orchestrator.processingJobs + orchestrator.completedJobs + orchestrator.failedJobs
    }
    
    private var progressColor: Color {
        if orchestrator.isPaused { return .yellow }
        if !orchestrator.failedJobs.isEmpty { return .orange }
        return .accentColor
    }
    

}

struct StatusIndicator: View {
    let isRunning: Bool
    let isPaused: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay {
                    if isRunning {
                        Circle()
                            .stroke(statusColor.opacity(0.5), lineWidth: 2)
                            .scaleEffect(1.5)
                            .opacity(0.5)
                            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: isRunning)
                    }
                }
            
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    private var statusColor: Color {
        if isPaused { return .yellow }
        if isRunning { return .green }
        return .gray
    }
    
    private var statusText: String {
        if isPaused { return "Paused" }
        if isRunning { return "Running" }
        return "Idle"
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
                
                // Phase-based status for processing jobs
                if task.status == "processing" {
                    HStack(spacing: 4) {
                        Text(task.phase.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        if task.phase == .polling && task.pollCount > 0 {
                            Text("#\(task.pollCount)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.orange)
                        }
                        
                        if let startedAt = task.startedAt {
                            Text("• \(elapsedTimeString(from: startedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let error = task.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let duration = task.duration {
                    Text(String(format: "%.1fs", duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Open output buttons for completed tasks
            if task.status == "completed", let outputURL = task.outputURL {
                HStack(spacing: 12) {
                    Button(action: { NSWorkspace.shared.open(outputURL.deletingLastPathComponent()) }) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                    
                    Button(action: { NSWorkspace.shared.open(outputURL) }) {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open in Preview")
                }
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
    
    @ViewBuilder
    private var statusIcon: some View {
        switch task.phase {
        case .pending:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.secondary)
        case .submitting:
            ProgressView()
                .scaleEffect(0.7)
        case .polling:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.orange)
        case .reconnecting:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.orange)
        case .downloading:
            ProgressView()
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: task.phase.icon)
                .foregroundStyle(.green)
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
