import SwiftUI

struct ProjectGalleryView: View {
    let entries: [HistoryEntry]
    @Environment(BatchOrchestrator.self) private var orchestrator
    
    var onReuse: ((HistoryEntry) -> Void)?
    var onResumePolling: ((HistoryEntry) -> Void)?
    
    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                // 1. Active Tasks (from Orchestrator)
                // We only show active tasks if they belong to the current project
                ForEach(activeTasks) { task in
                    ActiveTaskCard(task: task)
                }
                
                // 2. Completed History Entries
                ForEach(entries) { entry in
                    HistoryEntryCard(
                        entry: entry,
                        onReuse: onReuse,
                        onResumePolling: onResumePolling
                    )
                }
            }
            .padding()
        }
    }
    
    private var activeTasks: [ImageTask] {
        // In a real app, we'd filter orchestrator tasks by current project ID
        // For now, orchestrated jobs typically belong to the 'current' workspace
        orchestrator.processingJobs + orchestrator.pendingJobs
    }
}

struct ActiveTaskCard: View {
    let task: ImageTask
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
                
                VStack(spacing: 8) {
                    ProgressView(value: task.phase == .polling ? 0.5 : 0.1) // Mock progress for individual task
                        .progressViewStyle(.circular)
                    
                    Text(task.phase.displayName)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    
                    if task.pollCount > 0 {
                        Text("Poll #\(task.pollCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(task.filename)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Text("Processing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }
}

struct HistoryEntryCard: View {
    let entry: HistoryEntry
    var onReuse: ((HistoryEntry) -> Void)?
    var onResumePolling: ((HistoryEntry) -> Void)?
    
    @State private var thumbnail: NSImage?
    @State private var showingDetail = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                }
                
                if entry.status != "completed" {
                    Image(systemName: statusIcon)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(statusColor)
                        .clipShape(Circle())
                        .padding(8)
                }
            }
            .onTapGesture {
                showingDetail = true
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.prompt)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .frame(height: 32, alignment: .topLeading)
                
                HStack {
                    Text(entry.imageSize)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .background(.quaternary)
                        .cornerRadius(4)
                    
                    Text(formatDate(entry.timestamp))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Text(formatCurrency(entry.cost))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(entry.outputImagePath, inFileViewerRootedAtPath: "")
            }
            Button("Reuse Settings") {
                onReuse?(entry)
            }
            if entry.status == "failed" && entry.externalJobName != nil {
                Button("Resume Polling") {
                    onResumePolling?(entry)
                }
            }
        }
        .task {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        let path = entry.status == "completed" ? entry.outputImagePath : (entry.sourceImagePaths.first ?? "")
        if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            thumbnail = NSImage(contentsOfFile: path)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
    
    private var statusColor: Color {
        switch entry.status {
        case "completed": return .green
        case "cancelled": return .orange
        case "failed": return .red
        default: return .secondary
        }
    }
    
    private var statusIcon: String {
        switch entry.status {
        case "completed": return "checkmark"
        case "cancelled": return "xmark"
        case "failed": return "exclamationmark.triangle"
        default: return "questionmark"
        }
    }
}
