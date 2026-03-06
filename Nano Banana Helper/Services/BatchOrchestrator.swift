import Foundation
import Observation
import UserNotifications
import CoreGraphics

// MARK: - Sendable Helpers
struct InputProbeData: Sendable {
    let exists: Bool
    let readable: Bool
    let sizeBytes: Int?
    let modifiedAtISO8601: String?
    let inode: UInt64?
    let volumeUUID: String?
    let iCloudStatus: String
}

struct InputForensicRecord: Sendable {
    let inputIndex: Int
    let path: String
    let pathHash: String
    let pathBasename: String
    var bookmarkPresent: Bool
    var bookmarkResolveOK: Bool?
    var bookmarkIsStale: Bool?
    var scopeStartOK: Bool?
    var probe: InputProbeData?
}

struct JobSubmissionData: Sendable {
    let id: UUID
    let batchId: UUID?
    let projectId: UUID?
    let inputURLs: [URL]       // Security-scoped URLs (already started access)
    let inputPaths: [String]
    let hasSecurityScope: Bool // Whether we need to stop access after use
    let maskImageData: Data?   // Added for inpainting
    let customPrompt: String?  // Added for individual custom prompts
    let inputForensics: [InputForensicRecord]

    init(
        id: UUID,
        batchId: UUID? = nil,
        projectId: UUID? = nil,
        inputURLs: [URL],
        inputPaths: [String],
        hasSecurityScope: Bool,
        maskImageData: Data?,
        customPrompt: String?,
        inputForensics: [InputForensicRecord] = []
    ) {
        self.id = id
        self.batchId = batchId
        self.projectId = projectId
        self.inputURLs = inputURLs
        self.inputPaths = inputPaths
        self.hasSecurityScope = hasSecurityScope
        self.maskImageData = maskImageData
        self.customPrompt = customPrompt
        self.inputForensics = inputForensics
    }
}

struct BatchSettings: Sendable {
    let prompt: String
    let systemPrompt: String?
    let modelName: String
    let aspectRatio: String
    let imageSize: String
    let outputDirectory: String
    let outputDirectoryBookmark: Data?
    let useBatchTier: Bool
    let projectId: UUID?
    
    // Helper for cost calculation
    func cost(inputCount: Int, imageSizeOverride: String? = nil) -> Double {
        PricingEngine.estimate(
            modelName: modelName,
            imageSize: imageSizeOverride ?? imageSize,
            isBatchTier: useBatchTier,
            inputCount: inputCount,
            outputCount: 1
        ).total
    }
}

private enum OutputDirectoryAccessError: LocalizedError {
    case bookmarkAccessFailed(path: String)
    case missingBookmark(path: String)
    
    var errorDescription: String? {
        switch self {
        case .bookmarkAccessFailed(let path):
            return "Cannot access the output folder anymore. Re-select Output Location and retry. (\(path))"
        case .missingBookmark(let path):
            return "Output folder permission is required before writing files. Re-select Output Location and retry. (\(path))"
        }
    }
}

private enum InputFileAccessError: LocalizedError {
    case missingBookmark(path: String)
    case bookmarkAccessFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .missingBookmark(let path):
            return "Source image access permission is missing. Re-select the file and retry. (\(path))"
        case .bookmarkAccessFailed(let path):
            return "Cannot access the source image anymore. Re-add the file and retry. (\(path))"
        }
    }
}

private enum RegionEditPipelineError: LocalizedError {
    case requiresSingleInput
    case missingMask
    case missingCropMetadata
    case missingSourceImage
    case sourceBookmarkAccessFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .requiresSingleInput:
            return "Region Edit requires exactly one input image."
        case .missingMask:
            return "Region Edit mask is missing for this task."
        case .missingCropMetadata:
            return "Region Edit crop metadata is missing. Re-save the region edit and retry."
        case .missingSourceImage:
            return "Source image could not be loaded for local region compositing."
        case .sourceBookmarkAccessFailed(let path):
            return "Cannot access the source image anymore. Re-add the image and retry. (\(path))"
        }
    }
}

private enum FailureClassification: String, Codable {
    case permissionDenied = "permission_denied"
    case bookmarkResolveFailed = "bookmark_resolve_failed"
    case bookmarkStale = "bookmark_stale"
    case fileMissing = "file_missing"
    case fileUnreadable = "file_unreadable"
    case payloadLimitExceeded = "payload_limit_exceeded"
    case unknown = "unknown"
}

private struct FailureSnapshotInput: Codable {
    struct BookmarkState: Codable {
        let present: Bool
        let resolveOK: Bool?
        let isStale: Bool?
    }

    struct ScopeState: Codable {
        let startOK: Bool?
        let stopCalled: Bool
    }

    struct ProbeState: Codable {
        let exists: Bool
        let readable: Bool
        let sizeBytes: Int?
        let modifiedAtISO8601: String?
        let inode: UInt64?
        let volumeUUID: String?
        let iCloudStatus: String
    }

    let inputIndex: Int
    let pathHash: String
    let pathBasename: String
    let bookmark: BookmarkState
    let scope: ScopeState
    let probe: ProbeState?
}

private struct FailureSnapshot: Codable {
    struct SnapshotError: Codable {
        let classifiedAs: FailureClassification
        let message: String
        let errorDomain: String
        let errorCode: Int
        let underlyingErrorDomain: String?
        let underlyingErrorCode: Int?
    }

    let schemaVersion: Int
    let createdAt: Date
    let launchId: String
    let sessionId: String
    let projectId: String
    let batchId: String
    let taskId: String
    let jobId: String
    let model: String
    let batchTier: Bool
    let submitMode: String
    let payloadEstimateBytes: Int?
    let payloadLimitBytes: Int
    let error: SnapshotError
    let inputs: [FailureSnapshotInput]
}

private struct ResolvedOutputScope {
    let directoryURL: URL
    let requiresStopAccess: Bool
}

/// Orchestrates batch processing of image editing tasks
@Observable
@MainActor
final class BatchOrchestrator {
    // Permission hardening is always enforced (rollout complete).
    private let strictPermissionEnforcement = true

    private enum RunState {
        case idle
        case running
        case pausing
        case paused
        case cancelling
    }

    private let regionEditPromptClause = "Only change the intended region in this cropped image. Preserve all unrequested details, lighting, perspective, and style consistency."

    // Computed views over activeBatches
    var pendingJobs: [ImageTask] {
        activeBatches.flatMap { $0.tasks.filter { $0.status == .pending } }
    }
    var processingJobs: [ImageTask] {
        activeBatches.flatMap { $0.tasks.filter { $0.status == .processing } }
    }
    var completedJobs: [ImageTask] {
        activeBatches.flatMap { $0.tasks.filter { $0.status == .completed } }
    }
    var failedJobs: [ImageTask] {
        activeBatches.flatMap { $0.tasks.filter { $0.status == .failed } }
    }
    
    var isRunning: Bool {
        !isPaused && !activeBatches.filter { $0.status == .processing }.isEmpty
    }
    var isPaused: Bool {
        runState == .pausing || runState == .paused
    }
    var currentProgress: Double = 0.0
    var statusMessage: String = "Ready"
    
    private var activeBatches: [BatchJob] = []
    private let service = NanoBananaService()
    private let securityScopedPathing: any SecurityScopedPathing
    private let concurrencyLimit = 5 // Paid tier: safe default for concurrent submissions
    private let sessionID = UUID().uuidString
    private let forensicDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var runState: RunState = .idle
    private var batchRunnerTasks: [UUID: Task<Void, Never>] = [:]
    private var pollTasks: [UUID: Task<Void, Never>] = [:]

    // Callbacks for history/cost tracking
    var onImageCompleted: ((HistoryEntry) -> Void)?
    var onCostIncurred: ((Double, String, String, UUID) -> Void)?
    var onHistoryEntryUpdated: ((String, HistoryEntry) -> Void)?
    var onOutputDirectoryBookmarkRefreshed: ((UUID, Data) -> Void)?
    var onRestoreSettings: ((HistoryEntry) -> Void)?
    
    private let activeBatchURL = AppPaths.activeBatchURL

    @MainActor
    init(securityScopedPathing: any SecurityScopedPathing = LiveSecurityScopedPathing()) {
        self.securityScopedPathing = securityScopedPathing
        loadActiveBatches()
        sanitizeRestoredBatchesForAccess()
        refreshRunStateFromBatches()
        DebugLog.info("batch", "BatchOrchestrator initialized", metadata: [
            "restored_batches": String(activeBatches.count)
        ])
    }
    
