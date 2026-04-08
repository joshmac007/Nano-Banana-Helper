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
    var defaultPresetID: UUID?
    var defaultAspectRatio: String?
    var defaultImageSize: String?
    var defaultUseBatchTier: Bool?
    
    // Metadata
    var isArchived: Bool = false
    var projectNotes: String?
    
    var outputURL: URL {
        // Resolve the bookmark briefly to capture the path, then stop access immediately.
        // Display-only: we only need the path string for labels and FileManager checks.
        if let bookmark = outputDirectoryBookmark,
           let resolution = AppPaths.resolveBookmarkToPath(bookmark) {
            return URL(fileURLWithPath: resolution.path)
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
        case defaultPrompt, defaultPresetID, defaultAspectRatio, defaultImageSize, defaultUseBatchTier
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
        defaultPresetID = try container.decodeIfPresent(UUID.self, forKey: .defaultPresetID)
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
        try container.encodeIfPresent(defaultPresetID, forKey: .defaultPresetID)
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
    let tokenUsage: TokenUsage?
    let modelName: String?
    let systemPrompt: String?

    // Backward compatibility for single source path
    var sourceImagePath: String { sourceImagePaths.first ?? "" }
    
    // Security Scoped Bookmarks
    var sourceImageBookmarks: [Data]?
    var outputImageBookmark: Data?
    
    var sourceURLs: [URL] {
        // Plain path-based URLs for display and non-file-access contexts only.
        // Use AppPaths scoped helpers for image loading and Finder operations.
        return sourceImagePaths.map { URL(fileURLWithPath: $0) }
    }
    
    var sourceURL: URL { sourceURLs.first ?? URL(fileURLWithPath: "") }
    
    var outputURL: URL {
        // Plain path-based URL for display and non-file-access contexts only.
        // Use AppPaths scoped helpers for image loading and Finder operations.
        return URL(fileURLWithPath: outputImagePath)
    }

    var hasSourceImages: Bool {
        sourceImagePaths.contains { !$0.isEmpty }
    }

    var isTextToImage: Bool {
        !hasSourceImages
    }

    var generationDescription: String {
        isTextToImage ? "Text to Image" : "Image to Image"
    }
    
    enum CodingKeys: String, CodingKey {
        case id, projectId, timestamp, sourceImagePaths, outputImagePath
        case prompt, aspectRatio, imageSize, usedBatchTier, cost
        case status, error, externalJobName
        case sourceImageBookmarks, outputImageBookmark
        case tokenUsage, modelName, systemPrompt
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
        outputImageBookmark: Data? = nil,
        tokenUsage: TokenUsage? = nil,
        modelName: String? = nil,
        systemPrompt: String? = nil
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
        self.tokenUsage = tokenUsage
        self.modelName = modelName
        self.systemPrompt = systemPrompt
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
        tokenUsage = try container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
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
        try container.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
    }
}

// MARK: - Cost Summary

/// Aggregated cost tracking for reporting
struct CostSummary: Codable {
    var totalSpent: Double
    var imageCount: Int
    var byResolution: [String: Double]
    var byProject: [String: Double]  // Project ID string -> cost
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var byModel: [String: Double]

    enum CodingKeys: String, CodingKey {
        case totalSpent, imageCount, byResolution, byProject
        case totalTokens, inputTokens, outputTokens, byModel
    }

    init() {
        totalSpent = 0
        imageCount = 0
        byResolution = [:]
        byProject = [:]
        totalTokens = 0
        inputTokens = 0
        outputTokens = 0
        byModel = [:]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalSpent = try container.decode(Double.self, forKey: .totalSpent)
        imageCount = try container.decode(Int.self, forKey: .imageCount)
        byResolution = try container.decode([String: Double].self, forKey: .byResolution)
        byProject = try container.decode([String: Double].self, forKey: .byProject)
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        byModel = try container.decodeIfPresent([String: Double].self, forKey: .byModel) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalSpent, forKey: .totalSpent)
        try container.encode(imageCount, forKey: .imageCount)
        try container.encode(byResolution, forKey: .byResolution)
        try container.encode(byProject, forKey: .byProject)
        try container.encode(totalTokens, forKey: .totalTokens)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(byModel, forKey: .byModel)
    }

    mutating func record(cost: Double, resolution: String, projectId: UUID,
                         tokens: TokenUsage? = nil, modelName: String? = nil) {
        totalSpent += cost
        imageCount += 1
        byResolution[resolution, default: 0] += cost
        byProject[projectId.uuidString, default: 0] += cost
        if let tokens {
            totalTokens += tokens.totalTokenCount
            inputTokens += tokens.promptTokenCount
            outputTokens += tokens.candidatesTokenCount
        }
        if let modelName {
            byModel[modelName, default: 0] += cost
        }
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
    private let maxPayloadCharacters = 1600
    
    func log(_ type: LogEntry.LogType, payload: String) {
        let cappedPayload: String
        if payload.count > maxPayloadCharacters {
            let clipped = payload.prefix(maxPayloadCharacters)
            cappedPayload = "\(clipped)… [truncated \(payload.count - maxPayloadCharacters) chars]"
        } else {
            cappedPayload = payload
        }

        let entry = LogEntry(type: type, payload: cappedPayload)
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

enum QueueControlState: String, Codable {
    case idle
    case running
    case pausedLocal
    case resuming
    case cancelling
    case interrupted

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .pausedLocal: return "Paused locally"
        case .resuming: return "Resuming"
        case .cancelling: return "Cancelling"
        case .interrupted: return "Interrupted"
        }
    }
}

/// A batch editing job containing multiple image tasks
@Observable
class BatchJob: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var projectId: UUID?
    var modelName: String?
    var prompt: String
    var systemPrompt: String? // Added
    var aspectRatio: String
    var imageSize: String
    var outputDirectory: String
    var useBatchTier: Bool
    var status: String
    var tasks: [ImageTask]
    var isTextMode: Bool = false // For text-to-image generation

    enum CodingKeys: String, CodingKey {
        case id, createdAt, projectId, modelName, prompt, systemPrompt, aspectRatio, imageSize, outputDirectory, useBatchTier, status, tasks, isTextMode
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        prompt = try container.decode(String.self, forKey: .prompt)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) // Decode if present
        aspectRatio = try container.decode(String.self, forKey: .aspectRatio)
        imageSize = try container.decode(String.self, forKey: .imageSize)
        outputDirectory = try container.decode(String.self, forKey: .outputDirectory)
        useBatchTier = try container.decode(Bool.self, forKey: .useBatchTier)
        status = try container.decode(String.self, forKey: .status)
        tasks = try container.decode([ImageTask].self, forKey: .tasks)
        isTextMode = try container.decodeIfPresent(Bool.self, forKey: .isTextMode) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(projectId, forKey: .projectId)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encode(imageSize, forKey: .imageSize)
        try container.encode(outputDirectory, forKey: .outputDirectory)
        try container.encode(useBatchTier, forKey: .useBatchTier)
        try container.encode(status, forKey: .status)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(isTextMode, forKey: .isTextMode)
    }
    
    init(
        prompt: String,
        systemPrompt: String? = nil,
        aspectRatio: String = "16:9",
        imageSize: String = "4K",
        outputDirectory: String,
        useBatchTier: Bool = false,
        projectId: UUID? = nil,
        modelName: String? = nil
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.projectId = projectId
        self.modelName = modelName
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.aspectRatio = aspectRatio
        self.imageSize = imageSize
        self.outputDirectory = outputDirectory
        self.useBatchTier = useBatchTier
        self.status = "pending"
        self.tasks = []
    }
    
    var pendingCount: Int { tasks.filter { $0.status == "pending" }.count }
    var completedCount: Int { tasks.filter { $0.status == "completed" }.count }
    var failedCount: Int { tasks.filter { ImageTask.issueStatuses.contains($0.status) }.count }
    var progress: Double {
        guard !tasks.isEmpty else { return 0 }
        return Double(completedCount + failedCount) / Double(tasks.count)
    }
    
    /// Calculate cost for a specific task based on settings
    func cost(for task: ImageTask) -> Double {
        if isTextMode {
            return ImageSize.calculateTextModeCost(
                imageSize: imageSize,
                outputCount: 1,
                isBatchTier: useBatchTier,
                modelName: modelName
            )
        }
        return ImageSize.calculateCost(
            imageSize: imageSize,
            inputCount: task.inputPaths.count,
            isBatchTier: useBatchTier,
            modelName: modelName
        )
    }
}

