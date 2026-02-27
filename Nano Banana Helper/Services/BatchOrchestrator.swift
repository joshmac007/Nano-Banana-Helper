import Foundation
import Observation
import UserNotifications
import CoreGraphics

// MARK: - Sendable Helpers
struct JobSubmissionData: Sendable {
    let id: UUID
    let inputURLs: [URL]       // Security-scoped URLs (already started access)
    let inputPaths: [String]
    let hasSecurityScope: Bool // Whether we need to stop access after use
    let maskImageData: Data?   // Added for inpainting
    let customPrompt: String?  // Added for individual custom prompts
}

struct BatchSettings: Sendable {
    let prompt: String
    let systemPrompt: String?
    let aspectRatio: String
    let imageSize: String
    let outputDirectory: String
    let outputDirectoryBookmark: Data?
    let useBatchTier: Bool
    let projectId: UUID?
    
    // Helper for cost calculation
    func cost(inputCount: Int, imageSizeOverride: String? = nil) -> Double {
        let inputRate = useBatchTier ? 0.0006 : 0.0011
        let inputCost = inputRate * Double(inputCount)
        
        let outputCost: Double
        let outputSize = imageSizeOverride ?? imageSize
        if useBatchTier {
            switch outputSize {
            case "4K": outputCost = 0.12
            case "2K", "1K": outputCost = 0.067
            default: outputCost = 0.067
            }
        } else {
            switch outputSize {
            case "4K": outputCost = 0.24
            case "2K", "1K": outputCost = 0.134
            default: outputCost = 0.134
            }
        }
        return inputCost + outputCost
    }
}

private enum OutputDirectoryAccessError: LocalizedError {
    case bookmarkAccessFailed(path: String)
    
    var errorDescription: String? {
        switch self {
        case .bookmarkAccessFailed(let path):
            return "Cannot access the output folder anymore. Re-select Output Location and retry. (\(path))"
        }
    }
}

private enum InputFileAccessError: LocalizedError {
    case bookmarkAccessFailed(path: String)

