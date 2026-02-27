import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Bindable var stagingManager: BatchStagingManager
    var onBrowse: (() -> Void)? = nil
    @State private var isTargeted = false
    
    private let supportedTypes: [UTType] = [.png, .jpeg, .webP, .heic, .heif, .image]
    
    var body: some View {
        VStack(spacing: 16) {
            if stagingManager.isEmpty {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    
                    Text("Drop Images Here")
                        .font(.title2)
                        .fontWeight(.medium)
                    
                    Text("PNG, JPEG, WebP, HEIC • 4K supported")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if let onBrowse {
                        Button(action: onBrowse) {
                            Label("Browse...", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                // Minified File list (Summary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(stagingManager.count) Images Staged")
                            .font(.headline)
                        
                        Spacer()
                        
                        Button(action: { stagingManager.clearAll() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Text("Review them in the Staging Grid")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding()
        .frame(minHeight: 120) // Reduced height as it's just a drop target now
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
                .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: stagingManager.isEmpty ? [8, 4] : []))
        )
        .dropDestination(for: URL.self) { items, _ in
            handleDrop(items)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
    
    private func handleDrop(_ urls: [URL]) {
        var gatheredUrls: [URL] = []
        for url in urls {
            // Check if it's a directory
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // Scan directory for images
                    let images = scanDirectory(url)
                    gatheredUrls.append(contentsOf: images)
                } else if isValidImage(url) {
                    gatheredUrls.append(url)
                }
            }
        }
        
        // Add to manager
        stagingManager.addFilesCapturingBookmarks(gatheredUrls)
    }
    
    private func scanDirectory(_ directory: URL) -> [URL] {
        var result: [URL] = []
        
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        for case let fileURL as URL in enumerator {
            if isValidImage(fileURL) {
                result.append(fileURL)
            }
        }
        
        return result
    }
    
    private func isValidImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "heic", "heif"].contains(ext)
    }
}
