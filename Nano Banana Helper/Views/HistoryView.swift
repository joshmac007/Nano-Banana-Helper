import SwiftUI
import AppKit

struct HistoryView: View {
    let entries: [HistoryEntry]
    var projects: [Project] = []

    var activeJobIDs: Set<String> = [] // IDs of jobs currently in memory
    var onDelete: ((HistoryEntry) -> Void)?
    var onReuse: ((HistoryEntry) -> Void)?
    var onResumePolling: ((HistoryEntry) -> Void)?
    
    @State private var selectedEntry: HistoryEntry?
    @State private var rescueJobID: String = ""
    @State private var entryToRescue: HistoryEntry?
    @State private var showingRescueDialog = false
    
    @State private var searchText: String = ""
    @State private var selectedProjectId: UUID?
    
    init(
        entries: [HistoryEntry],
        projects: [Project] = [],
        initialProjectId: UUID? = nil,
        activeJobIDs: Set<String> = [],
        onDelete: ((HistoryEntry) -> Void)? = nil,
        onReuse: ((HistoryEntry) -> Void)? = nil,
        onResumePolling: ((HistoryEntry) -> Void)? = nil
    ) {
        self.entries = entries
        self.projects = projects
        self.activeJobIDs = activeJobIDs
        self.onDelete = onDelete
        self.onReuse = onReuse
        self.onResumePolling = onResumePolling
        self._selectedProjectId = State(initialValue: initialProjectId)
    }
    
    var headerTitle: String {
        if let selectedProjectId, let project = projects.first(where: { $0.id == selectedProjectId }) {
            return "\(project.name) History"
        }
        return "Global Feed"
    }
    
