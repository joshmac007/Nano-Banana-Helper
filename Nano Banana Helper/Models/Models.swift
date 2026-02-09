import Foundation

// MARK: - Project

/// A project groups related batch jobs together with shared cost tracking
@Observable
class Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var outputDirectory: String
    var totalCost: Double
    var imageCount: Int
    
    // Persistence
    var outputDirectoryBookmark: Data?
    
    // Presets
    var defaultPrompt: String?
    var defaultAspectRatio: String?
    var defaultImageSize: String?
    var defaultUseBatchTier: Bool?
    
    // Metadata
    var isArchived: Bool = false
    var projectNotes: String?
    
    var outputURL: URL {
        if let bookmark = outputDirectoryBookmark, let url = AppPaths.resolveBookmark(bookmark) {
            return url
        }
        return URL(fileURLWithPath: outputDirectory)
    }
    
    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    init(name: String, outputDirectory: String, outputDirectoryBookmark: Data? = nil) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.outputDirectory = outputDirectory
        self.outputDirectoryBookmark = outputDirectoryBookmark
        self.totalCost = 0
        self.imageCount = 0
    }
    
    enum CodingKeys: CodingKey {
        case id, name, createdAt, outputDirectory, totalCost, imageCount
        case defaultPrompt, defaultAspectRatio, defaultImageSize, defaultUseBatchTier
        case isArchived, projectNotes, outputDirectoryBookmark
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        outputDirectory = try container.decode(String.self, forKey: .outputDirectory)
        totalCost = try container.decode(Double.self, forKey: .totalCost)
        imageCount = try container.decode(Int.self, forKey: .imageCount)
        defaultPrompt = try container.decodeIfPresent(String.self, forKey: .defaultPrompt)
        defaultAspectRatio = try container.decodeIfPresent(String.self, forKey: .defaultAspectRatio)
        defaultImageSize = try container.decodeIfPresent(String.self, forKey: .defaultImageSize)
        defaultUseBatchTier = try container.decodeIfPresent(Bool.self, forKey: .defaultUseBatchTier)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        projectNotes = try container.decodeIfPresent(String.self, forKey: .projectNotes)
        outputDirectoryBookmark = try container.decodeIfPresent(Data.self, forKey: .outputDirectoryBookmark)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(outputDirectory, forKey: .outputDirectory)
        try container.encode(totalCost, forKey: .totalCost)
        try container.encode(imageCount, forKey: .imageCount)
        try container.encodeIfPresent(defaultPrompt, forKey: .defaultPrompt)
        try container.encodeIfPresent(defaultAspectRatio, forKey: .defaultAspectRatio)
        try container.encodeIfPresent(defaultImageSize, forKey: .defaultImageSize)
        try container.encodeIfPresent(defaultUseBatchTier, forKey: .defaultUseBatchTier)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(projectNotes, forKey: .projectNotes)
        try container.encodeIfPresent(outputDirectoryBookmark, forKey: .outputDirectoryBookmark)
    }
}

// MARK: - History Entry

