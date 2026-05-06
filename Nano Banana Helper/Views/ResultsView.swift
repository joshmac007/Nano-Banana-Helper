import AppKit
import ImageIO
import SwiftUI

struct ResultsView: View {
    var historyManager: HistoryManager
    var projectManager: ProjectManager
    var onReuse: ((HistoryEntry) -> Void)? = nil

    @State private var selectedEntry: HistoryEntry?
    @State private var imageLoader = ResultsImageLoader()
    @AppStorage("resultsImagesPerRow") private var imagesPerRow: Int = 3

    private var completedEntries: [HistoryEntry] {
        guard let projectID = projectManager.currentProject?.id else { return [] }
        return historyManager.allGlobalEntries.filter {
            $0.projectId == projectID && $0.status == "completed"
        }
    }

    private var clampedImagesPerRow: Int {
        min(max(imagesPerRow, 1), 6)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: clampedImagesPerRow)
    }

    private var activeThumbnailBucket: ThumbnailBucket {
        ThumbnailBucket(imagesPerRow: clampedImagesPerRow)
    }

    private var imagesPerRowBinding: Binding<Double> {
        Binding(
            get: { Double(clampedImagesPerRow) },
            set: { imagesPerRow = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Results")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                HStack {
                    Image(systemName: "square.grid.2x2")
                        .font(.caption)
                    Slider(value: imagesPerRowBinding, in: 1...6, step: 1)
                        .frame(width: 120)
                    Image(systemName: "square.grid.3x3")
                        .font(.caption)
                }
                .padding(.horizontal)
            }
            .padding()
            .background(.background.secondary)

            Divider()

            if completedEntries.isEmpty {
                ContentUnavailableView {
                    Label("No Results Yet", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Completed history entries for this project will appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(completedEntries) { entry in
                            if let project = projectManager.projects.first(where: { $0.id == entry.projectId }) {
                                ResultCard(
                                    entry: entry,
                                    project: project,
                                    historyManager: historyManager,
                                    projectManager: projectManager,
                                    imageLoader: imageLoader,
                                    thumbnailBucket: activeThumbnailBucket
                                )
                                .onTapGesture {
                                    selectedEntry = entry
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $selectedEntry) { entry in
            if let project = projectManager.projects.first(where: { $0.id == entry.projectId }) {
                ResultDetailView(
                    entry: entry,
                    project: project,
                    historyManager: historyManager,
                    projectManager: projectManager,
                    imageLoader: imageLoader,
                    onReuse: onReuse
                )
            }
        }
    }
}

fileprivate struct ResultCard: View {
    let entry: HistoryEntry
    let project: Project
    let historyManager: HistoryManager
    let projectManager: ProjectManager
    let imageLoader: ResultsImageLoader
    let thumbnailBucket: ThumbnailBucket

    @State private var outputPhase: ResultsImagePhase = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    ZStack(alignment: .topTrailing) {
                        if let image = displayOutputPhase.loadedImage {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.black.opacity(0.04))
                        } else if displayOutputPhase.isLoading {
                            ResultsCardLoadingPlaceholder()
                        } else {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.1))
                                .overlay {
                                    Image(systemName: displayOutputPhase.isAccessDenied ? "lock.fill" : "exclamationmark.triangle")
                                        .foregroundStyle(.secondary)
                                }
                        }

                        if displayOutputPhase.isAccessDenied {
                            Button(action: reauthorizeOutput) {
                                Image(systemName: "lock.badge.plus")
                                    .padding(8)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                            .help("Grant access to the output folder")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.04))
                .clipped()

            HStack {
                Text(URL(fileURLWithPath: entry.outputImagePath).lastPathComponent)
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
        .cornerRadius(8)
        .shadow(radius: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .task(id: outputReference.cacheKey) {
            await loadOutputImage()
        }
    }

    private var outputReference: ResultsImageReference {
        ResultsImageReference(
            entryID: entry.id,
            role: .output,
            variant: .thumbnail(bucket: thumbnailBucket),
            fallbackPath: entry.outputImagePath,
            bookmark: entry.outputImageBookmark
        )
    }

    private var displayOutputPhase: ResultsImagePhase {
        if case .loading = outputPhase,
           let cachedPhase = imageLoader.cachedPhase(for: outputReference) {
            return cachedPhase
        }
        return outputPhase
    }

    @MainActor
    private func loadOutputImage() async {
        outputPhase = imageLoader.cachedPhase(for: outputReference) ?? .loading
        let outcome = await imageLoader.load(reference: outputReference)
        guard !Task.isCancelled else { return }
        outputPhase = outcome.phase
        persistRefreshedOutputBookmark(outcome.refreshedBookmark)
    }

    private func reauthorizeOutput() {
        BookmarkReauthorization.reauthorizeOutputFolder(
            for: project,
            projectManager: projectManager,
            historyManager: historyManager
        )
    }

    private func persistRefreshedOutputBookmark(_ refreshedBookmark: Data?) {
        guard let refreshedBookmark else { return }
        historyManager.updateBookmarks(
            for: entry.id,
            outputBookmark: refreshedBookmark,
            sourceBookmarks: entry.sourceImageBookmarks
        )
    }
}

fileprivate struct ResultDetailView: View {
    let entry: HistoryEntry
    let project: Project
    let historyManager: HistoryManager
    let projectManager: ProjectManager
    let imageLoader: ResultsImageLoader
    let onReuse: ((HistoryEntry) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var outputPhase: ResultsImagePhase = .loading
    @State private var sourcePhase: ResultsImagePhase = .idle
    @State private var isComparisonEnabled = false

    var body: some View {
        VStack(spacing: 12) {
            imageStage
                .layoutPriority(1)

            ResultsPromptMetadataView(entry: entry)

            actionBar
        }
        .padding(.top, 36)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .overlay(alignment: .topTrailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(12)
            .help("Close")
        }
        .frame(
            minWidth: 780,
            idealWidth: 980,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 820,
            maxHeight: .infinity
        )
        .background(ResultDetailWindowConfigurator(minSize: NSSize(width: 780, height: 620)))
        .presentationSizing(.fitted.sticky(horizontal: true, vertical: true))
        .task(id: outputReference.cacheKey) {
            await loadOutputImage()
        }
        .task(id: sourceReference?.cacheKey ?? "result-source-\(entry.id.uuidString)-none") {
            await loadSourceImage()
        }
    }

    @ViewBuilder
    private var imageStage: some View {
        Group {
            if displayOutputPhase.isLoading {
                ResultsDetailLoadingState(message: "Loading image...")
            } else if displayOutputPhase.isAccessDenied {
                BookmarkAccessDeniedView(
                    message: "Output folder access has expired.",
                    onReauthorize: reauthorizeOutput
                )
            } else if let outputImage = displayOutputPhase.loadedImage {
                if isComparisonEnabled, hasSourceImage {
                    comparisonStage(for: outputImage)
                } else {
                    fittedImage(outputImage)
                }
            } else {
                ContentUnavailableView("Image Unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 360)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func comparisonStage(for outputImage: NSImage) -> some View {
        if displaySourcePhase.isLoading {
            VStack(spacing: 16) {
                fittedImage(outputImage)
                ResultsDetailLoadingState(message: "Loading original image...")
                    .frame(maxHeight: 96)
            }
            .padding(.bottom, 12)
        } else if displaySourcePhase.isAccessDenied {
            VStack(spacing: 16) {
                fittedImage(outputImage)
                BookmarkAccessDeniedView(
                    message: "Source image access has expired.",
                    onReauthorize: reauthorizeSource
                )
                .frame(maxHeight: 150)
            }
            .padding(.bottom, 12)
        } else if let inputImage = displaySourcePhase.loadedImage {
            ComparisonView(before: inputImage, after: outputImage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displaySourcePhase.isFailed {
            VStack(spacing: 16) {
                fittedImage(outputImage)
                Label("Original image could not be loaded.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: 64)
            }
            .padding(.bottom, 12)
        } else {
            fittedImage(outputImage)
        }
    }

    private func fittedImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Remix in Workbench", action: remixEntry)
                .buttonStyle(.borderedProminent)
                .disabled(onReuse == nil)

            Button("Open File", action: openFile)
                .buttonStyle(.bordered)
                .disabled(entry.outputImagePath.isEmpty)

            Button("Show in Finder", action: revealFile)
                .buttonStyle(.bordered)
                .disabled(entry.outputImagePath.isEmpty)

            Spacer()

            if hasSourceImage {
                Toggle("Comparison", isOn: $isComparisonEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Toggle comparison view")
            }
        }
    }

    private var hasSourceImage: Bool {
        !(entry.sourceImagePaths.first ?? "").isEmpty
    }

    private var outputReference: ResultsImageReference {
        ResultsImageReference(
            entryID: entry.id,
            role: .output,
            variant: .fullResolution,
            fallbackPath: entry.outputImagePath,
            bookmark: entry.outputImageBookmark
        )
    }

    private var sourceReference: ResultsImageReference? {
        guard let sourcePath = entry.sourceImagePaths.first, !sourcePath.isEmpty else { return nil }
        return ResultsImageReference(
            entryID: entry.id,
            role: .sourcePrimary,
            variant: .fullResolution,
            fallbackPath: sourcePath,
            bookmark: entry.sourceImageBookmarks?.first
        )
    }

    private var displayOutputPhase: ResultsImagePhase {
        if case .loading = outputPhase,
           let cachedPhase = imageLoader.cachedPhase(for: outputReference) {
            return cachedPhase
        }
        return outputPhase
    }

    private var displaySourcePhase: ResultsImagePhase {
        guard let sourceReference else { return .idle }
        if case .loading = sourcePhase,
           let cachedPhase = imageLoader.cachedPhase(for: sourceReference) {
            return cachedPhase
        }
        return sourcePhase
    }

    @MainActor
    private func loadOutputImage() async {
        outputPhase = imageLoader.cachedPhase(for: outputReference) ?? .loading
        let outcome = await imageLoader.load(reference: outputReference)
        guard !Task.isCancelled else { return }
        outputPhase = outcome.phase
        persistRefreshedOutputBookmark(outcome.refreshedBookmark)
    }

    @MainActor
    private func loadSourceImage() async {
        guard let sourceReference else {
            sourcePhase = .idle
            return
        }

        sourcePhase = imageLoader.cachedPhase(for: sourceReference) ?? .loading
        let outcome = await imageLoader.load(reference: sourceReference)
        guard !Task.isCancelled else { return }
        sourcePhase = outcome.phase
        persistRefreshedSourceBookmark(outcome.refreshedBookmark, at: 0)
    }

    private func remixEntry() {
        onReuse?(entry)
        dismiss()
    }

    private func openFile() {
        switch AppPaths.openFile(
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
            reauthorizeOutput()
        }
    }

    private func revealFile() {
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
            reauthorizeOutput()
        }
    }

    private func reauthorizeOutput() {
        BookmarkReauthorization.reauthorizeOutputFolder(
            for: project,
            projectManager: projectManager,
            historyManager: historyManager
        )
    }

    private func reauthorizeSource() {
        let suggestedFolderURL = entry.sourceImagePaths.first.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        }
        BookmarkReauthorization.reauthorizeSourceFolder(
            entryIds: [entry.id],
            suggestedFolderURL: suggestedFolderURL,
            historyManager: historyManager
        )
    }

    private func persistRefreshedOutputBookmark(_ refreshedBookmark: Data?) {
        guard let refreshedBookmark else { return }
        historyManager.updateBookmarks(
            for: entry.id,
            outputBookmark: refreshedBookmark,
            sourceBookmarks: entry.sourceImageBookmarks
        )
    }

    private func persistRefreshedSourceBookmark(_ refreshedBookmark: Data?, at index: Int) {
        guard let refreshedBookmark,
              var updatedSourceBookmarks = entry.sourceImageBookmarks,
              updatedSourceBookmarks.indices.contains(index) else {
            return
        }

        updatedSourceBookmarks[index] = refreshedBookmark
        historyManager.updateBookmarks(
            for: entry.id,
            outputBookmark: entry.outputImageBookmark,
            sourceBookmarks: updatedSourceBookmarks
        )
    }
}

private struct ResultsCardLoadingPlaceholder: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.08))
            .overlay {
                ProgressView()
                    .controlSize(.small)
            }
    }
}

private struct ResultsDetailLoadingState: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ResultsPromptMetadataView: View {
    let entry: HistoryEntry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggleExpanded) {
                HStack {
                    Text("Generation Details")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    metadataChip(entry.generationDescription, tint: entry.isTextToImage ? .blue : .secondary)
                    if let modelName = entry.modelName {
                        Text(modelName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: isExpanded ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse generation details" : "Expand generation details")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(entry.prompt)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let systemPrompt = entry.systemPrompt, !systemPrompt.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("System Prompt")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(systemPrompt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    HStack(spacing: 12) {
                        detailBadge("Ratio", entry.aspectRatio)
                        detailBadge("Size", entry.imageSize)
                        detailBadge("Tier", entry.usedBatchTier ? "Batch" : "Standard")
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(12)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isExpanded)
    }

    private func toggleExpanded() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                isExpanded.toggle()
            }
        }
    }

    private func detailBadge(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct ResultDetailWindowConfigurator: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> ConfiguringView {
        ConfiguringView(minSize: minSize)
    }

    func updateNSView(_ nsView: ConfiguringView, context: Context) {
        nsView.minSize = minSize
        nsView.configureWindow()
    }

    final class ConfiguringView: NSView {
        var minSize: NSSize

        init(minSize: NSSize) {
            self.minSize = minSize
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window,
                  window.sheetParent != nil else {
                return
            }

            window.styleMask.insert(.resizable)
            window.minSize = minSize
        }
    }
}

private enum ResultsImageRole: String, Sendable {
    case output
    case sourcePrimary
}

private enum ThumbnailBucket: Int, Sendable {
    case oneUp = 1200
    case twoUp = 800
    case threeUp = 600
    case denseGrid = 400

    init(imagesPerRow: Int) {
        switch imagesPerRow {
        case 1:
            self = .oneUp
        case 2:
            self = .twoUp
        case 3:
            self = .threeUp
        default:
            self = .denseGrid
        }
    }

    var maxPixelSize: Int {
        rawValue
    }

    var cacheKeyFragment: String {
        "thumbnail-\(rawValue)"
    }
}

private enum ResultsImageVariant: Sendable {
    case thumbnail(bucket: ThumbnailBucket)
    case fullResolution

    var cacheKeyFragment: String {
        switch self {
        case let .thumbnail(bucket):
            return bucket.cacheKeyFragment
        case .fullResolution:
            return "full-resolution"
        }
    }
}

private struct ResultsImageReference: Sendable {
    let cacheKey: String
    let fallbackPath: String
    let bookmark: Data?
    let variant: ResultsImageVariant

    init(entryID: UUID, role: ResultsImageRole, variant: ResultsImageVariant, fallbackPath: String, bookmark: Data?) {
        cacheKey = "\(entryID.uuidString)|\(role.rawValue)|\(variant.cacheKeyFragment)|\(fallbackPath)"
        self.fallbackPath = fallbackPath
        self.bookmark = bookmark
        self.variant = variant
    }
}

private enum ResultsImagePhase {
    case idle
    case loading
    case loaded(NSImage)
    case accessDenied
    case failed

    var loadedImage: NSImage? {
        guard case let .loaded(image) = self else { return nil }
        return image
    }

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }

    var isAccessDenied: Bool {
        if case .accessDenied = self {
            return true
        }
        return false
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

private struct ResultsImageLoadOutcome {
    let phase: ResultsImagePhase
    let refreshedBookmark: Data?
}

private enum ThumbnailDecodeResult {
    case decoded(NSImage)
    case failed
}

fileprivate final class ResultsImageLoader {
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let fullResolutionCache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<ResultsImageLoadOutcome, Never>] = [:]

    init() {
        thumbnailCache.countLimit = 160
        thumbnailCache.totalCostLimit = 128 * 1024 * 1024
        fullResolutionCache.countLimit = 16
        fullResolutionCache.totalCostLimit = 96 * 1024 * 1024
    }

    @MainActor
    fileprivate func cachedPhase(for reference: ResultsImageReference) -> ResultsImagePhase? {
        guard let image = cache(for: reference).object(forKey: reference.cacheKey as NSString) else { return nil }
        return .loaded(image)
    }

    @MainActor
    fileprivate func load(reference: ResultsImageReference) async -> ResultsImageLoadOutcome {
        if let cachedPhase = cachedPhase(for: reference) {
            return ResultsImageLoadOutcome(phase: cachedPhase, refreshedBookmark: nil)
        }

        if let task = inFlight[reference.cacheKey] {
            return await task.value
        }

        let task = Task<ResultsImageLoadOutcome, Never>(priority: .utility) { [reference] in
            do {
                try Task.checkCancellation()
                let outcome = try ResultsImageLoader.read(reference: reference)
                try Task.checkCancellation()

                if case let .loaded(image) = outcome.phase {
                    self.cache(image, for: reference)
                }

                return outcome
            } catch is CancellationError {
                return ResultsImageLoadOutcome(phase: .loading, refreshedBookmark: nil)
            } catch {
                return ResultsImageLoadOutcome(phase: .failed, refreshedBookmark: nil)
            }
        }

        inFlight[reference.cacheKey] = task
        defer { inFlight[reference.cacheKey] = nil }
        return await task.value
    }

    @MainActor
    private func cache(_ image: NSImage, for reference: ResultsImageReference) {
        cache(for: reference).setObject(
            image,
            forKey: reference.cacheKey as NSString,
            cost: image.approximateMemoryCost
        )
    }

    @MainActor
    private func cache(for reference: ResultsImageReference) -> NSCache<NSString, NSImage> {
        switch reference.variant {
        case .thumbnail:
            return thumbnailCache
        case .fullResolution:
            return fullResolutionCache
        }
    }

    nonisolated private static func read(reference: ResultsImageReference) throws -> ResultsImageLoadOutcome {
        try Task.checkCancellation()
        switch reference.variant {
        case .fullResolution:
            return try readFullResolution(reference: reference)
        case let .thumbnail(bucket):
            return try readThumbnail(reference: reference, bucket: bucket)
        }
    }

    nonisolated private static func readFullResolution(reference: ResultsImageReference) throws -> ResultsImageLoadOutcome {
        try Task.checkCancellation()
        switch AppPaths.loadImageData(
            bookmark: reference.bookmark,
            fallbackPath: reference.fallbackPath
        ) {
        case let .success(data, refreshedBookmark):
            try Task.checkCancellation()
            guard let image = NSImage(data: data) else {
                return ResultsImageLoadOutcome(phase: .failed, refreshedBookmark: refreshedBookmark)
            }
            return ResultsImageLoadOutcome(phase: .loaded(image), refreshedBookmark: refreshedBookmark)
        case let .fallbackUsed(data):
            try Task.checkCancellation()
            guard let image = NSImage(data: data) else {
                return ResultsImageLoadOutcome(phase: .failed, refreshedBookmark: nil)
            }
            return ResultsImageLoadOutcome(phase: .loaded(image), refreshedBookmark: nil)
        case .accessDenied:
            return ResultsImageLoadOutcome(phase: .accessDenied, refreshedBookmark: nil)
        }
    }

    nonisolated private static func readThumbnail(reference: ResultsImageReference, bucket: ThumbnailBucket) throws -> ResultsImageLoadOutcome {
        try Task.checkCancellation()
        switch AppPaths.withAccessibleURL(
            bookmark: reference.bookmark,
            fallbackPath: reference.fallbackPath,
            operation: { url in
                decodeThumbnail(at: url, maxPixelSize: bucket.maxPixelSize)
            }
        ) {
        case let .success(result, refreshedBookmark):
            return thumbnailOutcome(result, refreshedBookmark: refreshedBookmark)
        case let .fallbackUsed(result):
            return thumbnailOutcome(result, refreshedBookmark: nil)
        case .accessDenied:
            return ResultsImageLoadOutcome(phase: .accessDenied, refreshedBookmark: nil)
        }
    }

    nonisolated private static func thumbnailOutcome(
        _ result: ThumbnailDecodeResult,
        refreshedBookmark: Data?
    ) -> ResultsImageLoadOutcome {
        switch result {
        case let .decoded(image):
            return ResultsImageLoadOutcome(phase: .loaded(image), refreshedBookmark: refreshedBookmark)
        case .failed:
            return ResultsImageLoadOutcome(phase: .failed, refreshedBookmark: refreshedBookmark)
        }
    }

    nonisolated private static func decodeThumbnail(at url: URL, maxPixelSize: Int) -> ThumbnailDecodeResult? {
        try? Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return .failed
        }

        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        try? Task.checkCancellation()
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return .failed
        }

        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return .decoded(NSImage(cgImage: cgImage, size: size))
    }
}
private extension NSImage {
    var approximateMemoryCost: Int {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        return max(width * height * 4, 1)
    }
}

