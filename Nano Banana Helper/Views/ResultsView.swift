import SwiftUI

struct ResultsView: View {
    @Environment(BatchOrchestrator.self) private var orchestrator
    @Environment(ProjectManager.self) private var projectManager // Inject ProjectManager
    @State private var selectedTask: ImageTask?
    @State private var imagesPerRow: Double = 3
    @State private var previewHeightRatios: [UUID: CGFloat] = [:]

    private let gridSpacing: CGFloat = 16
    private let gridHorizontalPadding: CGFloat = 16

    private var visibleTasks: [ImageTask] {
        Array(
            orchestrator.completedJobs
                .filter { $0.projectId == projectManager.currentProject?.id }
                .reversed()
        )
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar / Filter Bar
            HStack {
                Text("Recent Results")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                // Images Per Row Slider
                HStack {
                    Image(systemName: "rectangle.grid.1x2")
                        .font(.caption)
                    Slider(value: $imagesPerRow, in: 2...5, step: 1)
                        .frame(width: 120)
                    Image(systemName: "square.grid.3x2")
                        .font(.caption)
                }
                .padding(.horizontal)
            }
            .padding()
            .background(.background.secondary)
            
            Divider()
            
            if orchestrator.completedJobs.isEmpty {
                ContentUnavailableView {
                    Label("No Results Yet", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Completed batch jobs will appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let columnCount = max(1, Int(imagesPerRow.rounded()))
                    let totalSpacing = gridSpacing * CGFloat(columnCount - 1)
                    let totalHorizontalPadding = gridHorizontalPadding * 2
                    let availableWidth = max(
                        1,
                        geometry.size.width - totalSpacing - totalHorizontalPadding
                    )
                    let cardWidth = floor(availableWidth / CGFloat(columnCount))
                    let columns = Array(
                        repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing, alignment: .top),
                        count: columnCount
                    )

                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: gridSpacing) {
                            ForEach(visibleTasks) { task in
                                ResultCard(
                                    task: task,
                                    project: projectManager.currentProject,
                                    size: cardWidth,
                                    fallbackPlaceholderHeightRatio: dominantPreviewHeightRatio,
                                    onPreviewHeightRatioChange: updatePreviewHeightRatio
                                )
                                    .onTapGesture {
                                        selectedTask = task
                                    }
                            }
                        }
                        .padding(.horizontal, gridHorizontalPadding)
                        .padding(.vertical, gridSpacing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $selectedTask) { task in
            ResultDetailView(task: task, project: projectManager.currentProject)
        }
    }

    private var dominantPreviewHeightRatio: CGFloat? {
        let taskIDs = Set(visibleTasks.map(\.id))
        let buckets = previewHeightRatios
            .filter { taskIDs.contains($0.key) }
            .reduce(into: [Int: Int]()) { counts, entry in
                let bucket = Int((entry.value * 1_000).rounded())
                counts[bucket, default: 0] += 1
            }

        guard
            let bestBucket = buckets.max(by: { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key > rhs.key
                }
                return lhs.value < rhs.value
            })?.key
        else {
            return nil
        }

        return CGFloat(bestBucket) / 1_000
    }

    private func updatePreviewHeightRatio(taskID: UUID, ratio: CGFloat?) {
        if let ratio, ratio > 0 {
            previewHeightRatios[taskID] = ratio
        } else {
            previewHeightRatios.removeValue(forKey: taskID)
        }
    }
}

struct ResultCard: View {
    let task: ImageTask
    let project: Project?
    let size: CGFloat
    let fallbackPlaceholderHeightRatio: CGFloat?
    let onPreviewHeightRatioChange: (UUID, CGFloat?) -> Void
    
    @State private var previewImage: NSImage?
    @State private var isLoadingPreview = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image Preview
            ZStack {
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: previewFrameHeight)
                        .background(Color.black.opacity(0.04))
                } else if isLoadingPreview {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: size, height: placeholderFrameHeight)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                        }
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: size, height: placeholderFrameHeight)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
                
                // Hover overlay or status could go here
            }
            // Footer
            HStack {
                Text(task.filename)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
            }
            .padding(8)
            .background(.background.secondary)
        }
        .frame(width: size, alignment: .leading)
        .cornerRadius(8)
        .shadow(radius: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .task(id: previewLoadKey) {
            await loadPreview()
        }
    }

    private var previewLoadKey: String {
        let projectID = project?.id.uuidString ?? "nil"
        let path = task.outputPath ?? "nil"
        return "\(task.id.uuidString)|\(projectID)|\(path)|\(Int(size))"
    }

    private var previewFrameHeight: CGFloat {
        guard
            let previewImage,
            previewImage.size.width > 0,
            previewImage.size.height > 0
        else {
            return placeholderFrameHeight
        }

        return size * (previewImage.size.height / previewImage.size.width)
    }

    private var placeholderFrameHeight: CGFloat {
        size * placeholderHeightRatio
    }

    private var placeholderHeightRatio: CGFloat {
        if let fallbackPlaceholderHeightRatio, fallbackPlaceholderHeightRatio > 0 {
            return fallbackPlaceholderHeightRatio
        }

        guard let aspectRatio = normalizedPlaceholderAspectRatio else {
            return 9 / 16
        }

        let components = aspectRatio
            .split(separator: ":")
            .compactMap { Double($0) }

        guard components.count == 2, components[0] > 0, components[1] > 0 else {
            return 9 / 16
        }

        return CGFloat(components[1] / components[0])
    }

    private var normalizedPlaceholderAspectRatio: String? {
        let rawValue = project?.defaultAspectRatio?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawValue, rawValue.isEmpty == false, rawValue.caseInsensitiveCompare("Auto") != .orderedSame else {
            return nil
        }

        return rawValue
    }

    private func loadPreview() async {
        guard let outputPath = task.outputPath else {
            previewImage = nil
            onPreviewHeightRatioChange(task.id, nil)
            return
        }

        isLoadingPreview = true
        let targetPixelSize = max(1, size * 2)
        let outputBookmark = project?.outputDirectoryBookmark
        let outputDirectory = project?.outputDirectory
        let image = await Task.detached(priority: .utility) {
            PreviewImageLoader.loadImage(
                path: outputPath,
                directoryBookmark: outputBookmark,
                directoryPath: outputDirectory,
                maxPixelSize: targetPixelSize
            )
        }.value
        previewImage = image
        onPreviewHeightRatioChange(task.id, image.flatMap(Self.heightRatio(for:)))
        isLoadingPreview = false
    }

    private static func heightRatio(for image: NSImage) -> CGFloat? {
        guard image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        return image.size.height / image.size.width
    }
}

