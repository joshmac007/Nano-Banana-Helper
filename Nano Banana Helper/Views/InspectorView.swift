import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct InspectorView: View {
    @Bindable var stagingManager: BatchStagingManager
    var projectManager: ProjectManager
    var historyManager: HistoryManager
    @Environment(PromptLibrary.self) private var promptLibrary
    @Environment(BatchOrchestrator.self) private var orchestrator
    @State private var showingMaskPicker = false

    let sizes = ImageSize.allCases.map { $0.rawValue }

    var body: some View {
        VStack(spacing: 0) {
            // Header with Mode Toggle
            HStack {
                Text("Configuration")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                // Mode Picker
                Picker("", selection: $stagingManager.generationMode) {
                    ForEach(GenerationMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    // Start Button (Primary Call to Action)
                    Button(action: startBatch) {
                        Text(buttonTitle)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                    .padding(.top)
                    .disabled(!canStartGeneration)

                    HStack {
                        Text("Variations")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Spacer()

                        HStack(spacing: 12) {
                            Button(action: decreaseVariationCount) {
                                Image(systemName: "minus.circle")
                            }
                            .disabled(currentVariationCount <= Constants.minTextImageVariations)

                            Text("\(currentVariationCount)")
                                .font(.system(.body, design: .rounded))
                                .frame(minWidth: 24)

                            Button(action: increaseVariationCount) {
                                Image(systemName: "plus.circle")
                            }
                            .disabled(currentVariationCount >= Constants.maxTextImageVariations)
                        }
                    }
                    .padding(.horizontal)

                    if stagingManager.generationMode == .image && stagingManager.containsPNGInputs && stagingManager.provider == .gemini {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text("PNG inputs are converted to JPEG before upload for Gemini compatibility. Original files stay unchanged.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }

                    if let project = projectManager.currentProject {
                        OutputLocationView(
                            project: project,
                            projectManager: projectManager,
                            historyManager: historyManager
                        ) { newURL, newBookmark in
                            project.outputDirectory = newURL.path
                            project.outputDirectoryBookmark = newBookmark
                            projectManager.saveProjects()
                        }
                        .padding(.horizontal)
                    }

                    // Prompt Bar
                    PromptBarView(stagingManager: stagingManager, project: projectManager.currentProject)
                        .padding(.horizontal)

                    // Ratio Selector
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aspect Ratio")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        AspectRatioSelector(selectedRatio: $stagingManager.aspectRatio)
                    }
                    .padding(.horizontal)

                    // Size Row
                    HStack {
                        Text("Size")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Picker("", selection: $stagingManager.imageSize) {
                            ForEach(sizes, id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 85)
                    }
                    .padding(.horizontal)

                    if stagingManager.generationMode == .image && stagingManager.provider == .openAI {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mask")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.primary)
                                        .textCase(.uppercase)
                                    Text(stagingManager.hasMask ? "Mask applies to the first input image." : "Optional. Same size, format, and alpha channel required.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 8) {
                                    Button(stagingManager.hasMask ? "Replace…" : "Select…") {
                                        showingMaskPicker = true
                                    }
                                    .buttonStyle(.bordered)

                                    if stagingManager.hasMask {
                                        Button("Clear", role: .destructive) {
                                            stagingManager.clearMask()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }

                            if let maskFile = stagingManager.maskFile {
                                Text(maskFile.lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            if !openAIAspectRatioSupported {
                                Text("OpenAI currently supports aspect ratios up to 3:1. Select Auto or a less extreme preset.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Batch Tier")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .textCase(.uppercase)
                                Text(stagingManager.provider == .openAI ? "Deferred for OpenAI in phase 1." : "50% cost savings.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $stagingManager.isBatchTier)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(stagingManager.provider == .openAI)
                        }

                        if stagingManager.generationMode == .image {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Multi-Input Mode")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.primary)
                                        .textCase(.uppercase)
                                    Text(stagingManager.provider == .openAI && stagingManager.hasMask ? "Mask applies to the first input image only." : "Merge all to 1 output.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: $stagingManager.isMultiInput)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                        }
                    }
                    .padding(.horizontal)

                    CostEstimatorView(
                        stagedImageCount: stagingManager.count,
                        variationCount: currentVariationCount,
                        outputCount: stagingManager.expectedOutputCount,
                        imageSize: stagingManager.imageSize,
                        isBatchTier: stagingManager.isBatchTier,
                        isMultiInput: stagingManager.isMultiInput,
                        generationMode: stagingManager.generationMode,
                        modelName: stagingManager.modelName
                    )
                    .padding(.horizontal)

                    // OpenAI Advanced Controls
                    if stagingManager.provider == .openAI {
                        DisclosureGroup(
                            content: {
                                VStack(spacing: 20) {
                                    // Output Format
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Output Format")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.primary)
                                                .textCase(.uppercase)
                                        }
                                        Spacer()
                                        Picker("", selection: $stagingManager.openAIOutputFormat) {
                                            ForEach(OpenAIOutputFormat.allCases) { fmt in
                                                Text(fmt.displayName).tag(fmt)
                                            }
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(width: 150)
                                        .labelsHidden()
                                    }

                                    // Background — only meaningful for transparency-capable formats
                                    if stagingManager.openAIOutputFormat.supportsBackground {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Background")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundStyle(.primary)
                                                    .textCase(.uppercase)
                                                Text("Transparent requires PNG or WebP format.")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Picker("", selection: $stagingManager.openAIBackground) {
                                                ForEach(OpenAIBackground.allCases) { bg in
                                                    Text(bg.displayName).tag(bg)
                                                }
                                            }
                                            .pickerStyle(.segmented)
                                            .frame(width: 150)
                                            .labelsHidden()
                                        }
                                    }

                                    // Input Fidelity — only relevant when editing images
                                    if stagingManager.generationMode == .image {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Input Fidelity")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundStyle(.primary)
                                                    .textCase(.uppercase)
                                                Text("How closely to follow source images.")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Picker("", selection: $stagingManager.openAIInputFidelity) {
                                                ForEach(OpenAIInputFidelity.allCases) { fidelity in
                                                    Text(fidelity.displayName).tag(fidelity)
                                                }
                                            }
                                            .pickerStyle(.segmented)
                                            .frame(width: 100)
                                            .labelsHidden()
                                        }
                                    }

                                    // Output Compression — only for JPEG or WebP
                                    if stagingManager.openAIOutputFormat.supportsCompression {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text("Compression")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundStyle(.primary)
                                                    .textCase(.uppercase)
                                                Spacer()
                                                Text("\(stagingManager.openAIOutputCompression)%")
                                                    .font(.system(.body, design: .rounded))
                                                    .foregroundStyle(.secondary)
                                                    .frame(minWidth: 36, alignment: .trailing)
                                            }
                                            Slider(
                                                value: Binding(
                                                    get: { Double(stagingManager.openAIOutputCompression) },
                                                    set: { stagingManager.openAIOutputCompression = Int($0) }
                                                ),
                                                in: 0...100,
                                                step: 1
                                            )
                                        }
                                    }

                                    // Images per Request (n)
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Images per Request")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.primary)
                                                .textCase(.uppercase)
                                            Text("Up to 4 images per API call.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        HStack(spacing: 12) {
                                            Button(action: { stagingManager.openAINCount = max(1, stagingManager.openAINCount - 1) }) {
                                                Image(systemName: "minus.circle")
                                            }
                                            .disabled(stagingManager.openAINCount <= 1)

                                            Text("\(stagingManager.openAINCount)")
                                                .font(.system(.body, design: .rounded))
                                                .frame(minWidth: 24)

                                            Button(action: { stagingManager.openAINCount = min(4, stagingManager.openAINCount + 1) }) {
                                                Image(systemName: "plus.circle")
                                            }
                                            .disabled(stagingManager.openAINCount >= 4)
                                        }
                                    }
                                }
                                .padding(.top, 12)
                            },
                            label: {
                                Text("Advanced")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                        )
                        .padding(.horizontal)
                    }
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 350)
        .background(VisualEffectView(material: .sidebar, blendingMode: .withinWindow))
        .onAppear {
            stagingManager.refreshProviderSelection()
            if stagingManager.provider == .openAI {
                stagingManager.isBatchTier = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appConfigDidChange)) { _ in
            stagingManager.refreshProviderSelection()
            if stagingManager.provider == .openAI {
                stagingManager.isBatchTier = false
            }
        }
        .fileImporter(
            isPresented: $showingMaskPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            let bookmark = AppPaths.bookmark(for: url)
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
            stagingManager.setMaskFile(url, bookmark: bookmark)
        }

    }

    private var buttonTitle: String {
        let count = max(1, stagingManager.expectedOutputCount)
        switch stagingManager.generationMode {
        case .image:
            if stagingManager.provider == .gemini && stagingManager.isBatchTier {
                return "Start Batch"
            }
            return count == 1 ? "Generate Image" : "Generate \(count) Images"
        case .text:
            return count == 1 ? "Generate Image" : "Generate \(count) Images"
        }
    }

    private var canStartGeneration: Bool {
        stagingManager.isReadyForGeneration &&
        (stagingManager.provider != .openAI || openAIAspectRatioSupported)
    }

    private var openAIAspectRatioSupported: Bool {
        let aspect = AspectRatio.from(string: stagingManager.aspectRatio)
        guard aspect.id != "Auto" else { return true }
        let ratio = Double(aspect.width / aspect.height)
        return ratio <= 3.0 && ratio >= (1.0 / 3.0)
    }

    private func startBatch() {
        guard let project = projectManager.currentProject else { return }
        guard ensureOutputDirectoryAccess(for: project) else { return }

        switch stagingManager.generationMode {
        case .image:
            startImageBatch(project: project)
        case .text:
            startTextBatch(project: project)
        }
    }

    private func ensureOutputDirectoryAccess(for project: Project) -> Bool {
        let fallbackPath = project.outputDirectory == AppPaths.defaultOutputDirectory.path
            ? project.outputDirectory
            : ""
        var capturedError: Error?

        let result = AppPaths.withAccessibleURL(
            bookmark: project.outputDirectoryBookmark,
            fallbackPath: fallbackPath
        ) { directoryURL in
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let probeURL = directoryURL.appendingPathComponent(".nano-banana-write-test-\(UUID().uuidString)")
                try Data().write(to: probeURL)
                try? FileManager.default.removeItem(at: probeURL)
                return true
            } catch {
                capturedError = error
                return nil
            }
        }

        switch result {
        case let .success(_, refreshedBookmark):
            if let refreshedBookmark {
                project.outputDirectoryBookmark = refreshedBookmark
                projectManager.saveProjects()
            }
            return true
        case .fallbackUsed:
            return true
        case .accessDenied:
            if let capturedError {
                print("Output directory access denied before generation: \(capturedError.localizedDescription)")
            }
            BookmarkReauthorization.reauthorizeOutputFolder(
                for: project,
                projectManager: projectManager,
                historyManager: historyManager
            )
            return false
        }
    }

    private func startImageBatch(project: Project) {
        let batch = BatchJob(
            prompt: stagingManager.prompt,
            systemPrompt: stagingManager.systemPrompt,
            aspectRatio: stagingManager.aspectRatio,
            imageSize: stagingManager.imageSize,
            outputDirectory: project.outputDirectory,
            outputDirectoryBookmark: project.outputDirectoryBookmark,
            useBatchTier: stagingManager.isBatchTier,
            projectId: project.id,
            modelName: stagingManager.modelName,
            provider: stagingManager.provider,
            maskImagePath: stagingManager.maskFile?.path,
            maskImageBookmark: stagingManager.maskBookmark,
            openAIOutputFormat: stagingManager.openAIOutputFormat,
            openAIBackground: stagingManager.openAIBackground,
            openAIInputFidelity: stagingManager.openAIInputFidelity,
            openAIOutputCompression: stagingManager.openAIOutputCompression,
            openAINCount: stagingManager.openAINCount
        )

        // Handle Multi-Input vs Standard Batch
        batch.tasks = stagingManager.makeImageTasks()

        orchestrator.enqueue(batch)

        // Clear staging
        withAnimation {
            stagingManager.clearAll()
        }
    }

    private func startTextBatch(project: Project) {
        orchestrator.enqueueTextGeneration(
            provider: stagingManager.provider,
            modelName: stagingManager.modelName,
            prompt: stagingManager.prompt,
            systemPrompt: stagingManager.systemPrompt,
            aspectRatio: stagingManager.aspectRatio,
            imageSize: stagingManager.imageSize,
            outputDirectory: project.outputDirectory,
            outputDirectoryBookmark: project.outputDirectoryBookmark,
            useBatchTier: stagingManager.isBatchTier,
            imageCount: stagingManager.textImageCount,
            projectId: project.id,
            openAIOutputFormat: stagingManager.openAIOutputFormat,
            openAIBackground: stagingManager.openAIBackground,
            openAIInputFidelity: stagingManager.openAIInputFidelity,
            openAIOutputCompression: stagingManager.openAIOutputCompression,
            openAINCount: stagingManager.openAINCount
        )

        // Clear prompt after generation
        stagingManager.prompt = ""
    }

    private var currentVariationCount: Int {
        switch stagingManager.generationMode {
        case .image:
            return stagingManager.imageVariationCount
        case .text:
            return stagingManager.textImageCount
        }
    }

    private func decreaseVariationCount() {
        switch stagingManager.generationMode {
        case .image:
            stagingManager.imageVariationCount -= 1
        case .text:
            stagingManager.textImageCount -= 1
        }
    }

    private func increaseVariationCount() {
        switch stagingManager.generationMode {
        case .image:
            stagingManager.imageVariationCount += 1
        case .text:
            stagingManager.textImageCount += 1
        }
    }
}

struct OutputLocationView: View {
    @Bindable var project: Project
    let projectManager: ProjectManager
    let historyManager: HistoryManager
    var onUpdate: (URL, Data) -> Void

    @State private var isMissing: Bool = false
    @State private var isAccessible: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) { // Tighter spacing
            Text("Output Location")
                .font(.system(size: 11, weight: .bold)) // Standardized header
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack {
                // Status Icon
                Group {
                    if isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .help("Folder does not exist")
                    } else if !isAccessible {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.red)
                            .help("Permission denied or access verification needed")
                    } else {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .frame(width: 16)

                // Path Display
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.outputURL.lastPathComponent)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(project.outputURL.path)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }

                Spacer()

                // Actions Menu
                Menu {
                    Button("Reveal in Finder", action: openInFinder)
                        .disabled(isMissing)

                    Button("Change Location...") {
                        selectNewFolder()
                    }

                    if isMissing {
                        Button("Recreate Folder") {
                            recreateFolder()
                        }
                    }

                    if !isAccessible && !isMissing {
                        Button("Grant Access...") {
                            reauthorizeFolder()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .onAppear { checkStatus() }
        .onChange(of: project) { checkStatus() }
    }

    private func checkStatus() {
        let url = project.outputURL
        var isDir: ObjCBool = false
        isMissing = !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue

        // Simple accessibility check
        isAccessible = FileManager.default.isWritableFile(atPath: url.path) ||
                      (try? url.checkResourceIsReachable()) ?? false
    }

    private func openInFinder() {
        switch AppPaths.revealDirectory(
            bookmark: project.outputDirectoryBookmark,
            fallbackPath: project.outputDirectory
        ) {
        case let .success(_, refreshedBookmark):
            if let refreshedBookmark {
                project.outputDirectoryBookmark = refreshedBookmark
                projectManager.saveProjects()
            }
        case .fallbackUsed:
            break
        case .accessDenied:
            reauthorizeFolder()
        }
    }

    private func selectNewFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an output directory for \(project.name)"
        panel.prompt = "Set Output"

        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = AppPaths.bookmark(for: url) {
                onUpdate(url, bookmark)
                checkStatus()
            }
        }
    }

    private func recreateFolder() {
        let url = project.outputURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            checkStatus()
        } catch {
            print("Failed to recreate folder: \(error)")
        }
    }

    private func reauthorizeFolder() {
        BookmarkReauthorization.reauthorizeOutputFolder(
            for: project,
            projectManager: projectManager,
            historyManager: historyManager
        )
        checkStatus()
    }
}
