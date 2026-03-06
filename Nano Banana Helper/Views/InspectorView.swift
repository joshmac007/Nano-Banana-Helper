import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InspectorView: View {
    @Bindable var stagingManager: BatchStagingManager
    var projectManager: ProjectManager
    var promptLibrary: PromptLibrary // Injected from parent
    @Environment(BatchOrchestrator.self) private var orchestrator
    
    @State private var showingSavePromptAlert = false
    @State private var showingBatchStartAlert = false
    @State private var batchStartAlertMessage = "Batch start is blocked by current settings."
    @State private var batchStartAlertOffersFileReselect = false
    @State private var newPromptName = ""
    @State private var activePromptTab: PromptType = .user // Tab State

    private var modelDefinitions: [ModelDefinition] { ModelCatalog.all }
    private var sizes: [String] { stagingManager.availableImageSizes }
    private var allowedAspectRatioSet: Set<String> { Set(stagingManager.availableAspectRatios) }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Configuration")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(spacing: 24) {
                    let canStart = stagingManager.canStartBatch
                    let payloadWarning = stagingManager.batchPayloadPreflightWarning
                    
                    // Start Button (Primary Call to Action)
                    Button(action: startBatch) {
                        Text("Start Batch")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                    .padding(.top)
                    .disabled(!canStart)

                    if let warning = payloadWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .cornerRadius(4)
                            .padding(.horizontal)
                    }
                    
                    if let project = projectManager.currentProject {
                        OutputLocationView(project: project) { newURL, newBookmark in
                            project.outputDirectory = newURL.path
                            project.outputDirectoryBookmark = newBookmark
                            project.invalidateOutputPathCache()
                            projectManager.saveProjects()
                        }
                        .padding(.horizontal)
                    }
                    
                    VStack(alignment: .leading, spacing: 10) {
                        // Semantic Header: Category [Mode Selector] [Actions]
                        HStack(alignment: .center, spacing: 8) {
                            Text("Prompt")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            
                            // Custom Pill Selector
                            HStack(spacing: 0) {
                                Button(action: { activePromptTab = .user }) {
                                    Text("User")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(activePromptTab == .user ? Color.blue : Color.clear)
                                        .foregroundColor(activePromptTab == .user ? .white : .secondary)
                                        .cornerRadius(4) // Pill shape
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { activePromptTab = .system }) {
                                    Text("System")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(activePromptTab == .system ? Color.blue : Color.clear)
                                        .foregroundColor(activePromptTab == .system ? .white : .secondary)
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                            .background(Color.secondary.opacity(0.1)) // Track background
                            .cornerRadius(4)
                            
                            Spacer()
                            
                            // Contextual Actions
                            HStack(spacing: 12) {
                                // Load Template Action
                                Menu {
                                    let prompts = activePromptTab == .user ? promptLibrary.userPrompts : promptLibrary.systemPrompts
                                    if prompts.isEmpty {
                                        Text("No saved templates")
                                    } else {
                                        ForEach(prompts) { saved in
                                            Button(saved.name) {
                                                if activePromptTab == .user {
                                                    stagingManager.prompt = saved.prompt
                                                } else {
                                                    stagingManager.systemPrompt = saved.prompt
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "bookmark.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Load Template")
                                
                                // Save Template Action (Custom Floppy Icon)
                                Button(action: {
                                    newPromptName = ""
                                    showingSavePromptAlert = true
                                }) {
                                    FloppyIcon(size: 13)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Save Template")
                                .disabled((activePromptTab == .user ? stagingManager.prompt : stagingManager.systemPrompt).isEmpty)
                            }
                        }
                        .padding(.horizontal, 2)
                        
                        // Editor Surface
                        ZStack(alignment: .topLeading) {
                            if activePromptTab == .user {
                                TextEditor(text: $stagingManager.prompt)
                                    .frame(minHeight: 80, maxHeight: 120)
                                    .font(.system(.body, design: .rounded))
                                    .padding(6)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .cornerRadius(8)
                            } else {
                                TextEditor(text: $stagingManager.systemPrompt)
                                    .frame(minHeight: 80, maxHeight: 120)
                                    .font(.system(.body, design: .rounded))
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.purple.opacity(0.04))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.purple.opacity(0.12), lineWidth: 1)
                                    )
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        // Divider
                        Rectangle()
                            .fill(.quaternary)
                            .frame(height: 1)
                            .padding(.top, 6)
                            .padding(.vertical, 4)

                        // Model Selector
                        HStack {
                            Text("Model")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Spacer()
                            Picker("", selection: $stagingManager.selectedModelName) {
                                ForEach(modelDefinitions) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 190)
                        }
                        
                        // Ratio Selector
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Aspect Ratio")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            
                            AspectRatioSelector(
                                selectedRatio: $stagingManager.aspectRatio,
                                allowedRatioIDs: allowedAspectRatioSet
                            )
                            
                            if stagingManager.isEmpty && stagingManager.aspectRatio == "Auto" && !stagingManager.prompt.isEmpty {
                                Label("Aspect ratio required for Text-to-Image", systemImage: "info.circle.fill")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundStyle(.orange)
                                    .cornerRadius(4)
                            }
                        }
                        
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

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Generations")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .textCase(.uppercase)
                                Text("Outputs per input (or per merged request).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Stepper("\(stagingManager.generationCount)", value: $stagingManager.generationCount, in: 1...8)
                        }

                        if !stagingManager.isEmpty {
                            // Multi-Input Toggle
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
                                    .disabled(stagingManager.hasAnyRegionEdits)
                            }
                            
                            if stagingManager.hasAnyRegionEdits {
                                Label("Region Edit is only available in standard batch mode.", systemImage: "info.circle.fill")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundStyle(.orange)
                                    .cornerRadius(4)
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    CostEstimatorView(
                        modelName: stagingManager.selectedModelName,
                        stagedInputCount: stagingManager.stagedFiles.count,
                        generationCount: stagingManager.generationCount,
                        inputCount: stagingManager.estimatedInputCountForCost,
                        outputCount: stagingManager.estimatedOutputCountForCost,
                        imageSize: stagingManager.imageSize,
                        isBatchTier: stagingManager.isBatchTier,
                        isMultiInput: stagingManager.isMultiInput
                    )
                    .padding(.horizontal)
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 350)
        .background(VisualEffectView(material: .sidebar, blendingMode: .withinWindow))
        .alert("Save Prompt Template", isPresented: $showingSavePromptAlert) {
            TextField("Template Name", text: $newPromptName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if activePromptTab == .user {
                    promptLibrary.save(name: newPromptName, prompt: stagingManager.prompt, type: .user)
                } else {
                    promptLibrary.save(name: newPromptName, prompt: stagingManager.systemPrompt, type: .system)
                }
            }
            .disabled(newPromptName.isEmpty)
        } message: {
            Text(activePromptTab == .user ? "Enter a name for this user prompt." : "Enter a name for this system prompt.")
        }
        .alert("Cannot Start Batch", isPresented: $showingBatchStartAlert) {
            if batchStartAlertOffersFileReselect {
                Button("Re-select Files...") {
                    reselectStagedFiles()
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(batchStartAlertMessage)
        }
        .onAppear {
            stagingManager.sanitizeSelectionsForCurrentModel()
        }
    }
    
    private func startBatch() {
        guard let project = projectManager.currentProject else { return }
        if let _ = stagingManager.startBlockReason {
            batchStartAlertMessage = stagingManager.startBlockReason ?? "Batch start is blocked by current settings."
            batchStartAlertOffersFileReselect = false
            showingBatchStartAlert = true
            return
        }

        let missingInputBookmarkPaths = stagingManager.stagedFiles
            .filter { stagingManager.bookmark(for: $0) == nil && AppPaths.requiresSecurityScope(path: $0.path) }
            .map { $0.lastPathComponent }
        if !missingInputBookmarkPaths.isEmpty {
            let sample = missingInputBookmarkPaths.prefix(3).joined(separator: ", ")
            let suffix = missingInputBookmarkPaths.count > 3 ? " (+\(missingInputBookmarkPaths.count - 3) more)" : ""
            batchStartAlertMessage = "Some staged files are missing sandbox access bookmarks: \(sample)\(suffix). Re-add them using Browse Files or drag them in again, then retry."
            batchStartAlertOffersFileReselect = true
            showingBatchStartAlert = true
            return
        }

        if project.outputDirectoryBookmark == nil && AppPaths.requiresSecurityScope(path: project.outputDirectory) {
            batchStartAlertMessage = "The selected output folder needs permission again. Re-select Output Location and retry."
            batchStartAlertOffersFileReselect = false
            showingBatchStartAlert = true
            return
        }

        let sanitizedAspectRatio = ModelCatalog.sanitizeAspectRatio(
            stagingManager.aspectRatio,
            for: stagingManager.selectedModelName
        )
        if sanitizedAspectRatio != stagingManager.aspectRatio {
            DebugLog.warning("ui.inspector", "Aspect ratio adjusted for selected model", metadata: [
                "model": stagingManager.selectedModelName,
                "from_ratio": stagingManager.aspectRatio,
                "to_ratio": sanitizedAspectRatio
            ])
            stagingManager.aspectRatio = sanitizedAspectRatio
        }

        let sanitizedImageSize = ModelCatalog.sanitizeImageSize(
            stagingManager.imageSize,
            for: stagingManager.selectedModelName
        )
        if sanitizedImageSize != stagingManager.imageSize {
            DebugLog.warning("ui.inspector", "Image size adjusted for selected model", metadata: [
                "model": stagingManager.selectedModelName,
                "from_size": stagingManager.imageSize,
                "to_size": sanitizedImageSize
            ])
            stagingManager.imageSize = sanitizedImageSize
        }

        guard ModelCatalog.isAspectRatioSupported(stagingManager.aspectRatio, for: stagingManager.selectedModelName),
              ModelCatalog.isImageSizeSupported(stagingManager.imageSize, for: stagingManager.selectedModelName) else {
            batchStartAlertMessage = "The selected model does not support the chosen aspect ratio or output size."
            showingBatchStartAlert = true
            return
        }
        
        let batch = BatchJob(
            prompt: stagingManager.prompt,
            systemPrompt: stagingManager.systemPrompt,
            modelName: stagingManager.selectedModelName,
            aspectRatio: stagingManager.aspectRatio,
            imageSize: stagingManager.imageSize,
            outputDirectory: project.outputDirectory,
            outputDirectoryBookmark: project.outputDirectoryBookmark,
            useBatchTier: stagingManager.isBatchTier,
            projectId: project.id
        )
        let preflightEstimate = PricingEngine.estimate(
            modelName: stagingManager.selectedModelName,
            imageSize: stagingManager.imageSize,
            isBatchTier: stagingManager.isBatchTier,
            inputCount: stagingManager.estimatedInputCountForCost,
            outputCount: stagingManager.estimatedOutputCountForCost
        )
        DebugLog.info("ui.inspector", "Starting batch", metadata: [
            "model": stagingManager.selectedModelName,
            "aspect_ratio": stagingManager.aspectRatio,
            "image_size": stagingManager.imageSize,
            "batch_tier": String(stagingManager.isBatchTier),
            "generation_count": String(stagingManager.generationCount),
            "estimated_outputs": String(stagingManager.estimatedOutputCountForCost),
            "estimated_cost": String(preflightEstimate.total)
        ])
        batch.tasks = stagingManager.buildTasksForCurrentConfiguration()
        
        orchestrator.enqueue(batch)
        
        // Clear staging
        withAnimation {
            stagingManager.clearAll()
        }
    }

    private func reselectStagedFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Re-select source files so Nano Banana Helper can access them."
        panel.prompt = "Grant Access"
        if let firstPath = stagingManager.stagedFiles.first?.path {
            panel.directoryURL = URL(fileURLWithPath: firstPath).deletingLastPathComponent()
        }

        guard panel.runModal() == .OK else { return }

        let addResult = stagingManager.addFilesCapturingBookmarks(panel.urls)
        if addResult.hasRejections {
            let names = addResult.rejectedFiles.map { $0.url.lastPathComponent }
            let sample = names.prefix(3).joined(separator: ", ")
            let suffix = names.count > 3 ? " (+\(names.count - 3) more)" : ""
            batchStartAlertMessage = "Access is still missing for: \(sample)\(suffix). Try re-selecting from Finder."
            batchStartAlertOffersFileReselect = true
            showingBatchStartAlert = true
            return
        }

        batchStartAlertOffersFileReselect = false
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
        
        // Prefer validating the persisted bookmark when present. A plain path check can
        // appear reachable even when sandbox access has expired.
        // FIX: Use resolveBookmarkToPath instead of resolveBookmarkAccess to avoid 
        // interrupting an active scope held by BatchOrchestrator.
        if let bookmark = project.outputDirectoryBookmark {
            guard let resolvedPath = AppPaths.resolveBookmarkToPath(bookmark) else {
                isAccessible = false
                DebugLog.warning("ui.output_location", "Output bookmark no longer resolves", metadata: [
                    "project_id": project.id.uuidString,
                    "path": project.outputDirectory
                ])
                return
            }
            
            isAccessible = FileManager.default.isWritableFile(atPath: resolvedPath) ||
                ((try? URL(fileURLWithPath: resolvedPath).checkResourceIsReachable()) ?? false)
            return
        }
        
        isAccessible = FileManager.default.isWritableFile(atPath: url.path) ||
            ((try? url.checkResourceIsReachable()) ?? false)
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
                DebugLog.info("ui.output_location", "User selected new output folder", metadata: [
                    "project_id": project.id.uuidString,
                    "path": url.path
                ])
                onUpdate(url, bookmark)
                checkStatus()
            } else {
                DebugLog.error("ui.output_location", "Failed to create bookmark for selected output folder", metadata: [
                    "project_id": project.id.uuidString,
                    "path": url.path
                ])
            }
        }
    }
    
    private func recreateFolder() {
        let url = project.outputURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            DebugLog.info("ui.output_location", "Recreated output folder", metadata: [
                "project_id": project.id.uuidString,
                "path": url.path
            ])
            checkStatus()
        } catch {
            DebugLog.error("ui.output_location", "Failed to recreate output folder", metadata: [
                "project_id": project.id.uuidString,
                "path": url.path,
                "error": String(describing: error)
            ])
            print("Failed to recreate folder: \(error)")
        }
    }
}

// MARK: - Custom Icons

struct FloppyIcon: View {
    var size: CGFloat = 16
    
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let scale = w / 16.0
            
            var path1 = Path()
            path1.move(to: CGPoint(x: 0, y: 1.5 * scale))
            path1.addCurve(to: CGPoint(x: 1.5 * scale, y: 0), control1: CGPoint(x: 0, y: 0.67 * scale), control2: CGPoint(x: 0.67 * scale, y: 0))
            path1.addLine(to: CGPoint(x: 3 * scale, y: 0))
            path1.addLine(to: CGPoint(x: 3 * scale, y: 5.5 * scale))
            path1.addCurve(to: CGPoint(x: 4.5 * scale, y: 7 * scale), control1: CGPoint(x: 3 * scale, y: 6.33 * scale), control2: CGPoint(x: 3.67 * scale, y: 7 * scale))
            path1.addLine(to: CGPoint(x: 11.5 * scale, y: 7 * scale))
            path1.addCurve(to: CGPoint(x: 13 * scale, y: 5.5 * scale), control1: CGPoint(x: 12.33 * scale, y: 7 * scale), control2: CGPoint(x: 13 * scale, y: 6.33 * scale))
            path1.addLine(to: CGPoint(x: 13 * scale, y: 0))
            path1.addLine(to: CGPoint(x: 13.086 * scale, y: 0))
            path1.addCurve(to: CGPoint(x: 14.146 * scale, y: 0.44 * scale), control1: CGPoint(x: 13.483 * scale, y: 0), control2: CGPoint(x: 13.861 * scale, y: 0.158 * scale))
            path1.addLine(to: CGPoint(x: 15.56 * scale, y: 1.854 * scale))
            path1.addCurve(to: CGPoint(x: 16 * scale, y: 2.914 * scale), control1: CGPoint(x: 15.842 * scale, y: 2.139 * scale), control2: CGPoint(x: 16 * scale, y: 2.517 * scale))
            path1.addLine(to: CGPoint(x: 16 * scale, y: 14.5 * scale))
            path1.addCurve(to: CGPoint(x: 14.5 * scale, y: 16 * scale), control1: CGPoint(x: 16 * scale, y: 15.328 * scale), control2: CGPoint(x: 15.328 * scale, y: 16 * scale))
            path1.addLine(to: CGPoint(x: 14 * scale, y: 16 * scale))
            path1.addLine(to: CGPoint(x: 14 * scale, y: 10.5 * scale))
            path1.addCurve(to: CGPoint(x: 12.5 * scale, y: 9 * scale), control1: CGPoint(x: 14 * scale, y: 9.672 * scale), control2: CGPoint(x: 13.328 * scale, y: 9 * scale))
            path1.addLine(to: CGPoint(x: 3.5 * scale, y: 9 * scale))
            path1.addCurve(to: CGPoint(x: 2 * scale, y: 10.5 * scale), control1: CGPoint(x: 2.672 * scale, y: 9 * scale), control2: CGPoint(x: 2 * scale, y: 9.672 * scale))
            path1.addLine(to: CGPoint(x: 2 * scale, y: 16 * scale))
            path1.addLine(to: CGPoint(x: 1.5 * scale, y: 16 * scale))
            path1.addCurve(to: CGPoint(x: 0 * scale, y: 14.5 * scale), control1: CGPoint(x: 0.672 * scale, y: 16 * scale), control2: CGPoint(x: 0 * scale, y: 15.328 * scale))
            path1.closeSubpath()
            
            var path2 = Path()
            path2.move(to: CGPoint(x: 3 * scale, y: 16 * scale))
            path2.addLine(to: CGPoint(x: 13 * scale, y: 16 * scale))
            path2.addLine(to: CGPoint(x: 13 * scale, y: 10.5 * scale))
            path2.addCurve(to: CGPoint(x: 12.5 * scale, y: 10 * scale), control1: CGPoint(x: 13 * scale, y: 10.224 * scale), control2: CGPoint(x: 12.776 * scale, y: 10 * scale))
            path2.addLine(to: CGPoint(x: 3.5 * scale, y: 10 * scale))
            path2.addCurve(to: CGPoint(x: 3 * scale, y: 10.5 * scale), control1: CGPoint(x: 3.224 * scale, y: 10 * scale), control2: CGPoint(x: 3 * scale, y: 10.224 * scale))
            path2.closeSubpath()
            
            var path3 = Path()
            path3.move(to: CGPoint(x: 12 * scale, y: 0 * scale))
            path3.addLine(to: CGPoint(x: 4 * scale, y: 0 * scale))
            path3.addLine(to: CGPoint(x: 4 * scale, y: 5.5 * scale))
            path3.addCurve(to: CGPoint(x: 4.5 * scale, y: 6 * scale), control1: CGPoint(x: 4 * scale, y: 5.776 * scale), control2: CGPoint(x: 4.224 * scale, y: 6 * scale))
            path3.addLine(to: CGPoint(x: 11.5 * scale, y: 6 * scale))
            path3.addCurve(to: CGPoint(x: 12 * scale, y: 5.5 * scale), control1: CGPoint(x: 11.776 * scale, y: 6 * scale), control2: CGPoint(x: 12 * scale, y: 5.776 * scale))
            path3.closeSubpath()
            
            var path4 = Path()
            path4.addRect(CGRect(x: 9 * scale, y: 1 * scale, width: 2 * scale, height: 4 * scale))
            
            context.fill(path1, with: .color(.primary))
            context.fill(path2, with: .color(.primary))
            context.fill(path3, with: .color(.primary))
            context.fill(path4, with: .color(.primary))
        }
        .frame(width: size, height: size)
    }
}
