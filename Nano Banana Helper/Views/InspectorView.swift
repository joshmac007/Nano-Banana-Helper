import SwiftUI
import AppKit

struct InspectorView: View {
    @Bindable var stagingManager: BatchStagingManager
    var projectManager: ProjectManager
    @Environment(PromptLibrary.self) private var promptLibrary
    @Environment(BatchOrchestrator.self) private var orchestrator

    @State private var showingPresetPopover = false
    @State private var showingSaveSheet = false

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
                    .disabled(!stagingManager.isReadyForGeneration)

                    // Variations Stepper (Text Mode Only)
                    if stagingManager.generationMode == .text {
                        HStack {
                            Text("Variations")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            Spacer()

                            HStack(spacing: 12) {
                                Button(action: { stagingManager.textImageCount -= 1 }) {
                                    Image(systemName: "minus.circle")
                                }
                                .disabled(stagingManager.textImageCount <= Constants.minTextImageVariations)

                                Text("\(stagingManager.textImageCount)")
                                    .font(.system(.body, design: .rounded))
                                    .frame(minWidth: 24)

                                Button(action: { stagingManager.textImageCount += 1 }) {
                                    Image(systemName: "plus.circle")
                                }
                                .disabled(stagingManager.textImageCount >= Constants.maxTextImageVariations)
                            }
                        }
                        .padding(.horizontal)
                    }

