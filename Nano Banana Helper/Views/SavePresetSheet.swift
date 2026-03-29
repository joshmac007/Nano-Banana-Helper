import SwiftUI

struct SavePresetSheet: View {
    var promptLibrary: PromptLibrary
    let userPrompt: String
    let systemPrompt: String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedTags: Set<String> = []
    @State private var newTagName = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Save Preset")
                .font(.headline)

            Form {
                Section("Name") {
                    TextField("Preset name", text: $name)
                }

                Section("User Prompt") {
                    Text(userPrompt)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                if let systemPrompt, !systemPrompt.isEmpty {
                    Section("System Prompt") {
                        Text(systemPrompt)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.purple)
                            .lineLimit(4)
                    }
                }

                Section("Tags") {
                    if promptLibrary.tags.isEmpty {
                        Text("No tags yet. Create tags in Settings.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
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

                    HStack {
                        TextField("New tag name", text: $newTagName)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Button("Add") {
                            let trimmed = newTagName.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                promptLibrary.addTag(trimmed)
                                selectedTags.insert(trimmed)
                                newTagName = ""
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    promptLibrary.save(
                        name: name,
                        userPrompt: userPrompt,
                        systemPrompt: systemPrompt,
                        tags: Array(selectedTags)
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 480)
    }
}