/// A single completed image edit with all associated metadata
struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let projectId: UUID
    let timestamp: Date
    let sourceImagePaths: [String] // Changed to array for multimodal support
    let outputImagePath: String
    let prompt: String
    let aspectRatio: String
    let imageSize: String
    let usedBatchTier: Bool
    let cost: Double
    let status: String // "completed", "cancelled", "failed"
    let error: String?
    let externalJobName: String?
    
    init(
        projectId: UUID,
        sourceImagePaths: [String],
        outputImagePath: String,
        prompt: String,
        aspectRatio: String,
        imageSize: String,
        usedBatchTier: Bool,
        cost: Double,
        status: String = "completed",
        error: String? = nil,
        externalJobName: String? = nil
    ) {
        self.id = UUID()
        self.projectId = projectId
        self.timestamp = Date()
        self.sourceImagePaths = sourceImagePaths
        self.outputImagePath = outputImagePath
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.imageSize = imageSize
        self.usedBatchTier = usedBatchTier
        self.cost = cost
        self.status = status
        self.error = error
        self.externalJobName = externalJobName
    }
    
    // Backward compatibility for single source path
    var sourceImagePath: String { sourceImagePaths.first ?? "" }
    
    // Security Scoped Bookmarks
    var sourceImageBookmarks: [Data]?
    var outputImageBookmark: Data?
    
    var sourceURLs: [URL] {
        // Try to use bookmarks first
        if let bookmarks = sourceImageBookmarks, bookmarks.count == sourceImagePaths.count {
            return bookmarks.compactMap { AppPaths.resolveBookmark($0) }
        }
        // Fallback to paths (legacy)
        return sourceImagePaths.map { URL(fileURLWithPath: $0) }
    }
    
    var sourceURL: URL { sourceURLs.first ?? URL(fileURLWithPath: "") }
    
    var outputURL: URL {
        if let bookmark = outputImageBookmark, let url = AppPaths.resolveBookmark(bookmark) {
            return url
        }
        return URL(fileURLWithPath: outputImagePath)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, projectId, timestamp, sourceImagePaths, outputImagePath
        case prompt, aspectRatio, imageSize, usedBatchTier, cost
        case status, error, externalJobName
        case sourceImageBookmarks, outputImageBookmark
    }
    
    init(
        projectId: UUID,
        sourceImagePaths: [String],
        outputImagePath: String,
        prompt: String,
        aspectRatio: String,
        imageSize: String,
        usedBatchTier: Bool,
        cost: Double,
        status: String = "completed",
        error: String? = nil,
        externalJobName: String? = nil,
        sourceImageBookmarks: [Data]? = nil,
        outputImageBookmark: Data? = nil
    ) {
        self.id = UUID()
        self.projectId = projectId
        self.timestamp = Date()
        self.sourceImagePaths = sourceImagePaths
        self.outputImagePath = outputImagePath
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.imageSize = imageSize
        self.usedBatchTier = usedBatchTier
        self.cost = cost
        self.status = status
        self.error = error
        self.externalJobName = externalJobName
        self.sourceImageBookmarks = sourceImageBookmarks
        self.outputImageBookmark = outputImageBookmark
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        sourceImagePaths = try container.decode([String].self, forKey: .sourceImagePaths)
        outputImagePath = try container.decode(String.self, forKey: .outputImagePath)
        prompt = try container.decode(String.self, forKey: .prompt)
        aspectRatio = try container.decode(String.self, forKey: .aspectRatio)
        imageSize = try container.decode(String.self, forKey: .imageSize)
        usedBatchTier = try container.decode(Bool.self, forKey: .usedBatchTier)
        cost = try container.decode(Double.self, forKey: .cost)
        status = try container.decode(String.self, forKey: .status)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        externalJobName = try container.decodeIfPresent(String.self, forKey: .externalJobName)
        sourceImageBookmarks = try container.decodeIfPresent([Data].self, forKey: .sourceImageBookmarks)
        outputImageBookmark = try container.decodeIfPresent(Data.self, forKey: .outputImageBookmark)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(sourceImagePaths, forKey: .sourceImagePaths)
        try container.encode(outputImagePath, forKey: .outputImagePath)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encode(imageSize, forKey: .imageSize)
        try container.encode(usedBatchTier, forKey: .usedBatchTier)
        try container.encode(cost, forKey: .cost)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(externalJobName, forKey: .externalJobName)
        try container.encodeIfPresent(sourceImageBookmarks, forKey: .sourceImageBookmarks)
        try container.encodeIfPresent(outputImageBookmark, forKey: .outputImageBookmark)
    }
}

// MARK: - Cost Summary

/// Aggregated cost tracking for reporting
struct CostSummary: Codable {
    var totalSpent: Double
    var imageCount: Int
    var byResolution: [String: Double]
    var byProject: [String: Double]  // Project ID string -> cost
    
    init() {
        totalSpent = 0
        imageCount = 0
        byResolution = [:]
        byProject = [:]
    }
    
    mutating func record(cost: Double, resolution: String, projectId: UUID) {
        totalSpent += cost
        imageCount += 1
        byResolution[resolution, default: 0] += cost
        byProject[projectId.uuidString, default: 0] += cost
    }
}

// MARK: - API Logging

/// A single raw API request/response log entry
struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let type: LogType
    let payload: String // Pretty printed JSON or description
    
    enum LogType: String, Codable {
        case request
        case response
        case error
    }
    
    init(type: LogType, payload: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.type = type
        self.payload = payload
    }
}

/// Simple in-memory logger for the current session
@Observable @MainActor
class LogManager {
    static let shared = LogManager()
    var entries: [LogEntry] = []
    private let maxEntries = 100
    
    func log(_ type: LogEntry.LogType, payload: String) {
        let entry = LogEntry(type: type, payload: payload)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast()
        }
    }
    
    func clear() {
        entries = []
    }
}

// MARK: - Batch Job

