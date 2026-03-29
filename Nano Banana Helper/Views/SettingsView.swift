import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var isSaving: Bool = false
    @State private var statusMessage: String = ""
    @State private var hasExistingKey: Bool = false
    @State private var isLoaded: Bool = false
    @State private var selectedTab: SettingsTab = .api
    @State private var selectedModel: String = "gemini-3.1-flash-image-preview"
    @State private var selectedPromptTag: String = "all"
    @State private var showingAddTagAlert = false
    @State private var showingRenameTagAlert = false
    @State private var newTagName = ""
    @State private var tagNameToRename: String? = nil
    @State private var editingPreset: PromptPreset? = nil

    @Environment(ProjectManager.self) private var projectManager
    @Environment(PromptLibrary.self) private var promptLibrary
    @Environment(\.dismiss) private var dismiss
    
    enum SettingsTab: String, CaseIterable {
        case api = "API"
        case projects = "Projects"
        case prompts = "Prompts"
        case usage = "Usage"
        case about = "About"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            
            Divider()
            
            ScrollView {
                switch selectedTab {
                case .api:
                    apiSection
                case .projects:
                    projectsSection
                case .prompts:
                    promptsSection
                case .usage:
                    UsageDashboardView()
                case .about:
                    aboutSection
                }
            }
        }
        .frame(width: 500, height: 650)
        .onAppear {
            if !isLoaded {
                checkExistingKey()
                loadCurrentModel()
                isLoaded = true
            }
        }
    }
    
    private var apiSection: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    // API Key Row
                    HStack(alignment: .center) {
                        Text("Gemini API Key")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        // Input + Eye Button Container
                        HStack(alignment: .center, spacing: 12) {
                            // Custom Field Container
                            ZStack(alignment: .leading) {
                                SecureField("", text: $apiKey)
                                    .textFieldStyle(.plain)
                                    .opacity(showKey ? 0 : 1)
                                    .disabled(showKey)
                                
                                TextField("", text: $apiKey)
                                    .textFieldStyle(.plain)
                                    .opacity(showKey ? 1 : 0)
                                    .disabled(!showKey)
                                    .offset(y: -1.0) // Correct macOS baseline shift
                            }
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 8)
                            .frame(width: 250, height: 28)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                            )
                            
                            Button(action: toggleKeyVisibility) {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // Model Selection Row
                    HStack(alignment: .center) {
                        Text("Image Model")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Picker("", selection: $selectedModel) {
                            Text("Nano Banana 2 (Default)").tag("gemini-3.1-flash-image-preview")
                            Text("Nano Banana (Stable)").tag("gemini-2.5-flash-image-preview")
                            Text("Nano Banana Pro (Legacy)").tag("gemini-3-pro-image-preview")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                        .onChange(of: selectedModel) { _, newValue in
                            saveModelSelection(newValue)
                        }
                    }
                    
                    // Status Messages
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusMessage.contains("Error") ? .red : .green)
                            .frame(height: 14)
                    }
                    
                    // Action Button
                    Group {
                        if hasExistingKey && apiKey == "••••••••••••••••" {
                            Button(role: .destructive, action: clearAPIKey) {
                                Text("Clear API Key")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(action: saveSettings) {
                                Text("Save API Key")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(apiKey.isEmpty || apiKey == "••••••••••••••••" || isSaving)
                        }
                    }
                    .frame(height: 32)
                    
                    Link("Get API Key from Google AI Studio",
                         destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            } header: {
                Text("API Configuration")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
        }
        .formStyle(.grouped)
    }
    
    private var projectsSection: some View {
        VStack(spacing: 0) {
            List {
                ForEach(projectManager.projects) { project in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.name)
                                .fontWeight(.medium)
                            Text(project.outputDirectory)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        if project.isArchived {
                            Button("Unarchive") { projectManager.unarchiveProject(project) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        } else {
                            Button("Archive") { projectManager.archiveProject(project) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        
                        Button(role: .destructive) {
                            projectManager.deleteProject(project)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }

    private var promptsSection: some View {
        HStack(spacing: 0) {
            // Tag Sidebar
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedPromptTag) {
                    Text("All Presets")
                        .tag("all")
                    Text("Untagged")
                        .tag("untagged")
                    Divider()
                    ForEach(promptLibrary.tags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                                .lineLimit(1)
                            Spacer()
                            Text("\(promptLibrary.presets.filter { $0.tags.contains(tag) }.count)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .tag(tag)
                        .contextMenu {
                            Button("Rename") {
                                showingRenameTagAlert = true
                                tagNameToRename = tag
                            }
                            Button("Delete", role: .destructive) {
                                promptLibrary.removeTag(tag)
                                if selectedPromptTag == tag {
                                    selectedPromptTag = "all"
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 150)

                Divider()

                // Add Tag Button
                Button(action: { showingAddTagAlert = true }) {
                    Label("Add Tag", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }

            Divider()

            // Preset Cards
            if filteredPresets.isEmpty {
                ContentUnavailableView(
                    "No Presets",
                    systemImage: "bookmark.slash",
                    description: Text("Save prompt presets from the Inspector.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(filteredPresets) { preset in
                            PresetCard(preset: preset, promptLibrary: promptLibrary)
                                .contextMenu {
                                    Button("Edit") {
                                        editingPreset = preset
                                    }
                                    Button("Duplicate") {
                                        promptLibrary.duplicate(preset)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        promptLibrary.delete(preset)
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .alert("Add Tag", isPresented: $showingAddTagAlert) {
            TextField("Tag name", text: $newTagName)
            Button("Cancel", role: .cancel) { newTagName = "" }
            Button("Add") {
                if !newTagName.trimmingCharacters(in: .whitespaces).isEmpty {
                    promptLibrary.addTag(newTagName.trimmingCharacters(in: .whitespaces))
                }
                newTagName = ""
            }
            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .alert("Rename Tag", isPresented: $showingRenameTagAlert) {
            TextField("New name", text: $newTagName)
            Button("Cancel", role: .cancel) { newTagName = "" }
            Button("Rename") {
                if !newTagName.trimmingCharacters(in: .whitespaces).isEmpty, let oldName = tagNameToRename {
                    promptLibrary.renameTag(oldName, to: newTagName.trimmingCharacters(in: .whitespaces))
                }
                newTagName = ""
                tagNameToRename = nil
            }
            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .sheet(item: $editingPreset) { preset in
            PresetEditSheet(preset: preset, promptLibrary: promptLibrary)
        }
    }

    private var filteredPresets: [PromptPreset] {
        switch selectedPromptTag {
        case "all":
            return promptLibrary.presets
        case "untagged":
            return promptLibrary.presets.filter { $0.tags.isEmpty }
        default:
            return promptLibrary.presets.filter { $0.tags.contains(selectedPromptTag) }
        }
    }
    
    private var aboutSection: some View {
        Form {
            Section("About Nano Banana Helper") {
                LabeledContent("Version") {
                    Text("1.3.2")
                        .fontWeight(.bold)
                }

                LabeledContent("Build") {
                    Text("March 2026")
                }

                LabeledContent("Copyright") {
                    Text("© 2026 Josh McSwain & Frédéric Guigand")
                }
                
                Text("A powerful interface for high-throughput image editing using the Gemini Batch API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                
                Link("Gemini API Documentation",
                     destination: URL(string: "https://ai.google.dev/gemini-api/docs")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
    
    private func checkExistingKey() {
        // Use synchronous check to avoid multiple async keychain accesses
        let service = NanoBananaService()
        Task {
            hasExistingKey = await service.hasAPIKey()
            if hasExistingKey {
                apiKey = "••••••••••••••••"
            }
        }
    }
    
    private func saveSettings() {
        guard !apiKey.isEmpty && apiKey != "••••••••••••••••" else { return }
        
        isSaving = true
        statusMessage = "Saving..."
        
        let service = NanoBananaService()
        Task {
            await service.setAPIKey(apiKey)
            statusMessage = "API key saved successfully!"
            hasExistingKey = true
            apiKey = "••••••••••••••••"
            isSaving = false
        }
    }
    
    private func clearAPIKey() {
        isSaving = true
        let service = NanoBananaService()
        Task {
            await service.setAPIKey("")
            statusMessage = "API key cleared"
            hasExistingKey = false
            isSaving = false
        }
    }
    
    private func toggleKeyVisibility() {
        if !showKey && apiKey == "••••••••••••••••" {
            // Need to fetch before revealing
            let service = NanoBananaService()
            Task {
                if let realKey = await service.getAPIKey() {
                    apiKey = realKey
                    showKey = true
                }
            }
        } else if showKey && hasExistingKey {
            // Hiding - check if we should show mask again
            let service = NanoBananaService()
            Task {
                if await service.getAPIKey() == apiKey {
                    apiKey = "••••••••••••••••"
                }
                showKey = false
            }
        } else {
            showKey.toggle()
        }
    }
    
    private func loadCurrentModel() {
        let service = NanoBananaService()
        Task {
            selectedModel = await service.getModelName()
        }
    }
    
    private func saveModelSelection(_ modelName: String) {
        let service = NanoBananaService()
        Task {
            await service.setModelName(modelName)
        }
    }
}

// MARK: - Preset Card

private struct PresetCard: View {
    let preset: PromptPreset
    var promptLibrary: PromptLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preset.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Text(preset.userPrompt)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if preset.systemPrompt != nil && !(preset.systemPrompt?.isEmpty ?? true) {
                HStack(spacing: 3) {
                    Image(systemName: "cpu")
                        .font(.system(size: 8))
                        .foregroundStyle(.purple)
                    Text("Has system prompt")
                        .font(.system(size: 9))
                        .foregroundStyle(.purple.opacity(0.8))
                }
            }

            HStack(spacing: 4) {
                ForEach(preset.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundStyle(Color.accentColor)
                        .cornerRadius(4)
                }
            }

            Text(preset.updatedAt, style: .relative)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

// MARK: - Preset Edit Sheet

private struct PresetEditSheet: View {
    let preset: PromptPreset
    var promptLibrary: PromptLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var userPrompt: String = ""
    @State private var systemPrompt: String = ""
    @State private var selectedTags: Set<String> = []

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Preset")
                .font(.headline)

            Form {
                Section("Name") {
                    TextField("Preset name", text: $name)
                }

                Section("User Prompt") {
                    TextEditor(text: $userPrompt)
                        .frame(minHeight: 80)
                }

                Section("System Prompt") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 60)
                }

                Section("Tags") {
                    ForEach(promptLibrary.tags, id: \.self) { tag in
                        Toggle(tag, isOn: Binding(
                            get: { selectedTags.contains(tag) },
                            set: { _ in
                                if selectedTags.contains(tag) {
                                    selectedTags.remove(tag)
                                } else {
                                    selectedTags.insert(tag)
                                }
                            }
                        ))
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    var updated = preset
                    updated.name = name
                    updated.userPrompt = userPrompt
                    updated.systemPrompt = systemPrompt.isEmpty ? nil : systemPrompt
                    updated.tags = Array(selectedTags)
                    promptLibrary.update(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 450, height: 500)
        .onAppear {
            name = preset.name
            userPrompt = preset.userPrompt
            systemPrompt = preset.systemPrompt ?? ""
            selectedTags = Set(preset.tags)
        }
    }
}
