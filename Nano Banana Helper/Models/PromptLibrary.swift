import Foundation

enum PromptType: String, Codable, CaseIterable, Identifiable {
    case user = "User"
    case system = "System"
    
    var id: String { rawValue }
}

/// A saved prompt template
struct SavedPrompt: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var prompt: String
    var type: PromptType
    var createdAt: Date
    
    init(name: String, prompt: String, type: PromptType = .user) {
        self.id = UUID()
        self.name = name
        self.prompt = prompt
        self.type = type
        self.createdAt = Date()
    }
    
    // Custom decoding to handle migration from old format missing 'type'
    enum CodingKeys: String, CodingKey {
        case id, name, prompt, type, createdAt
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Default to .user if type is missing
        type = try container.decodeIfPresent(PromptType.self, forKey: .type) ?? .user
    }
}

/// Manages saved prompt templates
@Observable
class PromptLibrary {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    var prompts: [SavedPrompt] = []
    
    private var storageURL: URL { AppPaths.promptsURL }
    
    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }
    
    // Filtered accessors
    var userPrompts: [SavedPrompt] {
        prompts.filter { $0.type == .user }
    }
    
    var systemPrompts: [SavedPrompt] {
        prompts.filter { $0.type == .system }
    }
    
    func save(name: String, prompt: String, type: PromptType) {
        let savedPrompt = SavedPrompt(name: name, prompt: prompt, type: type)
        prompts.insert(savedPrompt, at: 0)
        persist()
    }
    
    func delete(_ prompt: SavedPrompt) {
        prompts.removeAll { $0.id == prompt.id }
        persist()
    }
    
    func rename(_ prompt: SavedPrompt, to newName: String) {
        if let index = prompts.firstIndex(where: { $0.id == prompt.id }) {
            prompts[index].name = newName
            persist()
        }
    }
    
    func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: storageURL)
            prompts = try decoder.decode([SavedPrompt].self, from: data)
            
            // Only re-persist if the decoded data differs from what's on disk.
            // This handles migration (e.g., older entries missing the 'type' field)
            // without writing on every launch when nothing has changed.
            if let reEncoded = try? encoder.encode(prompts), reEncoded != data {
                persist()
            }
        } catch {
            print("Failed to load prompts: \(error)")
        }
    }
    
    private func persist() {
        // Ensure directory exists
        let directory = storageURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        
        do {
            let data = try encoder.encode(prompts)
            try data.write(to: storageURL)
        } catch {
            print("Failed to save prompts: \(error)")
        }
    }
}