/// A batch editing job containing multiple image tasks
@Observable
class BatchJob: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var projectId: UUID?
    var prompt: String
    var aspectRatio: String
    var imageSize: String
    var outputDirectory: String
    var useBatchTier: Bool
    var status: String
    var tasks: [ImageTask]

    enum CodingKeys: String, CodingKey {
        case id, createdAt, projectId, prompt, aspectRatio, imageSize, outputDirectory, useBatchTier, status, tasks
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        prompt = try container.decode(String.self, forKey: .prompt)
        aspectRatio = try container.decode(String.self, forKey: .aspectRatio)
        imageSize = try container.decode(String.self, forKey: .imageSize)
        outputDirectory = try container.decode(String.self, forKey: .outputDirectory)
        useBatchTier = try container.decode(Bool.self, forKey: .useBatchTier)
        status = try container.decode(String.self, forKey: .status)
        tasks = try container.decode([ImageTask].self, forKey: .tasks)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encode(imageSize, forKey: .imageSize)
        try container.encode(outputDirectory, forKey: .outputDirectory)
        try container.encode(useBatchTier, forKey: .useBatchTier)
        try container.encode(status, forKey: .status)
        try container.encode(tasks, forKey: .tasks)
    }
    
    init(
        prompt: String,
        aspectRatio: String = "16:9",
        imageSize: String = "4K",
        outputDirectory: String,
        useBatchTier: Bool = false,
        projectId: UUID? = nil
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.projectId = projectId
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.imageSize = imageSize
        self.outputDirectory = outputDirectory
        self.useBatchTier = useBatchTier
        self.status = "pending"
        self.tasks = []
    }
    
    var pendingCount: Int { tasks.filter { $0.status == "pending" }.count }
    var completedCount: Int { tasks.filter { $0.status == "completed" }.count }
    var failedCount: Int { tasks.filter { $0.status == "failed" }.count }
    var progress: Double {
        guard !tasks.isEmpty else { return 0 }
        return Double(completedCount + failedCount) / Double(tasks.count)
    }
    
    /// Calculate cost for a specific task based on settings
    func cost(for task: ImageTask) -> Double {
        let inputRate = useBatchTier ? 0.0006 : 0.0011
        let inputCost = inputRate * Double(max(1, task.inputPaths.count))
        
        let outputCost: Double
        if useBatchTier {
            // Batch Tier: 50% cheaper
            switch imageSize {
            case "4K": outputCost = 0.12
            case "2K", "1K": outputCost = 0.067
            default: outputCost = 0.067
            }
        } else {
            // Standard Tier
            switch imageSize {
            case "4K": outputCost = 0.24
            case "2K", "1K": outputCost = 0.134
            default: outputCost = 0.134
            }
        }
        
        return inputCost + outputCost
    }
}

// MARK: - Job Phase

/// Lifecycle phases for batch image processing
enum JobPhase: String, Codable {
    case pending
    case submitting
    case polling
    case reconnecting
    case downloading
    case completed
    case failed
    
    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .submitting: return "Submitting"
        case .polling: return "Waiting"
        case .reconnecting: return "Reconnecting"
        case .downloading: return "Downloading"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
    
    var icon: String {
        switch self {
        case .pending: return "circle"
        case .submitting: return "arrow.up.circle"
        case .polling: return "clock.arrow.circlepath"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}

// MARK: - Image Task

/// A single image editing task within a batch (can have multiple input images)
@Observable
class ImageTask: Identifiable, Codable {
    let id: UUID
    let inputPaths: [String] // Changed to array for multimodal support
    var outputPath: String?
    var status: String
    var phase: JobPhase
    var pollCount: Int
    var error: String?
    var startedAt: Date?
    var submittedAt: Date?
    var completedAt: Date?
    var externalJobName: String? // Store Gemini API job ID
    var projectId: UUID? // Added for filtering results by project

    enum CodingKeys: String, CodingKey {
        case id, inputPaths, outputPath, status, phase, pollCount, error, startedAt, submittedAt, completedAt, externalJobName, projectId
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        inputPaths = try container.decode([String].self, forKey: .inputPaths)
        outputPath = try container.decodeIfPresent(String.self, forKey: .outputPath)
        status = try container.decode(String.self, forKey: .status)
        phase = try container.decodeIfPresent(JobPhase.self, forKey: .phase) ?? .pending
        pollCount = try container.decodeIfPresent(Int.self, forKey: .pollCount) ?? 0
        error = try container.decodeIfPresent(String.self, forKey: .error)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        submittedAt = try container.decodeIfPresent(Date.self, forKey: .submittedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        externalJobName = try container.decodeIfPresent(String.self, forKey: .externalJobName)
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(inputPaths, forKey: .inputPaths)
        try container.encode(outputPath, forKey: .outputPath)
        try container.encode(status, forKey: .status)
        try container.encode(phase, forKey: .phase)
        try container.encode(pollCount, forKey: .pollCount)
        try container.encode(error, forKey: .error)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(submittedAt, forKey: .submittedAt)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(externalJobName, forKey: .externalJobName)
        try container.encode(projectId, forKey: .projectId)
    }
    
    init(inputPaths: [String], projectId: UUID? = nil) {
        self.id = UUID()
        self.inputPaths = inputPaths
        self.status = "pending"
        self.phase = .pending
        self.pollCount = 0
        self.projectId = projectId
    }
    
    init(inputPath: String, projectId: UUID? = nil) {
        self.id = UUID()
        self.inputPaths = [inputPath]
        self.status = "pending"
        self.phase = .pending
        self.pollCount = 0
        self.projectId = projectId
    }
    
    // Backward compatibility for single input path
    var inputPath: String { inputPaths.first ?? "" }
    
    var inputURLs: [URL] { inputPaths.map { URL(fileURLWithPath: $0) } }
    var inputURL: URL { inputURLs.first ?? URL(fileURLWithPath: "") }
    var outputURL: URL? { outputPath.map { URL(fileURLWithPath: $0) } }
    var filename: String { 
        if inputPaths.count > 1 {
            let label = status == "completed" ? "output" : "inputs"
            let count = status == "completed" ? "1" : "\(inputPaths.count)"
            return "Multimodal (\(count) \(label))"
        }
        return inputURL.lastPathComponent 
    }
    var errorMessage: String? { error }
    var duration: TimeInterval? {
        guard let start = startedAt, let end = completedAt else { return nil }
        return end.timeIntervalSince(start)
    }
}
