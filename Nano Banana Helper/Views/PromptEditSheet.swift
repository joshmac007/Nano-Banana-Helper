import SwiftUI

struct PromptEditSheet: View {
    @Binding var userPrompt: String
    @Binding var systemPrompt: String

    @Environment(PromptLibrary.self) private var promptLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var showSystemPrompt = false
    @State private var saveName = ""
    @State private var showSaveConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Prompt")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            // User Prompt
            VStack(alignment: .leading, spacing: 8) {
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
                .frame(minHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            }
            .padding(.horizontal)
            .padding(.top, 16)

            // System Prompt (collapsible)
            VStack(alignment: .leading, spacing: 8) {
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
            .padding(.horizontal)
            .padding(.top, 12)

            Spacer()

            Divider()
                .padding(.top, 8)

            // Inline Save as Preset
            HStack(spacing: 12) {
                TextField("Preset name", text: $saveName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .rounded))

                if showSaveConfirmation {
                    Text("Saved!")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Button("Save as Preset") {
                    let name = saveName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    promptLibrary.save(
                        name: name,
                        userPrompt: userPrompt,
                        systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt
                    )
                    withAnimation {
                        showSaveConfirmation = true
                    }
                    saveName = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { showSaveConfirmation = false }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 460)
        .onAppear {
            showSystemPrompt = !systemPrompt.isEmpty
        }
    }
}
