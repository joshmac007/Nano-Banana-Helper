import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var isSaving: Bool = false
    @State private var statusMessage: String = ""
    @State private var hasExistingKey: Bool = false
    @State private var isLoaded: Bool = false
    @State private var selectedTab: SettingsTab = .api
    @State private var selectedProvider: ModelProvider = .gemini
    @State private var selectedModel: String = CuratedModelCatalog.defaultModelID(for: .gemini)
    @State private var availableModels: [ModelCatalogEntry] = CuratedModelCatalog.fallbackEntries(for: .gemini)
    @State private var modelStatusMessage: String = ""

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
            guard !isLoaded else { return }
            selectedTab = initialTab
            loadCurrentSettings()
            isLoaded = true
        }
        .onChange(of: selectedProvider) { _, newProvider in
            guard isLoaded else { return }
            saveProviderSelection(newProvider)
        }
    }
    
    private var apiSection: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center) {
                        Text("Active Provider")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $selectedProvider) {
                            ForEach(ModelProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    HStack(alignment: .center) {
                        Text(selectedProvider.apiKeyLabel)
                            .font(.body)
                            .foregroundStyle(.secondary)

                        Spacer()

                        HStack(alignment: .center, spacing: 12) {
                            ZStack(alignment: .leading) {
                                SecureField("", text: $apiKey)
                                    .textFieldStyle(.plain)
                                    .opacity(showKey ? 0 : 1)
                                    .disabled(showKey)
                                
                                TextField("", text: $apiKey)
                                    .textFieldStyle(.plain)
                                    .opacity(showKey ? 1 : 0)
                                    .disabled(!showKey)
                                    .offset(y: -1.0)
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
                    
                    HStack(alignment: .center) {
                        Text("Image Model")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Picker("", selection: $selectedModel) {
                            ForEach(availableModels) { model in
                                Text(model.pickerLabel)
                                    .tag(model.id)
                                    .disabled(!model.isSelectable)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 240)
                        .onChange(of: selectedModel) { _, newValue in
                            saveModelSelection(newValue)
                        }
                    }

                    providerCapabilitiesCard

                    if !modelStatusMessage.isEmpty {
                        Text(modelStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusMessage.contains("Error") ? .red : .green)
                            .frame(height: 14)
                    }
                    
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

                    Link(apiKeyLinkLabel, destination: apiKeyLinkURL)
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

    private var providerCapabilitiesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selectedProvider == .openAI ? "OpenAI standard generation, edits, masking, and Batch Tier are enabled." : "Gemini standard and batch generation remain available.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if selectedProvider == .openAI {
                Text("When using a mask with multiple inputs, OpenAI applies the mask to the first input image only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
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
                    Text("2.0")
                        .fontWeight(.bold)
                }

                LabeledContent("Build") {
                    Text("April 2026")
                }

                LabeledContent("Copyright") {
                    Text("© 2026 Josh McSwain & Frédéric Guigand")
                }
                
                Text("A high-throughput image generation and editing workbench with Gemini and OpenAI provider support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                
                Link("Gemini API Documentation", destination: URL(string: "https://ai.google.dev/gemini-api/docs")!)
                    .font(.caption)
                Link("OpenAI Image API Documentation", destination: URL(string: "https://developers.openai.com/api/docs/guides/image-generation")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
    
    private var apiKeyLinkLabel: String {
        switch selectedProvider {
        case .gemini: return "Get API Key from Google AI Studio"
        case .openAI: return "Manage API Keys in OpenAI Platform"
        }
    }

    private var apiKeyLinkURL: URL {
        switch selectedProvider {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    private func loadCurrentSettings() {
        let service = NanoBananaService()
        Task {
            let provider = await service.getProvider()
            await MainActor.run {
                selectedProvider = provider
                statusMessage = ""
            }
            await loadProviderState(using: service, provider: provider)
        }
    }

    @MainActor
    private func loadProviderState(using service: NanoBananaService, provider: ModelProvider) async {
        selectedModel = await service.getModelName(for: provider)
        hasExistingKey = await service.hasAPIKey(for: provider)
        apiKey = hasExistingKey ? "••••••••••••••••" : ""
        showKey = false
        availableModels = CuratedModelCatalog.fallbackEntries(for: provider, selectedModelID: selectedModel)
        await refreshModelCatalog(using: service, provider: provider)
    }

    private func saveProviderSelection(_ provider: ModelProvider) {
        let service = NanoBananaService()
        Task {
            await service.setProvider(provider)
            await MainActor.run {
                statusMessage = "Using \(provider.displayName)."
            }
            await loadProviderState(using: service, provider: provider)
        }
    }

    private func saveSettings() {
        guard !apiKey.isEmpty && apiKey != "••••••••••••••••" else { return }
        
        isSaving = true
        statusMessage = "Saving..."
        
        let service = NanoBananaService()
        Task {
            await service.setAPIKey(apiKey, for: selectedProvider)
            await MainActor.run {
                statusMessage = "API key saved successfully!"
                hasExistingKey = true
                apiKey = "••••••••••••••••"
                isSaving = false
            }
            await refreshModelCatalog(using: service, provider: selectedProvider)
        }
    }
    
    private func clearAPIKey() {
        isSaving = true
        let service = NanoBananaService()
        Task {
            await service.setAPIKey("", for: selectedProvider)
            await MainActor.run {
                statusMessage = "API key cleared"
                hasExistingKey = false
                apiKey = ""
                isSaving = false
                availableModels = CuratedModelCatalog.fallbackEntries(for: selectedProvider, selectedModelID: selectedModel)
                modelStatusMessage = fallbackModelMessage(for: selectedProvider)
            }
        }
    }
    
    private func toggleKeyVisibility() {
        let service = NanoBananaService()

        if !showKey && apiKey == "••••••••••••••••" {
            Task {
                if let realKey = await service.getAPIKey(for: selectedProvider) {
                    await MainActor.run {
                        apiKey = realKey
                        showKey = true
                    }
                }
            }
        } else if showKey && hasExistingKey {
            Task {
                let storedKey = await service.getAPIKey(for: selectedProvider)
                await MainActor.run {
                    if storedKey == apiKey {
                        apiKey = "••••••••••••••••"
                    }
                    showKey = false
                }
            }
        } else {
            showKey.toggle()
        }
    }
    
    private func saveModelSelection(_ modelName: String) {
        let service = NanoBananaService()
        Task {
            await service.setModelName(modelName, for: selectedProvider)
            await MainActor.run {
                stagingNotification()
            }
        }
    }

    @MainActor
    private func refreshModelCatalog(using service: NanoBananaService, provider: ModelProvider) async {
        do {
            availableModels = try await service.fetchAvailableModels(for: provider, selectedModelID: selectedModel)
            modelStatusMessage = provider == .gemini
                ? (hasExistingKey ? "Model catalog synced from Gemini." : fallbackModelMessage(for: provider))
                : "Using bundled OpenAI model defaults."
        } catch {
            availableModels = CuratedModelCatalog.fallbackEntries(for: provider, selectedModelID: selectedModel)
            modelStatusMessage = "Using bundled model defaults. \(error.localizedDescription)"
        }
    }

    private func fallbackModelMessage(for provider: ModelProvider) -> String {
        switch provider {
        case .gemini:
            return "Using bundled model defaults until a Gemini API key is added."
        case .openAI:
            return "Using bundled OpenAI model defaults until an OpenAI API key is added."
        }
    }

    @MainActor
    private func stagingNotification() {
        NotificationCenter.default.post(name: .appConfigDidChange, object: nil)
    }
}