    /// Enqueue a new batch job for processing
    func enqueue(_ batch: BatchJob) {
        activeBatches.append(batch)
        let tasksMissingInputBookmarks = batch.tasks.filter { !$0.inputPaths.isEmpty && (($0.inputBookmarks ?? []).isEmpty) }.count
        let inputCount = batch.tasks.reduce(0) { $0 + $1.inputPaths.count }
        let bookmarkCount = batch.tasks.reduce(0) { $0 + ($1.inputBookmarks?.count ?? 0) }
        let scopeRequiredCount = batch.tasks
            .flatMap(\.inputPaths)
            .filter { securityScopedPathing.requiresSecurityScope(path: $0) }
            .count
        let sourceMode: String
        if inputCount == 0 {
            sourceMode = "text_to_image"
        } else if scopeRequiredCount == 0 {
            sourceMode = "managed_paths"
        } else if bookmarkCount == 0 {
            sourceMode = "external_no_bookmarks"
        } else if bookmarkCount < inputCount {
            sourceMode = "external_partial_bookmarks"
        } else {
            sourceMode = "external_bookmarked"
        }
        DebugLog.info("batch.enqueue", "Enqueued batch", metadata: [
            "batch_id": batch.id.uuidString,
            "task_count": String(batch.tasks.count),
            "project_id": batch.projectId?.uuidString ?? "nil",
            "has_output_bookmark": String(batch.outputDirectoryBookmark != nil),
            "tasks_missing_input_bookmarks": String(tasksMissingInputBookmarks),
            "input_count": String(inputCount),
            "bookmark_count": String(bookmarkCount),
            "scope_required_count": String(scopeRequiredCount),
            "source_mode": sourceMode,
            "fallback_used": "false"
        ])
        
        // Ensure all tasks have the project ID
        for task in batch.tasks {
            task.projectId = batch.projectId
        }
        
        saveActiveBatches()
        updateProgress()
        
        // Auto-start this batch
        _ = launchBatchRunner(for: batch)
    }
    
