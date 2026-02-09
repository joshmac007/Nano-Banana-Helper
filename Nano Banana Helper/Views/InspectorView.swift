import SwiftUI
import AppKit

struct InspectorView: View {
    @Bindable var stagingManager: BatchStagingManager
    var projectManager: ProjectManager
    var promptLibrary: PromptLibrary // Injected from parent
    @Environment(BatchOrchestrator.self) private var orchestrator
    
    @State private var showingSavePromptAlert = false
    @State private var newPromptName = ""
    
    let aspectRatios = ["1:1", "16:9", "9:16", "4:3", "3:4"]
    let sizes = ["1K", "2K", "4K"]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Inspector")
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
                    .disabled(stagingManager.isEmpty || stagingManager.prompt.isEmpty)
                    
                    if let project = projectManager.currentProject {
                        OutputLocationView(project: project) { newURL, newBookmark in
                            project.outputDirectory = newURL.path
                            project.outputDirectoryBookmark = newBookmark
                            projectManager.saveProjects()
                        }
                        .padding(.horizontal)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        // Prompt Label + Load Menu
                        HStack {
                            Text("Prompt")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            
                            Menu {
                                if promptLibrary.prompts.isEmpty {
                                    Text("No saved prompts")
                                } else {
                                    ForEach(promptLibrary.prompts) { saved in
                                        Button(saved.name) {
                                            stagingManager.prompt = saved.prompt
                                        }
                                    }
                                }
                            } label: {
                                Label("Load Saved", systemImage: "bookmark")
                                    .font(.caption)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        
                        TextEditor(text: $stagingManager.prompt)
                            .frame(height: 100)
                            .font(.body)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(6)
                        
                        // Save Prompt Button
                        HStack {
                            Spacer()
                            Button("Save as Template") {
                                newPromptName = ""
                                showingSavePromptAlert = true
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .disabled(stagingManager.prompt.isEmpty)
                        }

                        // Divider
                        Rectangle()
                            .fill(.quaternary)
                            .frame(height: 1)
                            .padding(.vertical, 4)
                        
                        // Ratio Row
                        HStack {
                            Text("Ratio")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $stagingManager.aspectRatio) {
                                ForEach(aspectRatios, id: \.self) { Text($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 85)
                        }
                        
                        // Size Row
                        HStack {
                            Text("Size")
                                .foregroundStyle(.secondary)
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
                                    .fontWeight(.medium)
                                Text("50% Cost savings.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $stagingManager.isBatchTier)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        
                        // Multi-Input Toggle
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Multi-Input Mode")
                                    .fontWeight(.medium)
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
                promptLibrary.save(name: newPromptName, prompt: stagingManager.prompt)
            }
            .disabled(newPromptName.isEmpty)
        } message: {
            Text("Enter a name for this prompt to save it for later use.")
        }
    }
    
    private func startBatch() {
        guard let project = projectManager.currentProject else { return }
        
        let batch = BatchJob(
            prompt: stagingManager.prompt,
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
            tasks = [ImageTask(inputPaths: inputPaths)]
        } else {
            // Standard: One task per file
            tasks = stagingManager.stagedFiles.map { url in
                ImageTask(inputPath: url.path)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Output Location")
                .font(.caption)
                .foregroundStyle(.secondary)
            
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
