import SwiftUI

extension Notification.Name {
    static let openPromptSettings = Notification.Name("openPromptSettings")
}

struct PromptBarView: View {
    @Bindable var stagingManager: BatchStagingManager
    var project: Project?

    @Environment(PromptLibrary.self) private var promptLibrary

    @State private var showingEditSheet = false
    @State private var presetToDelete: PromptPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack(alignment: .center, spacing: 8) {
                Text("Prompt")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                // Edit button
                Button(action: { showingEditSheet = true }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit Prompt")

                // Presets dropdown menu
                Menu {
                    presetsMenuContent
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Load Preset")
            }
            .padding(.horizontal, 2)

            // Prompt preview bar
            Button(action: { showingEditSheet = true }) {
                HStack(spacing: 8) {
                    // Content
                    if stagingManager.prompt.isEmpty && stagingManager.systemPrompt.isEmpty {
                        Text("Write or select a prompt...")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.tertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            if stagingManager.systemPrompt.isEmpty == false {
                                HStack(spacing: 3) {
                                    Image(systemName: "cpu")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.purple)
                                    Text("System prompt active")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.purple.opacity(0.8))
                                }
                            }
                            Text(stagingManager.prompt)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingEditSheet) {
            PromptEditSheet(
                userPrompt: $stagingManager.prompt,
                systemPrompt: $stagingManager.systemPrompt
            )
        }
        .alert("Delete Preset?", isPresented: Binding(
            get: { presetToDelete != nil },
            set: { if !$0 { presetToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { presetToDelete = nil }
            Button("Delete", role: .destructive) {
                if let preset = presetToDelete {
                    promptLibrary.delete(preset)
                    if project?.defaultPresetID == preset.id {
                        project?.defaultPresetID = nil
                    }
                }
                presetToDelete = nil
            }
        } message: {
            Text("\"\(presetToDelete?.name ?? "")\" will be permanently deleted.")
        }
    }

    // MARK: - Presets Menu

    @ViewBuilder
    private var presetsMenuContent: some View {
        if promptLibrary.presets.isEmpty {
            Text("No Saved Presets")
                .disabled(true)
        } else {
            ForEach(promptLibrary.presets) { preset in
                Button(action: { loadPreset(preset) }) {
                    HStack {
                        if project?.defaultPresetID == preset.id {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        Text(preset.name)
                    }
                }
            }
        }

        Divider()

        // Actions on current preset
        if let matchedPreset = currentMatchingPreset {
            Button("Edit \"\(matchedPreset.name)\"") {
                showingEditSheet = true
            }
            Button("Duplicate \"\(matchedPreset.name)\"") {
                promptLibrary.duplicate(matchedPreset)
            }
            if project != nil {
                if project?.defaultPresetID == matchedPreset.id {
                    Button("Remove as Default") {
                        project?.defaultPresetID = nil
                    }
                } else {
                    Button("Set as Project Default") {
                        project?.defaultPresetID = matchedPreset.id
                    }
                }
            }
            Button("Delete \"\(matchedPreset.name)\"", role: .destructive) {
                presetToDelete = matchedPreset
            }
            Divider()
        }

        Button("Manage All...") {
            NotificationCenter.default.post(name: .openPromptSettings, object: nil)
        }
    }

    // MARK: - Helpers

    /// Checks if the current prompt text exactly matches a saved preset
    private var currentMatchingPreset: PromptPreset? {
        guard !stagingManager.prompt.isEmpty || !stagingManager.systemPrompt.isEmpty else { return nil }
        return promptLibrary.presets.first { preset in
            preset.userPrompt == stagingManager.prompt
                && (preset.systemPrompt ?? "") == stagingManager.systemPrompt
        }
    }

    private func loadPreset(_ preset: PromptPreset) {
        stagingManager.prompt = preset.userPrompt
        stagingManager.systemPrompt = preset.systemPrompt ?? ""
    }
}
