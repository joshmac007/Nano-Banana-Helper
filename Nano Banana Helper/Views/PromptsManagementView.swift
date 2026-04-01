import SwiftUI

struct PromptsManagementView: View {
    @Environment(PromptLibrary.self) private var promptLibrary
    @Environment(ProjectManager.self) private var projectManager

    @State private var searchText = ""
    @State private var sortOrder: PresetSortOrder = .modified
    @State private var selectedPreset: PromptPreset? = nil
    @State private var editingPreset: PromptPreset? = nil
    @State private var isCreatingNew = false
    @State private var presetToDelete: PromptPreset?

    private enum PresetSortOrder: String, CaseIterable {
        case name = "Name"
        case created = "Date Created"
        case modified = "Last Modified"
    }

    private var filteredPresets: [PromptPreset] {
        let base = searchText.isEmpty
            ? promptLibrary.presets
            : promptLibrary.presets(matching: searchText)
        switch sortOrder {
        case .name:
            return base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .created:
            return base.sorted { $0.createdAt > $1.createdAt }
        case .modified:
            return base.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    TextField("Search presets...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

                Spacer()

                Button(action: {
                    if let preset = selectedPreset { editingPreset = preset }
                }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("Edit Selected")
                .disabled(selectedPreset == nil)

                Button(action: { isCreatingNew = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("New Preset")

                Menu {
                    ForEach(PresetSortOrder.allCases, id: \.self) { option in
                        Button(option.rawValue) {
                            withAnimation { sortOrder = option }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort by \(sortOrder.rawValue)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Content
            if filteredPresets.isEmpty {
                emptyState
            } else {
                List(selection: $selectedPreset) {
                    ForEach(filteredPresets) { preset in
                        presetRow(for: preset)
                            .tag(preset)
                            .contextMenu {
                                presetContextMenu(for: preset)
                            }
                    }
                }
                .listStyle(.inset)
                .onKeyPress(.return) {
                    if let preset = selectedPreset {
                        editingPreset = preset
                        return .handled
                    }
                    return .ignored
                }
            }
        }
        .sheet(item: $editingPreset) { preset in
            PresetDetailSheet(mode: .edit(preset), promptLibrary: promptLibrary)
        }
        .sheet(isPresented: $isCreatingNew) {
            PresetDetailSheet(mode: .create, promptLibrary: promptLibrary)
        }
        .alert("Delete Preset?", isPresented: Binding(
            get: { presetToDelete != nil },
            set: { if !$0 { presetToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { presetToDelete = nil }
            Button("Delete", role: .destructive) {
                if let preset = presetToDelete {
                    if selectedPreset?.id == preset.id {
                        selectedPreset = nil
                    }
                    if projectManager.currentProject?.defaultPresetID == preset.id {
                        projectManager.currentProject?.defaultPresetID = nil
                    }
                    promptLibrary.delete(preset)
                }
                presetToDelete = nil
            }
        } message: {
            Text("\"\(presetToDelete?.name ?? "")\" will be permanently deleted.")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Presets", systemImage: "bookmark.slash")
        } description: {
            Text("Create presets to save frequently used prompts.")
        } actions: {
            Button("Create Preset") {
                isCreatingNew = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preset Row

    @ViewBuilder
    private func presetRow(for preset: PromptPreset) -> some View {
        let isDefault = projectManager.currentProject?.defaultPresetID == preset.id

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if isDefault {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.yellow)
                }
                Text(preset.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }

            if preset.userPrompt.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "cpu")
                        .font(.system(size: 9))
                    Text("System prompt only")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple.opacity(0.85))
                }
            } else {
                Text(preset.userPrompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let sys = preset.systemPrompt, !sys.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "cpu")
                            .font(.system(size: 8))
                        Text("Has system prompt")
                            .font(.system(size: 9))
                            .foregroundStyle(.purple.opacity(0.7))
                    }
                }
            }

            Text(preset.updatedAt, style: .relative)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func presetContextMenu(for preset: PromptPreset) -> some View {
        Button("Edit") {
            editingPreset = preset
        }

        Button("Duplicate") {
            promptLibrary.duplicate(preset)
        }

        Divider()

        if let project = projectManager.currentProject {
            if project.defaultPresetID == preset.id {
                Button("Remove as Project Default") {
                    project.defaultPresetID = nil
                }
            } else {
                Button("Set as Project Default") {
                    project.defaultPresetID = preset.id
                }
            }
        }

        Divider()

        Button("Delete", role: .destructive) {
            presetToDelete = preset
        }
    }
}

// MARK: - Preset Detail Sheet

private enum SheetMode {
    case create
    case edit(PromptPreset)
}

private struct PresetDetailSheet: View {
    let mode: SheetMode
    var promptLibrary: PromptLibrary

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    @State private var name: String = ""
    @State private var userPrompt: String = ""
    @State private var systemPrompt: String = ""
    @State private var showSystemPrompt: Bool = false

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isCreating ? "New Preset" : "Edit Preset")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        TextField("Preset name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFocused)
                    }

                    // User Prompt
                    VStack(alignment: .leading, spacing: 4) {
                        Text("User Prompt")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ZStack(alignment: .topLeading) {
                            if userPrompt.isEmpty {
                                Text("Describe how you want to transform this image...")
                                    .foregroundStyle(.tertiary)
                                    .padding(10)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $userPrompt)
                                .font(.system(.body, design: .rounded))
                                .padding(8)
                                .scrollContentBackground(.hidden)
                        }
                        .frame(minHeight: 100)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                    }

                    // System Prompt (collapsible)
                    VStack(alignment: .leading, spacing: 4) {
                        Button(action: { withAnimation { showSystemPrompt.toggle() } }) {
                            HStack {
                                Image(systemName: showSystemPrompt ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 12)
                                Text("System Prompt")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                if !systemPrompt.isEmpty {
                                    Text("(active)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.purple)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)

                        if showSystemPrompt {
                            ZStack(alignment: .topLeading) {
                                if systemPrompt.isEmpty {
                                    Text("Set behavioral context for the model...")
                                        .foregroundStyle(.tertiary)
                                        .padding(10)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $systemPrompt)
                                    .font(.system(.body, design: .rounded))
                                    .padding(8)
                                    .scrollContentBackground(.hidden)
                            }
                            .frame(minHeight: 80)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.purple.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.purple.opacity(0.12), lineWidth: 1)
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(isCreating ? "Create Preset" : "Save Changes") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
        .onAppear {
            if case .edit(let preset) = mode {
                name = preset.name
                userPrompt = preset.userPrompt
                systemPrompt = preset.systemPrompt ?? ""
                showSystemPrompt = !systemPrompt.isEmpty
            } else {
                isNameFocused = true
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let sysPrompt = systemPrompt.isEmpty ? nil : systemPrompt

        if case .edit(let original) = mode {
            var updated = original
            updated.name = trimmedName
            updated.userPrompt = userPrompt
            updated.systemPrompt = sysPrompt
            promptLibrary.update(updated)
        } else {
            promptLibrary.save(
                name: trimmedName,
                userPrompt: userPrompt,
                systemPrompt: sysPrompt
            )
        }
        dismiss()
    }
}