struct ComparisonView: View {
    let before: NSImage
    let after: NSImage
    @State private var sliderValue: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let imageRect = fittedRect(for: after.size, in: geometry.size)
            let dividerX = imageRect.minX + imageRect.width * sliderValue

            ZStack {
                Color.clear

                Image(nsImage: after)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)

                Image(nsImage: before)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: imageRect.width * sliderValue)
                            Spacer(minLength: 0)
                        }
                    )
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)

                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: imageRect.height)
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
                    .position(x: dividerX, y: imageRect.midY)

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
                .frame(width: imageRect.width, height: imageRect.height, alignment: .bottom)
                .position(x: imageRect.midX, y: imageRect.midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        sliderValue = normalizedSliderValue(for: value.location.x, in: imageRect)
                    }
            )
        }
        .padding(12)
    }

    private func fittedRect(for imageSize: NSSize, in containerSize: CGSize) -> CGRect {
        let containerWidth = max(containerSize.width, 1)
        let containerHeight = max(containerSize.height, 1)
        let imageWidth = max(imageSize.width, 1)
        let imageHeight = max(imageSize.height, 1)
        let imageRatio = imageWidth / imageHeight
        let containerRatio = containerWidth / containerHeight

        let fittedSize: CGSize
        if imageRatio > containerRatio {
            fittedSize = CGSize(width: containerWidth, height: containerWidth / imageRatio)
        } else {
            fittedSize = CGSize(width: containerHeight * imageRatio, height: containerHeight)
        }

        return CGRect(
            x: (containerWidth - fittedSize.width) / 2,
            y: (containerHeight - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func normalizedSliderValue(for locationX: CGFloat, in imageRect: CGRect) -> CGFloat {
        guard imageRect.width > 0 else { return sliderValue }
        return min(max((locationX - imageRect.minX) / imageRect.width, 0), 1)
    }
}