// MARK: - Job Phase

/// Lifecycle phases for batch image processing
enum JobPhase: String, Codable {
    case pending
    case submitting
    case submittedRemote
    case polling
    case reconnecting
    case pausedLocal
    case cancelRequested
    case stalled
    case downloading
    case completed
    case cancelled
    case expired
    case failed
    
    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .submitting: return "Submitting"
        case .submittedRemote: return "Submitted"
        case .polling: return "Waiting"
        case .reconnecting: return "Reconnecting"
        case .pausedLocal: return "Paused locally"
        case .cancelRequested: return "Cancel requested"
        case .stalled: return "Paused locally"
        case .downloading: return "Downloading"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .expired: return "Expired"
        case .failed: return "Failed"
        }
    }
    
    var icon: String {
        switch self {
        case .pending: return "circle"
        case .submitting: return "arrow.up.circle"
        case .submittedRemote: return "tray.and.arrow.up"
        case .polling: return "clock.arrow.circlepath"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .pausedLocal: return "pause.circle"
        case .cancelRequested: return "xmark.circle"
        case .stalled: return "pause.circle"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}

// MARK: - Image Task

/// A single image editing task within a batch (can have multiple input images)
@Observable
class ImageTask: Identifiable, Codable {
    static let terminalStatuses: Set<String> = ["completed", "failed", "cancelled", "expired"]
    static let issueStatuses: Set<String> = ["failed", "expired"]

    let id: UUID
    let inputPaths: [String] // Changed to array for multimodal support
    var inputBookmarks: [Data]? // Security-scoped bookmarks for file picker selections
    var outputPath: String?
    var status: String
    var phase: JobPhase
    var pollCount: Int
    var lastPollState: String?
    var lastPollUpdatedAt: Date?
    var stalledAt: Date?
    var error: String?
    var startedAt: Date?
    var submittedAt: Date?
    var completedAt: Date?
    var externalJobName: String? // Store Gemini API job ID
    var projectId: UUID? // Added for filtering results by project
    var cancelRequestedAt: Date?
    var variationIndex: Int?
    var variationTotal: Int?

    enum CodingKeys: String, CodingKey {
        case id, inputPaths, inputBookmarks, outputPath, status, phase, pollCount
        case lastPollState, lastPollUpdatedAt, stalledAt
        case error, startedAt, submittedAt, completedAt, externalJobName, projectId, cancelRequestedAt
        case variationIndex, variationTotal
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        inputPaths = try container.decode([String].self, forKey: .inputPaths)
        inputBookmarks = try container.decodeIfPresent([Data].self, forKey: .inputBookmarks)
        outputPath = try container.decodeIfPresent(String.self, forKey: .outputPath)
        status = try container.decode(String.self, forKey: .status)
        phase = try container.decodeIfPresent(JobPhase.self, forKey: .phase) ?? .pending
        pollCount = try container.decodeIfPresent(Int.self, forKey: .pollCount) ?? 0
        lastPollState = try container.decodeIfPresent(String.self, forKey: .lastPollState)
        lastPollUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastPollUpdatedAt)
        stalledAt = try container.decodeIfPresent(Date.self, forKey: .stalledAt)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        submittedAt = try container.decodeIfPresent(Date.self, forKey: .submittedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        externalJobName = try container.decodeIfPresent(String.self, forKey: .externalJobName)
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        cancelRequestedAt = try container.decodeIfPresent(Date.self, forKey: .cancelRequestedAt)
        variationIndex = try container.decodeIfPresent(Int.self, forKey: .variationIndex)
        variationTotal = try container.decodeIfPresent(Int.self, forKey: .variationTotal)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(inputPaths, forKey: .inputPaths)
        try container.encodeIfPresent(inputBookmarks, forKey: .inputBookmarks)
        try container.encode(outputPath, forKey: .outputPath)
        try container.encode(status, forKey: .status)
        try container.encode(phase, forKey: .phase)
        try container.encode(pollCount, forKey: .pollCount)
        try container.encodeIfPresent(lastPollState, forKey: .lastPollState)
        try container.encodeIfPresent(lastPollUpdatedAt, forKey: .lastPollUpdatedAt)
        try container.encodeIfPresent(stalledAt, forKey: .stalledAt)
        try container.encode(error, forKey: .error)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(submittedAt, forKey: .submittedAt)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(externalJobName, forKey: .externalJobName)
        try container.encode(projectId, forKey: .projectId)
        try container.encodeIfPresent(cancelRequestedAt, forKey: .cancelRequestedAt)
        try container.encodeIfPresent(variationIndex, forKey: .variationIndex)
        try container.encodeIfPresent(variationTotal, forKey: .variationTotal)
    }
    
    init(
        inputPaths: [String],
        projectId: UUID? = nil,
        inputBookmarks: [Data]? = nil,
        variationIndex: Int? = nil,
        variationTotal: Int? = nil
    ) {
        self.id = UUID()
        self.inputPaths = inputPaths
        self.inputBookmarks = inputBookmarks
        self.status = "pending"
        self.phase = .pending
        self.pollCount = 0
        self.lastPollState = nil
        self.lastPollUpdatedAt = nil
        self.stalledAt = nil
        self.projectId = projectId
        self.cancelRequestedAt = nil
        self.variationIndex = variationIndex
        self.variationTotal = variationTotal
    }
    
    init(
        inputPath: String,
        projectId: UUID? = nil,
        inputBookmark: Data? = nil,
        variationIndex: Int? = nil,
        variationTotal: Int? = nil
    ) {
        self.id = UUID()
        self.inputPaths = [inputPath]
        self.inputBookmarks = inputBookmark.map { [$0] }
        self.status = "pending"
        self.phase = .pending
        self.pollCount = 0
        self.lastPollState = nil
        self.lastPollUpdatedAt = nil
        self.stalledAt = nil
        self.projectId = projectId
        self.cancelRequestedAt = nil
        self.variationIndex = variationIndex
        self.variationTotal = variationTotal
    }
    
    // Backward compatibility for single input path
    var inputPath: String { inputPaths.first ?? "" }
    
    /// Returns plain path-based URLs for display purposes.
    /// For security-scoped access during batch processing, use `inputBookmarks` via
    /// `AppPaths.withResolvedBookmark` or `AppPaths.resolveBookmark` (with paired stop call).
    var inputURLs: [URL] { inputPaths.map { URL(fileURLWithPath: $0) } }
    var inputURL: URL { URL(fileURLWithPath: inputPath) }
    var outputURL: URL? { outputPath.map { URL(fileURLWithPath: $0) } }
    var filename: String {
        let baseName: String
        if inputPaths.count > 1 {
            let label = status == "completed" ? "output" : "inputs"
            let count = status == "completed" ? "1" : "\(inputPaths.count)"
            baseName = "Multimodal (\(count) \(label))"
        } else if inputPaths.isEmpty {
            baseName = "Generated Image \(shortDisplayID)"
        } else {
            let component = URL(fileURLWithPath: inputPath).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !component.isEmpty, !Self.genericDisplayNames.contains(component.lowercased()) {
                baseName = component
            } else {
                baseName = "Image \(shortDisplayID)"
            }
        }

        if let variationLabel {
            return "\(baseName) (\(variationLabel))"
        }
        return baseName
    }
    var errorMessage: String? { error }
    var duration: TimeInterval? {
        guard let start = startedAt, let end = completedAt else { return nil }
        return end.timeIntervalSince(start)
    }

    var isTerminal: Bool {
        Self.terminalStatuses.contains(status)
    }

    var isIssue: Bool {
        Self.issueStatuses.contains(status)
    }

    var hasRemoteJob: Bool {
        externalJobName != nil
    }

    var variationLabel: String? {
        guard let variationIndex, let variationTotal, variationTotal > 1 else { return nil }
        return "Variation \(variationIndex)/\(variationTotal)"
    }

    private static let genericDisplayNames: Set<String> = ["data", "image", "file"]

    private var shortDisplayID: String {
        String(id.uuidString.prefix(8)).uppercased()
    }
}

// MARK: - Image Size Configuration

/// Supported output image sizes with centralized pricing
enum ImageSize: String, CaseIterable, Identifiable {
    case size512 = "512"
    case size1K = "1K"
    case size2K = "2K"
    case size4K = "4K"
    
    var id: String { rawValue }
    
    var displayName: String { rawValue }
    
    /// Output cost per image for standard tier
    var standardCost: Double {
        AppPricing.outputRate(for: self, modelName: nil, isBatchTier: false)
    }
    
    /// Output cost per image for batch tier (50% off)
    var batchCost: Double {
        AppPricing.outputRate(for: self, modelName: nil, isBatchTier: true)
    }
    
    /// Get cost for given tier
    func cost(modelName: String?, isBatchTier: Bool) -> Double {
        AppPricing.outputRate(for: self, modelName: modelName, isBatchTier: isBatchTier)
    }
    
    /// Calculate total cost including input images
    static func calculateCost(imageSize: String, inputCount: Int, isBatchTier: Bool, modelName: String?) -> Double {
        let inputRate = AppPricing.inputRate(modelName: modelName, isBatchTier: isBatchTier)
        let inputCost = inputRate * Double(max(1, inputCount))
        
        guard let size = ImageSize(rawValue: imageSize) else {
            return inputCost + AppPricing.outputFallbackRate(modelName: modelName, isBatchTier: isBatchTier)
        }
        
        return inputCost + size.cost(modelName: modelName, isBatchTier: isBatchTier)
    }
    
    /// Calculate cost for text-to-image generation (no input images)
    static func calculateTextModeCost(imageSize: String, outputCount: Int, isBatchTier: Bool, modelName: String?) -> Double {
        guard let size = ImageSize(rawValue: imageSize) else {
            return Double(outputCount) * AppPricing.outputFallbackRate(modelName: modelName, isBatchTier: isBatchTier)
        }
        return Double(outputCount) * size.cost(modelName: modelName, isBatchTier: isBatchTier)
    }
}
