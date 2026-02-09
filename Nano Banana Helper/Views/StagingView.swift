import SwiftUI
import UniformTypeIdentifiers

struct StagingView: View {
    @Bindable var stagingManager: BatchStagingManager
    @State private var isTargeted = false
    @State private var showingFilePicker = false
    
    var body: some View {
        ZStack {
            // Empty State / Drop Zone
            if stagingManager.isEmpty {
                emptyStateView
            } else {
                // Grid View
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)], spacing: 16) {
                        ForEach(stagingManager.stagedFiles, id: \.self) { url in
                            StagedImageCell(url: url) {
                                stagingManager.removeFile(url)
                            }
                        }
                        
                        // Add More Button
                        Button(action: { showingFilePicker = true }) {
                            VStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .font(.largeTitle)
                                Text("Add More")
                                    .font(.caption)
                            }
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(style: Style.dashedBorder)
                                    .foregroundStyle(.secondary)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
            
            // Drop Target Overlay
            if isTargeted {
                Color.accentColor.opacity(0.1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.accentColor, lineWidth: 4)
                            .padding(20)
                    )
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            // Handle Drop
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = await provider.loadFileURL() {
                        urls.append(url)
                    }
                }
                DispatchQueue.main.async {
                    stagingManager.addFiles(urls)
                }
            }
            return true
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                stagingManager.addFiles(urls)
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("Drop Images Here")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("or")
                .foregroundStyle(.secondary)
            
            Button("Browse Files...") {
                showingFilePicker = true
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StagedImageCell: View {
    let url: URL
    let onDelete: () -> Void
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Image Preview (AsyncImage logic or placeholder)
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                Color.secondary.opacity(0.2)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.2)) // Letterbox background
            .cornerRadius(8)
            .clipped()
            
            // Delete Button
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .overlay(
            VStack {
                Spacer()
                Text(url.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
            }
        )
        .cornerRadius(8)
        .shadow(radius: 2)
    }
}

// Helper for dashed border
struct Style {
    static let dashedBorder = StrokeStyle(
        lineWidth: 2,
        lineCap: .round,
        lineJoin: .round,
        dash: [10, 10]
    )
}

extension NSItemProvider {
    func loadFileURL() async -> URL? {
        return await withCheckedContinuation { continuation in
            self.loadItem(forTypeIdentifier: "public.file-url", options: nil) { (item, error) in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
