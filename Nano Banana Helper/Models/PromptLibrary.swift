import Foundation

/// A saved prompt template
struct SavedPrompt: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var prompt: String
    var createdAt: Date
    
    init(name: String, prompt: String) {
        self.id = UUID()
        self.name = name
        self.prompt = prompt
        self.createdAt = Date()
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
    
    func save(name: String, prompt: String) {
        let savedPrompt = SavedPrompt(name: name, prompt: prompt)
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
