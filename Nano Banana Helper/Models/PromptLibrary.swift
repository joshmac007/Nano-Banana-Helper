import Foundation

// MARK: - PromptPreset

/// A saved prompt template combining optional user and system prompts with tags.
nonisolated struct PromptPreset: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var userPrompt: String
    var systemPrompt: String?  // nil = no system prompt
    var tags: [String]          // from curated tag list
    let createdAt: Date
    var updatedAt: Date

    init(name: String, userPrompt: String, systemPrompt: String? = nil, tags: [String] = []) {
        self.id = UUID()
        self.name = name
        self.userPrompt = userPrompt
        self.systemPrompt = systemPrompt
        self.tags = tags
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }

    enum CodingKeys: String, CodingKey {
        case id, name, userPrompt, systemPrompt, tags, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        userPrompt = try container.decode(String.self, forKey: .userPrompt)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(userPrompt, forKey: .userPrompt)
        try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try container.encodeIfPresent(tags.isEmpty ? nil : tags, forKey: .tags)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    static func == (lhs: PromptPreset, rhs: PromptPreset) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - PromptLibraryStore (v2 persistence wrapper)

/// Wrapper for v2 persistence format containing both presets and curated tags.
nonisolated struct PromptLibraryStore: Codable {
    let version: Int  // value: 2
    var tags: [String]
    var presets: [PromptPreset]
}

// MARK: - PromptLibrary

/// Manages saved prompt templates with tagging support.
@Observable
class PromptLibrary {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var presets: [PromptPreset] = []
    var tags: [String] = []

    private var storageURL: URL { AppPaths.promptsURL }

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    // MARK: - CRUD

    func save(name: String, userPrompt: String, systemPrompt: String? = nil, tags: [String] = []) {
        let preset = PromptPreset(name: name, userPrompt: userPrompt, systemPrompt: systemPrompt, tags: tags)
        presets.insert(preset, at: 0)
        persist()
    }

    func delete(_ preset: PromptPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    func rename(_ preset: PromptPreset, to newName: String) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index].name = newName
            presets[index].updatedAt = Date()
            persist()
        }
    }

    func update(_ preset: PromptPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
            presets[index].updatedAt = Date()
            persist()
        }
    }

    func duplicate(_ preset: PromptPreset) {
        let copy = PromptPreset(
            name: preset.name + " (copy)",
            userPrompt: preset.userPrompt,
            systemPrompt: preset.systemPrompt,
            tags: preset.tags
        )
        if let insertIndex = presets.firstIndex(where: { $0.id == preset.id }) {
            presets.insert(copy, at: insertIndex + 1)
        } else {
            presets.insert(copy, at: 0)
        }
        persist()
    }

    // MARK: - Tag Management

    func addTag(_ tag: String) {
        guard !tags.contains(tag) else { return }
        tags.append(tag)
        persist()
    }

    func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        // Also remove from all presets
        for index in presets.indices {
            presets[index].tags.removeAll { $0 == tag }
        }
        persist()
    }

    func renameTag(_ oldName: String, to newName: String) {
        guard let tagIndex = tags.firstIndex(of: oldName) else { return }
        tags[tagIndex] = newName
        // Also rename in all presets
        for index in presets.indices {
            presets[index].tags = presets[index].tags.map { $0 == oldName ? newName : $0 }
        }
        persist()
    }

    // MARK: - Query

    func presetsWithTag(_ tag: String) -> [PromptPreset] {
        presets.filter { $0.tags.contains(tag) }
    }

    func presets(matching query: String) -> [PromptPreset] {
        let lowercased = query.lowercased()
        return presets.filter { preset in
            preset.name.lowercased().contains(lowercased)
                || preset.userPrompt.lowercased().contains(lowercased)
                || (preset.systemPrompt?.lowercased().contains(lowercased) ?? false)
        }
    }

    func preset(id: UUID) -> PromptPreset? {
        presets.first { $0.id == id }
    }

    // MARK: - Persistence

    func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)

            // Try v2 format first
            if let store = try? decoder.decode(PromptLibraryStore.self, from: data) {
                self.presets = store.presets
                self.tags = store.tags
                return
            }

            // Fall back to v1 legacy format and migrate
            migrateFromV1(data)
        } catch {
            print("Failed to load prompts: \(error)")
        }
    }

    private func migrateFromV1(_ data: Data) {
        struct LegacyPrompt: Codable {
            let id: UUID
            let name: String
            let prompt: String
            let type: String // "User" or "System"
            let createdAt: Date
        }

        guard let legacy = try? decoder.decode([LegacyPrompt].self, from: data) else { return }

        var userByName: [String: LegacyPrompt] = [:]
        var systemByName: [String: LegacyPrompt] = [:]
        var merged: [PromptPreset] = []
        var processedNames = Set<String>()

        for item in legacy {
            if item.type == "System" {
                systemByName[item.name] = item
            } else {
                userByName[item.name] = item
            }
        }

        // Build merged list: prefer pairing same-named user+system
        for item in legacy {
            guard !processedNames.contains(item.name) else { continue }
            processedNames.insert(item.name)

            if let userItem = userByName[item.name], let systemItem = systemByName[item.name] {
                merged.append(PromptPreset(name: userItem.name, userPrompt: userItem.prompt, systemPrompt: systemItem.prompt))
            } else if let userItem = userByName[item.name] {
                merged.append(PromptPreset(name: userItem.name, userPrompt: userItem.prompt, systemPrompt: nil))
            } else if let systemItem = systemByName[item.name] {
                merged.append(PromptPreset(name: systemItem.name, userPrompt: "", systemPrompt: systemItem.prompt))
            }
        }

        self.presets = merged
        self.tags = []
        persist()
        print("Migrated \(legacy.count) legacy prompts into \(merged.count) presets")
    }

    private func persist() {
        let directory = storageURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let store = PromptLibraryStore(version: 2, tags: tags, presets: presets)
            let data = try encoder.encode(store)
            try data.write(to: storageURL)
        } catch {
            print("Failed to save prompts: \(error)")
        }
    }
}
