import SwiftUI

struct PromptPresetPopover: View {
    @Bindable var stagingManager: BatchStagingManager
    var project: Project?

    @Environment(PromptLibrary.self) private var promptLibrary

    @State private var searchText = ""
    @State private var selectedTag: String? = nil
    @State private var editingPresetID: UUID? = nil
    @State private var showingSaveSheet = false
    @State private var presetToDelete: PromptPreset? = nil

    // Edit state
    @State private var editName = ""
    @State private var editUserPrompt = ""
    @State private var editSystemPrompt = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Search presets...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onChange(of: searchText) { _, _ in
                        editingPresetID = nil
                    }
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.top, 12)

            // Tag Filter Chips
            if !promptLibrary.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        TagChip(label: "All", isSelected: selectedTag == nil) {
                            withAnimation { selectedTag = nil }
                        }
                        TagChip(label: "Untagged", isSelected: selectedTag == "") {
                            withAnimation { selectedTag = "" }
                        }
                        ForEach(promptLibrary.tags, id: \.self) { tag in
                            TagChip(label: tag, isSelected: selectedTag == tag) {
                                withAnimation { selectedTag = selectedTag == tag ? nil : tag }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }

            Divider()
                .padding(.vertical, 4)

            // Preset List
            if filteredPresets.isEmpty {
                Spacer()
                ContentUnavailableView(
                    searchText.isEmpty && selectedTag == nil
                        ? "No Presets"
                        : "No Matches",
                    systemImage: searchText.isEmpty && selectedTag == nil
                        ? "bookmark.slash"
                        : "magnifyingglass",
                    description: Text(searchText.isEmpty && selectedTag == nil
                        ? "Save your first prompt preset."
                        : "Try a different search or tag.")
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredPresets) { preset in
                            if editingPresetID == preset.id {
                                editRow(for: preset)
                            } else {
                                PresetRow(
                                    preset: preset,
                                    isDefault: project?.defaultPresetID == preset.id,
                                    onTap: { loadPreset(preset) }
                                )
                                .contextMenu {
                                    Button("Load") { loadPreset(preset) }
                                    Button("Edit") {
                                        editName = preset.name
                                        editUserPrompt = preset.userPrompt
                                        editSystemPrompt = preset.systemPrompt ?? ""
                                        editingPresetID = preset.id
                                    }
                                    Button("Duplicate") { promptLibrary.duplicate(preset) }
                                    Divider()
                                    if project != nil {
                                        Button(defaultButtonLabel(for: preset)) {
                                            toggleDefault(preset)
                                        }
                                        Divider()
                                    }
                                    Button("Delete", role: .destructive) {
                                        presetToDelete = preset
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(filteredPresets.count) preset\(filteredPresets.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showingSaveSheet = true }) {
                    Label("Save Current", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(stagingManager.prompt.isEmpty && stagingManager.systemPrompt.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingSaveSheet) {
            SavePresetSheet(
                promptLibrary: promptLibrary,
                userPrompt: stagingManager.prompt,
                systemPrompt: stagingManager.systemPrompt
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

    private var filteredPresets: [PromptPreset] {
        var result = promptLibrary.presets
        if let selectedTag {
            result = selectedTag.isEmpty
                ? result.filter { $0.tags.isEmpty }
                : result.filter { $0.tags.contains(selectedTag) }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { p in
                p.name.lowercased().contains(q)
                    || p.userPrompt.lowercased().contains(q)
                    || (p.systemPrompt?.lowercased().contains(q) ?? false)
            }
        }
        return result
    }

    private func loadPreset(_ preset: PromptPreset) {
        stagingManager.prompt = preset.userPrompt
        stagingManager.systemPrompt = preset.systemPrompt ?? ""
    }

    private func defaultButtonLabel(for preset: PromptPreset) -> String {
        project?.defaultPresetID == preset.id ? "Remove as Default" : "Set as Project Default"
    }

    private func toggleDefault(_ preset: PromptPreset) {
        guard let project else { return }
        project.defaultPresetID = project.defaultPresetID == preset.id ? nil : preset.id
    }

    @ViewBuilder
    private func editRow(for preset: PromptPreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $editName)
                    .font(.system(size: 12, weight: .medium))
                    .textFieldStyle(.roundedBorder)
                Spacer()
                HStack(spacing: 4) {
                    Button("Cancel") {
                        editingPresetID = nil
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)
                    Button("Save") {
                        var updated = preset
                        updated.name = editName
                        updated.userPrompt = editUserPrompt
                        updated.systemPrompt = editSystemPrompt.isEmpty ? nil : editSystemPrompt
                        promptLibrary.update(updated)
                        editingPresetID = nil
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.borderless)
                    .disabled(editName.isEmpty)
                }
            }
            TextField("User prompt...", text: $editUserPrompt, axis: .vertical)
                .font(.system(size: 11))
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            TextField("System prompt...", text: $editSystemPrompt, axis: .vertical)
                .font(.system(size: 11))
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .foregroundStyle(.purple)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.05))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Tag Chip

private struct TagChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
                .foregroundStyle(isSelected ? .white : .secondary)
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preset Row

private struct PresetRow: View {
    let preset: PromptPreset
    var isDefault: Bool = false
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if isDefault {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.yellow)
                        }
                        Text(preset.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Text(preset.userPrompt)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        if preset.systemPrompt != nil && !(preset.systemPrompt?.isEmpty ?? true) {
                            Image(systemName: "cpu")
                                .font(.system(size: 8))
                                .foregroundStyle(.purple)
                        }
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
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}
