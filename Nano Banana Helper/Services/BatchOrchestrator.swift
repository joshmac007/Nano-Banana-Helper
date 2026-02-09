import Foundation
import Observation
import UserNotifications

// MARK: - Sendable Helpers
struct JobSubmissionData: Sendable {
    let id: UUID
    let inputURLs: [URL]
    let inputPaths: [String]
}

struct BatchSettings: Sendable {
    let prompt: String
    let aspectRatio: String
    let imageSize: String
    let outputDirectory: String
    let useBatchTier: Bool
    let projectId: UUID?
    
    // Helper for cost calculation
    func cost(inputCount: Int) -> Double {
        let inputRate = useBatchTier ? 0.0006 : 0.0011
        let inputCost = inputRate * Double(max(1, inputCount))
        
        let outputCost: Double
        if useBatchTier {
            switch imageSize {
            case "4K": outputCost = 0.12
            case "2K", "1K": outputCost = 0.067
            default: outputCost = 0.067
            }
        } else {
            switch imageSize {
            case "4K": outputCost = 0.24
            case "2K", "1K": outputCost = 0.134
            default: outputCost = 0.134
            }
        }
        return inputCost + outputCost
    }
}

/// Orchestrates batch processing of image editing tasks
@Observable
@MainActor
final class BatchOrchestrator {
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
    private let service = NanoBananaService()
    private let concurrencyLimit = 1 
    private let timeoutSeconds: TimeInterval = 300

    // Callbacks for history/cost tracking
    var onImageCompleted: ((HistoryEntry) -> Void)?
    var onCostIncurred: ((Double, String, UUID) -> Void)?
    var onHistoryEntryUpdated: ((String, HistoryEntry) -> Void)?
    var onRestoreSettings: ((HistoryEntry) -> Void)?
    
    private let activeBatchURL = AppPaths.activeBatchURL

    init() {
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
        Task {
            await start(batch: batch)
        }
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
        
        await processQueue(batch: batch)
    }
    
    /// Resume all interrupted batches
    func startAll() async {
        for batch in activeBatches where batch.status == "pending" || batch.status == "processing" {
            await start(batch: batch)
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
        
        // Cancel API jobs in background
        Task {
            for job in jobsToCancel {
                if let jobName = job.externalJobName {
                    try? await service.cancelBatchJob(jobName: jobName)
                }
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
    
    private func processQueue(batch: BatchJob) async {
        // 1. Queue all pending jobs in THIS batch to Processing immediately
        let jobsToSubmit = batch.tasks.filter { $0.status == "pending" }
        for job in jobsToSubmit {
             job.status = "processing"
        }
        updateProgress()
        
        statusMessage = "Submitting \(jobsToSubmit.count) jobs..."
        
        let submissionDataList = jobsToSubmit.map { job in
            JobSubmissionData(id: job.id, inputURLs: job.inputURLs, inputPaths: job.inputPaths)
        }
        
        let batchSettings = BatchSettings(
            prompt: batch.prompt,
            aspectRatio: batch.aspectRatio,
            imageSize: batch.imageSize,
            outputDirectory: batch.outputDirectory,
            useBatchTier: batch.useBatchTier,
            projectId: batch.projectId
        )
        
        // 2. Submit all jobs to get IDs
        await withTaskGroup(of: Void.self) { group in
            for data in submissionDataList {
                group.addTask {
                    await self.performSubmission(data: data, settings: batchSettings)
                }
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
        
        let request = ImageEditRequest(
            inputImageURLs: data.inputURLs,
            prompt: settings.prompt,
            aspectRatio: settings.aspectRatio,
            imageSize: settings.imageSize,
            useBatchTier: settings.useBatchTier
        )
        
        do {
            if settings.useBatchTier {
                let jobInfo = try await service.startBatchJob(request: request)
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
                                prompt: settings.prompt,
                                aspectRatio: settings.aspectRatio,
                                imageSize: settings.imageSize,
                                usedBatchTier: settings.useBatchTier,
                                cost: 0,
                                status: "processing",
                                externalJobName: jobInfo.jobName
                            )
                            onImageCompleted?(entry)
                        }
                    }
                }
            } else {
                let response = try await service.editImage(request)
                await handleSuccess(
                    jobId: data.id,
                    data: data,
                    settings: settings,
                    response: response,
                    jobName: nil
                )
            }
        } catch {
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
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: []),
                settings: settings,
                response: response,
                jobName: jobName
            )
        } catch {
            await handleError(
                jobId: jobId,
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: []),
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
            
            let cost = settings.cost(inputCount: job.inputPaths.count)
            if let projectId = settings.projectId {
                let sourceBookmarks = job.inputURLs.compactMap { AppPaths.bookmark(for: $0) }
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
                    outputImageBookmark: outputBookmark
                )
                
                if let jobName = jobName {
                    onHistoryEntryUpdated?(jobName, historyEntry)
                } else {
                    onImageCompleted?(historyEntry)
                }
                onCostIncurred?(cost, settings.imageSize, projectId)
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

    private func generateOutputURL(for task: ImageTask, in directory: String, mimeType: String) -> URL {
        let directoryURL = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        
        let inputName = task.inputURL.deletingPathExtension().lastPathComponent
        let ext = mimeType == "image/png" ? "png" : "jpg"
        let outputName = "\(inputName)_edited.\(ext)"
        
        return directoryURL.appendingPathComponent(outputName)
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
            
            if let batches = try? decoder.decode([BatchJob].self, from: data) {
                activeBatches = batches
            } else if let singleBatch = try? decoder.decode(BatchJob.self, from: data) {
                 activeBatches = [singleBatch]
            }
            
            if !processingJobs.isEmpty || !pendingJobs.isEmpty {
                statusMessage = "Resumed sessions"
            }
            updateProgress()
        } catch {
            print("Failed to load active batches: \(error)")
        }
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
            useBatchTier: entry.usedBatchTier,
            projectId: entry.projectId
        )
        batch.tasks = [task]
        
        enqueue(batch)
        statusMessage = "Resumed job from history..."
    }
}
