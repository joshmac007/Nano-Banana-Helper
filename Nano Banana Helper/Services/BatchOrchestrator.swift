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
    let outputDirectoryBookmark: Data?
    let useBatchTier: Bool
    let projectId: UUID?
    let modelName: String?

    func cost(inputCount: Int) -> Double {
        ImageSize.calculateCost(
            imageSize: imageSize,
            inputCount: inputCount,
            isBatchTier: useBatchTier,
            modelName: modelName
        )
    }
}

struct PersistedQueueState: Codable {
    let controlState: QueueControlState
    let batches: [BatchJob]
}

private struct StartupRecoveryNormalizationResult {
    let controlState: QueueControlState
    let shouldAutoResume: Bool
    let hadAmbiguousSubmittingTasks: Bool
    let didChangePersistedState: Bool
}

enum QueueAggregateTone: Equatable {
    case neutral
    case success
    case cancelled
    case issue
}

/// Orchestrates batch processing of image editing tasks
@Observable
@MainActor
final class BatchOrchestrator {
    typealias ProcessQueueOverride = @Sendable (UUID) async -> Void

    private var allJobs: [ImageTask] {
        activeBatches.flatMap(\.tasks)
    }

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
        activeBatches.flatMap { $0.tasks.filter { ImageTask.issueStatuses.contains($0.status) } }
    }

    var cancelledJobs: [ImageTask] {
        activeBatches.flatMap { $0.tasks.filter { $0.status == "cancelled" } }
    }

    var hasNonTerminalWork: Bool {
        allJobs.contains(where: { !$0.isTerminal })
    }

    var hasActiveNonCancelledWork: Bool {
        allJobs.contains { !$0.isTerminal && $0.phase != .cancelRequested }
    }

    var hasCancellationInProgress: Bool {
        controlState == .cancelling || allJobs.contains {
            !$0.isTerminal && $0.phase == .cancelRequested
        }
    }

    var hasRemoteCancellationReconciliation: Bool {
        allJobs.contains {
            !$0.isTerminal && $0.phase == .cancelRequested && $0.hasRemoteJob
        }
    }

    var hasTrueFailures: Bool {
        !failedJobs.isEmpty
    }

    var hasOnlyCancelledTerminalJobs: Bool {
        !allJobs.isEmpty &&
        allJobs.allSatisfy(\.isTerminal) &&
        allJobs.allSatisfy { $0.status == "cancelled" }
    }

    var canResumeQueue: Bool {
        !hasCancellationInProgress &&
        !hasOnlyCancelledTerminalJobs &&
        (isPaused || hasInterruptedJobs)
    }

    var aggregateTone: QueueAggregateTone {
        if hasTrueFailures { return .issue }
        if !isRunning && !cancelledJobs.isEmpty { return .cancelled }
        if !isRunning && !completedJobs.isEmpty { return .success }
        return .neutral
    }

    var cancellationStatusMessage: String {
        hasRemoteCancellationReconciliation ? "Reconciling cancellation..." : "Cancelling jobs..."
    }

    var isRunning: Bool {
        switch controlState {
        case .running, .resuming, .cancelling:
            return true
        case .idle, .pausedLocal, .interrupted:
            return false
        }
    }

    var isPaused: Bool {
        controlState == .pausedLocal
    }

    var hasInterruptedJobs: Bool {
        controlState == .interrupted || activeBatches.contains { batch in
            batch.tasks.contains { task in
                task.hasRemoteJob && !task.isTerminal && (
                    task.phase == .reconnecting ||
                    task.phase == .stalled ||
                    task.phase == .pausedLocal ||
                    task.phase == .submittedRemote
                )
            }
        }
    }

    var currentProgress: Double = 0.0
    var statusMessage: String = "Ready"
    var controlState: QueueControlState = .idle

    private var activeBatches: [BatchJob] = []
    private let service: NanoBananaService
    private let concurrencyLimit = 5
    private let activeBatchURL: URL
    private let bookmarkDependencies: AppPaths.BookmarkResolutionDependencies
    private let autoStartEnqueuedBatches: Bool
    private let processQueueOverride: ProcessQueueOverride?
    private var activeBatchRunIDs: Set<UUID> = []
    private var startAllTask: Task<Void, Never>?
    private var startupRecoveryTask: Task<Void, Never>?
    private var didAttemptStartupRecovery = false
    private var shouldAutoResumeRecoveredQueueOnLaunch = false
    private var startupRecoveryHadAmbiguousSubmittingTasks = false

    var onImageCompleted: ((HistoryEntry) -> Void)?
    var onCostIncurred: ((Double, String, UUID, TokenUsage?, String?) -> Void)?
    var onHistoryEntryUpdated: ((String, HistoryEntry) -> Void)?
    var onLedgerEntryCreated: ((UsageLedgerEntry) -> Void)?
    var onOutputDirectoryBookmarkRefreshed: ((UUID?, String, Data) -> Void)?
    var onRestoreSettings: ((HistoryEntry) -> Void)?

    private let ambiguousSubmittingRecoveryMessage = "App closed before submission completed. Remote job id was not saved; retry manually to avoid duplicate jobs."

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

    func enqueue(_ batch: BatchJob) {
        activeBatches.append(batch)

        for task in batch.tasks {
            task.projectId = batch.projectId
        }

        normalizeBatchStatus(batch)
        saveActiveBatches()
        updateProgress()

        if autoStartEnqueuedBatches, controlState != .pausedLocal, controlState != .cancelling {
            Task {
                await start(batch: batch)
            }
        }
    }

    func enqueueTextGeneration(
        prompt: String,
        systemPrompt: String? = nil,
        aspectRatio: String,
        imageSize: String,
        outputDirectory: String,
        outputDirectoryBookmark: Data? = nil,
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
            outputDirectoryBookmark: outputDirectoryBookmark,
            useBatchTier: useBatchTier,
            projectId: projectId,
            modelName: AppConfig.load().modelName ?? AppPricing.defaultModelName
        )
        batch.isTextMode = true
        batch.tasks = (0..<imageCount).map { _ in
            ImageTask(inputPaths: [], projectId: projectId)
        }
        enqueue(batch)
    }

    func start(batch: BatchJob) async {
        guard !activeBatchRunIDs.contains(batch.id) else { return }
        guard batch.tasks.contains(where: { !$0.isTerminal }) else {
            normalizeBatchStatus(batch)
            await refreshControlStateAfterWork()
            return
        }
        guard controlState != .pausedLocal else { return }

        activeBatchRunIDs.insert(batch.id)
        defer { activeBatchRunIDs.remove(batch.id) }

        if !isTesting && Bundle.main.bundleIdentifier != nil {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }

        if controlState == .idle || controlState == .interrupted {
            controlState = .running
        }

        batch.status = "processing"
        if controlState == .resuming {
            statusMessage = "Resuming batch jobs..."
        } else if controlState == .cancelling {
            statusMessage = "Cancelling jobs..."
        } else {
            statusMessage = "Processing \(activeBatches.count) batches..."
        }
        saveActiveBatches()

        if let processQueueOverride {
            await processQueueOverride(batch.id)
        } else {
            await processQueue(batch: batch)
        }

        normalizeBatchStatus(batch)
        await refreshControlStateAfterWork()
        saveActiveBatches()
        updateProgress()
    }

    func startAll() async {
        if let startAllTask {
            await startAllTask.value
            return
        }

        let task = Task { @MainActor in
            await self.performStartAll()
        }
        startAllTask = task
        await task.value
        startAllTask = nil
    }

    private func performStartAll() async {
        guard !activeBatches.isEmpty else {
            controlState = .idle
            statusMessage = "Ready"
            saveActiveBatches()
            return
        }

        if controlState == .pausedLocal || controlState == .interrupted {
            controlState = .resuming
            statusMessage = "Resuming batch jobs..."
        } else if controlState != .cancelling {
            controlState = .running
            statusMessage = "Processing \(activeBatches.count) batches..."
        }
        saveActiveBatches()

        let batchIDs = activeBatches
            .filter { $0.tasks.contains(where: { !$0.isTerminal }) }
            .map(\.id)

        await withTaskGroup(of: Void.self) { group in
            for batchID in batchIDs {
                group.addTask {
                    await self.startBatchIfNeeded(id: batchID)
                }
            }
        }

        await refreshControlStateAfterWork()
        saveActiveBatches()
        updateProgress()
    }

    func recoverSavedQueueOnLaunchIfNeeded() async {
        if let startupRecoveryTask {
            await startupRecoveryTask.value
            return
        }

        if let startAllTask {
            didAttemptStartupRecovery = true
            shouldAutoResumeRecoveredQueueOnLaunch = false
            await startAllTask.value
            return
        }

        guard !didAttemptStartupRecovery else { return }
        didAttemptStartupRecovery = true

        guard shouldAutoResumeRecoveredQueueOnLaunch else { return }

        let task = Task { @MainActor in
            guard self.shouldAutoResumeRecoveredQueueOnLaunch else { return }
            self.statusMessage = "Recovering saved queue..."
            self.saveActiveBatches()
            await self.startAll()
            self.shouldAutoResumeRecoveredQueueOnLaunch = false
        }
        startupRecoveryTask = task
        await task.value
        startupRecoveryTask = nil
    }

    func pause() {
        guard isRunning, !hasCancellationInProgress else { return }
        controlState = .pausedLocal
        statusMessage = "Paused locally"
        applyPausedStateToActiveTasks()
        saveActiveBatches()
        updateProgress()
    }

    func cancel() {
        guard hasNonTerminalWork else {
            controlState = .idle
            statusMessage = "Ready"
            saveActiveBatches()
            return
        }

        controlState = .cancelling
        statusMessage = cancellationStatusMessage
        for batch in activeBatches {
            cancel(batch: batch)
        }
        saveActiveBatches()
        updateProgress()

        if activeBatches.contains(where: { $0.tasks.contains(where: { $0.status == "processing" && ($0.externalJobName != nil || $0.phase == .submitting) }) }) {
            Task {
                await self.startAll()
            }
        } else {
            Task {
                await self.refreshControlStateAfterWork()
                self.saveActiveBatches()
            }
        }
    }

    func cancel(batch: BatchJob) {
        batch.status = "processing"

        for job in batch.tasks where !job.isTerminal {
            if job.status == "pending", job.externalJobName == nil, job.phase != .submitting {
                finalizeLocalCancellation(job: job, batch: batch)
                continue
            }

            job.status = "processing"
            job.phase = .cancelRequested
            job.cancelRequestedAt = job.cancelRequestedAt ?? Date()
            job.error = "Cancel requested. Waiting for final status."
            job.stalledAt = nil

            if let jobName = job.externalJobName {
                Task {
                    try? await self.service.cancelBatchJob(jobName: jobName)
                }
            }
        }

        normalizeBatchStatus(batch)
        statusMessage = cancellationStatusMessage
        saveActiveBatches()
        updateProgress()
    }

    func reset() {
        activeBatches = []
        controlState = .idle
        currentProgress = 0.0
        statusMessage = "Ready"
        saveActiveBatches()
    }

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

    func removeCancelledTasks(at offsets: IndexSet) {
        let tasksToRemove = offsets.map { cancelledJobs[$0] }
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

    func resumeInterruptedJobs() async {
        await startAll()
    }

    private func processQueue(batch: BatchJob) async {
        let batchSettings = BatchSettings(
            prompt: batch.prompt,
            systemPrompt: batch.systemPrompt,
            aspectRatio: batch.aspectRatio,
            imageSize: batch.imageSize,
            outputDirectory: batch.outputDirectory,
            outputDirectoryBookmark: batch.outputDirectoryBookmark,
            useBatchTier: batch.useBatchTier,
            projectId: batch.projectId,
            modelName: batch.modelName
        )

        if controlState != .cancelling {
            let submissionDataList = buildSubmissionDataList(for: batch)
            if !submissionDataList.isEmpty {
                statusMessage = "Submitting \(submissionDataList.count) jobs..."
                await runSubmissions(submissionDataList, settings: batchSettings)
            }
        }

        if controlState == .pausedLocal {
            applyPausedStateToBatch(batch)
            return
        }

        let jobsToPoll = batch.tasks.compactMap { task -> (UUID, String, Bool)? in
            guard let jobName = task.externalJobName, shouldPoll(task: task) else { return nil }
            let recovering = task.phase == .reconnecting || task.phase == .stalled || task.phase == .pausedLocal || task.phase == .submittedRemote || task.phase == .cancelRequested
            return (task.id, jobName, recovering)
        }

        if !jobsToPoll.isEmpty {
            statusMessage = controlState == .cancelling ? "Reconciling cancellation..." : "Polling batch jobs..."
            await withTaskGroup(of: Void.self) { group in
                for (id, name, recovering) in jobsToPoll {
                    group.addTask {
                        await self.performPoll(jobId: id, jobName: name, settings: batchSettings, recovering: recovering)
                    }
                }
            }
        }

        normalizeBatchStatus(batch)
        if batch.status == "completed" {
            let count = batch.tasks.filter { $0.status == "completed" }.count
            statusMessage = "Completed: \(count) output images"
            await sendCompletionNotification()
        } else if batch.status == "failed" {
            statusMessage = "Completed with issues"
            await sendCompletionNotification()
        } else if batch.status == "cancelled" {
            statusMessage = "Cancellation complete"
        }
    }

    private func runSubmissions(_ submissionDataList: [JobSubmissionData], settings: BatchSettings) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = submissionDataList.makeIterator()
            var inFlight = 0

            while true {
                while inFlight < concurrencyLimit, let data = iterator.next() {
                    guard canStartNewLocalWork else { break }
                    group.addTask {
                        await self.performSubmission(data: data, settings: settings)
                    }
                    inFlight += 1
                }

                if inFlight == 0 {
                    break
                }

                await group.next()
                inFlight -= 1

                if !canStartNewLocalWork {
                    while inFlight > 0 {
                        await group.next()
                        inFlight -= 1
                    }
                    break
                }
            }
        }
    }

    private func buildSubmissionDataList(for batch: BatchJob) -> [JobSubmissionData] {
        var didRefreshInputBookmarks = false

        let submissionDataList: [JobSubmissionData] = batch.tasks.compactMap { job in
            guard shouldSubmit(task: job) else { return nil }
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
            return JobSubmissionData(
                id: job.id,
                inputURLs: job.inputPaths.map { URL(fileURLWithPath: $0) },
                inputPaths: job.inputPaths,
                hasSecurityScope: false
            )
        }

        if didRefreshInputBookmarks {
            saveActiveBatches()
        }

        return submissionDataList
    }

    // MARK: - Task Workers

    private func performSubmission(data: JobSubmissionData, settings: BatchSettings) async {
        guard let job = task(for: data.id) else { return }

        if controlState == .cancelling {
            finalizeLocalCancellation(job: job, batch: batch(containing: data.id))
            return
        }

        if controlState == .pausedLocal {
            job.phase = .pausedLocal
            job.error = "Paused locally. Resume to continue."
            saveActiveBatches()
            updateProgress()
            return
        }

        job.status = "processing"
        job.phase = .submitting
        job.startedAt = job.startedAt ?? Date()
        job.error = nil
        saveActiveBatches()
        updateProgress()

        let request: ImageEditRequest
        if data.inputURLs.isEmpty {
            request = ImageEditRequest.textOnly(
                prompt: settings.prompt,
                systemInstruction: settings.systemPrompt,
                aspectRatio: settings.aspectRatio,
                imageSize: settings.imageSize,
                useBatchTier: settings.useBatchTier
            )
        } else {
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
                if data.hasSecurityScope {
                    data.inputURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                }

                guard let submittedJob = task(for: data.id) else { return }
                submittedJob.externalJobName = jobInfo.jobName
                submittedJob.submittedAt = Date()
                submittedJob.lastPollState = "JOB_STATE_PENDING"
                submittedJob.lastPollUpdatedAt = Date()
                submittedJob.stalledAt = nil
                submittedJob.status = "processing"
                submittedJob.cancelRequestedAt = submittedJob.cancelRequestedAt ?? (submittedJob.phase == .cancelRequested ? Date() : nil)

                    if let projectId = settings.projectId {
                        let entry = HistoryEntry(
                            projectId: projectId,
                            sourceImagePaths: submittedJob.inputPaths,
                            outputImagePath: "",
                        prompt: settings.prompt,
                        aspectRatio: settings.aspectRatio,
                        imageSize: settings.imageSize,
                            usedBatchTier: settings.useBatchTier,
                            cost: 0,
                            status: "processing",
                            externalJobName: jobInfo.jobName,
                            sourceImageBookmarks: submittedJob.inputBookmarks,
                            outputDirectoryBookmark: settings.outputDirectoryBookmark,
                            modelName: settings.modelName,
                            systemPrompt: settings.systemPrompt
                        )
                    onImageCompleted?(entry)
                }

                if submittedJob.phase == .cancelRequested || controlState == .cancelling {
                    submittedJob.phase = .cancelRequested
                    submittedJob.error = "Cancel requested. Waiting for final status."
                    submittedJob.cancelRequestedAt = submittedJob.cancelRequestedAt ?? Date()
                    Task {
                        try? await self.service.cancelBatchJob(jobName: jobInfo.jobName)
                    }
                } else if controlState == .pausedLocal {
                    submittedJob.phase = .pausedLocal
                    submittedJob.error = "Paused locally. Resume to reconcile remote status."
                } else {
                    submittedJob.phase = .submittedRemote
                    submittedJob.error = nil
                }
                saveActiveBatches()
                updateProgress()
            } else {
                let response = try await service.editImage(request)
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
            if data.hasSecurityScope {
                data.inputURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            }
            await handleError(jobId: data.id, data: data, settings: settings, error: error)
        }
    }

    private func performPoll(jobId: UUID, jobName: String, settings: BatchSettings, recovering: Bool) async {
        do {
            let response: ImageEditResponse
            let shouldContinue: @Sendable () async -> Bool = { [weak self] in
                await MainActor.run {
                    self?.shouldContinuePolling(jobId: jobId) ?? false
                }
            }

            if recovering {
                response = try await service.resumePolling(
                    jobName: jobName,
                    onPollUpdate: { @Sendable update in
                        Task { @MainActor [weak self] in
                            self?.updatePollStatus(jobId: jobId, update: update)
                        }
                    },
                    softTimeout: softPollTimeout,
                    shouldContinue: shouldContinue
                )
            } else {
                response = try await service.pollBatchJob(
                    jobName: jobName,
                    requestKey: "",
                    onPollUpdate: { @Sendable update in
                        Task { @MainActor [weak self] in
                            self?.updatePollStatus(jobId: jobId, update: update)
                        }
                    },
                    softTimeout: softPollTimeout,
                    shouldContinue: shouldContinue
                )
            }

            await handleSuccess(
                jobId: jobId,
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: [], hasSecurityScope: false),
                settings: settings,
                response: response,
                jobName: jobName
            )
        } catch NanoBananaError.jobCancelled {
            await handleCancelled(jobId: jobId, settings: settings, message: "Cancelled by user", jobName: jobName)
        } catch NanoBananaError.jobExpired {
            await handleExpired(jobId: jobId, settings: settings, message: "Remote batch expired before completion.", jobName: jobName)
        } catch NanoBananaError.softTimeout(let state) {
            await markJobAsStalled(jobId: jobId, state: state)
        } catch NanoBananaError.pollingStopped(let state) {
            markJobAsPaused(jobId: jobId, state: state)
        } catch {
            await handleError(
                jobId: jobId,
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: [], hasSecurityScope: false),
                settings: settings,
                error: error
            )
        }
    }

    private func updatePollStatus(jobId: UUID, update: PollStatusUpdate) {
        guard let job = task(for: jobId), !job.isTerminal else { return }
        job.status = "processing"
        job.phase = job.phase == .cancelRequested ? .cancelRequested : .polling
        job.pollCount = update.attempt
        job.lastPollState = update.state
        job.lastPollUpdatedAt = update.updatedAt
        job.stalledAt = nil
        if job.phase != .cancelRequested {
            job.error = nil
        }
    }

    private func markJobAsStalled(jobId: UUID, state: String) async {
        guard let batch = batch(containing: jobId), let job = task(for: jobId) else { return }
        if job.phase == .cancelRequested || job.cancelRequestedAt != nil || controlState == .cancelling {
            job.phase = .cancelRequested
            job.status = "processing"
            job.lastPollState = state
            job.lastPollUpdatedAt = Date()
            job.stalledAt = Date()
            job.error = "Cancel requested. Waiting for the final remote status."
            batch.status = "processing"
            controlState = .cancelling
            statusMessage = cancellationStatusMessage
            saveActiveBatches()
            updateProgress()
            return
        }

        job.phase = .stalled
        job.status = "processing"
        job.lastPollState = state
        job.lastPollUpdatedAt = Date()
        job.stalledAt = Date()
        job.error = "Polling paused locally after the configured timeout."
        batch.status = "pending"
        controlState = .interrupted
        statusMessage = "Polling paused locally. Use Resume to continue."
        saveActiveBatches()
        updateProgress()
    }

    private func markJobAsPaused(jobId: UUID, state: String) {
        guard let batch = batch(containing: jobId), let job = task(for: jobId), !job.isTerminal else { return }
        job.phase = .pausedLocal
        job.status = "processing"
        job.lastPollState = state
        job.lastPollUpdatedAt = Date()
        job.error = "Paused locally. Resume to reconcile remote status."
        job.stalledAt = nil
        batch.status = "pending"
        statusMessage = "Paused locally"
        saveActiveBatches()
        updateProgress()
    }

    private func handleSuccess(jobId: UUID, data: JobSubmissionData, settings: BatchSettings, response: ImageEditResponse, jobName: String?) async {
        guard let job = task(for: jobId) else { return }
        let owningBatch = batch(containing: jobId)

        do {
            let writeResult = try withAccessibleOutputDirectory(
                path: settings.outputDirectory,
                bookmark: settings.outputDirectoryBookmark
            ) { directoryURL in
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let outputURL = generateOutputURL(
                    for: job,
                    in: directoryURL,
                    mimeType: response.mimeType
                )
                try response.imageData.write(to: outputURL)
                return (outputURL: outputURL, directoryBookmark: AppPaths.bookmark(for: directoryURL))
            }
            let outputURL = writeResult.value.outputURL
            let outputDirectoryBookmark = writeResult.refreshedBookmark ?? writeResult.value.directoryBookmark
            if let outputDirectoryBookmark, let batchId = owningBatch?.id {
                updateOutputBookmark(outputDirectoryBookmark, for: batchId)
                onOutputDirectoryBookmarkRefreshed?(settings.projectId, settings.outputDirectory, outputDirectoryBookmark)
            }

            let completedDespiteCancel = job.cancelRequestedAt != nil
            job.status = "completed"
            job.phase = .completed
            job.outputPath = outputURL.path
            job.completedAt = Date()
            job.error = nil
            job.stalledAt = nil
            job.cancelRequestedAt = nil

            let cost = settings.cost(inputCount: job.inputPaths.count)
            if let projectId = settings.projectId {
                let sourceBookmarks = job.inputBookmarks ?? []
                let outputBookmark = AppPaths.bookmark(for: outputURL)
                let historyEntry = makeHistoryEntry(
                    projectId: projectId,
                    job: job,
                    settings: settings,
                    outputImagePath: outputURL.path,
                    cost: cost,
                    status: "completed",
                    error: nil,
                    externalJobName: jobName,
                    sourceImageBookmarks: sourceBookmarks.isEmpty ? nil : sourceBookmarks,
                    outputImageBookmark: outputBookmark,
                    outputDirectoryBookmark: outputDirectoryBookmark ?? settings.outputDirectoryBookmark,
                    tokenUsage: response.tokenUsage,
                    modelName: settings.modelName
                )
                persistHistoryEntry(historyEntry, externalJobName: jobName)
                onLedgerEntryCreated?(
                    UsageLedgerEntry(
                        kind: .jobCompletion,
                        projectId: projectId,
                        projectNameSnapshot: nil,
                        costDelta: cost,
                        imageDelta: 1,
                        tokenDelta: response.tokenUsage?.totalTokenCount ?? 0,
                        inputTokenDelta: response.tokenUsage?.promptTokenCount ?? 0,
                        outputTokenDelta: response.tokenUsage?.candidatesTokenCount ?? 0,
                        resolution: settings.imageSize,
                        modelName: settings.modelName,
                        relatedHistoryEntryId: historyEntry.id,
                        note: nil
                    )
                )
                onCostIncurred?(cost, settings.imageSize, projectId, response.tokenUsage, settings.modelName)
            }

            if completedDespiteCancel, !hasCancellationInProgress {
                statusMessage = "Some jobs completed before cancellation took effect."
            }

            saveActiveBatches()
            updateProgress()
        } catch {
            await handleError(jobId: jobId, data: data, settings: settings, error: error)
        }
    }

    private func handleCancelled(jobId: UUID, settings: BatchSettings, message: String, jobName: String?) async {
        guard let job = task(for: jobId) else { return }
        job.status = "cancelled"
        job.phase = .cancelled
        job.error = message
        job.completedAt = Date()
        job.stalledAt = nil
        job.cancelRequestedAt = nil

        if let projectId = settings.projectId {
            let historyEntry = makeHistoryEntry(
                projectId: projectId,
                job: job,
                settings: settings,
                outputImagePath: "",
                cost: 0,
                status: "cancelled",
                error: message,
                externalJobName: job.externalJobName ?? jobName,
                sourceImageBookmarks: job.inputBookmarks,
                outputImageBookmark: nil,
                outputDirectoryBookmark: settings.outputDirectoryBookmark,
                tokenUsage: nil,
                modelName: settings.modelName
            )
            persistHistoryEntry(historyEntry, externalJobName: job.externalJobName ?? jobName)
        }

        saveActiveBatches()
        updateProgress()
    }

    private func handleExpired(jobId: UUID, settings: BatchSettings, message: String, jobName: String?) async {
        guard let job = task(for: jobId) else { return }
        job.status = "expired"
        job.phase = .expired
        job.error = message
        job.completedAt = Date()
        job.stalledAt = nil
        job.cancelRequestedAt = nil

        if let projectId = settings.projectId {
            let historyEntry = makeHistoryEntry(
                projectId: projectId,
                job: job,
                settings: settings,
                outputImagePath: "",
                cost: 0,
                status: "expired",
                error: message,
                externalJobName: job.externalJobName ?? jobName,
                sourceImageBookmarks: job.inputBookmarks,
                outputImageBookmark: nil,
                outputDirectoryBookmark: settings.outputDirectoryBookmark,
                tokenUsage: nil,
                modelName: settings.modelName
            )
            persistHistoryEntry(historyEntry, externalJobName: job.externalJobName ?? jobName)
        }

        saveActiveBatches()
        updateProgress()
    }

    private func handleError(jobId: UUID, data: JobSubmissionData, settings: BatchSettings, error: Error) async {
        guard let job = task(for: jobId) else { return }

        job.status = "failed"
        job.phase = .failed
        job.error = error.localizedDescription
        job.completedAt = Date()
        job.stalledAt = nil
        job.cancelRequestedAt = nil

        if let projectId = settings.projectId {
            let historyEntry = makeHistoryEntry(
                projectId: projectId,
                job: job,
                settings: settings,
                outputImagePath: "",
                cost: 0,
                status: "failed",
                error: error.localizedDescription,
                externalJobName: job.externalJobName,
                sourceImageBookmarks: job.inputBookmarks,
                outputImageBookmark: nil,
                outputDirectoryBookmark: settings.outputDirectoryBookmark,
                tokenUsage: nil,
                modelName: settings.modelName
            )
            persistHistoryEntry(historyEntry, externalJobName: job.externalJobName)
        }

        saveActiveBatches()
        updateProgress()
    }

    private func makeHistoryEntry(
        projectId: UUID,
        job: ImageTask,
        settings: BatchSettings,
        outputImagePath: String,
        cost: Double,
        status: String,
        error: String?,
        externalJobName: String?,
        sourceImageBookmarks: [Data]?,
        outputImageBookmark: Data?,
        outputDirectoryBookmark: Data?,
        tokenUsage: TokenUsage?,
        modelName: String?
    ) -> HistoryEntry {
        HistoryEntry(
            projectId: projectId,
            sourceImagePaths: job.inputPaths,
            outputImagePath: outputImagePath,
            prompt: settings.prompt,
            aspectRatio: settings.aspectRatio,
            imageSize: settings.imageSize,
            usedBatchTier: settings.useBatchTier,
            cost: cost,
            status: status,
            error: error,
            externalJobName: externalJobName,
            sourceImageBookmarks: sourceImageBookmarks,
            outputImageBookmark: outputImageBookmark,
            outputDirectoryBookmark: outputDirectoryBookmark,
            tokenUsage: tokenUsage,
            modelName: modelName,
            systemPrompt: settings.systemPrompt
        )
    }

    private func persistHistoryEntry(_ entry: HistoryEntry, externalJobName: String?) {
        if let externalJobName {
            onHistoryEntryUpdated?(externalJobName, entry)
        } else {
            onImageCompleted?(entry)
        }
    }

    private func finalizeLocalCancellation(job: ImageTask, batch: BatchJob?) {
        job.status = "cancelled"
        job.phase = .cancelled
        job.error = "Cancelled by user"
        job.completedAt = Date()
        job.cancelRequestedAt = nil
        job.stalledAt = nil

        if let projectId = batch?.projectId {
            let entry = HistoryEntry(
                projectId: projectId,
                sourceImagePaths: job.inputPaths,
                outputImagePath: "",
                prompt: batch?.prompt ?? "",
                aspectRatio: batch?.aspectRatio ?? "16:9",
                imageSize: batch?.imageSize ?? "4K",
                usedBatchTier: batch?.useBatchTier ?? false,
                cost: 0,
                status: "cancelled",
                error: "Cancelled by user",
                externalJobName: job.externalJobName,
                sourceImageBookmarks: job.inputBookmarks,
                outputDirectoryBookmark: batch?.outputDirectoryBookmark,
                modelName: batch?.modelName,
                systemPrompt: batch?.systemPrompt
            )
            persistHistoryEntry(entry, externalJobName: job.externalJobName)
        }
    }

    private func shouldSubmit(task: ImageTask) -> Bool {
        !task.isTerminal &&
        task.externalJobName == nil &&
        task.phase != .submitting &&
        task.phase != .cancelRequested &&
        (task.status == "pending" || task.phase == .pausedLocal)
    }

    private func shouldPoll(task: ImageTask) -> Bool {
        guard task.externalJobName != nil, !task.isTerminal else { return false }
        guard controlState != .pausedLocal else { return false }
        switch task.phase {
        case .submitting, .pending, .completed, .cancelled, .expired, .failed:
            return false
        default:
            return true
        }
    }

    private var canStartNewLocalWork: Bool {
        controlState != .pausedLocal && controlState != .cancelling
    }

    private func shouldContinuePolling(jobId: UUID) -> Bool {
        guard let job = task(for: jobId) else { return false }
        guard !job.isTerminal else { return false }
        return controlState != .pausedLocal
    }

    private func applyPausedStateToActiveTasks() {
        for batch in activeBatches {
            applyPausedStateToBatch(batch)
        }
    }

    private func applyPausedStateToBatch(_ batch: BatchJob) {
        for job in batch.tasks where !job.isTerminal {
            if job.phase == .cancelRequested {
                continue
            }
            if job.status == "pending" || job.externalJobName == nil {
                job.phase = .pausedLocal
                job.error = "Paused locally. Resume to continue."
            } else {
                job.status = "processing"
                job.phase = .pausedLocal
                job.error = "Paused locally. Resume to reconcile remote status."
            }
        }
        batch.status = "pending"
    }

    private func normalizeBatchStatus(_ batch: BatchJob) {
        let tasks = batch.tasks
        guard !tasks.isEmpty else {
            batch.status = "pending"
            return
        }

        if tasks.allSatisfy(\.isTerminal) {
            if tasks.allSatisfy({ $0.status == "cancelled" }) {
                batch.status = "cancelled"
            } else if tasks.allSatisfy({ $0.status == "completed" }) {
                batch.status = "completed"
            } else {
                batch.status = "failed"
            }
            return
        }

        if tasks.contains(where: { $0.status == "processing" }) {
            batch.status = "processing"
        } else {
            batch.status = "pending"
        }
    }

    private func refreshControlStateAfterWork() async {
        recomputeControlStateAfterWork()
    }

    private func recomputeControlStateAfterWork() {
        if activeBatches.isEmpty {
            controlState = .idle
            statusMessage = "Ready"
            return
        }

        if activeBatches.allSatisfy({ $0.tasks.allSatisfy(\.isTerminal) }) {
            controlState = .idle
            if hasOnlyCancelledTerminalJobs {
                statusMessage = "Cancellation complete"
            } else if hasTrueFailures {
                statusMessage = "Queue finished with issues"
            } else {
                statusMessage = "Queue finished"
            }
            return
        }

        if hasCancellationInProgress {
            controlState = .cancelling
            statusMessage = cancellationStatusMessage
            return
        }

        if controlState == .pausedLocal {
            statusMessage = "Paused locally"
            return
        }

        if activeBatches.contains(where: { batch in
            batch.tasks.contains { task in
                task.hasRemoteJob && !task.isTerminal && (
                    task.phase == .stalled || 
                    task.phase == .reconnecting || 
                    task.phase == .submittedRemote || 
                    task.phase == .pausedLocal
                )
            }
        }) {
            controlState = .interrupted
            statusMessage = "Polling paused locally. Use Resume to continue."
            return
        }

        if activeBatches.contains(where: { $0.tasks.contains(where: { $0.status == "processing" }) }) {
            controlState = .running
            return
        }

        if activeBatches.contains(where: { $0.tasks.contains(where: { !$0.isTerminal }) }) {
            controlState = .interrupted
            statusMessage = "Queue has unfinished work. Use Resume to continue."
            return
        }

        controlState = .idle
        statusMessage = "Ready"
    }

    private func batch(containing taskID: UUID) -> BatchJob? {
        activeBatches.first(where: { $0.tasks.contains(where: { $0.id == taskID }) })
    }

    private func task(for id: UUID) -> ImageTask? {
        activeBatches.lazy.flatMap(\.tasks).first(where: { $0.id == id })
    }

    private func generateOutputURL(for task: ImageTask, in directoryURL: URL, mimeType: String) -> URL {
        let ext = mimeType == "image/png" ? "png" : "jpg"

        let baseName: String
        if task.inputPaths.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())
            let shortID = task.id.uuidString.prefix(8)
            baseName = "generated_\(timestamp)_\(shortID)"
        } else {
            let inputName = URL(fileURLWithPath: task.inputPaths.first ?? "image")
                .deletingPathExtension().lastPathComponent
            let variationSuffix: String
            if let variationIndex = task.variationIndex,
               let variationTotal = task.variationTotal,
               variationTotal > 1 {
                variationSuffix = "_v\(variationIndex)of\(variationTotal)"
            } else {
                variationSuffix = ""
            }
            baseName = "\(inputName)_edited\(variationSuffix)"
        }

        var candidate = directoryURL.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(baseName)_\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private func updateOutputBookmark(_ bookmark: Data, for batchId: UUID) {
        guard let batch = activeBatches.first(where: { $0.id == batchId }) else { return }
        batch.outputDirectoryBookmark = bookmark
        saveActiveBatches()
    }

    private func updateProgress() {
        let allTasks = activeBatches.flatMap(\.tasks)
        let total = allTasks.count
        let completed = allTasks.filter(\.isTerminal).count

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
        content.body = "Batch complete: \(successCount) output succeeded, \(failCount) finished with issues"
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
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(PersistedQueueState(controlState: controlState, batches: activeBatches))
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

            let persistedControlState: QueueControlState

            if let persistedState = try? decoder.decode(PersistedQueueState.self, from: data) {
                activeBatches = persistedState.batches
                persistedControlState = persistedState.controlState
            } else if let batches = try? decoder.decode([BatchJob].self, from: data) {
                activeBatches = batches
                persistedControlState = inferredControlState(from: batches)
            } else if let singleBatch = try? decoder.decode(BatchJob.self, from: data) {
                activeBatches = [singleBatch]
                persistedControlState = inferredControlState(from: [singleBatch])
            } else {
                return
            }

            let normalization = normalizeLoadedQueueState(persistedControlState: persistedControlState)
            controlState = normalization.controlState
            shouldAutoResumeRecoveredQueueOnLaunch = normalization.shouldAutoResume
            startupRecoveryHadAmbiguousSubmittingTasks = normalization.hadAmbiguousSubmittingTasks

            recomputeControlStateAfterWork()

            if startupRecoveryHadAmbiguousSubmittingTasks && !activeBatches.contains(where: { $0.tasks.contains(where: { !$0.isTerminal }) }) {
                statusMessage = "Saved queue has submission issues. Retry failed items manually."
            } else if hasCancellationInProgress {
                statusMessage = cancellationStatusMessage
            } else if controlState == .pausedLocal {
                statusMessage = "Paused locally"
            } else if shouldAutoResumeRecoveredQueueOnLaunch {
                statusMessage = "Recovered queue is ready to resume"
            }

            Task {
                if self.refreshInputBookmarksIfNeeded() {
                    self.saveActiveBatches()
                }
            }

            if normalization.didChangePersistedState {
                saveActiveBatches()
            }
            updateProgress()
        } catch {
            print("Failed to load active batches: \(error)")
        }
    }

    private func normalizeLoadedQueueState(persistedControlState: QueueControlState) -> StartupRecoveryNormalizationResult {
        var didChangePersistedState = false
        var hadAmbiguousSubmittingTasks = false

        for batch in activeBatches {
            for task in batch.tasks {
                if task.phase == .submitting && task.externalJobName == nil {
                    task.status = "failed"
                    task.phase = .failed
                    task.error = ambiguousSubmittingRecoveryMessage
                    task.cancelRequestedAt = nil
                    task.stalledAt = nil
                    hadAmbiguousSubmittingTasks = true
                    didChangePersistedState = true
                } else if task.phase == .submitting && task.externalJobName != nil {
                    task.phase = .submittedRemote
                    didChangePersistedState = true
                }
            }
            normalizeBatchStatus(batch)
        }

        let normalizedControlState: QueueControlState
        switch persistedControlState {
        case .pausedLocal, .idle:
            normalizedControlState = persistedControlState
        case .running, .resuming, .cancelling, .interrupted:
            normalizedControlState = .interrupted
            if persistedControlState != .interrupted {
                didChangePersistedState = true
            }
        }

        let hasNonTerminalTasks = activeBatches.contains { $0.tasks.contains(where: { !$0.isTerminal }) }
        let shouldAutoResume = normalizedControlState != .pausedLocal && hasNonTerminalTasks

        return StartupRecoveryNormalizationResult(
            controlState: hasNonTerminalTasks ? normalizedControlState : .idle,
            shouldAutoResume: shouldAutoResume,
            hadAmbiguousSubmittingTasks: hadAmbiguousSubmittingTasks,
            didChangePersistedState: didChangePersistedState
        )
    }

    private func inferredControlState(from batches: [BatchJob]) -> QueueControlState {
        if batches.isEmpty {
            return .idle
        }
        if batches.contains(where: { batch in
            batch.tasks.contains { task in
                task.phase == .pausedLocal || task.phase == .stalled || task.phase == .reconnecting
            }
        }) {
            return .interrupted
        }
        if batches.contains(where: { $0.tasks.contains(where: { $0.status == "processing" }) }) {
            return .interrupted
        }
        return .idle
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
            Task {
                await self.startAll()
            }
            return
        }

        let task = ImageTask(inputPaths: entry.sourceImagePaths, projectId: entry.projectId)
        task.inputBookmarks = entry.sourceImageBookmarks
        task.externalJobName = jobName
        task.status = "processing"
        task.phase = .pausedLocal
        task.submittedAt = entry.timestamp
        task.lastPollState = "JOB_STATE_PENDING"
        task.lastPollUpdatedAt = entry.timestamp
        task.error = "Resuming from history. Reconciling remote status."

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
            systemPrompt: entry.systemPrompt,
            aspectRatio: entry.aspectRatio,
            imageSize: entry.imageSize,
            outputDirectory: outputDir,
            outputDirectoryBookmark: entry.outputDirectoryBookmark,
            useBatchTier: entry.usedBatchTier,
            projectId: entry.projectId,
            modelName: entry.modelName
        )
        batch.tasks = [task]
        batch.status = "pending"

        enqueue(batch)
        statusMessage = "Resuming job from history..."

        Task {
            await self.startAll()
        }
    }

    private func withAccessibleOutputDirectory<T>(
        path: String,
        bookmark: Data?,
        operation: (URL) throws -> T
    ) throws -> (value: T, refreshedBookmark: Data?) {
        let fallbackPath = canFallbackToPath(for: path) ? path : ""
        var capturedError: Error?
        let result = AppPaths.withAccessibleURL(
            bookmark: bookmark,
            fallbackPath: fallbackPath,
            dependencies: bookmarkDependencies
        ) { directoryURL in
            do {
                return try operation(directoryURL)
            } catch {
                capturedError = error
                return nil
            }
        }

        switch result {
        case let .success(value, refreshedBookmark):
            return (value, refreshedBookmark)
        case let .fallbackUsed(value):
            return (value, nil)
        case .accessDenied:
            throw capturedError ?? CocoaError(.fileWriteNoPermission)
        }
    }

    private func canFallbackToPath(for outputDirectory: String) -> Bool {
        outputDirectory == AppPaths.defaultOutputDirectory.path
    }
}
