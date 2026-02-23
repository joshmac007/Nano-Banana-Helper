import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var isSaving: Bool = false
    @State private var statusMessage: String = ""
    @State private var hasExistingKey: Bool = false
    @State private var isLoaded: Bool = false
    @State private var selectedTab: SettingsTab = .api
    @State private var debugLoggingEnabled: Bool = true
    @State private var debugStatusMessage: String = ""
    
    @Environment(ProjectManager.self) private var projectManager
    @Environment(PromptLibrary.self) private var promptLibrary
    @Environment(\.dismiss) private var dismiss
    
    enum SettingsTab: String, CaseIterable {
        case api = "API"
        case projects = "Projects"
        case prompts = "Prompts"
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
                case .about:
                    aboutSection
                }
            }
        }
        .frame(width: 500, height: 650)
        .onAppear {
            if !isLoaded {
                checkExistingKey()
                loadDiagnosticsSettings()
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
            .frame(height: 400)
        }
    }
    
    private var promptsSection: some View {
        VStack(spacing: 0) {
            if promptLibrary.prompts.isEmpty {
                ContentUnavailableView("No Saved Prompts", 
                                       systemImage: "bookmark.slash",
                                       description: Text("Prompts you save as templates will appear here."))
                    .frame(height: 400)
            } else {
                List {
                    ForEach(promptLibrary.prompts) { saved in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(saved.name)
                                    .fontWeight(.medium)
                                Text(saved.prompt)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            
                            Spacer()
                            
                            Button(role: .destructive) {
                                withAnimation {
                                    promptLibrary.delete(saved)
                                }
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
                .frame(height: 400)
            }
        }
    }
    
    private var aboutSection: some View {
        Form {
            Section("About Nano Banana Pro") {
                LabeledContent("Version") {
                    Text("1.0")
                        .fontWeight(.bold)
                }
                
                LabeledContent("Build") {
                    Text("February 2026")
                }

                LabeledContent("Copyright") {
                    Text("© 2026 Josh McSwain")
                }
                
                Text("A powerful interface for high-throughput image editing using the Gemini Batch API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                
                Link("Gemini API Documentation",
                     destination: URL(string: "https://ai.google.dev/gemini-api/docs")!)
                    .font(.caption)
            }

            Section("Diagnostics") {
                Toggle("Enable debug file logging", isOn: Binding(
                    get: { debugLoggingEnabled },
                    set: { setDebugLogging($0) }
                ))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Log File")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(DebugLog.fileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                
                HStack {
                    Button("Reveal Log") {
                        ensureLogFileExistsForUI()
                        NSWorkspace.shared.activateFileViewerSelecting([DebugLog.fileURL])
                        DebugLog.info("settings.debug", "Revealed debug log in Finder")
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Open Log") {
                        ensureLogFileExistsForUI()
                        NSWorkspace.shared.open(DebugLog.fileURL)
                        DebugLog.info("settings.debug", "Opened debug log file")
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Clear Log", role: .destructive) {
                        Task {
                            await DebugLogger.shared.clearLog()
                            await DebugLogger.shared.log(
                                level: .info,
                                category: "settings.debug",
                                message: "Debug log cleared by user",
                                force: true
                            )
                            await MainActor.run {
                                debugStatusMessage = "Debug log cleared"
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                if !debugStatusMessage.isEmpty {
                    Text(debugStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Text("Writes detailed permission, bookmark, and save diagnostics to a local file for troubleshooting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func loadDiagnosticsSettings() {
        let config = AppConfig.load()
        debugLoggingEnabled = config.debugLoggingEnabled
        if debugLoggingEnabled {
            ensureLogFileExistsForUI()
            DebugLog.info("settings.debug", "Diagnostics settings loaded", metadata: [
                "enabled": String(debugLoggingEnabled)
            ])
        }
    }

    private func setDebugLogging(_ enabled: Bool) {
        if enabled == debugLoggingEnabled { return }
        
        if !enabled {
            DebugLog.forceInfo("settings.debug", "Debug logging disabled by user")
        }
        
        debugLoggingEnabled = enabled
        var config = AppConfig.load()
        config.debugLoggingEnabled = enabled
        config.save()
        
        if enabled {
            ensureLogFileExistsForUI()
            DebugLog.info("settings.debug", "Debug logging enabled by user")
        }
        
        debugStatusMessage = enabled ? "Debug logging enabled" : "Debug logging disabled"
    }

    private func ensureLogFileExistsForUI() {
        DebugLog.ensureLogFileExists()
    }
    
    private func saveSettings() {
        guard !apiKey.isEmpty && apiKey != "••••••••••••••••" else { return }
        
        isSaving = true
        statusMessage = "Saving..."
        
        let service = NanoBananaService()
        Task {
            await service.setAPIKey(apiKey)
            DebugLog.info("settings.api", "API key saved")
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
            DebugLog.info("settings.api", "API key cleared")
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
}
