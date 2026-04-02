import AppKit
import SwiftUI

struct ProjectGalleryView: View {
    let entries: [HistoryEntry]
    let historyManager: HistoryManager
    let projectManager: ProjectManager

    @Environment(BatchOrchestrator.self) private var orchestrator

    var onReuse: ((HistoryEntry) -> Void)?
    var onResumePolling: ((HistoryEntry) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(activeTasks) { task in
                    ActiveTaskCard(task: task)
                }

                ForEach(entries) { entry in
                    HistoryEntryCard(
                        entry: entry,
                        project: projectManager.projects.first(where: { $0.id == entry.projectId }),
                        historyManager: historyManager,
                        projectManager: projectManager,
                        onReuse: onReuse,
                        onResumePolling: onResumePolling
                    )
                }
            }
            .padding()
        }
    }

    private var activeTasks: [ImageTask] {
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
                    ProgressView(value: task.phase == .polling ? 0.5 : 0.1)
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
    let project: Project?
    let historyManager: HistoryManager
    let projectManager: ProjectManager
    var onReuse: ((HistoryEntry) -> Void)?
    var onResumePolling: ((HistoryEntry) -> Void)?

    @State private var thumbnail: NSImage?
    @State private var accessDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
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
                        .overlay(Image(systemName: accessDenied ? "lock.fill" : "photo").foregroundStyle(.tertiary))
                }

                if accessDenied {
                    Button(action: reauthorize) {
                        Image(systemName: "lock.badge.plus")
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                } else if entry.status != "completed" {
                    Image(systemName: statusIcon)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(statusColor)
                        .clipShape(Circle())
                        .padding(8)
                }
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
            if project != nil {
                Button("Show in Finder", action: revealOutput)
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
        .task(id: loadID) {
            loadThumbnail()
        }
    }

    private var loadID: String {
        let thumbnailPath = entry.status == "completed" ? entry.outputImagePath : (entry.sourceImagePaths.first ?? "")
        let bookmark = entry.status == "completed"
            ? entry.outputImageBookmark?.base64EncodedString()
            : entry.sourceImageBookmarks?.first?.base64EncodedString()
        return "\(entry.id.uuidString)-\(thumbnailPath)-\(bookmark ?? "none")"
    }

    private func loadThumbnail() {
        let fallbackPath = entry.status == "completed" ? entry.outputImagePath : (entry.sourceImagePaths.first ?? "")
        let bookmark = entry.status == "completed" ? entry.outputImageBookmark : entry.sourceImageBookmarks?.first

        guard !fallbackPath.isEmpty else {
            thumbnail = nil
            accessDenied = false
            return
        }

        switch AppPaths.loadImageData(bookmark: bookmark, fallbackPath: fallbackPath) {
        case let .success(data, refreshedBookmark):
            thumbnail = NSImage(data: data)
            accessDenied = false
            persistRefreshedBookmark(refreshedBookmark)
        case let .fallbackUsed(data):
            thumbnail = NSImage(data: data)
            accessDenied = false
        case .accessDenied:
            thumbnail = nil
            accessDenied = true
        }
    }

    private func revealOutput() {
        guard let project else { return }

        switch AppPaths.revealInFinder(
            bookmark: entry.outputImageBookmark,
            fallbackPath: entry.outputImagePath
        ) {
        case let .success(_, refreshedBookmark):
            if let refreshedBookmark {
                historyManager.updateBookmarks(
                    for: entry.id,
                    outputBookmark: refreshedBookmark,
                    sourceBookmarks: entry.sourceImageBookmarks
                )
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

    private func reauthorize() {
        if entry.status == "completed", let project {
            BookmarkReauthorization.reauthorizeOutputFolder(
                for: project,
                projectManager: projectManager,
                historyManager: historyManager
            )
            return
        }

        let suggestedFolderURL = entry.sourceImagePaths.first.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        }
        BookmarkReauthorization.reauthorizeSourceFolder(
            entryIds: [entry.id],
            suggestedFolderURL: suggestedFolderURL,
            historyManager: historyManager
        )
    }

    private func persistRefreshedBookmark(_ refreshedBookmark: Data?) {
        guard let refreshedBookmark else { return }

        if entry.status == "completed" {
            historyManager.updateBookmarks(
                for: entry.id,
                outputBookmark: refreshedBookmark,
                sourceBookmarks: entry.sourceImageBookmarks
            )
        } else if var sourceBookmarks = entry.sourceImageBookmarks, !sourceBookmarks.isEmpty {
            sourceBookmarks[0] = refreshedBookmark
            historyManager.updateBookmarks(
                for: entry.id,
                outputBookmark: entry.outputImageBookmark,
                sourceBookmarks: sourceBookmarks
            )
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
