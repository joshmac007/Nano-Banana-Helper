import AppKit
import SwiftUI

struct ResultsView: View {
    var historyManager: HistoryManager
    var projectManager: ProjectManager

    @State private var selectedEntry: HistoryEntry?
    @State private var iconSize: CGFloat = 200

    private var completedEntries: [HistoryEntry] {
        guard let projectID = projectManager.currentProject?.id else { return [] }
        return historyManager.allGlobalEntries.filter {
            $0.projectId == projectID && $0.status == "completed"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Results")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                HStack {
                    Image(systemName: "photo")
                        .font(.caption)
                    Slider(value: $iconSize, in: 100...400)
                        .frame(width: 120)
                    Image(systemName: "photo.fill")
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSize), spacing: 16)], spacing: 16) {
                        ForEach(completedEntries) { entry in
                            if let project = projectManager.projects.first(where: { $0.id == entry.projectId }) {
                                ResultCard(
                                    entry: entry,
                                    project: project,
                                    historyManager: historyManager,
                                    projectManager: projectManager,
                                    size: iconSize
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
                    projectManager: projectManager
                )
            }
        }
    }
}

struct ResultCard: View {
    let entry: HistoryEntry
    let project: Project
    let historyManager: HistoryManager
    let projectManager: ProjectManager
    let size: CGFloat

    @State private var image: NSImage?
    @State private var outputAccessDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size * 3 / 4)
                        .background(Color.black.opacity(0.04))
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: size, height: size * 3 / 4)
                        .overlay {
                            Image(systemName: outputAccessDenied ? "lock.fill" : "photo")
                                .foregroundStyle(.secondary)
                        }
                }

                if outputAccessDenied {
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
        .task(id: outputLoadID) {
            loadOutputImage()
        }
    }

    private var outputLoadID: String {
        "\(entry.id.uuidString)-\(entry.outputImagePath)-\(entry.outputImageBookmark?.base64EncodedString() ?? "none")"
    }

    private func loadOutputImage() {
        switch AppPaths.loadImageData(
            bookmark: entry.outputImageBookmark,
            fallbackPath: entry.outputImagePath
        ) {
        case let .success(data, refreshedBookmark):
            image = NSImage(data: data)
            outputAccessDenied = false
            if let refreshedBookmark {
                historyManager.updateBookmarks(
                    for: entry.id,
                    outputBookmark: refreshedBookmark,
                    sourceBookmarks: entry.sourceImageBookmarks
                )
            }
        case let .fallbackUsed(data):
            image = NSImage(data: data)
            outputAccessDenied = false
        case .accessDenied:
            image = nil
            outputAccessDenied = true
        }
    }

    private func reauthorizeOutput() {
        BookmarkReauthorization.reauthorizeOutputFolder(
            for: project,
            projectManager: projectManager,
            historyManager: historyManager
        )
    }
}

struct ResultDetailView: View {
    let entry: HistoryEntry
    let project: Project
    let historyManager: HistoryManager
    let projectManager: ProjectManager

    @Environment(\.dismiss) private var dismiss

    @State private var outputImage: NSImage?
    @State private var inputImage: NSImage?
    @State private var outputAccessDenied = false
    @State private var sourceAccessDenied = false

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
                if outputAccessDenied {
                    BookmarkAccessDeniedView(
                        message: "Output folder access has expired.",
                        onReauthorize: reauthorizeOutput
                    )
                } else if let outputImage {
                    if sourceAccessDenied {
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
                    } else if let inputImage {
                        ComparisonView(before: inputImage, after: outputImage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding()
                    } else {
                        Image(nsImage: outputImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    }
                } else {
                    ContentUnavailableView("Image Not Found", systemImage: "exclamationmark.triangle")
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
        .task(id: outputLoadID) {
            loadOutputImage()
        }
        .task(id: sourceLoadID) {
            loadSourceImage()
        }
    }

    private var outputLoadID: String {
        "\(entry.id.uuidString)-\(entry.outputImagePath)-\(entry.outputImageBookmark?.base64EncodedString() ?? "none")"
    }

    private var sourceLoadID: String {
        let sourcePath = entry.sourceImagePaths.first ?? ""
        let sourceBookmark = entry.sourceImageBookmarks?.first?.base64EncodedString() ?? "none"
        return "\(entry.id.uuidString)-\(sourcePath)-\(sourceBookmark)"
    }

    private func loadOutputImage() {
        switch AppPaths.loadImageData(
            bookmark: entry.outputImageBookmark,
            fallbackPath: entry.outputImagePath
        ) {
        case let .success(data, refreshedBookmark):
            outputImage = NSImage(data: data)
            outputAccessDenied = false
            if let refreshedBookmark {
                historyManager.updateBookmarks(
                    for: entry.id,
                    outputBookmark: refreshedBookmark,
                    sourceBookmarks: entry.sourceImageBookmarks
                )
            }
        case let .fallbackUsed(data):
            outputImage = NSImage(data: data)
            outputAccessDenied = false
        case .accessDenied:
            outputImage = nil
            outputAccessDenied = true
        }
    }

    private func loadSourceImage() {
        guard let sourcePath = entry.sourceImagePaths.first, !sourcePath.isEmpty else {
            inputImage = nil
            sourceAccessDenied = false
            return
        }

        switch AppPaths.loadImageData(
            bookmark: entry.sourceImageBookmarks?.first,
            fallbackPath: sourcePath
        ) {
        case let .success(data, refreshedBookmark):
            inputImage = NSImage(data: data)
            sourceAccessDenied = false
            if let refreshedBookmark {
                persistRefreshedSourceBookmark(refreshedBookmark, at: 0)
            }
        case let .fallbackUsed(data):
            inputImage = NSImage(data: data)
            sourceAccessDenied = false
        case .accessDenied:
            inputImage = nil
            sourceAccessDenied = true
        }
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

    private func persistRefreshedSourceBookmark(_ refreshedBookmark: Data, at index: Int) {
        guard var updatedSourceBookmarks = entry.sourceImageBookmarks,
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