    var errorDescription: String? {
        switch self {
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

/// Orchestrates batch processing of image editing tasks
@Observable
@MainActor
final class BatchOrchestrator {
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
        activeBatches.flatMap { $0.tasks.filter { $0.status == "pending" } }
    }
    var processingJobs: [ImageTask] {
        activeBatches.flatMap { $0.tasks.filter { $0.status == "processing" } }
    }
    var completedJobs: [ImageTask] {
        activeBatches.flatMap { $0.tasks.filter { $0.status == "completed" } }
    }
    var failedJobs: [ImageTask] {
        activeBatches.flatMap { $0.tasks.filter { $0.status == "failed" } }
    }
    
    var isRunning: Bool {
        !isPaused && !activeBatches.filter { $0.status == "processing" }.isEmpty
    }
    var isPaused: Bool {
        runState == .pausing || runState == .paused
    }
    var currentProgress: Double = 0.0
    var statusMessage: String = "Ready"
    
    private var activeBatches: [BatchJob] = []
    private let service = NanoBananaService()
    private let concurrencyLimit = 5 // Paid tier: safe default for concurrent submissions
    private var runState: RunState = .idle
    private var batchRunnerTasks: [UUID: Task<Void, Never>] = [:]
    private var pollTasks: [UUID: Task<Void, Never>] = [:]

    // Callbacks for history/cost tracking
    var onImageCompleted: ((HistoryEntry) -> Void)?
    var onCostIncurred: ((Double, String, UUID) -> Void)?
    var onHistoryEntryUpdated: ((String, HistoryEntry) -> Void)?
    var onOutputDirectoryBookmarkRefreshed: ((UUID, Data) -> Void)?
    var onRestoreSettings: ((HistoryEntry) -> Void)?
    
    private let activeBatchURL = AppPaths.activeBatchURL

    init() {
        loadActiveBatches()
        refreshRunStateFromBatches()
        DebugLog.info("batch", "BatchOrchestrator initialized", metadata: [
            "restored_batches": String(activeBatches.count)
        ])
    }
    
    /// Enqueue a new batch job for processing
    func enqueue(_ batch: BatchJob) {
        activeBatches.append(batch)
        let tasksMissingInputBookmarks = batch.tasks.filter { !$0.inputPaths.isEmpty && (($0.inputBookmarks ?? []).isEmpty) }.count
        DebugLog.info("batch.enqueue", "Enqueued batch", metadata: [
            "batch_id": batch.id.uuidString,
            "task_count": String(batch.tasks.count),
            "project_id": batch.projectId?.uuidString ?? "nil",
            "has_output_bookmark": String(batch.outputDirectoryBookmark != nil),
            "tasks_missing_input_bookmarks": String(tasksMissingInputBookmarks)
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
        guard batch.status != "completed" && batch.status != "cancelled" else { return }
        guard runState != .cancelling else { return }
        DebugLog.info("batch.start", "Starting batch", metadata: [
            "batch_id": batch.id.uuidString,
            "status": batch.status,
            "tasks": String(batch.tasks.count)
        ])
        
        // Request notification permission - Skip in tests
        if !isTesting && Bundle.main.bundleIdentifier != nil {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        
        runState = .running
        batch.status = "processing"
        statusMessage = "Processing \(activeBatches.count) batches..."
        
        await processQueue(batch: batch)
    }
    
    /// Resume all interrupted batches
    func startAll() async {
        if runState == .paused || runState == .pausing {
            runState = .running
        }

        var runners: [Task<Void, Never>] = []
        for batch in activeBatches where batch.status == "pending" || batch.status == "processing" || batch.status == "paused" {
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
        guard activeBatches.contains(where: { $0.status == "processing" }) || !pollTasks.isEmpty else { return }

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
        batch.status = "cancelled"
        
        // Move all pending/processing to failed and cancel on API side
        let jobsToCancel = batch.tasks.filter { $0.status == "processing" || $0.status == "pending" || $0.status == "submitting" }
        
        for job in jobsToCancel {
            job.status = "failed"
            job.phase = .failed
            job.error = "Cancelled by user"
            
            // Record cancellation in history
            if let projectId = batch.projectId {
                let entry = HistoryEntry(
                    projectId: projectId,
                    sourceImagePaths: job.inputPaths,
                    outputImagePath: "",
                    prompt: batch.prompt,
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
        
        // Cancel API jobs in background — capture names (strings) not ImageTask references
        let namesToCancel = jobsToCancel.compactMap { $0.externalJobName }
        Task {
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
        let tasksToRemove = offsets.map { failedJobs[$0] }
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
        let tasksToRemove = offsets.map { completedJobs[$0] }
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
        let tasksToRemove = offsets.map { pendingJobs[$0] }
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
            batch.tasks.contains { $0.externalJobName != nil && ($0.phase == .polling || $0.phase == .reconnecting) } && batch.status != "processing"
        }
    }
    
    func resumeInterruptedJobs() async {
        await startAll()
    }

    private var shouldPauseProcessing: Bool {
        runState == .pausing || runState == .paused
    }

    private var isPauseRequested: Bool {
        runState == .pausing || runState == .paused
    }

    @discardableResult
    private func launchBatchRunner(for batch: BatchJob) -> Task<Void, Never>? {
        guard batch.status != "completed" && batch.status != "cancelled" else { return nil }
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
        for batch in activeBatches where batch.status == "processing" {
            batch.status = "paused"
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
           job.status == "processing" {
            job.phase = .reconnecting
        }
    }

    private func refreshRunStateFromBatches() {
        guard runState != .cancelling else { return }

        let hasProcessing = activeBatches.contains { $0.status == "processing" }
        let hasPaused = activeBatches.contains { $0.status == "paused" }

        if isPauseRequested {
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
        guard !batch.tasks.contains(where: { $0.status == "processing" || $0.status == "pending" }) else {
            return false
        }

        if batch.tasks.contains(where: { $0.status == "failed" }) {
            batch.status = "failed"
            statusMessage = "Completed with errors"
        } else {
            batch.status = "completed"
            let count = batch.tasks.filter { $0.status == "completed" }.count
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
        let jobsToSubmit = batch.tasks.filter { $0.status == "pending" }
        for job in jobsToSubmit {
             job.status = "processing"
        }
        updateProgress()
        
        statusMessage = "Submitting \(jobsToSubmit.count) jobs..."
        
        let batchSettings = BatchSettings(
            prompt: batch.prompt,
            systemPrompt: batch.systemPrompt,
            aspectRatio: batch.aspectRatio,
            imageSize: batch.imageSize,
            outputDirectory: batch.outputDirectory,
            outputDirectoryBookmark: batch.outputDirectoryBookmark,
            useBatchTier: batch.useBatchTier,
            projectId: batch.projectId
        )

        var submissionDataList: [JobSubmissionData] = []
        submissionDataList.reserveCapacity(jobsToSubmit.count)

        for job in jobsToSubmit {
            // Resolve security-scoped URLs from bookmarks if available.
            // resolveBookmarkAccess calls startAccessingSecurityScopedResource internally.
            if let bookmarks = job.inputBookmarks, !bookmarks.isEmpty {
                var resolvedURLs: [URL] = []
                var refreshedBookmarks = bookmarks
                var didRefreshBookmarks = false
                var failedPath = job.inputPaths.first ?? "unknown"
                var resolutionFailed = false
                
                for (index, bookmark) in bookmarks.enumerated() {
                    guard let resolved = AppPaths.resolveBookmarkAccess(bookmark) else {
                        DebugLog.error("batch.input", "Input bookmark resolution failed; marking job failed", metadata: [
                            "job_id": job.id.uuidString,
                            "bookmark_index": String(index),
                            "input_count": String(bookmarks.count)
                        ])
                        // Avoid partially submitting multi-input jobs when only some bookmarks resolve.
                        resolvedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                        resolvedURLs = []
                        failedPath = job.inputPaths.indices.contains(index) ? job.inputPaths[index] : failedPath
                        resolutionFailed = true
                        break
                    }
                    resolvedURLs.append(resolved.url)
                    if let refreshed = resolved.refreshedBookmarkData {
                        refreshedBookmarks[index] = refreshed
                        didRefreshBookmarks = true
                    }
                }
                
                if didRefreshBookmarks {
                    job.inputBookmarks = refreshedBookmarks
                    saveActiveBatches()
                    DebugLog.info("batch.input", "Refreshed one or more input bookmarks", metadata: [
                        "job_id": job.id.uuidString,
                        "input_count": String(bookmarks.count)
                    ])
                }
                
                if resolutionFailed {
                    await handleError(
                        jobId: job.id,
                        data: JobSubmissionData(
                            id: job.id,
                            inputURLs: [],
                            inputPaths: job.inputPaths,
                            hasSecurityScope: false,
                            maskImageData: job.maskImageData ?? batch.maskImageData,
                            customPrompt: job.customPrompt
                        ),
                        settings: batchSettings,
                        error: InputFileAccessError.bookmarkAccessFailed(path: failedPath)
                    )
                    continue
                }

                if !resolvedURLs.isEmpty {
                    submissionDataList.append(
                        JobSubmissionData(
                            id: job.id,
                            inputURLs: resolvedURLs,
                            inputPaths: job.inputPaths,
                            hasSecurityScope: true,
                            maskImageData: job.maskImageData ?? batch.maskImageData,
                            customPrompt: job.customPrompt
                        )
                    )
                    continue
                }
            }
            // Fallback to plain path-based URLs (drag-and-drop, or already-accessible files)
            submissionDataList.append(
                JobSubmissionData(
                    id: job.id,
                    inputURLs: job.inputPaths.map { URL(fileURLWithPath: $0) },
                    inputPaths: job.inputPaths,
                    hasSecurityScope: false,
                    maskImageData: job.maskImageData ?? batch.maskImageData,
                    customPrompt: job.customPrompt
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
                    await self.performSubmission(data: data, settings: batchSettings)
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
        let validJobs = batch.tasks.filter { $0.externalJobName != nil && $0.phase != .failed && $0.status == "processing" }
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
                await self.performPoll(jobId: id, jobName: name, settings: batchSettings, recovering: false)
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
    
    private func performSubmission(data: JobSubmissionData, settings: BatchSettings) async {
        await MainActor.run {
            if let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == data.id }) {
                job.status = "processing"
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
                    data.inputURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                }
                await handleError(jobId: data.id, data: data, settings: settings, error: RegionEditPipelineError.requiresSingleInput)
                return
            }

            do {
                let sourceImageData = try Data(contentsOf: data.inputURLs[0])
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
                        userSelectedMax: settings.imageSize
                    )
                    job.regionEditProcessingImageSize = chosenSize
                    requestImageSize = chosenSize
                }

                let cropURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("region-edit-\(data.id.uuidString)")
                    .appendingPathExtension("png")
                try preparation.croppedImageData.write(to: cropURL, options: .atomic)
                requestInputURLs = [cropURL]
                tempCropURL = cropURL
            } catch {
                if data.hasSecurityScope {
                    data.inputURLs.forEach { $0.stopAccessingSecurityScopedResource() }
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
            aspectRatio: settings.aspectRatio,
            imageSize: requestImageSize,
            useBatchTier: settings.useBatchTier
        )
        
        do {
            if settings.useBatchTier {
                let jobInfo = try await service.startBatchJob(request: request)
                DebugLog.info("batch.submit", "Batch-tier job submitted", metadata: [
                    "job_id": data.id.uuidString,
                    "remote_job": jobInfo.jobName
                ])
                // Stop security-scoped access now that the service has read the file data
                if data.hasSecurityScope {
                    data.inputURLs.forEach { $0.stopAccessingSecurityScopedResource() }
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
                DebugLog.info("batch.submit", "Standard job completed inline", metadata: [
                    "job_id": data.id.uuidString,
                    "bytes": String(response.imageData.count),
                    "mime_type": response.mimeType
                ])
                // Stop security-scoped access now that the service has read the file data
                if data.hasSecurityScope {
                    data.inputURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                }
                await handleSuccess(
                    jobId: data.id,
                    data: data,
                    settings: settings,
                    response: response,
                    jobName: nil
                )
            }
        } catch {
            DebugLog.error("batch.submit", "Submission failed", metadata: [
                "job_id": data.id.uuidString,
                "error": String(describing: error)
            ])
            // Always stop security-scoped access on error too
            if data.hasSecurityScope {
                data.inputURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            }
            await handleError(jobId: data.id, data: data, settings: settings, error: error)
        }
    }
    
    private func performPoll(jobId: UUID, jobName: String, settings: BatchSettings, recovering: Bool) async {
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
                jobName: jobName
            )
        } catch is CancellationError {
            if isPauseRequested {
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
                if isPauseRequested {
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
    
    private func handleSuccess(jobId: UUID, data: JobSubmissionData, settings: BatchSettings, response: ImageEditResponse, jobName: String?) async {
        guard let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == jobId }) else { return }
        
        var requiresStopAccess = false
        var directoryURL: URL!
        if let bookmark = settings.outputDirectoryBookmark {
            guard let resolved = AppPaths.resolveBookmarkAccess(bookmark) else {
                await handleError(
                    jobId: jobId,
                    data: data,
                    settings: settings,
                    error: OutputDirectoryAccessError.bookmarkAccessFailed(path: settings.outputDirectory)
                )
                return
            }
            directoryURL = resolved.url
            requiresStopAccess = true
            
            if let refreshedBookmark = resolved.refreshedBookmarkData,
               let batch = activeBatches.first(where: { $0.tasks.contains(where: { $0.id == jobId }) }) {
                batch.outputDirectoryBookmark = refreshedBookmark
                DebugLog.info("batch.output", "Refreshed output directory bookmark", metadata: [
                    "job_id": jobId.uuidString,
                    "batch_id": batch.id.uuidString
                ])
                if let projectId = settings.projectId {
                    onOutputDirectoryBookmarkRefreshed?(projectId, refreshedBookmark)
                }
            }
        } else {
            directoryURL = URL(fileURLWithPath: settings.outputDirectory)
        }
        
        defer {
            if requiresStopAccess {
                directoryURL.stopAccessingSecurityScopedResource()
            }
        }
        
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
                inDirectory: directoryURL,
                mimeType: finalOutput.mimeType
            )
            attemptedOutputPath = outputURL.path

            DebugLog.debug("batch.output", "Writing output image", metadata: [
                "job_id": jobId.uuidString,
                "path": outputURL.path,
                "bytes": String(finalOutput.data.count),
                "mime_type": finalOutput.mimeType,
                "region_edit": String(job.maskImageData != nil)
            ])
            try finalOutput.data.write(to: outputURL)
            DebugLog.info("batch.output", "Output image write succeeded", metadata: [
                "job_id": jobId.uuidString,
                "path": outputURL.path
            ])
            
            job.status = "completed"
            job.phase = .completed
            job.outputPath = outputURL.path
            job.completedAt = Date()
            
            let effectiveImageSize = job.regionEditProcessingImageSize ?? settings.imageSize
            let cost = settings.cost(inputCount: job.inputPaths.count, imageSizeOverride: effectiveImageSize)
            if let projectId = settings.projectId {
                // Use bookmarks already captured before security scope was stopped.
                // Do NOT use job.inputURLs here — that computed property calls
                // startAccessingSecurityScopedResource() on an already-stopped resource.
                let sourceBookmarks = job.inputBookmarks ?? []
                let outputBookmark = AppPaths.bookmark(for: outputURL)
                
                let historyEntry = HistoryEntry(
                    projectId: projectId,
                    sourceImagePaths: job.inputPaths,
                    outputImagePath: outputURL.path,
                    prompt: mergedTaskPrompt(
                        globalPrompt: settings.prompt,
                        customPrompt: job.customPrompt,
                        isRegionEdit: (job.maskImageData ?? data.maskImageData) != nil
                    ),
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
                onCostIncurred?(cost, effectiveImageSize, projectId)
            }
            
            saveActiveBatches()
            updateProgress()
        } catch {
            DebugLog.error("batch.output", "Output image write failed", metadata: [
                "job_id": jobId.uuidString,
                "path": attemptedOutputPath,
                "error": String(describing: error)
            ])
            await handleError(jobId: jobId, data: data, settings: settings, error: error)
        }
    }
    
    private func handleError(jobId: UUID, data: JobSubmissionData, settings: BatchSettings, error: Error) async {
        guard let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == jobId }) else { return }
        
        job.status = "failed"
        job.phase = .failed
        job.error = error.localizedDescription
        DebugLog.error("batch.error", "Job marked failed", metadata: [
            "job_id": jobId.uuidString,
            "project_id": settings.projectId?.uuidString ?? "nil",
            "error": error.localizedDescription
        ])
        
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
        guard let sourcePath = job.inputPaths.first else {
            throw RegionEditPipelineError.missingSourceImage
        }

        if let bookmark = job.inputBookmarks?.first {
            guard let resolved = AppPaths.resolveBookmarkAccess(bookmark) else {
                throw RegionEditPipelineError.sourceBookmarkAccessFailed(path: sourcePath)
            }
            defer { resolved.url.stopAccessingSecurityScopedResource() }
            return try Data(contentsOf: resolved.url)
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

    private func chooseRegionEditProcessingImageSize(cropRect: CGRect, userSelectedMax: String) -> String {
        let maxDimension = max(cropRect.width, cropRect.height)
        let allowedSizes = allowedImageSizes(upTo: userSelectedMax)
        for candidate in allowedSizes {
            if maxDimension <= pixelDimension(forImageSize: candidate) {
                return candidate
            }
        }
        return allowedSizes.last ?? userSelectedMax
    }

    private func allowedImageSizes(upTo userSelectedMax: String) -> [String] {
        switch userSelectedMax {
        case "4K":
            return ["1K", "2K", "4K"]
        case "2K":
            return ["1K", "2K"]
        case "1K":
            return ["1K"]
        default:
            return [userSelectedMax]
        }
    }

    private func pixelDimension(forImageSize imageSize: String) -> CGFloat {
        switch imageSize {
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
        let completed = allTasks.filter { $0.status == "completed" || $0.status == "failed" }.count
        
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
            
            if activeBatches.contains(where: { $0.status == "paused" }) {
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
        
        let task = ImageTask(inputPaths: entry.sourceImagePaths, projectId: entry.projectId)
        task.externalJobName = jobName
        task.status = "processing"
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
            aspectRatio: entry.aspectRatio,
            imageSize: entry.imageSize,
            outputDirectory: outputDir,
            outputDirectoryBookmark: entry.outputImageBookmark,
            useBatchTier: entry.usedBatchTier,
            projectId: entry.projectId
        )
        batch.tasks = [task]
        
        enqueue(batch)
        statusMessage = "Resumed job from history..."
    }
}