    /// Start or resume batch processing
    func start(batch: BatchJob) async {
        guard batch.status != .completed && batch.status != .cancelled else { return }
        guard runState != .cancelling else { return }
        DebugLog.info("batch.start", "Starting batch", metadata: [
            "batch_id": batch.id.uuidString,
            "status": batch.status.rawValue,
            "tasks": String(batch.tasks.count)
        ])
        
        // Request notification permission - Skip in tests
        if !isTesting && Bundle.main.bundleIdentifier != nil {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        
        runState = .running
        batch.status = .processing
        statusMessage = "Processing \(activeBatches.count) batches..."
        
        await processQueue(batch: batch)
    }
    
    /// Resume all interrupted batches
    func startAll() async {
        if runState == .paused || runState == .pausing {
            runState = .running
        }

        var runners: [Task<Void, Never>] = []
        for batch in activeBatches where batch.status == .pending || batch.status == .processing || batch.status == .paused {
            if let runner = launchBatchRunner(for: batch) {
                runners.append(runner)
            }
        }
        if runners.isEmpty {
            refreshRunStateFromBatches()
        }
        for runner in runners {
            await runner.value
        }
    }
    
    /// Pause batch processing
    func pause() {
        guard runState != .paused && runState != .pausing else { return }
        guard runState != .cancelling else { return }
        guard activeBatches.contains(where: { $0.status == .processing }) || !pollTasks.isEmpty else { return }

        runState = .pausing
        statusMessage = "Pausing..."
        markProcessingBatchesAsPaused()
        cancelActivePollTasks()
        saveActiveBatches()

        if pollTasks.isEmpty {
            finalizePause()
        }
    }
    
    /// Cancel all pending tasks
    func cancel() {
        runState = .cancelling
        cancelActivePollTasks()
        cancelActiveBatchRunners()

        // Cancel all batches
        for batch in activeBatches {
             cancel(batch: batch)
        }
        activeBatches = []
        batchRunnerTasks.removeAll()
        pollTasks.removeAll()
        runState = .idle
        statusMessage = "Cancelled all jobs"
        saveActiveBatches()
        updateProgress()
    }
    
    func cancel(batch: BatchJob) {
        batch.status = .cancelled
        
        // Move all pending/processing to failed and cancel on API side
        let jobsToCancel = batch.tasks.filter { $0.status == .processing || $0.status == .pending || $0.status == .submitting }
        
        for job in jobsToCancel {
            job.status = .failed
            job.phase = .failed
            job.error = "Cancelled by user"
            
            // Record cancellation in history
            if let projectId = batch.projectId {
                let entry = HistoryEntry(
                    projectId: projectId,
                    sourceImagePaths: job.inputPaths,
                    outputImagePath: "",
                    prompt: batch.prompt,
                    modelName: batch.modelName,
                    aspectRatio: batch.aspectRatio,
                    imageSize: batch.imageSize,
                    usedBatchTier: batch.useBatchTier,
                    cost: 0,
                    status: "cancelled",
                    error: "Cancelled by user",
                    externalJobName: job.externalJobName
                )
                if let jobName = job.externalJobName {
                    onHistoryEntryUpdated?(jobName, entry)
                } else {
                    onImageCompleted?(entry)
                }
            }
        }
        
        // Fix #2: Cancel API jobs in background — capture service explicitly to avoid implicit
        // main-actor capture; store task to give ARC a chance to keep it alive until completion.
        let namesToCancel = jobsToCancel.compactMap { $0.externalJobName }
        let service = self.service
        Task.detached {
            for jobName in namesToCancel {
                try? await service.cancelBatchJob(jobName: jobName)
            }
        }
        
        statusMessage = "Cancelled"
        saveActiveBatches()
        updateProgress()
    }
    
    /// Reset the orchestrator for a new session (clears history of current view)
    func reset() {
        cancelActivePollTasks()
        cancelActiveBatchRunners()
        activeBatches = []
        batchRunnerTasks.removeAll()
        pollTasks.removeAll()
        runState = .idle
        currentProgress = 0.0
        statusMessage = "Ready"
    }
    
    /// Remove failed tasks at specific indices
    func removeFailedTasks(at offsets: IndexSet) {
        // Fix #4: snapshot the collection before mutating to avoid stale index reads.
        let snapshot = failedJobs
        let tasksToRemove = offsets.map { snapshot[$0] }
        for task in tasksToRemove {
             if let batchIndex = activeBatches.firstIndex(where: { $0.tasks.contains(where: { $0.id == task.id }) }) {
                 activeBatches[batchIndex].tasks.removeAll(where: { $0.id == task.id })
                 if activeBatches[batchIndex].tasks.isEmpty {
                     activeBatches.remove(at: batchIndex)
                 }
             }
        }
        updateProgress()
        saveActiveBatches()
    }
    
    /// Remove completed tasks at specific indices
    func removeCompletedTasks(at offsets: IndexSet) {
        // Fix #4: snapshot the collection before mutating to avoid stale index reads.
        let snapshot = completedJobs
        let tasksToRemove = offsets.map { snapshot[$0] }
        for task in tasksToRemove {
             if let batchIndex = activeBatches.firstIndex(where: { $0.tasks.contains(where: { $0.id == task.id }) }) {
                 activeBatches[batchIndex].tasks.removeAll(where: { $0.id == task.id })
                 if activeBatches[batchIndex].tasks.isEmpty {
                     activeBatches.remove(at: batchIndex)
                 }
             }
        }
        updateProgress()
        saveActiveBatches()
    }
    
    /// Remove pending tasks at specific indices
    func removePendingTasks(at offsets: IndexSet) {
        // Fix #4: snapshot the collection before mutating to avoid stale index reads.
        let snapshot = pendingJobs
        let tasksToRemove = offsets.map { snapshot[$0] }
        for task in tasksToRemove {
             if let batchIndex = activeBatches.firstIndex(where: { $0.tasks.contains(where: { $0.id == task.id }) }) {
                 activeBatches[batchIndex].tasks.removeAll(where: { $0.id == task.id })
                 if activeBatches[batchIndex].tasks.isEmpty {
                     activeBatches.remove(at: batchIndex)
                 }
             }
        }
        updateProgress()
        saveActiveBatches()
    }
    
    /// Check if there are interrupted jobs that need resuming
    var hasInterruptedJobs: Bool {
        activeBatches.contains { batch in
            batch.tasks.contains { $0.externalJobName != nil && ($0.phase == .polling || $0.phase == .reconnecting) } && batch.status != .processing
        }
    }
    
    func resumeInterruptedJobs() async {
        await startAll()
    }

    private var shouldPauseProcessing: Bool {
        runState == .pausing || runState == .paused
    }

    @discardableResult
    private func launchBatchRunner(for batch: BatchJob) -> Task<Void, Never>? {
        guard batch.status != .completed && batch.status != .cancelled else { return nil }
        guard runState != .pausing && runState != .paused && runState != .cancelling else { return nil }
        if let existing = batchRunnerTasks[batch.id], !existing.isCancelled {
            return existing
        }

        let runner = Task { [weak self] in
            guard let self else { return }
            await self.start(batch: batch)
            self.finishBatchRunner(batchId: batch.id)
        }
        batchRunnerTasks[batch.id] = runner
        return runner
    }

    private func finishBatchRunner(batchId: UUID) {
        batchRunnerTasks.removeValue(forKey: batchId)
        if runState != .pausing && runState != .paused {
            refreshRunStateFromBatches()
        }
    }

    private func cancelActivePollTasks() {
        for task in pollTasks.values {
            task.cancel()
        }
    }

    private func cancelActiveBatchRunners() {
        for task in batchRunnerTasks.values {
            task.cancel()
        }
    }

    private func markProcessingBatchesAsPaused() {
        for batch in activeBatches where batch.status == .processing {
            batch.status = .paused
        }
    }

    private func finalizePause() {
        markProcessingBatchesAsPaused()
        runState = .paused
        statusMessage = "Paused"
        saveActiveBatches()
        refreshRunStateFromBatches()
    }

    private func markPollJobInterrupted(jobId: UUID) {
        if let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == jobId }),
           job.status == .processing {
            job.phase = .reconnecting
        }
    }

    private func refreshRunStateFromBatches() {
        guard runState != .cancelling else { return }

        let hasProcessing = activeBatches.contains { $0.status == .processing }
        let hasPaused = activeBatches.contains { $0.status == .paused }

        if shouldPauseProcessing {
            if hasProcessing {
                runState = .pausing
            } else if hasPaused {
                runState = .paused
            } else {
                runState = .idle
            }
            return
        }

        if hasProcessing {
            runState = .running
        } else if hasPaused {
            runState = .paused
        } else {
            runState = .idle
        }
    }

    @discardableResult
    private func finalizeBatchStatusIfFinished(_ batch: BatchJob) -> Bool {
        guard !batch.tasks.contains(where: { $0.status == .processing || $0.status == .pending }) else {
            return false
        }

        if batch.tasks.contains(where: { $0.status == .failed }) {
            batch.status = .failed
            statusMessage = "Completed with errors"
        } else {
            batch.status = .completed
            let count = batch.tasks.filter { $0.status == .completed }.count
            statusMessage = "Completed: \(count) output images"
        }

        refreshRunStateFromBatches()
        return true
    }
    
    private func processQueue(batch: BatchJob) async {
        if shouldPauseProcessing {
            if finalizeBatchStatusIfFinished(batch) {
                await sendCompletionNotification()
                return
            }
            finalizePause()
            return
        }

        // 1. Queue all pending jobs in THIS batch to Processing immediately
        let jobsToSubmit = batch.tasks.filter { $0.status == .pending }
        for job in jobsToSubmit {
             job.status = .processing
        }
        updateProgress()
        
        statusMessage = "Submitting \(jobsToSubmit.count) jobs..."
        
        let batchSettings = BatchSettings(
            prompt: batch.prompt,
            systemPrompt: batch.systemPrompt,
            modelName: batch.modelName,
            aspectRatio: batch.aspectRatio,
            imageSize: batch.imageSize,
            outputDirectory: batch.outputDirectory,
            outputDirectoryBookmark: batch.outputDirectoryBookmark,
            useBatchTier: batch.useBatchTier,
            projectId: batch.projectId
        )

        // Resolve output directory scope ONCE for the entire batch runtime
        let resolvedOutput: ResolvedOutputScope
        let batchBaseMeta = forensicMetadata(
            batchId: batch.id,
            projectId: batch.projectId,
            taskId: batch.tasks.first?.id ?? UUID(),
            jobId: batch.tasks.first?.id ?? UUID()
        )
        if let bookmark = batch.outputDirectoryBookmark {
            guard let resolved = securityScopedPathing.resolveBookmarkAccess(bookmark, metadata: mergedMetadata(batchBaseMeta, [
                "path": batch.outputDirectory
            ])) else {
                DebugLog.error("batch.output", "Batch output bookmark resolution failed", metadata: mergedMetadata(batchBaseMeta, [
                    "batch_id": batch.id.uuidString,
                    "path": batch.outputDirectory
                ]))
                statusMessage = "Output folder access denied. Re-select it."
                for job in batch.tasks where job.status == .pending || job.status == .processing {
                    job.status = .failed
                    job.phase = .failed
                    job.error = "Output folder access denied"
                }
                _ = finalizeBatchStatusIfFinished(batch)
                return
            }
            resolvedOutput = ResolvedOutputScope(directoryURL: resolved.url, requiresStopAccess: true)
            if let refreshed = resolved.refreshedBookmarkData {
                batch.outputDirectoryBookmark = refreshed
                if let projectId = batch.projectId {
                    onOutputDirectoryBookmarkRefreshed?(projectId, refreshed)
                }
            }
        } else if strictPermissionEnforcement && securityScopedPathing.requiresSecurityScope(path: batch.outputDirectory) {
            statusMessage = "Output folder needs permission. Re-select it."
            for job in batch.tasks where job.status == .pending || job.status == .processing {
                job.status = .failed
                job.phase = .failed
                job.error = "Output folder requires permission"
            }
            _ = finalizeBatchStatusIfFinished(batch)
            return
        } else {
            resolvedOutput = ResolvedOutputScope(directoryURL: URL(fileURLWithPath: batch.outputDirectory), requiresStopAccess: false)
        }
        defer {
            if resolvedOutput.requiresStopAccess {
                securityScopedPathing.stopAccessing(resolvedOutput.directoryURL, metadata: mergedMetadata(batchBaseMeta, [
                    "batch_id": batch.id.uuidString,
                    "event": "security.scope.stop.batch"
                ]))
            }
        }

        var submissionDataList: [JobSubmissionData] = []
        submissionDataList.reserveCapacity(jobsToSubmit.count)

        for job in jobsToSubmit {
            let inputPaths = job.inputPaths
            let inputCount = inputPaths.count
            let bookmarkCount = job.inputBookmarks?.count ?? 0
            let scopeRequiredCount = inputPaths.filter { securityScopedPathing.requiresSecurityScope(path: $0) }.count
            let sourceMode = inputCount == 0 ? "text_to_image" : (scopeRequiredCount == 0 ? "managed_paths" : "external_paths")
            let baseMeta = forensicMetadata(
                batchId: batch.id,
                projectId: batch.projectId,
                taskId: job.id,
                jobId: job.id
            )
            var inputForensics: [InputForensicRecord] = inputPaths.enumerated().map { index, path in
                InputForensicRecord(
                    inputIndex: index,
                    path: path,
                    pathHash: securityScopedPathing.pathHash(for: path),
                    pathBasename: securityScopedPathing.pathBasename(for: path),
                    bookmarkPresent: false,
                    bookmarkResolveOK: nil,
                    bookmarkIsStale: nil,
                    scopeStartOK: nil,
                    probe: nil
                )
            }

            if inputCount == 0 {
                DebugLog.debug("batch.input", "Prepared submission without source files", metadata: mergedMetadata(baseMeta, [
                    "job_id": job.id.uuidString,
                    "input_count": "0",
                    "bookmark_count": "0",
                    "scope_required_count": "0",
                    "source_mode": sourceMode,
                    "fallback_used": "false"
                ]))
                submissionDataList.append(
                    JobSubmissionData(
                        id: job.id,
                        batchId: batch.id,
                        projectId: batch.projectId,
                        inputURLs: [],
                        inputPaths: [],
                        hasSecurityScope: false,
                        maskImageData: job.maskImageData ?? batch.maskImageData,
                        customPrompt: job.customPrompt,
                        inputForensics: []
                    )
                )
                continue
            }

            if strictPermissionEnforcement && scopeRequiredCount > 0 {
                let resolution = SecurityScopedInputResolver.resolve(
                    inputPaths: inputPaths,
                    inputBookmarks: job.inputBookmarks,
                    pathing: securityScopedPathing,
                    metadataForBookmark: { bookmarkIndex, expectedPath in
                        forensicMetadata(
                            batchId: batch.id,
                            projectId: batch.projectId,
                            taskId: job.id,
                            jobId: job.id,
                            inputIndex: bookmarkIndex,
                            path: expectedPath
                        )
                    }
                )

                switch resolution {
                case .failure(.missingBookmark(let missingPath)):
                    if let failedIndex = inputPaths.firstIndex(where: {
                        URL(fileURLWithPath: $0).standardizedFileURL.path == URL(fileURLWithPath: missingPath).standardizedFileURL.path
                    }), inputForensics.indices.contains(failedIndex) {
                        inputForensics[failedIndex].bookmarkPresent = false
                        inputForensics[failedIndex].bookmarkResolveOK = false
                        inputForensics[failedIndex].scopeStartOK = false
                    }

                    DebugLog.error("batch.input", "Missing input bookmark; failing before submission", metadata: mergedMetadata(baseMeta, [
                        "job_id": job.id.uuidString,
                        "input_count": String(inputCount),
                        "bookmark_count": String(bookmarkCount),
                        "scope_required_count": String(scopeRequiredCount),
                        "path": missingPath,
                        "path_hash": securityScopedPathing.pathHash(for: missingPath),
                        "path_basename": securityScopedPathing.pathBasename(for: missingPath),
                        "source_mode": sourceMode,
                        "fallback_used": "false"
                    ]))

                    let failureData = JobSubmissionData(
                        id: job.id,
                        batchId: batch.id,
                        projectId: batch.projectId,
                        inputURLs: [],
                        inputPaths: inputPaths,
                        hasSecurityScope: false,
                        maskImageData: job.maskImageData ?? batch.maskImageData,
                        customPrompt: job.customPrompt,
                        inputForensics: inputForensics
                    )

                    await writeFailureSnapshot(
                        for: InputFileAccessError.missingBookmark(path: missingPath),
                        data: failureData,
                        settings: batchSettings
                    )
                    await handleError(
                        jobId: job.id,
                        data: failureData,
                        settings: batchSettings,
                        error: InputFileAccessError.missingBookmark(path: missingPath)
                    )
                    continue

                case .failure(.bookmarkAccessFailed(let failedPath)):
                    if let failedIndex = inputPaths.firstIndex(where: {
                        URL(fileURLWithPath: $0).standardizedFileURL.path == URL(fileURLWithPath: failedPath).standardizedFileURL.path
                    }), inputForensics.indices.contains(failedIndex) {
                        inputForensics[failedIndex].bookmarkPresent = true
                        inputForensics[failedIndex].bookmarkResolveOK = false
                        inputForensics[failedIndex].scopeStartOK = false
                    }

                    DebugLog.error("batch.input", "Input bookmark resolution failed; failing before submission", metadata: mergedMetadata(baseMeta, [
                        "job_id": job.id.uuidString,
                        "input_count": String(inputCount),
                        "bookmark_count": String(bookmarkCount),
                        "scope_required_count": String(scopeRequiredCount),
                        "path": failedPath,
                        "path_hash": securityScopedPathing.pathHash(for: failedPath),
                        "path_basename": securityScopedPathing.pathBasename(for: failedPath),
                        "source_mode": sourceMode,
                        "fallback_used": "false",
                        "bookmark_resolve_failed": "true"
                    ]))

                    let failureData = JobSubmissionData(
                        id: job.id,
                        batchId: batch.id,
                        projectId: batch.projectId,
                        inputURLs: [],
                        inputPaths: inputPaths,
                        hasSecurityScope: false,
                        maskImageData: job.maskImageData ?? batch.maskImageData,
                        customPrompt: job.customPrompt,
                        inputForensics: inputForensics
                    )

                    await writeFailureSnapshot(
                        for: InputFileAccessError.bookmarkAccessFailed(path: failedPath),
                        data: failureData,
                        settings: batchSettings
                    )
                    await handleError(
                        jobId: job.id,
                        data: failureData,
                        settings: batchSettings,
                        error: InputFileAccessError.bookmarkAccessFailed(path: failedPath)
                    )
                    continue

                case .success(let resolvedInputs):
                    if let bookmarks = job.inputBookmarks {
                        let refreshedBookmarks = resolvedInputs.applyingRefreshes(to: bookmarks)
                        if refreshedBookmarks != bookmarks {
                            job.inputBookmarks = refreshedBookmarks
                            saveActiveBatches()
                            DebugLog.info("batch.input", "Refreshed one or more input bookmarks", metadata: mergedMetadata(baseMeta, [
                                "job_id": job.id.uuidString,
                                "input_count": String(inputCount),
                                "bookmark_refresh_persisted": "true"
                            ]))
                        }
                    }

                    for (index, path) in inputPaths.enumerated() {
                        if let bookmarkIndex = resolvedInputs.bookmarkIndexByInputIndex[index] {
                            inputForensics[index].bookmarkPresent = true
                            inputForensics[index].bookmarkResolveOK = true
                            inputForensics[index].bookmarkIsStale = resolvedInputs.staleByInputIndex[index]
                            inputForensics[index].scopeStartOK = true
                            let probe = probeInputFile(url: resolvedInputs.inputURLs[index])
                            inputForensics[index].probe = probe
                            logInputProbe(
                                probe,
                                metadata: forensicMetadata(
                                    batchId: batch.id,
                                    projectId: batch.projectId,
                                    taskId: job.id,
                                    jobId: job.id,
                                    inputIndex: bookmarkIndex,
                                    path: path
                                )
                            )
                        } else {
                            inputForensics[index].bookmarkPresent = false
                            let url = URL(fileURLWithPath: path)
                            let probe = probeInputFile(url: url)
                            inputForensics[index].probe = probe
                            logInputProbe(
                                probe,
                                metadata: forensicMetadata(
                                    batchId: batch.id,
                                    projectId: batch.projectId,
                                    taskId: job.id,
                                    jobId: job.id,
                                    inputIndex: index,
                                    path: path
                                )
                            )
                        }
                    }

                    DebugLog.debug("batch.input", "Prepared submission with security-scoped inputs", metadata: mergedMetadata(baseMeta, [
                    "job_id": job.id.uuidString,
                    "input_count": String(inputCount),
                    "bookmark_count": String(bookmarkCount),
                    "scope_required_count": String(scopeRequiredCount),
                    "source_mode": sourceMode,
                    "fallback_used": "false"
                ]))
                    submissionDataList.append(
                        JobSubmissionData(
                            id: job.id,
                            batchId: batch.id,
                            projectId: batch.projectId,
                            inputURLs: resolvedInputs.inputURLs,
                            inputPaths: inputPaths,
                            hasSecurityScope: !resolvedInputs.scopedInputIndices.isEmpty,
                            maskImageData: job.maskImageData ?? batch.maskImageData,
                            customPrompt: job.customPrompt,
                            inputForensics: inputForensics
                        )
                    )
                    continue
                }
            }

            for (index, path) in inputPaths.enumerated() {
                let url = URL(fileURLWithPath: path)
                let probe = probeInputFile(url: url)
                if inputForensics.indices.contains(index) {
                    inputForensics[index].probe = probe
                }
                logInputProbe(
                    probe,
                    metadata: forensicMetadata(
                        batchId: batch.id,
                        projectId: batch.projectId,
                        taskId: job.id,
                        jobId: job.id,
                        inputIndex: index,
                        path: path
                    )
                )
            }

            DebugLog.debug("batch.input", "Prepared submission with managed plain-path inputs", metadata: mergedMetadata(baseMeta, [
                "job_id": job.id.uuidString,
                "input_count": String(inputCount),
                "bookmark_count": String(bookmarkCount),
                "scope_required_count": String(scopeRequiredCount),
                "source_mode": sourceMode,
                "fallback_used": "false"
            ]))
            submissionDataList.append(
                JobSubmissionData(
                    id: job.id,
                    batchId: batch.id,
                    projectId: batch.projectId,
                    inputURLs: inputPaths.map { URL(fileURLWithPath: $0) },
                    inputPaths: inputPaths,
                    hasSecurityScope: false,
                    maskImageData: job.maskImageData ?? batch.maskImageData,
                    customPrompt: job.customPrompt,
                    inputForensics: inputForensics
                )
            )
        }
        
        // 2. Submit all jobs to get IDs — throttled to concurrencyLimit concurrent submissions
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for data in submissionDataList {
                // If at capacity, wait for one slot to free before adding another
                if inFlight >= concurrencyLimit {
                    await group.next()
                    inFlight -= 1
                }
                group.addTask {
                    await self.performSubmission(data: data, settings: batchSettings, resolvedOutputDirectory: resolvedOutput.directoryURL)
                }
                inFlight += 1
            }
        }
        
        if batch.tasks.contains(where: { $0.phase == .failed }) {
            statusMessage = "Submission errors occurred."
        }

        if runState == .cancelling {
            return
        }

        if shouldPauseProcessing {
            if finalizeBatchStatusIfFinished(batch) {
                await sendCompletionNotification()
                return
            }
            finalizePause()
            return
        }
        
        // 3. Poll all successfully submitted jobs concurrently
        statusMessage = "Polling batch jobs..."
        let validJobs = batch.tasks.filter { $0.externalJobName != nil && $0.phase != .failed && $0.status == .processing }
        let validJobsData: [(UUID, String)] = validJobs.compactMap {
            guard let name = $0.externalJobName else { return nil }
            return ($0.id, name)
        }

        var workers: [(jobId: UUID, task: Task<Void, Never>)] = []
        workers.reserveCapacity(validJobsData.count)
        for (id, name) in validJobsData {
            if shouldPauseProcessing {
                break
            }
            let worker = Task { [weak self] in
                guard let self else { return }
                await self.performPoll(jobId: id, jobName: name, settings: batchSettings, recovering: false, resolvedOutputDirectory: resolvedOutput.directoryURL)
            }
            pollTasks[id] = worker
            workers.append((jobId: id, task: worker))
        }

        for worker in workers {
            await worker.task.value
            pollTasks.removeValue(forKey: worker.jobId)
        }

        if runState == .cancelling {
            return
        }

        if shouldPauseProcessing {
            if finalizeBatchStatusIfFinished(batch) {
                await sendCompletionNotification()
                return
            }
            finalizePause()
            return
        }
        
        _ = finalizeBatchStatusIfFinished(batch)

        await sendCompletionNotification()
    }
    
    // MARK: - Task Workers
    
    private func performSubmission(data: JobSubmissionData, settings: BatchSettings, resolvedOutputDirectory: URL) async {
        let inputCount = data.inputPaths.count
        let scopeRequiredCount = data.inputPaths.filter { securityScopedPathing.requiresSecurityScope(path: $0) }.count
        let bookmarkCount = activeBatches.lazy
            .flatMap({ $0.tasks })
            .first(where: { $0.id == data.id })?
            .inputBookmarks?
            .count ?? 0
        let sourceMode = inputCount == 0 ? "text_to_image" : (scopeRequiredCount == 0 ? "managed_paths" : "external_paths")
        let baseMeta = forensicMetadata(
            batchId: data.batchId,
            projectId: data.projectId ?? settings.projectId,
            taskId: data.id,
            jobId: data.id
        )

        await MainActor.run {
            if let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == data.id }) {
                job.status = .processing
                job.phase = .submitting
                job.startedAt = Date()
            }
        }
        
        let mergedPrompt = mergedTaskPrompt(
            globalPrompt: settings.prompt,
            customPrompt: data.customPrompt,
            isRegionEdit: data.maskImageData != nil
        )

        var requestInputURLs = data.inputURLs
        var tempCropURL: URL?
        var requestImageSize = settings.imageSize
        defer {
            if let tempCropURL {
                try? FileManager.default.removeItem(at: tempCropURL)
            }
        }
        if let maskImageData = data.maskImageData {
            guard data.inputURLs.count == 1 else {
                if data.hasSecurityScope {
                    stopInputSecurityScopeAccess(data: data)
                }
                await handleError(jobId: data.id, data: data, settings: settings, error: RegionEditPipelineError.requiresSingleInput)
                return
            }

            do {
                // Fix #6: move synchronous file I/O off the main actor.
                let inputURL = data.inputURLs[0]
                let sourceImageData = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: inputURL)
                }.value
                
                // Cache for post-poll compositing
                if let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == data.id }) {
                    job.cachedSourceImageData = sourceImageData
                }
                
                let preparation = try await MainActor.run {
                    try RegionEditProcessor.prepareCrop(
                        sourceImageData: sourceImageData,
                        maskImageData: maskImageData
                    )
                }

                if let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == data.id }) {
                    job.regionEditCropRect = preparation.cropRect
                    let chosenSize = chooseRegionEditProcessingImageSize(
                        cropRect: preparation.cropRect,
                        userSelectedMax: settings.imageSize,
                        modelName: settings.modelName
                    )
                    job.regionEditProcessingImageSize = chosenSize
                    requestImageSize = chosenSize
                }

                let cropURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("region-edit-\(data.id.uuidString)")
                    .appendingPathExtension("png")
                let croppedData = preparation.croppedImageData
                try await Task.detached(priority: .userInitiated) {
                    try croppedData.write(to: cropURL, options: .atomic)
                }.value
                requestInputURLs = [cropURL]
                tempCropURL = cropURL
            } catch {
                if data.hasSecurityScope {
                    stopInputSecurityScopeAccess(data: data)
                }
                await handleError(jobId: data.id, data: data, settings: settings, error: error)
                return
            }
        }

        let request = ImageEditRequest(
            inputImageURLs: requestInputURLs,
            maskImageData: data.maskImageData,
            prompt: mergedPrompt,
            systemInstruction: settings.systemPrompt,
            modelName: settings.modelName,
            aspectRatio: settings.aspectRatio,
            imageSize: requestImageSize,
            useBatchTier: settings.useBatchTier
        )
        
        do {
            if settings.useBatchTier {
                let jobInfo = try await service.startBatchJob(request: request)
                DebugLog.info("batch.submit", "Batch-tier job submitted", metadata: mergedMetadata(baseMeta, [
                    "job_id": data.id.uuidString,
                    "remote_job": jobInfo.jobName,
                    "input_count": String(inputCount),
                    "bookmark_count": String(bookmarkCount),
                    "scope_required_count": String(scopeRequiredCount),
                    "source_mode": sourceMode,
                    "fallback_used": "false"
                ]))
                // Stop security-scoped access now that the service has read the file data
                if data.hasSecurityScope {
                    stopInputSecurityScopeAccess(data: data)
                }
                await MainActor.run {
                     if let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == data.id }) {
                        job.externalJobName = jobInfo.jobName
                        job.phase = .polling
                        job.submittedAt = Date()
                        
                        if let projectId = settings.projectId {
                            let entry = HistoryEntry(
                                projectId: projectId,
                                sourceImagePaths: job.inputPaths,
                                outputImagePath: "",
                                prompt: mergedPrompt,
                                modelName: settings.modelName,
                                aspectRatio: settings.aspectRatio,
                                imageSize: job.regionEditProcessingImageSize ?? settings.imageSize,
                                usedBatchTier: settings.useBatchTier,
                                cost: 0,
                                status: "processing",
                                externalJobName: jobInfo.jobName
                            )
                            onImageCompleted?(entry)
                        }
                    }
                }
                saveActiveBatches()
            } else {
                let response = try await service.editImage(request)
                DebugLog.info("batch.submit", "Standard job completed inline", metadata: mergedMetadata(baseMeta, [
                    "job_id": data.id.uuidString,
                    "bytes": String(response.imageData.count),
                    "mime_type": response.mimeType,
                    "input_count": String(inputCount),
                    "bookmark_count": String(bookmarkCount),
                    "scope_required_count": String(scopeRequiredCount),
                    "source_mode": sourceMode,
                    "fallback_used": "false"
                ]))
                // Stop security-scoped access now that the service has read the file data
                if data.hasSecurityScope {
                    stopInputSecurityScopeAccess(data: data)
                }
                await handleSuccess(
                    jobId: data.id,
                    data: data,
                    settings: settings,
                    response: response,
                    jobName: nil,
                    resolvedOutputDirectory: resolvedOutputDirectory
                )
            }
        } catch {
            let classification = classifyFailure(error)
            let payloadEstimate = estimateInlinePayloadBytes(
                for: requestInputURLs,
                prompt: mergedPrompt,
                systemPrompt: settings.systemPrompt
            )
            DebugLog.error("batch.submit", "Submission failed", metadata: mergedMetadata(baseMeta, [
                "job_id": data.id.uuidString,
                "error": String(describing: error),
                "classified_as": classification.rawValue,
                "input_count": String(inputCount),
                "bookmark_count": String(bookmarkCount),
                "scope_required_count": String(scopeRequiredCount),
                "payload_estimate_bytes": payloadEstimate.map(String.init) ?? "nil",
                "payload_limit_bytes": String(NanoBananaService.maxInlineBatchPayloadBytes),
                "source_mode": sourceMode,
                "fallback_used": "false"
            ]))
            // Always stop security-scoped access on error too
            if data.hasSecurityScope {
                stopInputSecurityScopeAccess(data: data)
            }
            await writeFailureSnapshot(
                for: error,
                data: data,
                settings: settings,
                payloadEstimateBytes: payloadEstimate
            )
            await handleError(jobId: data.id, data: data, settings: settings, error: error)
        }
    }
    
    private func performPoll(jobId: UUID, jobName: String, settings: BatchSettings, recovering: Bool, resolvedOutputDirectory: URL) async {
        do {
            let response: ImageEditResponse
            if recovering {
                response = try await service.resumePolling(jobName: jobName, onPollUpdate: { @Sendable count in
                    Task { @MainActor [weak self] in
                        self?.updatePollCount(jobId: jobId, count: count)
                    }
                })
            } else {
                response = try await service.pollBatchJob(jobName: jobName, requestKey: "", onPollUpdate: { @Sendable count in
                    Task { @MainActor [weak self] in
                        self?.updatePollCount(jobId: jobId, count: count)
                    }
                })
            }
            
            await handleSuccess(
                jobId: jobId,
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: [], hasSecurityScope: false, maskImageData: nil, customPrompt: nil),
                settings: settings,
                response: response,
                jobName: jobName,
                resolvedOutputDirectory: resolvedOutputDirectory
            )
        } catch is CancellationError {
            if shouldPauseProcessing {
                markPollJobInterrupted(jobId: jobId)
                return
            }
            if runState == .cancelling {
                return
            }
            await handleError(
                jobId: jobId,
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: [], hasSecurityScope: false, maskImageData: nil, customPrompt: nil),
                settings: settings,
                error: CancellationError()
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                if shouldPauseProcessing {
                    markPollJobInterrupted(jobId: jobId)
                    return
                }
                if runState == .cancelling {
                    return
                }
            }
            await handleError(
                jobId: jobId,
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: [], hasSecurityScope: false, maskImageData: nil, customPrompt: nil),
                settings: settings,
                error: error
            )
        }
    }
    
    private func updatePollCount(jobId: UUID, count: Int) {
        if let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == jobId }) {
            job.phase = .polling
            job.pollCount = count
        }
    }
    
    private func handleSuccess(jobId: UUID, data: JobSubmissionData, settings: BatchSettings, response: ImageEditResponse, jobName: String?, resolvedOutputDirectory: URL) async {
        guard let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == jobId }) else { return }
        let baseMeta = forensicMetadata(
            batchId: data.batchId ?? batchID(for: jobId),
            projectId: settings.projectId,
            taskId: jobId,
            jobId: jobId
        )
        
        var attemptedOutputPath = settings.outputDirectory

        do {
            let finalOutput: (data: Data, mimeType: String)
            if job.maskImageData != nil {
                finalOutput = try await compositeRegionEditOutput(job: job, response: response)
            } else {
                finalOutput = (response.imageData, response.mimeType)
            }

            let outputURL = generateOutputURL(
                for: job,
                inDirectory: resolvedOutputDirectory,
                mimeType: finalOutput.mimeType
            )
            attemptedOutputPath = outputURL.path

            DebugLog.debug("batch.output", "Writing output image", metadata: mergedMetadata(baseMeta, [
                "job_id": jobId.uuidString,
                "path": outputURL.path,
                "path_hash": securityScopedPathing.pathHash(for: outputURL.path),
                "path_basename": securityScopedPathing.pathBasename(for: outputURL.path),
                "bytes": String(finalOutput.data.count),
                "mime_type": finalOutput.mimeType,
                "region_edit": String(job.maskImageData != nil)
            ]))
            try finalOutput.data.write(to: outputURL)
            DebugLog.info("batch.output", "Output image write succeeded", metadata: mergedMetadata(baseMeta, [
                "job_id": jobId.uuidString,
                "path": outputURL.path
            ]))
            
            job.status = .completed
            job.phase = .completed
            job.outputPath = outputURL.path
            job.completedAt = Date()
            
            // Clear cached source image data to free memory
            job.cachedSourceImageData = nil
            
            let effectiveImageSize = job.regionEditProcessingImageSize ?? settings.imageSize
            let cost = settings.cost(inputCount: job.inputPaths.count, imageSizeOverride: effectiveImageSize)
            DebugLog.info("batch.cost", "Calculated task cost", metadata: [
                "job_id": jobId.uuidString,
                "model": settings.modelName,
                "aspect_ratio": settings.aspectRatio,
                "image_size": effectiveImageSize,
                "batch_tier": String(settings.useBatchTier),
                "estimated_cost": String(cost)
            ])
            if let projectId = settings.projectId {
                // Use bookmarks already captured before security scope was stopped.
                // Do NOT use job.inputURLs here — that computed property calls
                // startAccessingSecurityScopedResource() on an already-stopped resource.
                let sourceBookmarks = job.inputBookmarks ?? []
                let outputBookmark = securityScopedPathing.bookmark(for: outputURL, metadata: mergedMetadata(baseMeta, [
                    "event": "security.bookmark.create.output"
                ]))
                
                let historyEntry = HistoryEntry(
                    projectId: projectId,
                    sourceImagePaths: job.inputPaths,
                    outputImagePath: outputURL.path,
                    prompt: mergedTaskPrompt(
                        globalPrompt: settings.prompt,
                        customPrompt: job.customPrompt,
                        isRegionEdit: (job.maskImageData ?? data.maskImageData) != nil
                    ),
                    modelName: settings.modelName,
                    aspectRatio: settings.aspectRatio,
                    imageSize: effectiveImageSize,
                    usedBatchTier: settings.useBatchTier,
                    cost: cost,
                    status: "completed",
                    externalJobName: jobName,
                    sourceImageBookmarks: sourceBookmarks.isEmpty ? nil : sourceBookmarks,
                    outputImageBookmark: outputBookmark
                )
                
                if let jobName = jobName {
                    onHistoryEntryUpdated?(jobName, historyEntry)
                } else {
                    onImageCompleted?(historyEntry)
                }
                onCostIncurred?(cost, effectiveImageSize, settings.modelName, projectId)
            }
            
            saveActiveBatches()
            updateProgress()
        } catch {
            DebugLog.error("batch.output", "Output image write failed", metadata: mergedMetadata(baseMeta, [
                "job_id": jobId.uuidString,
                "path": attemptedOutputPath,
                "error": String(describing: error)
            ]))
            await handleError(jobId: jobId, data: data, settings: settings, error: error)
        }
    }
    
    private func handleError(jobId: UUID, data: JobSubmissionData, settings: BatchSettings, error: Error) async {
        guard let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == jobId }) else { return }
        let classification = classifyFailure(error)
        
        job.status = .failed
        job.phase = .failed
        job.error = error.localizedDescription
        DebugLog.error("batch.error", "Job marked failed", metadata: mergedMetadata(forensicMetadata(
            batchId: data.batchId ?? batchID(for: jobId),
            projectId: settings.projectId,
            taskId: jobId,
            jobId: jobId
        ), [
            "job_id": jobId.uuidString,
            "project_id": settings.projectId?.uuidString ?? "nil",
            "error": error.localizedDescription,
            "classified_as": classification.rawValue
        ]))
        
        if let projectId = settings.projectId {
            let historyEntry = HistoryEntry(
                projectId: projectId,
                sourceImagePaths: job.inputPaths,
                outputImagePath: "",
                prompt: mergedTaskPrompt(
                    globalPrompt: settings.prompt,
                    customPrompt: job.customPrompt,
                    isRegionEdit: (job.maskImageData ?? data.maskImageData) != nil
                ),
                modelName: settings.modelName,
                aspectRatio: settings.aspectRatio,
                imageSize: job.regionEditProcessingImageSize ?? settings.imageSize,
                usedBatchTier: settings.useBatchTier,
                cost: 0,
                status: "failed",
                error: error.localizedDescription,
                externalJobName: job.externalJobName
            )
            
            if let jobName = job.externalJobName {
                onHistoryEntryUpdated?(jobName, historyEntry)
            } else {
                onImageCompleted?(historyEntry)
            }
        }
        
        saveActiveBatches()
        updateProgress()
    }

    private func mergedMetadata(_ lhs: [String: String], _ rhs: [String: String]) -> [String: String] {
        lhs.merging(rhs) { _, new in new }
    }

    private func batchID(for jobId: UUID) -> UUID? {
        activeBatches.first(where: { $0.tasks.contains(where: { $0.id == jobId }) })?.id
    }

    private func forensicMetadata(
        batchId: UUID?,
        projectId: UUID?,
        taskId: UUID,
        jobId: UUID,
        inputIndex: Int? = nil,
        path: String? = nil
    ) -> [String: String] {
        var metadata: [String: String] = [
            "launch_id": securityScopedPathing.launchID,
            "session_id": sessionID,
            "job_id": jobId.uuidString,
            "task_id": taskId.uuidString
        ]
        if let batchId {
            metadata["batch_id"] = batchId.uuidString
        }
        if let projectId {
            metadata["project_id"] = projectId.uuidString
        }
        if let inputIndex {
            metadata["input_index"] = String(inputIndex)
        }
        if let path {
            metadata["path"] = path
            metadata["path_hash"] = securityScopedPathing.pathHash(for: path)
            metadata["path_basename"] = securityScopedPathing.pathBasename(for: path)
        }
        return metadata
    }

    private func stopInputSecurityScopeAccess(data: JobSubmissionData) {
        var stoppedPaths = Set<String>()
        for (index, url) in data.inputURLs.enumerated() {
            let path = data.inputPaths.indices.contains(index) ? data.inputPaths[index] : url.path
            guard securityScopedPathing.requiresSecurityScope(path: path) else { continue }
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard stoppedPaths.insert(normalizedPath).inserted else { continue }
            securityScopedPathing.stopAccessing(
                url,
                metadata: forensicMetadata(
                    batchId: data.batchId ?? batchID(for: data.id),
                    projectId: data.projectId,
                    taskId: data.id,
                    jobId: data.id,
                    inputIndex: index,
                    path: path
                )
            )
        }
    }

    private func firstMissingScopeRequiredPath(inputPaths: [String], inputBookmarks: [Data]?) -> String? {
        let requiredPaths = inputPaths.filter { securityScopedPathing.requiresSecurityScope(path: $0) }
        guard !requiredPaths.isEmpty else { return nil }
        guard let inputBookmarks, !inputBookmarks.isEmpty else { return requiredPaths.first }

        var resolvedPaths = Set<String>()
        for (bookmarkIndex, bookmarkData) in inputBookmarks.enumerated() {
            if let resolvedPath = securityScopedPathing.resolveBookmarkToPath(bookmarkData) {
                let normalized = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path
                resolvedPaths.insert(normalized)
                continue
            }

            if inputPaths.indices.contains(bookmarkIndex),
               securityScopedPathing.requiresSecurityScope(path: inputPaths[bookmarkIndex]) {
                return inputPaths[bookmarkIndex]
            }
        }

        return requiredPaths.first { requiredPath in
            let normalized = URL(fileURLWithPath: requiredPath).standardizedFileURL.path
            return resolvedPaths.contains(normalized) == false
        }
    }

    private func probeInputFile(url: URL) -> InputProbeData {
        let path = url.path
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: path)
        let readable = fileManager.isReadableFile(atPath: path)
        guard exists else {
            return InputProbeData(
                exists: false,
                readable: readable,
                sizeBytes: nil,
                modifiedAtISO8601: nil,
                inode: nil,
                volumeUUID: nil,
                iCloudStatus: "unknown"
            )
        }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let sizeBytes = (attributes?[.size] as? NSNumber)?.intValue
        let modified = (attributes?[.modificationDate] as? Date).map { forensicDateFormatter.string(from: $0) }
        let inode = (attributes?[.systemFileNumber] as? NSNumber).map { UInt64(truncating: $0) }
        let resourceValues = try? url.resourceValues(forKeys: [
            .volumeUUIDStringKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        let iCloudStatus: String
        if resourceValues?.isUbiquitousItem == true {
            iCloudStatus = resourceValues?.ubiquitousItemDownloadingStatus?.rawValue ?? "unknown"
        } else if resourceValues?.isUbiquitousItem == false {
            iCloudStatus = "not_ubiquitous"
        } else {
            iCloudStatus = "unknown"
        }

        return InputProbeData(
            exists: exists,
            readable: readable,
            sizeBytes: sizeBytes,
            modifiedAtISO8601: modified,
            inode: inode,
            volumeUUID: resourceValues?.volumeUUIDString,
            iCloudStatus: iCloudStatus
        )
    }

    private func logInputProbe(_ probe: InputProbeData, metadata: [String: String]) {
        DebugLog.debug("security.input", "Input file probe", metadata: mergedMetadata(metadata, [
            "event": "security.input.probe",
            "exists": String(probe.exists),
            "readable": String(probe.readable),
            "size_bytes": probe.sizeBytes.map(String.init) ?? "nil",
            "modified_at": probe.modifiedAtISO8601 ?? "nil",
            "inode": probe.inode.map(String.init) ?? "nil",
            "volume_uuid": probe.volumeUUID ?? "nil",
            "icloud_status": probe.iCloudStatus
        ]))
    }

    private func classifyFailure(_ error: Error) -> FailureClassification {
        let message = error.localizedDescription.lowercased()
        let nsError = error as NSError
        let nsCode = nsError.code
        let nsDomain = nsError.domain

        if message.contains("exceeds the 20mb limit") || message.contains("payload") {
            return .payloadLimitExceeded
        }
        if nsDomain == NSCocoaErrorDomain && nsCode == 257 {
            return .permissionDenied
        }
        if nsDomain == NSCocoaErrorDomain && nsCode == 256 {
            return .bookmarkResolveFailed
        }
        if nsDomain == NSPOSIXErrorDomain && (nsCode == 1 || nsCode == 13) {
            return .permissionDenied
        }
        if nsDomain == NSCocoaErrorDomain && nsCode == NSFileNoSuchFileError {
            return .fileMissing
        }
        if message.contains("stale bookmark") {
            return .bookmarkStale
        }
        if message.contains("cannot access the source image") || message.contains("permission") || message.contains("don't have permission") {
            return .permissionDenied
        }
        if message.contains("could not be loaded") || message.contains("unreadable") {
            return .fileUnreadable
        }
        return .unknown
    }

    private func estimateInlinePayloadBytes(for urls: [URL], prompt: String, systemPrompt: String?) -> Int? {
        guard !urls.isEmpty else { return nil }
        var rawBytes = 0
        for url in urls {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                return nil
            }
            rawBytes += size.intValue
        }
        return NanoBananaService.estimateInlineBatchPayloadBytes(
            rawImageBytes: rawBytes,
            prompt: prompt,
            systemInstruction: systemPrompt
        )
    }

    private func writeFailureSnapshot(
        for error: Error,
        data: JobSubmissionData,
        settings: BatchSettings,
        payloadEstimateBytes: Int? = nil
    ) async {
        let classification = classifyFailure(error)
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let submitMode = settings.useBatchTier ? "batch" : "inline"

        let inputForensics: [InputForensicRecord]
        if data.inputForensics.isEmpty {
            inputForensics = data.inputPaths.enumerated().map { index, path in
                let probe = probeInputFile(url: URL(fileURLWithPath: path))
                return InputForensicRecord(
                    inputIndex: index,
                    path: path,
                    pathHash: securityScopedPathing.pathHash(for: path),
                    pathBasename: securityScopedPathing.pathBasename(for: path),
                    bookmarkPresent: false,
                    bookmarkResolveOK: nil,
                    bookmarkIsStale: nil,
                    scopeStartOK: nil,
                    probe: probe
                )
            }
        } else {
            inputForensics = data.inputForensics
        }

        let snapshotInputs: [FailureSnapshotInput] = inputForensics.sorted(by: { $0.inputIndex < $1.inputIndex }).map { record in
            let probeState = record.probe.map {
                FailureSnapshotInput.ProbeState(
                    exists: $0.exists,
                    readable: $0.readable,
                    sizeBytes: $0.sizeBytes,
                    modifiedAtISO8601: $0.modifiedAtISO8601,
                    inode: $0.inode,
                    volumeUUID: $0.volumeUUID,
                    iCloudStatus: $0.iCloudStatus
                )
            }
            return FailureSnapshotInput(
                inputIndex: record.inputIndex,
                pathHash: record.pathHash,
                pathBasename: record.pathBasename,
                bookmark: FailureSnapshotInput.BookmarkState(
                    present: record.bookmarkPresent,
                    resolveOK: record.bookmarkResolveOK,
                    isStale: record.bookmarkIsStale
                ),
                scope: FailureSnapshotInput.ScopeState(
                    startOK: record.scopeStartOK,
                    stopCalled: data.hasSecurityScope
                ),
                probe: probeState
            )
        }

        let snapshot = FailureSnapshot(
            schemaVersion: 1,
            createdAt: Date(),
            launchId: securityScopedPathing.launchID,
            sessionId: sessionID,
            projectId: (data.projectId ?? settings.projectId)?.uuidString ?? "nil",
            batchId: data.batchId?.uuidString ?? (batchID(for: data.id)?.uuidString ?? "nil"),
            taskId: data.id.uuidString,
            jobId: data.id.uuidString,
            model: settings.modelName,
            batchTier: settings.useBatchTier,
            submitMode: submitMode,
            payloadEstimateBytes: payloadEstimateBytes,
            payloadLimitBytes: NanoBananaService.maxInlineBatchPayloadBytes,
            error: FailureSnapshot.SnapshotError(
                classifiedAs: classification,
                message: error.localizedDescription,
                errorDomain: nsError.domain,
                errorCode: nsError.code,
                underlyingErrorDomain: underlying?.domain,
                underlyingErrorCode: underlying?.code
            ),
            inputs: snapshotInputs
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            let timestamp = forensicDateFormatter
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let fileURL = AppPaths.failureSnapshotsDirectoryURL
                .appendingPathComponent("\(snapshot.jobId)-\(timestamp).json")
            try data.write(to: fileURL, options: .atomic)
            DebugLog.info("batch.diagnostics", "Wrote failure snapshot", metadata: [
                "event": "batch.failure_snapshot.written",
                "launch_id": securityScopedPathing.launchID,
                "session_id": sessionID,
                "job_id": snapshot.jobId,
                "path": fileURL.path,
                "bytes": String(data.count)
            ])
        } catch {
            DebugLog.error("batch.diagnostics", "Failed to write failure snapshot", metadata: [
                "event": "batch.failure_snapshot.failed",
                "launch_id": securityScopedPathing.launchID,
                "session_id": sessionID,
                "job_id": data.id.uuidString,
                "error": String(describing: error)
            ])
        }
    }

    private func compositeRegionEditOutput(job: ImageTask, response: ImageEditResponse) async throws -> (data: Data, mimeType: String) {
        guard job.inputPaths.count == 1 else {
            throw RegionEditPipelineError.requiresSingleInput
        }
        guard let maskImageData = job.maskImageData else {
            throw RegionEditPipelineError.missingMask
        }
        guard let cropRect = job.regionEditCropRect else {
            throw RegionEditPipelineError.missingCropMetadata
        }

        let sourceImageData = try readSingleSourceImageData(for: job)
        let composite = try await MainActor.run {
            try RegionEditProcessor.compositeEditedCrop(
                originalImageData: sourceImageData,
                editedCropImageData: response.imageData,
                maskImageData: maskImageData,
                cropRect: cropRect
            )
        }
        return (data: composite.imageData, mimeType: composite.mimeType)
    }

    private func readSingleSourceImageData(for job: ImageTask) throws -> Data {
        // Prefer cached data (captured during submission while scope was active)
        if let cached = job.cachedSourceImageData {
            return cached
        }
        
        guard let sourcePath = job.inputPaths.first else {
            throw RegionEditPipelineError.missingSourceImage
        }

        if let bookmark = job.inputBookmarks?.first {
            let bookmarkMeta = forensicMetadata(
                batchId: batchID(for: job.id),
                projectId: job.projectId,
                taskId: job.id,
                jobId: job.id,
                inputIndex: 0,
                path: sourcePath
            )
            guard let resolved = securityScopedPathing.resolveBookmarkAccess(bookmark, metadata: bookmarkMeta) else {
                throw RegionEditPipelineError.sourceBookmarkAccessFailed(path: sourcePath)
            }
            defer { securityScopedPathing.stopAccessing(resolved.url, metadata: bookmarkMeta) }
            return try Data(contentsOf: resolved.url)
        }

        if strictPermissionEnforcement && securityScopedPathing.requiresSecurityScope(path: sourcePath) {
            throw RegionEditPipelineError.sourceBookmarkAccessFailed(path: sourcePath)
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw RegionEditPipelineError.missingSourceImage
        }
        return try Data(contentsOf: sourceURL)
    }

    private func mergedTaskPrompt(globalPrompt: String, customPrompt: String?, isRegionEdit: Bool) -> String {
        let global = globalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = (customPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let base: String
        if !global.isEmpty && !custom.isEmpty {
            base = "Global instructions:\n\(global)\n\nRegion edit instructions:\n\(custom)"
        } else if !custom.isEmpty {
            base = custom
        } else {
            base = global
        }

        guard isRegionEdit else { return base }
        if base.isEmpty {
            return regionEditPromptClause
        }
        return "\(base)\n\n\(regionEditPromptClause)"
    }

    private func chooseRegionEditProcessingImageSize(cropRect: CGRect, userSelectedMax: String, modelName: String) -> String {
        let maxDimension = max(cropRect.width, cropRect.height)
        let allowedSizes = allowedImageSizes(upTo: userSelectedMax, modelName: modelName)
        for candidate in allowedSizes {
            if maxDimension <= pixelDimension(forImageSize: candidate) {
                return candidate
            }
        }
        return allowedSizes.last ?? userSelectedMax
    }

    private func allowedImageSizes(upTo userSelectedMax: String, modelName: String) -> [String] {
        let orderedSizes = ["0.5K", "1K", "2K", "4K"]
        let supported = Set(ModelCatalog.supportedImageSizes(for: modelName))
        let cappedIndex = orderedSizes.firstIndex(of: userSelectedMax) ?? (orderedSizes.count - 1)
        return orderedSizes
            .prefix(cappedIndex + 1)
            .filter { supported.contains($0) }
    }

    private func pixelDimension(forImageSize imageSize: String) -> CGFloat {
        switch imageSize {
        case "0.5K":
            return 512
        case "4K":
            return 4096
        case "2K":
            return 2048
        case "1K":
            return 1024
        default:
            return 1024
        }
    }

    private func generateOutputURL(for task: ImageTask, inDirectory directoryURL: URL, mimeType: String) -> URL {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        
        let inputName = task.inputPaths.first.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "generation"
        let ext = mimeType == "image/png" ? "png" : "jpg"
        let baseName = task.inputPaths.isEmpty ? inputName : "\(inputName)_edited"
        
        // Find a unique filename to avoid silently overwriting existing outputs
        var candidate = directoryURL.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(baseName)_\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
    
    private func updateProgress() {
        let allTasks = activeBatches.flatMap { $0.tasks }
        let total = allTasks.count
        let completed = allTasks.filter { $0.status == .completed || $0.status == .failed }.count
        
        if total > 0 {
            currentProgress = Double(completed) / Double(total)
        } else {
            currentProgress = 0
        }
    }
    
    private var isTesting: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private func sendCompletionNotification() async {
        guard !isTesting && Bundle.main.bundleIdentifier != nil else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Nano Banana Pro"
        let successCount = completedJobs.count
        let failCount = failedJobs.count
        content.body = "Batch complete: \(successCount) output succeeded, \(failCount) failed"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence Helpers

    private func sanitizeRestoredBatchesForAccess() {
        guard !activeBatches.isEmpty else {
            DebugLog.info("batch.permissions", "Sanitized restored batches", metadata: [
                "valid": "0",
                "invalid_input": "0",
                "invalid_output": "0",
                "auto_failed": "0"
            ])
            return
        }

        var valid = 0
        var invalidInput = 0
        var invalidOutput = 0
        var autoFailed = 0
        var didMutate = false

        for batch in activeBatches {
            let outputRequiresScope = strictPermissionEnforcement && securityScopedPathing.requiresSecurityScope(path: batch.outputDirectory)
            let outputMissingBookmark = outputRequiresScope && batch.outputDirectoryBookmark == nil

            for task in batch.tasks {
                // Leave terminal tasks untouched.
                if task.status == .completed || task.status == .cancelled || task.status == .failed {
                    valid += 1
                    continue
                }

                var validationError: Error?

                if !task.inputPaths.isEmpty {
                    if strictPermissionEnforcement, let missingPath = firstMissingScopeRequiredPath(
                        inputPaths: task.inputPaths,
                        inputBookmarks: task.inputBookmarks
                    ) {
                        validationError = InputFileAccessError.missingBookmark(path: missingPath)
                        invalidInput += 1
                    }
                }

                if validationError == nil && outputMissingBookmark {
                    validationError = OutputDirectoryAccessError.missingBookmark(path: batch.outputDirectory)
                    invalidOutput += 1
                }

                if let validationError {
                    task.status = .failed
                    task.phase = .failed
                    task.error = validationError.localizedDescription
                    autoFailed += 1
                    didMutate = true
                } else {
                    valid += 1
                }
            }

            if batch.tasks.contains(where: { $0.status == .processing || $0.status == .pending || $0.status == .submitting }) {
                batch.status = .processing
            } else if batch.tasks.contains(where: { $0.status == .failed }) {
                batch.status = .failed
            } else if batch.tasks.allSatisfy({ $0.status == .completed || $0.status == .cancelled }) {
                batch.status = .completed
            }
        }

        DebugLog.info("batch.permissions", "Sanitized restored batches", metadata: [
            "valid": String(valid),
            "invalid_input": String(invalidInput),
            "invalid_output": String(invalidOutput),
            "auto_failed": String(autoFailed)
        ])

        if didMutate {
            saveActiveBatches()
            updateProgress()
        }
    }

    private func saveActiveBatches() {
        if activeBatches.isEmpty {
             try? FileManager.default.removeItem(at: activeBatchURL)
             DebugLog.debug("batch.persistence", "Cleared active batch persistence file")
             return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(activeBatches)
            try data.write(to: activeBatchURL, options: .atomic)
            DebugLog.debug("batch.persistence", "Saved active batches", metadata: [
                "count": String(activeBatches.count),
                "bytes": String(data.count)
            ])
        } catch {
            DebugLog.error("batch.persistence", "Failed to save active batches", metadata: [
                "error": String(describing: error)
            ])
            print("Failed to save active batches: \(error)")
        }
    }

    private func loadActiveBatches() {
        guard FileManager.default.fileExists(atPath: activeBatchURL.path) else { return }
        do {
            let data = try Data(contentsOf: activeBatchURL)
            let decoded = try decodePersistedActiveBatches(from: data)
            activeBatches = decoded.batches
            
            if activeBatches.contains(where: { $0.status == .paused }) {
                statusMessage = "Paused"
            } else if !processingJobs.isEmpty || !pendingJobs.isEmpty {
                statusMessage = "Resumed sessions"
            }
            updateProgress()
            DebugLog.info("batch.persistence", "Loaded active batches", metadata: [
                "count": String(activeBatches.count),
                "decode_mode": decoded.mode
            ])
        } catch {
            DebugLog.error("batch.persistence", "Failed to load active batches", metadata: [
                "error": String(describing: error)
            ])
            print("Failed to load active batches: \(error)")
        }
    }

    private func decodePersistedActiveBatches(from data: Data) throws -> (batches: [BatchJob], mode: String) {
        let attempts: [(label: String, decoder: JSONDecoder, decodeArray: Bool)] = [
            {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return (label: "array_iso8601", decoder: decoder, decodeArray: true)
            }(),
            {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return (label: "single_iso8601", decoder: decoder, decodeArray: false)
            }(),
            (label: "array_legacy_default", decoder: JSONDecoder(), decodeArray: true),
            (label: "single_legacy_default", decoder: JSONDecoder(), decodeArray: false)
        ]

        var errors: [String] = []

        for attempt in attempts {
            do {
                if attempt.decodeArray {
                    let batches = try attempt.decoder.decode([BatchJob].self, from: data)
                    return (batches, attempt.label)
                } else {
                    let batch = try attempt.decoder.decode(BatchJob.self, from: data)
                    return ([batch], attempt.label)
                }
            } catch {
                errors.append("\(attempt.label): \(error)")
            }
        }

        throw NSError(
            domain: "BatchOrchestrator.Persistence",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Unable to decode active batches using any supported format",
                "attempt_errors": errors.joined(separator: " | ")
            ]
        )
    }

    func resumePollingFromHistory(for entry: HistoryEntry) {
        guard let jobName = entry.externalJobName else { return }
        
        if activeBatches.contains(where: { $0.tasks.contains(where: { $0.externalJobName == jobName }) }) {
             return
        }
        
        let task = ImageTask(
            inputPaths: entry.sourceImagePaths,
            projectId: entry.projectId,
            inputBookmarks: entry.sourceImageBookmarks
        )
        task.externalJobName = jobName
        task.status = .processing
        task.phase = .polling
        task.submittedAt = entry.timestamp 
        
        let outputDir: String
        if !entry.outputImagePath.isEmpty {
            outputDir = (entry.outputImagePath as NSString).deletingLastPathComponent
        } else {
            let projectsDir = AppPaths.projectsDirectoryURL
            outputDir = projectsDir
                .appendingPathComponent(entry.projectId.uuidString)
                .appendingPathComponent("Outputs")
                .path(percentEncoded: false)
        }

        let batch = BatchJob(
            prompt: entry.prompt,
            modelName: entry.modelName,
            aspectRatio: entry.aspectRatio,
            imageSize: entry.imageSize,
            outputDirectory: outputDir,
            // Fix #7: entry.outputImageBookmark is a file-level bookmark, not a directory
            // bookmark. Passing it here would cause spurious permission failures when trying
            // to write new output. Pass nil so the user gets a clear "re-select output folder"
            // error rather than a cryptic sandbox failure.
            outputDirectoryBookmark: nil,
            useBatchTier: entry.usedBatchTier,
            projectId: entry.projectId
        )
        batch.tasks = [task]
        
        enqueue(batch)
        statusMessage = "Resumed job from history..."
    }
}
