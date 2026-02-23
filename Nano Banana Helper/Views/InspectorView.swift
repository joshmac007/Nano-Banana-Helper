import SwiftUI
import AppKit

struct InspectorView: View {
    @Bindable var stagingManager: BatchStagingManager
    var projectManager: ProjectManager
    var promptLibrary: PromptLibrary // Injected from parent
    @Environment(BatchOrchestrator.self) private var orchestrator
    
    @State private var showingSavePromptAlert = false
    @State private var newPromptName = ""
    @State private var activePromptTab: PromptType = .user // Tab State
    
    let sizes = ["1K", "2K", "4K"]
    
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
                    .disabled(!stagingManager.canStartBatch)
                    
                    if let project = projectManager.currentProject {
                        OutputLocationView(project: project) { newURL, newBookmark in
                            project.outputDirectory = newURL.path
                            project.outputDirectoryBookmark = newBookmark
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
                        
                        // Ratio Selector
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Aspect Ratio")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            
                            AspectRatioSelector(selectedRatio: $stagingManager.aspectRatio)
                            
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
                        
                        if stagingManager.isEmpty {
                            // Text-To-Image stepper
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Generated Images")
                                        .font(.system(size: 11, weight: .bold)) // Standardized header
                                        .foregroundStyle(.primary)
                                        .textCase(.uppercase)
                                    Text("Number of images to generate.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Stepper("\(stagingManager.textToImageCount)", value: $stagingManager.textToImageCount, in: 1...100)
                            }
                        } else {
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
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    CostEstimatorView(
                        imageCount: stagingManager.count,
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
    }
    
    private func startBatch() {
        guard let project = projectManager.currentProject else { return }
        
        let batch = BatchJob(
            prompt: stagingManager.prompt,
            systemPrompt: stagingManager.systemPrompt,
            aspectRatio: stagingManager.aspectRatio,
            imageSize: stagingManager.imageSize,
            outputDirectory: project.outputDirectory,
            outputDirectoryBookmark: project.outputDirectoryBookmark,
            useBatchTier: stagingManager.isBatchTier,
            projectId: project.id
        )
        
        // Handle Multi-Input vs Standard Batch
        let tasks: [ImageTask]
        if stagingManager.isEmpty {
            tasks = (0..<stagingManager.textToImageCount).map { _ in
                ImageTask(inputPaths: [])
            }
        } else if stagingManager.isMultiInput {
            // All staged files become ONE task with multiple inputs
            let inputPaths = stagingManager.stagedFiles.map { $0.path }
            let inputBookmarks = stagingManager.stagedFiles.compactMap { stagingManager.bookmark(for: $0) }
            // For multi-input, if a mask was provided, we'll arbitrarily use the first one available
            let firstMaskURL = stagingManager.stagedFiles.first { stagingManager.hasMaskEdit(for: $0) }
            let stagedEdit = firstMaskURL.flatMap { stagingManager.stagedMaskEdits[$0] }
            
            tasks = [ImageTask(
                inputPaths: inputPaths,
                inputBookmarks: inputBookmarks.isEmpty ? nil : inputBookmarks,
                maskImageData: stagedEdit?.maskData,
                customPrompt: stagedEdit?.prompt
            )]
        } else {
            // Standard: One task per file
            tasks = stagingManager.stagedFiles.map { url in
                let stagedEdit = stagingManager.stagedMaskEdits[url]
                return ImageTask(
                    inputPath: url.path,
                    inputBookmark: stagingManager.bookmark(for: url),
                    maskImageData: stagedEdit?.maskData,
                    customPrompt: stagedEdit?.prompt
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