struct ResultDetailView: View {
    let task: ImageTask
    let project: Project?
    @Environment(\.dismiss) var dismiss
    
    @State private var outputImage: NSImage?
    @State private var inputImage: NSImage?
    @State private var isLoadingImages = true
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding()
            }
            
            if let outputImage {
                VStack {
                    // Comparison Toggle
                    if let inputImage {
                        ComparisonView(before: inputImage, after: outputImage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding()
                    } else {
                        // Fallback if no input available
                        Image(nsImage: outputImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    }
                }
            } else if isLoadingImages {
                ContentUnavailableView {
                    Label("Loading Images", systemImage: "photo")
                } description: {
                    Text("Preparing previews...")
                }
            } else {
                ContentUnavailableView("Image Not Found", systemImage: "exclamationmark.triangle")
            }
            
            HStack {
                if let path = task.outputPath {
                    Button("Open File") {
                        openOutputFile(path: path)
                    }
                    .buttonStyle(.bordered)

                    Button("Show in Finder") {
                        revealOutputFile(path: path)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.bottom)
        }
        .frame(minWidth: 800, minHeight: 600)
        .task(id: imageLoadKey) {
            await loadImages()
        }
    }

    private var imageLoadKey: String {
        let projectID = project?.id.uuidString ?? "nil"
        let outputPath = task.outputPath ?? "nil"
        let inputPath = task.inputPaths.first ?? "nil"
        return "\(task.id.uuidString)|\(projectID)|\(outputPath)|\(inputPath)"
    }

    private func loadImages() async {
        guard let outputPath = task.outputPath else {
            outputImage = nil
            inputImage = nil
            return
        }

        isLoadingImages = true
        let outputBookmark = project?.outputDirectoryBookmark
        let outputDirectory = project?.outputDirectory
        let inputPath = task.inputPaths.first
        let inputBookmark = task.inputBookmarks?.first
        async let loadedOutput: NSImage? = Task.detached(priority: .userInitiated) {
            PreviewImageLoader.loadImage(
                path: outputPath,
                directoryBookmark: outputBookmark,
                directoryPath: outputDirectory
            )
        }.value
        async let loadedInput: NSImage? = Task.detached(priority: .userInitiated) {
            guard let inputPath else { return nil }
            return PreviewImageLoader.loadImage(
                path: inputPath,
                bookmark: inputBookmark
            )
        }.value

        outputImage = await loadedOutput
        inputImage = await loadedInput
        isLoadingImages = false
    }

    private func openOutputFile(path: String) {
        _ = PreviewImageLoader.SecurityScopedFileAccess.withAccessibleURL(
            path: path,
            directoryBookmark: project?.outputDirectoryBookmark,
            directoryPath: project?.outputDirectory
        ) { accessibleURL in
            NSWorkspace.shared.open(accessibleURL)
        }
    }

    private func revealOutputFile(path: String) {
        _ = PreviewImageLoader.SecurityScopedFileAccess.withAccessibleURL(
            path: path,
            directoryBookmark: project?.outputDirectoryBookmark,
            directoryPath: project?.outputDirectory
        ) { accessibleURL in
            NSWorkspace.shared.activateFileViewerSelecting([accessibleURL])
            return true
        }
    }
}

struct ComparisonView: View {
    let before: NSImage
    let after: NSImage
    @State private var sliderValue: CGFloat = 0.5
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background (After Image)
                Image(nsImage: after)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                
                // Foreground (Before Image) - Masked
                Image(nsImage: before)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: geometry.size.width * sliderValue)
                            Spacer()
                        }
                    )
                
                // Slider Handle
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .overlay(
                        Circle()
                            .fill(.white)
                            .frame(width: 24, height: 24)
                            .shadow(radius: 2)
                            .overlay(
                                Image(systemName: "chevron.left.chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.black)
                            )
                    )
                    .position(x: geometry.size.width * sliderValue, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let location = value.location.x
                                sliderValue = min(max(location / geometry.size.width, 0), 1)
                            }
                    )
                
                // Labels
                VStack {
                    Spacer()
                    HStack {
                        Text("Original")
                            .font(.caption)
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)
                            .opacity(sliderValue > 0.1 ? 1 : 0)
                        
                        Spacer()
                        
                        Text("Result")
                            .font(.caption)
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)
                            .opacity(sliderValue < 0.9 ? 1 : 0)
                    }
                    .padding()
                }
            }
        }
        .background(Color.black.opacity(0.1))
    }
}