                    if let project = projectManager.currentProject {
                        OutputLocationView(project: project) { newURL, newBookmark in
                            project.outputDirectory = newURL.path
                            project.outputDirectoryBookmark = newBookmark
                            projectManager.saveProjects()
                        }
                        .padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        // Semantic Header: Category [Actions]
                        HStack(alignment: .center, spacing: 8) {
                            Text("Prompt")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            Spacer()

                            // Contextual Actions
                            HStack(spacing: 12) {
                                // Load Preset Popover
                                Button(action: { showingPresetPopover = true }) {
                                    Image(systemName: "bookmark.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Browse Presets")
                                .popover(isPresented: $showingPresetPopover) {
                                    PromptPresetPopover(
                                        stagingManager: stagingManager,
                                        project: projectManager.currentProject
                                    )
                                    .frame(width: 320, height: 400)
                                }

                                // Save Preset
                                Button(action: {
                                    showingSaveSheet = true
                                }) {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Save as Preset")
                                .disabled(stagingManager.prompt.isEmpty && stagingManager.systemPrompt.isEmpty)
                            }
                        }
                        .padding(.horizontal, 2)

                        // Stacked Editors: User + System
                        VStack(spacing: 8) {
                            // User prompt editor
                            ZStack(alignment: .topLeading) {
                                if stagingManager.prompt.isEmpty {
                                    Text("Describe how you want to transform this image...")
                                        .foregroundStyle(.tertiary)
                                        .padding(8)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $stagingManager.prompt)
                                    .font(.system(.body, design: .rounded))
                                    .padding(6)
                                    .frame(minHeight: 80, maxHeight: 160)
                            }
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(8)

                            // System prompt editor (with purple tint)
                            ZStack(alignment: .topLeading) {
                                if stagingManager.systemPrompt.isEmpty {
                                    Text("Set behavioral context for the model...")
                                        .foregroundStyle(.tertiary)
                                        .padding(8)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $stagingManager.systemPrompt)
                                    .font(.system(.body, design: .rounded))
                                    .padding(6)
                                    .frame(minHeight: 80, maxHeight: 160)
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.purple.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.purple.opacity(0.12), lineWidth: 1)
                            )
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        // Divider
                        Rectangle()
                            .fill(.quaternary)
                            .frame(height: 1)
                            .padding(.top, 6)
                            .padding(.vertical, 4)

                        // Ratio Selector (keep existing)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Aspect Ratio")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            AspectRatioSelector(selectedRatio: $stagingManager.aspectRatio)
                        }

                        // Size Row (keep existing)
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
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 16) {
                        // Batch Tier Toggle
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Batch Tier")
                                    .font(.system(size: 11, weight: .bold)) // Standardized header
                                    .foregroundStyle(.primary)
                                    .textCase(.uppercase)
                                Text("50% Cost savings.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $stagingManager.isBatchTier)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        // Multi-Input Toggle (Image mode only)
                        if stagingManager.generationMode == .image {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Multi-Input Mode")
                                        .font(.system(size: 11, weight: .bold)) // Standardized header
                                        .foregroundStyle(.primary)
                                        .textCase(.uppercase)
                                    Text("Merge all to 1 output.")
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
                        imageCount: stagingManager.effectiveTaskCount,
                        imageSize: stagingManager.imageSize,
                        isBatchTier: stagingManager.isBatchTier,
                        isMultiInput: stagingManager.isMultiInput,
                        generationMode: stagingManager.generationMode,
                        modelName: AppConfig.load().modelName
                    )
                    .padding(.horizontal)
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 350)
        .background(VisualEffectView(material: .sidebar, blendingMode: .withinWindow))
        .sheet(isPresented: $showingSaveSheet) {
            SavePresetSheet(
                promptLibrary: promptLibrary,
                userPrompt: stagingManager.prompt,
                systemPrompt: stagingManager.systemPrompt
            )
        }
    }

    private var buttonTitle: String {
        switch stagingManager.generationMode {
        case .image:
            return "Start Batch"
        case .text:
            let count = stagingManager.textImageCount
            return count == 1 ? "Generate Image" : "Generate \(count) Images"
        }
    }

    private func startBatch() {
        guard let project = projectManager.currentProject else { return }

        switch stagingManager.generationMode {
        case .image:
            startImageBatch(project: project)
        case .text:
            startTextBatch(project: project)
        }
    }

    private func startImageBatch(project: Project) {
        let batch = BatchJob(
            prompt: stagingManager.prompt,
            systemPrompt: stagingManager.systemPrompt,
            aspectRatio: stagingManager.aspectRatio,
            imageSize: stagingManager.imageSize,
            outputDirectory: project.outputDirectory,
            useBatchTier: stagingManager.isBatchTier,
            projectId: project.id
        )

        // Handle Multi-Input vs Standard Batch
        let tasks: [ImageTask]
        if stagingManager.isMultiInput {
            // All staged files become ONE task with multiple inputs
            let inputPaths = stagingManager.stagedFiles.map { $0.path }
            let inputBookmarks = stagingManager.stagedFiles.compactMap { stagingManager.bookmark(for: $0) }
            tasks = [ImageTask(
                inputPaths: inputPaths,
                inputBookmarks: inputBookmarks.isEmpty ? nil : inputBookmarks
            )]
        } else {
            // Standard: One task per file
            tasks = stagingManager.stagedFiles.map { url in
                ImageTask(
                    inputPath: url.path,
                    inputBookmark: stagingManager.bookmark(for: url)
                )
            }
        }
        batch.tasks = tasks

        orchestrator.enqueue(batch)

        // Clear staging
        withAnimation {
            stagingManager.clearAll()
        }
    }

    private func startTextBatch(project: Project) {
        orchestrator.enqueueTextGeneration(
            prompt: stagingManager.prompt,
            systemPrompt: stagingManager.systemPrompt,
            aspectRatio: stagingManager.aspectRatio,
            imageSize: stagingManager.imageSize,
            outputDirectory: project.outputDirectory,
            useBatchTier: stagingManager.isBatchTier,
            imageCount: stagingManager.textImageCount,
            projectId: project.id
        )

        // Clear prompt after generation
        stagingManager.prompt = ""
    }
}

struct OutputLocationView: View {
    @Bindable var project: Project
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
                            selectNewFolder() // Re-selecting grants permission
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
        let url = project.outputURL
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
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
}