    var filteredEntries: [HistoryEntry] {
        entries.filter { entry in
            let matchesSearch = searchText.isEmpty || 
                entry.prompt.localizedCaseInsensitiveContains(searchText) ||
                entry.externalJobName?.localizedCaseInsensitiveContains(searchText) == true
            
            let matchesProject = selectedProjectId == nil || entry.projectId == selectedProjectId
            
            return matchesSearch && matchesProject
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header - full width with search and project filter
            VStack(spacing: 12) {
                HStack {
                    Text(headerTitle)
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    Text("\(filteredEntries.count) edits found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search historical prompts or job IDs...", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    
                    Picker("Project", selection: $selectedProjectId) {
                        Text("All Projects").tag(UUID?.none)
                        Divider()
                        ForEach(projects) { project in
                            Text(project.name).tag(UUID?.some(project.id))
                        }
                    }
                    .frame(width: 200)
                }
            }
            .padding()
            
            Divider()
            
            if entries.isEmpty {
                VStack {
                    Spacer()
                    ContentUnavailableView {
                        Label("No History", systemImage: "clock")
                    } description: {
                        Text("Completed edits will appear here.")
                    }
                    Spacer()
                }
            } else {
                List(filteredEntries, selection: $selectedEntry) { entry in
                    let projectName = projects.first { $0.id == entry.projectId }?.name ?? "Unknown"
                    let isActive = entry.externalJobName.map { activeJobIDs.contains($0) } ?? false
                    
                    HistoryRowView(
                        entry: entry, 
                        projectName: projectName,
                        isActive: isActive,
                        onReuse: onReuse, 
                        onResumePolling: onResumePolling,
                        onRescue: { 
                            entryToRescue = entry
                            rescueJobID = ""
                            showingRescueDialog = true
                        }
                    )
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.outputURL])
                        }
                        Button("Reuse Settings") {
                            onReuse?(entry)
                        }
                        if entry.status == "failed" {
                            if entry.externalJobName != nil {
                                Button("Resume Polling (No Cost)") {
                                    onResumePolling?(entry)
                                }
                            } else {
                                Button("Rescue with Job ID...") {
                                    entryToRescue = entry
                                    rescueJobID = ""
                                    showingRescueDialog = true
                                }
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            onDelete?(entry)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingRescueDialog) {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rescue Batch Job")
                        .font(.headline)
                    Text("If you have a Job ID from the logs (e.g. batches/...), paste it here to try and recover the results without paying again.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                TextField("Job ID (e.g. batches/bkzq...)", text: $rescueJobID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                
                HStack {
                    Button("Cancel") {
                        showingRescueDialog = false
                    }
                    .keyboardShortcut(.cancelAction)
                    
                    Spacer()
                    
                    Button("Rescue & Poll") {
                        if let entry = entryToRescue, !rescueJobID.isEmpty {
                            // Create a temporary entry with the ID
                            let rescuedEntry = HistoryEntry(
                                projectId: entry.projectId,
                                sourceImagePaths: entry.sourceImagePaths,
                                outputImagePath: entry.outputImagePath,
                                prompt: entry.prompt,
                                aspectRatio: entry.aspectRatio,
                                imageSize: entry.imageSize,
                                usedBatchTier: entry.usedBatchTier,
                                cost: entry.cost,
                                status: entry.status,
                                error: entry.error,
                                externalJobName: rescueJobID.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            onResumePolling?(rescuedEntry)
                        }
                        showingRescueDialog = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(rescueJobID.isEmpty)
                }
            }
            .padding()
            .frame(width: 400)
        }
    }
}


struct HistoryRowView: View {
    let entry: HistoryEntry
    let projectName: String
    var isActive: Bool = false
    var onReuse: ((HistoryEntry) -> Void)?
    var onResumePolling: ((HistoryEntry) -> Void)?
    var onRescue: (() -> Void)?
    
    @State private var sourceImage: NSImage?
    @State private var outputImage: NSImage?
    @State private var showingPreview = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // Part 1: Thumbnails (Matched to text height)
            HStack(spacing: 4) {
                // Source
                ZStack(alignment: .bottomTrailing) {
                    if let sourceImage {
                        Image(nsImage: sourceImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 64, height: 64)
                            .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                    }
                    
                    if entry.sourceImagePaths.count > 1 {
                        Text("\(entry.sourceImagePaths.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                            .offset(x: 4, y: 4)
                    }
                }
                
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                
                // Output/Status
                if entry.status == "completed" {
                    if let outputImage {
                        ZStack(alignment: .bottomTrailing) {
                            Image(nsImage: outputImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .onTapGesture {
                                    showingPreview = true
                                }
                                .help("Click to preview")
                            
                            if entry.sourceImagePaths.count > 1 {
                                Text("1")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .background(Color.green)
                                    .clipShape(Capsule())
                                    .offset(x: 4, y: 4)
                            }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 64, height: 64)
                            .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                    }
                } else {
                    // Processing / Failed / Cancelled
                    RoundedRectangle(cornerRadius: 8)
                        .fill(statusColor.opacity(0.1))
                        .frame(width: 64, height: 64)
                        .overlay(
                            Group {
                                if isActive {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: statusIcon)
                                        .font(.system(size: 20))
                                        .foregroundStyle(statusColor)
                                }
                            }
                        )
                }
            }
            
            // Part 2: Actions Column (Vertically Justified/Centered)
            VStack(spacing: 12) {
                Button(action: { onReuse?(entry) }) {
                    Image(systemName: "gobackward")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Reuse Settings")
                
                if entry.status == "failed" || (entry.status == "processing" && !isActive) {
                    if entry.externalJobName != nil {
                        Button(action: { onResumePolling?(entry) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Resume Polling")
                    } else {
                        Button(action: { onRescue?() }) {
                            Image(systemName: "lifepreserver")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("Rescue ID")
                    }
                }
            }
            .frame(width: 24)
            
            // Part 3: Text Column (3 Lines)
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: Prompt
                Text(entry.prompt)
                    .font(.system(.subheadline, weight: .medium))
                    .lineLimit(2)
                
                // Line 2: Metadata Bundle (Cost, Project, Size, Aspect, Batch)
                HStack(spacing: 8) {
                    Text(formatCurrency(entry.cost))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    
                    Text("in \(projectName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    
                    // Meta Badges
                    HStack(spacing: 6) {
                        Text(entry.imageSize)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .cornerRadius(4)
                        
                        Text(entry.aspectRatio)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        
                        if entry.usedBatchTier {
                            Text("Batch")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                        }
                    }
                }
                
                // Line 3: Status / Error
                if entry.status != "completed" {
                    HStack(spacing: 4) {
                        Text(entry.status.uppercased())
                            .font(.system(size: 9, weight: .black))
                        
                        if let error = entry.error {
                            Text(error)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .cornerRadius(4)
                } else {
                    Text("Completed")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())


        .task {
            await loadThumbnails()
        }
        .sheet(isPresented: $showingPreview) {
            if let outputImage {
                VStack(spacing: 16) {
                    Text("Preview")
                        .font(.headline)
                    
                    Image(nsImage: outputImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 600, maxHeight: 600)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    HStack {
                        Text(entry.prompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        
                        Spacer()
                        
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.outputURL])
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Close") {
                            showingPreview = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .frame(minWidth: 400, minHeight: 400)
            }
        }
    }
    
    private func loadThumbnails() async {
        // Load first source
        if let firstURL = entry.sourceURLs.first {
             sourceImage = NSImage(contentsOf: firstURL)
        }
        
        // Load output
        outputImage = NSImage(contentsOf: entry.outputURL)
    }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
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

        case "completed": return "checkmark.circle"
        case "processing": return "pause.circle" // Zombie state if we see this icon
        case "cancelled": return "xmark.circle"
        case "failed": return "exclamationmark.triangle"
        default: return "questionmark"
        }
    }
}
