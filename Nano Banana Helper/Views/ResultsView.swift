import AppKit
import SwiftUI

struct ResultsView: View {
    var historyManager: HistoryManager
    var projectManager: ProjectManager

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
                                    imageLoader: imageLoader
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
                    imageLoader: imageLoader
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

    @Environment(\.dismiss) private var dismiss

    @State private var outputPhase: ResultsImagePhase = .loading
    @State private var sourcePhase: ResultsImagePhase = .idle

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

            Group {
                if displayOutputPhase.isLoading {
                    ResultsDetailLoadingState(message: "Loading image...")
                } else if displayOutputPhase.isAccessDenied {
                    BookmarkAccessDeniedView(
                        message: "Output folder access has expired.",
                        onReauthorize: reauthorizeOutput
                    )
                } else if let outputImage = displayOutputPhase.loadedImage {
                    if hasSourceImage, displaySourcePhase.isLoading {
                        VStack(spacing: 16) {
                            Image(nsImage: outputImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.horizontal)

                            ResultsDetailLoadingState(message: "Loading original image...")
                                .frame(maxHeight: 120)
                        }
                    } else if displaySourcePhase.isAccessDenied {
                        VStack(spacing: 16) {
                            Image(nsImage: outputImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.horizontal)

                            BookmarkAccessDeniedView(
                                message: "Source image access has expired.",
                                onReauthorize: reauthorizeSource
                            )
                        }
                    } else if let inputImage = displaySourcePhase.loadedImage {
                        ComparisonView(before: inputImage, after: outputImage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding()
                    } else if hasSourceImage, displaySourcePhase.isFailed {
                        VStack(spacing: 16) {
                            Image(nsImage: outputImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.horizontal)

                            Label("Original image could not be loaded.", systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(nsImage: outputImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    }
                } else {
                    ContentUnavailableView("Image Unavailable", systemImage: "exclamationmark.triangle")
                }
            }

            HStack {
                Button("Open File", action: openFile)
                    .buttonStyle(.bordered)
                    .disabled(entry.outputImagePath.isEmpty)

                Button("Show in Finder", action: revealFile)
                    .buttonStyle(.bordered)
                    .disabled(entry.outputImagePath.isEmpty)
            }
            .padding(.bottom)
        }
        .frame(minWidth: 800, minHeight: 600)
        .task(id: outputReference.cacheKey) {
            await loadOutputImage()
        }
        .task(id: sourceReference?.cacheKey ?? "result-source-\(entry.id.uuidString)-none") {
            await loadSourceImage()
        }
    }

    private var hasSourceImage: Bool {
        !(entry.sourceImagePaths.first ?? "").isEmpty
    }

    private var outputReference: ResultsImageReference {
        ResultsImageReference(
            entryID: entry.id,
            role: .output,
            fallbackPath: entry.outputImagePath,
            bookmark: entry.outputImageBookmark
        )
    }

    private var sourceReference: ResultsImageReference? {
        guard let sourcePath = entry.sourceImagePaths.first, !sourcePath.isEmpty else { return nil }
        return ResultsImageReference(
            entryID: entry.id,
            role: .sourcePrimary,
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
        sourcePhase = outcome.phase
        persistRefreshedSourceBookmark(outcome.refreshedBookmark, at: 0)
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

private enum ResultsImageRole: String, Sendable {
    case output
    case sourcePrimary
}

private struct ResultsImageReference: Sendable {
    let cacheKey: String
    let fallbackPath: String
    let bookmark: Data?

    init(entryID: UUID, role: ResultsImageRole, fallbackPath: String, bookmark: Data?) {
        cacheKey = "\(entryID.uuidString)|\(role.rawValue)|\(fallbackPath)"
        self.fallbackPath = fallbackPath
        self.bookmark = bookmark
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

private enum ResultsImageReadResult: Sendable {
    case success(Data, refreshedBookmark: Data?)
    case fallbackUsed(Data)
    case accessDenied
}

fileprivate final class ResultsImageLoader {
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 120
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    fileprivate func cachedPhase(for reference: ResultsImageReference) -> ResultsImagePhase? {
        guard let image = cache.object(forKey: reference.cacheKey as NSString) else { return nil }
        return .loaded(image)
    }

    fileprivate func load(reference: ResultsImageReference) async -> ResultsImageLoadOutcome {
        if let cachedPhase = cachedPhase(for: reference) {
            return ResultsImageLoadOutcome(phase: cachedPhase, refreshedBookmark: nil)
        }

        let readResult = await Task.detached(priority: .utility) {
            ResultsImageLoader.read(reference: reference)
        }.value

        switch readResult {
        case let .success(data, refreshedBookmark):
            guard let image = NSImage(data: data) else {
                return ResultsImageLoadOutcome(phase: .failed, refreshedBookmark: refreshedBookmark)
            }
            cache(image, for: reference)
            return ResultsImageLoadOutcome(phase: .loaded(image), refreshedBookmark: refreshedBookmark)
        case let .fallbackUsed(data):
            guard let image = NSImage(data: data) else {
                return ResultsImageLoadOutcome(phase: .failed, refreshedBookmark: nil)
            }
            cache(image, for: reference)
            return ResultsImageLoadOutcome(phase: .loaded(image), refreshedBookmark: nil)
        case .accessDenied:
            return ResultsImageLoadOutcome(phase: .accessDenied, refreshedBookmark: nil)
        }
    }

    private func cache(_ image: NSImage, for reference: ResultsImageReference) {
        cache.setObject(
            image,
            forKey: reference.cacheKey as NSString,
            cost: image.approximateMemoryCost
        )
    }

    nonisolated private static func read(reference: ResultsImageReference) -> ResultsImageReadResult {
        switch AppPaths.loadImageData(
            bookmark: reference.bookmark,
            fallbackPath: reference.fallbackPath
        ) {
        case let .success(data, refreshedBookmark):
            return .success(data, refreshedBookmark: refreshedBookmark)
        case let .fallbackUsed(data):
            return .fallbackUsed(data)
        case .accessDenied:
            return .accessDenied
        }
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
            ZStack {
                Image(nsImage: after)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)

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
