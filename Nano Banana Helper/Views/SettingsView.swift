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

    var initialTab: SettingsTab = .api

    @Environment(ProjectManager.self) private var projectManager
    @Environment(PromptLibrary.self) private var promptLibrary
    @Environment(\.dismiss) private var dismiss
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        var id: String { rawValue }
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
            
            switch selectedTab {
            case .api:
                apiSection
            case .projects:
                projectsSection
            case .prompts:
                PromptsManagementView()
            case .usage:
                UsageDashboardView()
            case .about:
                aboutSection
            }
        }
        .frame(width: 500, height: 650)
        .onAppear {
            if !isLoaded {
                selectedTab = initialTab
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


    private var aboutSection: some View {
        Form {
            Section("About Nano Banana Helper") {
                LabeledContent("Version") {
                    Text("1.3.5")
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
