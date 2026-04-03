import Foundation
import Observation
import UserNotifications

// MARK: - Sendable Helpers
struct JobSubmissionData: Sendable {
    let id: UUID
    let inputURLs: [URL]       // Security-scoped URLs (already started access)
    let inputPaths: [String]
    let hasSecurityScope: Bool // Whether we need to stop access after use
}

struct BatchSettings: Sendable {
    let prompt: String
    let systemPrompt: String?
    let aspectRatio: String
    let imageSize: String
    let outputDirectory: String
    let useBatchTier: Bool
    let projectId: UUID?
    
    // Helper for cost calculation
    func cost(inputCount: Int) -> Double {
        ImageSize.calculateCost(imageSize: imageSize, inputCount: inputCount, isBatchTier: useBatchTier)
    }
}

/// Orchestrates batch processing of image editing tasks
@Observable
@MainActor
final class BatchOrchestrator {
    typealias ProcessQueueOverride = @Sendable (UUID) async -> Void

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
        !activeBatches.filter { $0.status == "processing" }.isEmpty
    }
    var isPaused: Bool = false
    var currentProgress: Double = 0.0
    var statusMessage: String = "Ready"
    
    private var activeBatches: [BatchJob] = []
    private let service: NanoBananaService
    private let concurrencyLimit = 5 // Paid tier: safe default for concurrent submissions
    private let activeBatchURL: URL
    private let bookmarkDependencies: AppPaths.BookmarkResolutionDependencies
    private let autoStartEnqueuedBatches: Bool
    private let processQueueOverride: ProcessQueueOverride?

    // Callbacks for history/cost tracking
    var onImageCompleted: ((HistoryEntry) -> Void)?
    var onCostIncurred: ((Double, String, UUID, TokenUsage?, String?) -> Void)?
    var onHistoryEntryUpdated: ((String, HistoryEntry) -> Void)?
    var onRestoreSettings: ((HistoryEntry) -> Void)?

    init(
        service: NanoBananaService = NanoBananaService(),
        activeBatchURL: URL? = nil,
        bookmarkDependencies: AppPaths.BookmarkResolutionDependencies? = nil,
        autoStartEnqueuedBatches: Bool = true,
        processQueueOverride: ProcessQueueOverride? = nil
    ) {
        self.service = service
        self.activeBatchURL = activeBatchURL ?? AppPaths.activeBatchURL
        self.bookmarkDependencies = bookmarkDependencies ?? .live
        self.autoStartEnqueuedBatches = autoStartEnqueuedBatches
        self.processQueueOverride = processQueueOverride
        loadActiveBatches()
    }
    
    /// Enqueue a new batch job for processing
    func enqueue(_ batch: BatchJob) {
        activeBatches.append(batch)
        
        // Ensure all tasks have the project ID
        for task in batch.tasks {
            task.projectId = batch.projectId
        }
        
        saveActiveBatches()
        updateProgress()
        
        // Auto-start this batch
        if autoStartEnqueuedBatches {
            Task {
                await start(batch: batch)
            }
        }
    }
    
    /// Enqueue a text-to-image generation batch job
    func enqueueTextGeneration(
        prompt: String,
        systemPrompt: String? = nil,
        aspectRatio: String,
        imageSize: String,
        outputDirectory: String,
        useBatchTier: Bool,
        imageCount: Int,
        projectId: UUID?
    ) {
        let batch = BatchJob(
            prompt: prompt,
            systemPrompt: systemPrompt,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            outputDirectory: outputDirectory,
            useBatchTier: useBatchTier,
            projectId: projectId
        )
        batch.isTextMode = true
        batch.tasks = (0..<imageCount).map { _ in
            ImageTask(inputPaths: [], projectId: projectId)
        }
        enqueue(batch)
    }
    
    /// Start or resume batch processing
    func start(batch: BatchJob) async {
        guard batch.status != "processing" && batch.status != "completed" else { return }
        
        // Request notification permission - Skip in tests
        if !isTesting && Bundle.main.bundleIdentifier != nil {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        
        batch.status = "processing"
        statusMessage = "Processing \(activeBatches.count) batches..."
        
        if let processQueueOverride {
            await processQueueOverride(batch.id)
        } else {
            await processQueue(batch: batch)
        }
    }
    
    /// Resume all interrupted batches
    func startAll() async {
        let batchIDs = activeBatches
            .filter { $0.status == "pending" || $0.status == "processing" }
            .map(\.id)

        await withTaskGroup(of: Void.self) { group in
            for batchID in batchIDs {
                group.addTask {
                    await self.startBatchIfNeeded(id: batchID)
                }
            }
        }
    }
    
    /// Pause batch processing
    func pause() {
        isPaused = true
        statusMessage = "Paused"
    }
    
    /// Cancel all pending tasks
    func cancel() {
        // Cancel all batches
        for batch in activeBatches {
             cancel(batch: batch)
        }
        activeBatches = []
        isPaused = false
        statusMessage = "Cancelled all jobs"
    }
    
    func cancel(batch: BatchJob) {
        batch.status = "cancelled"
        
        // Move all pending/processing to failed and cancel on API side
        let jobsToCancel = batch.tasks.filter {
            $0.status == "processing" || $0.status == "pending" || $0.phase == .submitting
        }
        
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
                    externalJobName: job.externalJobName,
                    modelName: AppConfig.load().modelName,
                    systemPrompt: batch.systemPrompt
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
        activeBatches = []
        currentProgress = 0.0
        statusMessage = "Ready"
        saveActiveBatches()
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
            batch.tasks.contains {
                $0.externalJobName != nil && ($0.phase == .polling || $0.phase == .reconnecting || $0.phase == .stalled)
            } && batch.status != "processing"
        }
    }
    
    func resumeInterruptedJobs() async {
        await startAll()
    }
    
    private func processQueue(batch: BatchJob) async {
        // 1. Queue all pending jobs in THIS batch to Processing immediately
        let jobsToSubmit = batch.tasks.filter { $0.status == "pending" }
        for job in jobsToSubmit {
             job.status = "processing"
        }
        updateProgress()
        
        statusMessage = "Submitting \(jobsToSubmit.count) jobs..."
        
        var didRefreshInputBookmarks = false
        let submissionDataList: [JobSubmissionData] = jobsToSubmit.map { job in
            // Resolve security-scoped URLs from bookmarks if available.
            // resolveBookmark calls startAccessingSecurityScopedResource internally.
            if let bookmarks = job.inputBookmarks, !bookmarks.isEmpty {
                var updatedBookmarks = bookmarks
                let resolvedBookmarks: [AppPaths.ResolvedBookmark] = bookmarks.enumerated().compactMap { item in
                    guard let resolution = AppPaths.resolveBookmark(
                        item.element,
                        dependencies: bookmarkDependencies
                    ) else {
                        return nil
                    }
                    if let refreshedBookmark = resolution.refreshedBookmarkData {
                        updatedBookmarks[item.offset] = refreshedBookmark
                    }
                    return resolution
                }

                if updatedBookmarks != bookmarks {
                    job.inputBookmarks = updatedBookmarks
                    didRefreshInputBookmarks = true
                }

                if !resolvedBookmarks.isEmpty {
                    return JobSubmissionData(
                        id: job.id,
                        inputURLs: resolvedBookmarks.map(\.url),
                        inputPaths: job.inputPaths,
                        hasSecurityScope: true
                    )
                }
            }
            // Fallback to plain path-based URLs (drag-and-drop, or already-accessible files)
            return JobSubmissionData(id: job.id, inputURLs: job.inputPaths.map { URL(fileURLWithPath: $0) }, inputPaths: job.inputPaths, hasSecurityScope: false)
        }

        if didRefreshInputBookmarks {
            saveActiveBatches()
        }
        
        let batchSettings = BatchSettings(
            prompt: batch.prompt,
            systemPrompt: batch.systemPrompt,
            aspectRatio: batch.aspectRatio,
            imageSize: batch.imageSize,
            outputDirectory: batch.outputDirectory,
            useBatchTier: batch.useBatchTier,
            projectId: batch.projectId
        )
        
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
        
        // 3. Poll all successfully submitted jobs concurrently
        statusMessage = "Polling batch jobs..."
        let validJobs = batch.tasks.filter { $0.externalJobName != nil && $0.phase != .failed && $0.status == "processing" }
        let validJobsData: [(UUID, String)] = validJobs.compactMap {
            guard let name = $0.externalJobName else { return nil }
            return ($0.id, name)
        }
        
        await withTaskGroup(of: Void.self) { group in
            for (id, name) in validJobsData {
                group.addTask {
                    await self.performPoll(jobId: id, jobName: name, settings: batchSettings, recovering: false)
                }
            }
        }
        
        // Batch complete check
        if !batch.tasks.contains(where: { $0.status == "processing" || $0.status == "pending" }) {
             if batch.tasks.contains(where: { $0.status == "failed" }) {
                  batch.status = "failed"
             } else {
                  batch.status = "completed"
             }
        }
        
        if batch.status == "completed" {
            let count = batch.tasks.filter { $0.status == "completed" }.count
            statusMessage = "Completed: \(count) output images"
        } else if batch.status == "failed" {
            statusMessage = "Completed with errors"
        }
        
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
        
        let request: ImageEditRequest
        if data.inputURLs.isEmpty {
            // Text-to-image mode: no input images
            request = ImageEditRequest.textOnly(
                prompt: settings.prompt,
                systemInstruction: settings.systemPrompt,
                aspectRatio: settings.aspectRatio,
                imageSize: settings.imageSize,
                useBatchTier: settings.useBatchTier
            )
        } else {
            // Image editing mode: with input images
            request = ImageEditRequest(
                inputImageURLs: data.inputURLs,
                prompt: settings.prompt,
                systemInstruction: settings.systemPrompt,
                aspectRatio: settings.aspectRatio,
                imageSize: settings.imageSize,
                useBatchTier: settings.useBatchTier
            )
        }
        
        do {
            if settings.useBatchTier {
                let jobInfo = try await service.startBatchJob(request: request)
                // Stop security-scoped access now that the service has read the file data
                if data.hasSecurityScope {
                    data.inputURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                }
                await MainActor.run {
                     if let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == data.id }) {
                        job.externalJobName = jobInfo.jobName
                        job.phase = .polling
                        job.submittedAt = Date()
                        job.lastPollState = "JOB_STATE_PENDING"
                        job.lastPollUpdatedAt = Date()
                        job.stalledAt = nil
                        
                        if let projectId = settings.projectId {
                            let entry = HistoryEntry(
                                projectId: projectId,
                                sourceImagePaths: job.inputPaths,
                                outputImagePath: "",
                                prompt: settings.prompt,
                                aspectRatio: settings.aspectRatio,
                                imageSize: settings.imageSize,
                                usedBatchTier: settings.useBatchTier,
                                cost: 0,
                                status: "processing",
                                externalJobName: jobInfo.jobName,
                                modelName: AppConfig.load().modelName,
                                systemPrompt: settings.systemPrompt
                            )
                            onImageCompleted?(entry)
                        }
                    }
                }
            } else {
                let response = try await service.editImage(request)
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
                response = try await service.resumePolling(jobName: jobName, onPollUpdate: { @Sendable update in
                    Task { @MainActor [weak self] in
                        self?.updatePollStatus(jobId: jobId, update: update)
                    }
                }, softTimeout: softPollTimeout)
            } else {
                response = try await service.pollBatchJob(jobName: jobName, requestKey: "", onPollUpdate: { @Sendable update in
                    Task { @MainActor [weak self] in
                        self?.updatePollStatus(jobId: jobId, update: update)
                    }
                }, softTimeout: softPollTimeout)
            }
            
            await handleSuccess(
                jobId: jobId,
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: [], hasSecurityScope: false),
                settings: settings,
                response: response,
                jobName: jobName
            )
        } catch {
            if case let NanoBananaError.softTimeout(state) = error {
                await markJobAsStalled(jobId: jobId, state: state)
                return
            }
            await handleError(
                jobId: jobId,
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: [], hasSecurityScope: false),
                settings: settings,
                error: error
            )
        }
    }
    
    private func updatePollStatus(jobId: UUID, update: PollStatusUpdate) {
        if let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == jobId }) {
            job.phase = .polling
            job.status = "processing"
            job.pollCount = update.attempt
            job.lastPollState = update.state
            job.lastPollUpdatedAt = update.updatedAt
            job.stalledAt = nil
        }
    }

    private func markJobAsStalled(jobId: UUID, state: String) async {
        guard let batch = activeBatches.first(where: { $0.tasks.contains(where: { $0.id == jobId }) }),
              let job = batch.tasks.first(where: { $0.id == jobId }) else {
            return
        }

        job.phase = .stalled
        job.status = "processing"
        job.lastPollState = state
        job.lastPollUpdatedAt = Date()
        job.stalledAt = Date()
        job.error = "Polling paused locally after the configured timeout."
        batch.status = "pending"
        statusMessage = "Polling paused locally. Use Resume Batch to continue."
        saveActiveBatches()
        updateProgress()
    }
    
    private func handleSuccess(jobId: UUID, data: JobSubmissionData, settings: BatchSettings, response: ImageEditResponse, jobName: String?) async {
        guard let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == jobId }) else { return }
        
        let outputURL = generateOutputURL(
            for: job,
            in: settings.outputDirectory,
            mimeType: response.mimeType
        )
        
        do {
            try response.imageData.write(to: outputURL)
            
            job.status = "completed"
            job.phase = .completed
            job.outputPath = outputURL.path
            job.completedAt = Date()
            job.error = nil
            job.stalledAt = nil
            
            let cost = settings.cost(inputCount: job.inputPaths.count)
            let currentModelName = await service.getModelName()
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
                    prompt: settings.prompt,
                    aspectRatio: settings.aspectRatio,
                    imageSize: settings.imageSize,
                    usedBatchTier: settings.useBatchTier,
                    cost: cost,
                    status: "completed",
                    externalJobName: jobName,
                    sourceImageBookmarks: sourceBookmarks.isEmpty ? nil : sourceBookmarks,
                    outputImageBookmark: outputBookmark,
                    tokenUsage: response.tokenUsage,
                    modelName: currentModelName,
                    systemPrompt: settings.systemPrompt
                )
                
                if let jobName = jobName {
                    onHistoryEntryUpdated?(jobName, historyEntry)
                } else {
                    onImageCompleted?(historyEntry)
                }
                onCostIncurred?(cost, settings.imageSize, projectId, response.tokenUsage, currentModelName)
            }
            
            saveActiveBatches()
            updateProgress()
        } catch {
            await handleError(jobId: jobId, data: data, settings: settings, error: error)
        }
    }
    
    private func handleError(jobId: UUID, data: JobSubmissionData, settings: BatchSettings, error: Error) async {
        guard let job = activeBatches.lazy.flatMap({ $0.tasks }).first(where: { $0.id == jobId }) else { return }
        
        job.status = "failed"
        job.phase = .failed
        job.error = error.localizedDescription
        job.stalledAt = nil
        
        if let projectId = settings.projectId {
            let historyEntry = HistoryEntry(
                projectId: projectId,
                sourceImagePaths: job.inputPaths,
                outputImagePath: "",
                prompt: settings.prompt,
                aspectRatio: settings.aspectRatio,
                imageSize: settings.imageSize,
                usedBatchTier: settings.useBatchTier,
                cost: 0,
                status: "failed",
                error: error.localizedDescription,
                externalJobName: job.externalJobName,
                modelName: await service.getModelName(),
                systemPrompt: settings.systemPrompt
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

    private func generateOutputURL(for task: ImageTask, in directory: String, mimeType: String) -> URL {
        let directoryURL = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        
        let ext = mimeType == "image/png" ? "png" : "jpg"
        
        let baseName: String
        if task.inputPaths.isEmpty {
            // Text mode: use filesystem-safe timestamp with UUID component for uniqueness
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())
            let shortID = task.id.uuidString.prefix(8)
            baseName = "generated_\(timestamp)_\(shortID)"
        } else {
            // Image mode: use input filename
            let inputName = URL(fileURLWithPath: task.inputPaths.first ?? "image")
                .deletingPathExtension().lastPathComponent
            baseName = "\(inputName)_edited"
        }
        
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

    private var softPollTimeout: TimeInterval {
        30 * 60
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
             return
        }
        do {
            let data = try JSONEncoder().encode(activeBatches)
            try data.write(to: activeBatchURL)
        } catch {
            print("Failed to save active batches: \(error)")
        }
    }

    private func loadActiveBatches() {
        guard FileManager.default.fileExists(atPath: activeBatchURL.path) else { return }
        do {
            let data = try Data(contentsOf: activeBatchURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            var loadedBatches: [BatchJob] = []
            if let batches = try? decoder.decode([BatchJob].self, from: data) {
                loadedBatches = batches
            } else if let singleBatch = try? decoder.decode(BatchJob.self, from: data) {
                 loadedBatches = [singleBatch]
            }

            activeBatches = loadedBatches

            // Refresh stale bookmarks in the background so they don't block app launch.
            // BatchOrchestrator is @MainActor, so this Task also runs on the main actor —
            // writes to activeBatches are safe, but they happen after init returns.
            Task {
                if self.refreshInputBookmarksIfNeeded() {
                    self.saveActiveBatches()
                }
            }
            
            if !processingJobs.isEmpty || !pendingJobs.isEmpty {
                statusMessage = "Resumed sessions"
            }
            updateProgress()
        } catch {
            print("Failed to load active batches: \(error)")
        }
    }


    private func startBatchIfNeeded(id: UUID) async {
        guard let batch = activeBatches.first(where: { $0.id == id }) else { return }
        await start(batch: batch)
    }

    @discardableResult
    private func refreshInputBookmarksIfNeeded() -> Bool {
        var didRefresh = false

        for batch in activeBatches {
            for task in batch.tasks {
                guard let inputBookmarks = task.inputBookmarks else { continue }
                var updatedBookmarks = inputBookmarks

                for index in inputBookmarks.indices {
                    guard let resolution = AppPaths.resolveBookmarkToPath(
                        inputBookmarks[index],
                        dependencies: bookmarkDependencies
                    ),
                    let refreshedBookmark = resolution.refreshedBookmarkData else {
                        continue
                    }

                    updatedBookmarks[index] = refreshedBookmark
                    didRefresh = true
                }

                if updatedBookmarks != inputBookmarks {
                    task.inputBookmarks = updatedBookmarks
                }
            }
        }

        return didRefresh
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
        task.lastPollState = "JOB_STATE_PENDING"
        task.lastPollUpdatedAt = entry.timestamp
        
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
            useBatchTier: entry.usedBatchTier,
            projectId: entry.projectId
        )
        batch.tasks = [task]
        
        enqueue(batch)
        statusMessage = "Resumed job from history..."
    }
}
