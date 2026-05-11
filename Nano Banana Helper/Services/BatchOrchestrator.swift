import Foundation
import Observation
import UserNotifications

// MARK: - Sendable Helpers
struct JobSubmissionData: Sendable {
    let id: UUID
    let inputURLs: [URL]       // Security-scoped URLs (already started access)
    let inputPaths: [String]
    let securityScopedInputURLs: [URL]

    func stopAccessingSecurityScopedResources() {
        securityScopedInputURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}

struct BatchSettings: Sendable {
    let provider: ModelProvider
    let prompt: String
    let systemPrompt: String?
    let aspectRatio: String
    let imageSize: String
    let outputDirectory: String
    let outputDirectoryBookmark: Data?
    let useBatchTier: Bool
    let projectId: UUID?
    let modelName: String?
    let maskImagePath: String?
    let maskImageBookmark: Data?
    let openAIOutputFormat: OpenAIOutputFormat
    let openAIBackground: OpenAIBackground
    let openAIInputFidelity: OpenAIInputFidelity
    let openAIOutputCompression: Int
    let openAINCount: Int

    func cost(inputCount: Int) -> Double {
        ImageSize.calculateCost(
            imageSize: imageSize,
            inputCount: inputCount,
            isBatchTier: useBatchTier,
            modelName: modelName
        )
    }
}

struct PersistedResponseOutput: Sendable {
    let outputURL: URL
    let outputBookmark: Data?
    let cost: Double
    let tokenUsage: TokenUsage?
}

struct PersistedResponseBatch: Sendable {
    let outputs: [PersistedResponseOutput]
    let outputDirectoryBookmark: Data?
    let totalCost: Double
    let totalTokenUsage: TokenUsage?
    let usedRecoveryDirectory: Bool
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
    private let recoveredOutputsDirectoryURL: URL
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
    private let cancellationFinalStatusTimedOutMessage = "Cancelled locally. Remote final status was not confirmed before polling timed out."

    init(
        service: NanoBananaService = NanoBananaService(),
        activeBatchURL: URL? = nil,
        recoveredOutputsDirectoryURL: URL? = nil,
        bookmarkDependencies: AppPaths.BookmarkResolutionDependencies? = nil,
        autoStartEnqueuedBatches: Bool = true,
        processQueueOverride: ProcessQueueOverride? = nil
    ) {
        self.service = service
        self.activeBatchURL = activeBatchURL ?? AppPaths.activeBatchURL
        self.recoveredOutputsDirectoryURL = recoveredOutputsDirectoryURL ?? AppPaths.recoveredOutputsDirectoryURL
        self.bookmarkDependencies = bookmarkDependencies ?? .live
        self.autoStartEnqueuedBatches = autoStartEnqueuedBatches
        self.processQueueOverride = processQueueOverride
        loadActiveBatches()
    }

    func enqueue(_ batch: BatchJob) {
        discardTerminalQueueItemsBeforeNewBatch()
        activeBatches.append(batch)

        for task in batch.tasks {
            task.projectId = batch.projectId
            task.provider = batch.provider
            task.maskImagePath = batch.maskImagePath
            task.maskImageBookmark = batch.maskImageBookmark
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

    private func discardTerminalQueueItemsBeforeNewBatch() {
        guard !activeBatches.isEmpty else { return }
        guard activeBatches.allSatisfy({ $0.tasks.allSatisfy(\.isTerminal) }) else { return }

        activeBatches.removeAll()
        controlState = .idle
        currentProgress = 0
        statusMessage = "Ready"
    }

    func enqueueTextGeneration(
        provider: ModelProvider,
        modelName: String,
        prompt: String,
        systemPrompt: String? = nil,
        aspectRatio: String,
        imageSize: String,
        outputDirectory: String,
        outputDirectoryBookmark: Data? = nil,
        useBatchTier: Bool,
        imageCount: Int,
        projectId: UUID?,
        openAIOutputFormat: OpenAIOutputFormat = .png,
        openAIBackground: OpenAIBackground = .auto,
        openAIInputFidelity: OpenAIInputFidelity = .high,
        openAIOutputCompression: Int = 100,
        openAINCount: Int = 1
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
            modelName: modelName,
            provider: provider,
            openAIOutputFormat: openAIOutputFormat,
            openAIBackground: openAIBackground,
            openAIInputFidelity: openAIInputFidelity,
            openAIOutputCompression: openAIOutputCompression,
            openAINCount: openAINCount
        )
        batch.isTextMode = true
        batch.tasks = (0..<imageCount).map { _ in
            ImageTask(inputPaths: [], projectId: projectId, provider: provider)
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

        if activeBatches.contains(where: { $0.tasks.contains(where: { $0.status == "processing" && ($0.hasRemoteJob || $0.phase == .submitting) }) }) {
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
        if batch.provider == .openAI && batch.useBatchTier {
            cancelOpenAIBatch(batch: batch)
            return
        }

        batch.status = "processing"

        for job in batch.tasks where !job.isTerminal {
            if job.status == "pending", !job.hasRemoteJob, job.phase != .submitting {
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

    private func cancelOpenAIBatch(batch: BatchJob) {
        batch.status = "processing"
        var remoteBatchIDs = Set<String>()

        for job in batch.tasks where !job.isTerminal {
            if job.status == "pending", !job.hasRemoteJob, job.phase != .submitting {
                finalizeLocalCancellation(job: job, batch: batch)
                continue
            }

            job.status = "processing"
            job.phase = .cancelRequested
            job.cancelRequestedAt = job.cancelRequestedAt ?? Date()
            job.error = "Cancel requested. Waiting for final status."
            job.stalledAt = nil

            if let remoteBatchId = job.remoteBatchId {
                remoteBatchIDs.insert(remoteBatchId)
            }
        }

        for remoteBatchID in remoteBatchIDs {
            Task {
                try? await self.service.cancelOpenAIBatch(batchID: remoteBatchID)
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

    func resumeIssueTask(_ task: ImageTask) {
        resumeIssueTask(id: task.id)
    }

    func resumeIssueTask(id taskId: UUID) {
        guard let batch = batch(containing: taskId), let job = task(for: taskId) else {
            LogManager.shared.log(.error, payload: "Queue resume ignored: task \(taskId.uuidString) is no longer in the active queue.")
            return
        }

        guard let remoteJobID = job.remoteJobIdForDisplay else {
            LogManager.shared.log(.error, payload: "Queue resume ignored: task \(taskId.uuidString) has no remote batch job id.")
            return
        }

        rearmRemoteJobForPolling(job, in: batch, jobIdentifier: remoteJobID, source: "queue issue")
        Task {
            await self.startAll()
        }
    }

    private func processQueue(batch: BatchJob) async {
        let batchSettings = BatchSettings(
            provider: batch.provider,
            prompt: batch.prompt,
            systemPrompt: batch.systemPrompt,
            aspectRatio: batch.aspectRatio,
            imageSize: batch.imageSize,
            outputDirectory: batch.outputDirectory,
            outputDirectoryBookmark: batch.outputDirectoryBookmark,
            useBatchTier: batch.useBatchTier,
            projectId: batch.projectId,
            modelName: batch.modelName,
            maskImagePath: batch.maskImagePath,
            maskImageBookmark: batch.maskImageBookmark,
            openAIOutputFormat: batch.openAIOutputFormat,
            openAIBackground: batch.openAIBackground,
            openAIInputFidelity: batch.openAIInputFidelity,
            openAIOutputCompression: batch.openAIOutputCompression,
            openAINCount: batch.openAINCount
        )

        if batch.provider == .openAI && batch.useBatchTier {
            await processOpenAIBatchQueue(batch: batch, settings: batchSettings)
            return
        }

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

    private func processOpenAIBatchQueue(batch: BatchJob, settings: BatchSettings) async {
        if controlState != .cancelling {
            let submissionDataList = buildSubmissionDataList(for: batch)
            if !submissionDataList.isEmpty {
                statusMessage = "Submitting \(submissionDataList.count) OpenAI batch requests..."
                await submitOpenAIBatch(submissionDataList, in: batch, settings: settings)
            }
        }

        if controlState == .pausedLocal {
            applyPausedStateToBatch(batch)
            return
        }

        let remoteBatchIDs = Set(
            batch.tasks.compactMap { task -> String? in
                guard shouldPollOpenAIBatch(task: task) else { return nil }
                return task.remoteBatchId
            }
        )

        if !remoteBatchIDs.isEmpty {
            statusMessage = controlState == .cancelling ? "Reconciling OpenAI batch cancellation..." : "Polling OpenAI batch..."
            for remoteBatchID in remoteBatchIDs {
                await performOpenAIBatchPoll(remoteBatchID: remoteBatchID, batch: batch, settings: settings)
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

    private func submitOpenAIBatch(_ submissionDataList: [JobSubmissionData], in batch: BatchJob, settings: BatchSettings) async {
        let resolvedMaskBookmark = settings.maskImageBookmark.flatMap {
            AppPaths.resolveBookmark($0, dependencies: bookmarkDependencies)
        }
        if let refreshedMaskBookmark = resolvedMaskBookmark?.refreshedBookmarkData {
            batch.maskImageBookmark = refreshedMaskBookmark
            for data in submissionDataList {
                task(for: data.id)?.maskImageBookmark = refreshedMaskBookmark
            }
            saveActiveBatches()
        }
        let maskImageURL = resolvedMaskBookmark?.url ?? settings.maskImagePath.map { URL(fileURLWithPath: $0) }
        let resolvedModelName = settings.modelName ?? AppPricing.defaultModelName(for: settings.provider)
        defer {
            resolvedMaskBookmark?.url.stopAccessingSecurityScopedResource()
            submissionDataList.forEach { $0.stopAccessingSecurityScopedResources() }
        }

        do {
            let requestItems = try submissionDataList.map { data -> OpenAIBatchSubmissionItem in
                guard let job = task(for: data.id) else {
                    throw NanoBananaError.batchError(message: "OpenAI batch task disappeared before submission.")
                }

                job.status = "processing"
                job.phase = .submitting
                job.startedAt = job.startedAt ?? Date()
                job.error = nil

                let request = makeImageEditRequest(
                    data: data,
                    settings: settings,
                    maskImageURL: maskImageURL,
                    resolvedModelName: resolvedModelName
                )

                return OpenAIBatchSubmissionItem(
                    taskID: data.id,
                    customID: "task-\(data.id.uuidString)",
                    request: request
                )
            }

            saveActiveBatches()
            updateProgress()

            let batchInfo = try await service.startOpenAIBatch(requests: requestItems)
            for mapping in batchInfo.requests {
                guard let job = task(for: mapping.taskID) else { continue }
                job.remoteBatchId = batchInfo.batchID
                job.remoteRequestId = mapping.customID
                job.remoteBatchProvider = .openAI
                job.submittedAt = Date()
                job.lastPollState = "validating"
                job.lastPollUpdatedAt = Date()
                job.stalledAt = nil
                job.status = "processing"
                job.cancelRequestedAt = job.cancelRequestedAt ?? (job.phase == .cancelRequested ? Date() : nil)

                if job.phase == .cancelRequested || controlState == .cancelling {
                    job.phase = .cancelRequested
                    job.error = "Cancel requested. Waiting for final status."
                    job.cancelRequestedAt = job.cancelRequestedAt ?? Date()
                } else if controlState == .pausedLocal {
                    job.phase = .pausedLocal
                    job.error = "Paused locally. Resume to reconcile remote status."
                } else {
                    job.phase = .submittedRemote
                    job.error = nil
                }
            }

            if controlState == .cancelling {
                try? await service.cancelOpenAIBatch(batchID: batchInfo.batchID)
            }

            saveActiveBatches()
            updateProgress()
        } catch {
            for data in submissionDataList {
                await handleError(jobId: data.id, data: data, settings: settings, error: error)
            }
        }
    }

    private func makeImageEditRequest(
        data: JobSubmissionData,
        settings: BatchSettings,
        maskImageURL: URL?,
        resolvedModelName: String
    ) -> ImageEditRequest {
        if data.inputURLs.isEmpty {
            return ImageEditRequest.textOnly(
                provider: settings.provider,
                modelName: resolvedModelName,
                prompt: settings.prompt,
                systemInstruction: settings.systemPrompt,
                aspectRatio: settings.aspectRatio,
                imageSize: settings.imageSize,
                useBatchTier: settings.useBatchTier,
                openAIOutputFormat: settings.openAIOutputFormat,
                openAIBackground: settings.openAIBackground,
                openAIInputFidelity: settings.openAIInputFidelity,
                openAIOutputCompression: settings.openAIOutputCompression,
                openAINCount: settings.openAINCount
            )
        }

        return ImageEditRequest(
            provider: settings.provider,
            modelName: resolvedModelName,
            inputImageURLs: data.inputURLs,
            maskImageURL: maskImageURL,
            prompt: settings.prompt,
            systemInstruction: settings.systemPrompt,
            aspectRatio: settings.aspectRatio,
            imageSize: settings.imageSize,
            useBatchTier: settings.useBatchTier,
            openAIOutputFormat: settings.openAIOutputFormat,
            openAIBackground: settings.openAIBackground,
            openAIInputFidelity: settings.openAIInputFidelity,
            openAIOutputCompression: settings.openAIOutputCompression,
            openAINCount: settings.openAINCount
        )
    }

    private func performOpenAIBatchPoll(remoteBatchID: String, batch: BatchJob, settings: BatchSettings) async {
        let tasksForRemoteBatch = batch.tasks.filter {
            $0.remoteBatchId == remoteBatchID && !$0.isTerminal
        }
        let expectedCustomIDs = tasksForRemoteBatch.compactMap(\.remoteRequestId)
        guard !expectedCustomIDs.isEmpty else { return }

        do {
            let shouldContinue: @Sendable () async -> Bool = { [orchestrator = self] in
                await MainActor.run {
                    orchestrator.shouldContinueOpenAIBatchPolling(remoteBatchID: remoteBatchID)
                }
            }

            let result = try await service.pollOpenAIBatch(
                batchID: remoteBatchID,
                expectedCustomIDs: expectedCustomIDs,
                onPollUpdate: { @Sendable update in
                    Task { @MainActor [weak self] in
                        self?.updateOpenAIBatchPollStatus(remoteBatchID: remoteBatchID, update: update)
                    }
                },
                softTimeout: softPollTimeout,
                shouldContinue: shouldContinue
            )

            await applyOpenAIBatchResult(result, batch: batch, settings: settings)
        } catch NanoBananaError.softTimeout(let state) {
            for task in tasksForRemoteBatch {
                await markJobAsStalled(jobId: task.id, state: state)
            }
        } catch NanoBananaError.pollingStopped(let state) {
            for task in tasksForRemoteBatch {
                markJobAsPaused(jobId: task.id, state: state)
            }
        } catch {
            for task in tasksForRemoteBatch {
                await handleError(
                    jobId: task.id,
                    data: JobSubmissionData(id: task.id, inputURLs: [], inputPaths: [], securityScopedInputURLs: []),
                    settings: settings,
                    error: error
                )
            }
        }
    }

    func applyOpenAIBatchResult(_ result: OpenAIBatchResult, batch: BatchJob, settings: BatchSettings) async {
        for success in result.successes {
            guard let job = batch.tasks.first(where: { $0.remoteRequestId == success.customID }),
                  !job.isTerminal else { continue }
            await handleSuccess(
                jobId: job.id,
                data: JobSubmissionData(id: job.id, inputURLs: [], inputPaths: [], securityScopedInputURLs: []),
                settings: settings,
                responses: success.responses,
                jobName: nil
            )
        }

        for failure in result.failures {
            guard let job = batch.tasks.first(where: { $0.remoteRequestId == failure.customID }),
                  !job.isTerminal else { continue }

            switch result.terminalStatus {
            case "cancelled":
                await handleCancelled(jobId: job.id, settings: settings, message: failure.message, jobName: nil)
            case "expired":
                await handleExpired(jobId: job.id, settings: settings, message: failure.message, jobName: nil)
            default:
                await handleError(
                    jobId: job.id,
                    data: JobSubmissionData(id: job.id, inputURLs: [], inputPaths: [], securityScopedInputURLs: []),
                    settings: settings,
                    error: NanoBananaError.batchError(message: failure.message)
                )
            }
        }
    }

    private func updateOpenAIBatchPollStatus(remoteBatchID: String, update: OpenAIBatchStatusUpdate) {
        for job in allJobs where job.remoteBatchId == remoteBatchID && !job.isTerminal {
            job.status = "processing"
            job.phase = job.phase == .cancelRequested ? .cancelRequested : .polling
            job.pollCount += 1
            job.lastPollState = update.status
            job.lastPollUpdatedAt = update.updatedAt
            job.stalledAt = nil
            if job.phase != .cancelRequested {
                job.error = nil
            }
        }
    }

    func buildSubmissionDataList(for batch: BatchJob) -> [JobSubmissionData] {
        var didRefreshInputBookmarks = false

        let submissionDataList: [JobSubmissionData] = batch.tasks.compactMap { job in
            guard shouldSubmit(task: job) else { return nil }

            var inputURLs: [URL] = []
            var securityScopedInputURLs: [URL] = []

            if let bookmarks = job.inputBookmarks, !bookmarks.isEmpty {
                var updatedBookmarks = bookmarks

                for (index, path) in job.inputPaths.enumerated() {
                    if bookmarks.indices.contains(index),
                       let resolution = AppPaths.resolveBookmark(
                        bookmarks[index],
                        dependencies: bookmarkDependencies
                       ) {
                        inputURLs.append(resolution.url)
                        securityScopedInputURLs.append(resolution.url)
                        if let refreshedBookmark = resolution.refreshedBookmarkData {
                            updatedBookmarks[index] = refreshedBookmark
                        }
                    } else {
                        inputURLs.append(URL(fileURLWithPath: path))
                    }
                }

                if updatedBookmarks != bookmarks {
                    job.inputBookmarks = updatedBookmarks
                    didRefreshInputBookmarks = true
                }
            } else {
                inputURLs = job.inputPaths.map { URL(fileURLWithPath: $0) }
            }

            return JobSubmissionData(
                id: job.id,
                inputURLs: inputURLs,
                inputPaths: job.inputPaths,
                securityScopedInputURLs: securityScopedInputURLs
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

        let resolvedMaskBookmark = settings.maskImageBookmark.flatMap {
            AppPaths.resolveBookmark($0, dependencies: bookmarkDependencies)
        }
        if let refreshedMaskBookmark = resolvedMaskBookmark?.refreshedBookmarkData, let owningBatch = batch(containing: data.id) {
            owningBatch.maskImageBookmark = refreshedMaskBookmark
            job.maskImageBookmark = refreshedMaskBookmark
            saveActiveBatches()
        }
        let maskImageURL = resolvedMaskBookmark?.url ?? settings.maskImagePath.map { URL(fileURLWithPath: $0) }
        let resolvedModelName = settings.modelName ?? AppPricing.defaultModelName(for: settings.provider)
        defer {
            resolvedMaskBookmark?.url.stopAccessingSecurityScopedResource()
        }
        let request: ImageEditRequest
        if data.inputURLs.isEmpty {
            request = ImageEditRequest.textOnly(
                provider: settings.provider,
                modelName: resolvedModelName,
                prompt: settings.prompt,
                systemInstruction: settings.systemPrompt,
                aspectRatio: settings.aspectRatio,
                imageSize: settings.imageSize,
                useBatchTier: settings.useBatchTier,
                openAIOutputFormat: settings.openAIOutputFormat,
                openAIBackground: settings.openAIBackground,
                openAIInputFidelity: settings.openAIInputFidelity,
                openAIOutputCompression: settings.openAIOutputCompression,
                openAINCount: settings.openAINCount
            )
        } else {
            request = ImageEditRequest(
                provider: settings.provider,
                modelName: resolvedModelName,
                inputImageURLs: data.inputURLs,
                maskImageURL: maskImageURL,
                prompt: settings.prompt,
                systemInstruction: settings.systemPrompt,
                aspectRatio: settings.aspectRatio,
                imageSize: settings.imageSize,
                useBatchTier: settings.useBatchTier,
                openAIOutputFormat: settings.openAIOutputFormat,
                openAIBackground: settings.openAIBackground,
                openAIInputFidelity: settings.openAIInputFidelity,
                openAIOutputCompression: settings.openAIOutputCompression,
                openAINCount: settings.openAINCount
            )
        }

        do {
            if settings.useBatchTier {
                let jobInfo = try await service.startBatchJob(request: request)
                data.stopAccessingSecurityScopedResources()

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
                        modelName: resolvedModelName,
                        provider: settings.provider,
                        systemPrompt: settings.systemPrompt,
                        maskImagePath: submittedJob.maskImagePath,
                        maskImageBookmark: submittedJob.maskImageBookmark,
                        openAIOutputFormat: settings.openAIOutputFormat,
                        openAIBackground: settings.openAIBackground,
                        openAIInputFidelity: settings.openAIInputFidelity,
                        openAIOutputCompression: settings.openAIOutputCompression,
                        openAINCount: settings.openAINCount
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
                let responses = try await service.editImages(request)
                data.stopAccessingSecurityScopedResources()
                await handleSuccess(
                    jobId: data.id,
                    data: data,
                    settings: settings,
                    responses: responses,
                    jobName: nil
                )
            }
        } catch {
            data.stopAccessingSecurityScopedResources()
            await handleError(jobId: data.id, data: data, settings: settings, error: error)
        }
    }

    private func performPoll(jobId: UUID, jobName: String, settings: BatchSettings, recovering: Bool) async {
        do {
            let response: ImageEditResponse
            let shouldContinue: @Sendable () async -> Bool = { [orchestrator = self] in
                await MainActor.run {
                    orchestrator.shouldContinuePolling(jobId: jobId)
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
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: [], securityScopedInputURLs: []),
                settings: settings,
                responses: [response],
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
                data: JobSubmissionData(id: jobId, inputURLs: [], inputPaths: [], securityScopedInputURLs: []),
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
            job.lastPollState = state
            job.lastPollUpdatedAt = Date()
            finalizeLocalCancellation(
                job: job,
                batch: batch,
                message: cancellationFinalStatusTimedOutMessage
            )
            normalizeBatchStatus(batch)
            recomputeControlStateAfterWork()
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

    private func handleSuccess(jobId: UUID, data: JobSubmissionData, settings: BatchSettings, responses: [ImageEditResponse], jobName: String?) async {
        guard let job = task(for: jobId) else { return }
        let owningBatch = batch(containing: jobId)
        let resolvedModelName = settings.modelName ?? AppPricing.defaultModelName(for: settings.provider)

        do {
            let persisted = try persistResponses(
                responses,
                for: job,
                settings: settings,
                resolvedModelName: resolvedModelName,
                owningBatchId: owningBatch?.id
            )

            let completedDespiteCancel = job.cancelRequestedAt != nil
            let recoveryWarning = persisted.usedRecoveryDirectory
                ? "Output folder could not be accessed. Saved to the recovery folder instead."
                : nil
            job.status = "completed"
            job.phase = .completed
            job.outputPath = persisted.outputs.first?.outputURL.path
            job.completedAt = Date()
            job.error = recoveryWarning
            job.stalledAt = nil
            job.cancelRequestedAt = nil
            if let owningBatch {
                normalizeBatchStatus(owningBatch)
            }

            if let projectId = settings.projectId {
                let sourceBookmarks = job.inputBookmarks ?? []
                let outputDirectoryBookmark = persisted.usedRecoveryDirectory
                    ? nil
                    : (persisted.outputDirectoryBookmark ?? settings.outputDirectoryBookmark)
                for output in persisted.outputs {
                    let historyEntry = makeHistoryEntry(
                        projectId: projectId,
                        job: job,
                        settings: settings,
                        outputImagePath: output.outputURL.path,
                        cost: output.cost,
                        status: "completed",
                        error: recoveryWarning,
                        externalJobName: jobName,
                        sourceImageBookmarks: sourceBookmarks.isEmpty ? nil : sourceBookmarks,
                        outputImageBookmark: output.outputBookmark,
                        outputDirectoryBookmark: outputDirectoryBookmark,
                        tokenUsage: output.tokenUsage,
                        modelName: resolvedModelName
                    )
                    persistHistoryEntry(historyEntry, externalJobName: jobName)
                    onLedgerEntryCreated?(
                        UsageLedgerEntry(
                            kind: .jobCompletion,
                            projectId: projectId,
                            projectNameSnapshot: nil,
                            costDelta: output.cost,
                            imageDelta: 1,
                            tokenDelta: output.tokenUsage?.totalTokenCount ?? 0,
                            inputTokenDelta: output.tokenUsage?.promptTokenCount ?? 0,
                            outputTokenDelta: output.tokenUsage?.candidatesTokenCount ?? 0,
                            resolution: settings.imageSize,
                            modelName: resolvedModelName,
                            relatedHistoryEntryId: historyEntry.id,
                            note: recoveryWarning
                        )
                    )
                }
                onCostIncurred?(persisted.totalCost, settings.imageSize, projectId, persisted.totalTokenUsage, resolvedModelName)
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
        if let batch = batch(containing: jobId) {
            normalizeBatchStatus(batch)
        }

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

    func persistResponses(
        _ responses: [ImageEditResponse],
        for job: ImageTask,
        settings: BatchSettings,
        resolvedModelName: String,
        owningBatchId: UUID?
    ) throws -> PersistedResponseBatch {
        guard !responses.isEmpty else {
            throw NanoBananaError.noImageInResponse
        }

        let totalTokenUsage = responses.compactMap(\.tokenUsage).first
        let totalCost = AppPricing.usageCost(
            modelName: resolvedModelName,
            provider: settings.provider,
            tokenUsage: totalTokenUsage,
            isBatchTier: settings.useBatchTier
        ) ?? settings.cost(inputCount: job.inputPaths.count)
        let costShares = splitTotalCost(totalCost, across: responses.count)

        let writeResult: (value: (outputURLs: [URL], directoryBookmark: Data?), refreshedBookmark: Data?)
        let usedRecoveryDirectory: Bool

        do {
            writeResult = try withAccessibleOutputDirectory(
                path: settings.outputDirectory,
                bookmark: settings.outputDirectoryBookmark
            ) { directoryURL in
                try writeResponses(
                    responses,
                    for: job,
                    in: directoryURL
                )
            }
            usedRecoveryDirectory = false
        } catch {
            LogManager.shared.log(
                .error,
                payload: "Primary output write failed for task \(job.id.uuidString): \(error.localizedDescription). Saving returned image data to recovery folder."
            )
            let recovered = try writeResponses(
                responses,
                for: job,
                in: recoveredOutputsDirectoryURL
            )
            writeResult = (value: recovered, refreshedBookmark: nil)
            usedRecoveryDirectory = true
            LogManager.shared.log(
                .response,
                payload: "Recovered \(responses.count) output image(s) for task \(job.id.uuidString) in \(recoveredOutputsDirectoryURL.path)."
            )
        }

        let outputDirectoryBookmark = usedRecoveryDirectory
            ? nil
            : (writeResult.refreshedBookmark ?? writeResult.value.directoryBookmark)
        if !usedRecoveryDirectory, let outputDirectoryBookmark, let batchId = owningBatchId {
            updateOutputBookmark(outputDirectoryBookmark, for: batchId)
            onOutputDirectoryBookmarkRefreshed?(settings.projectId, settings.outputDirectory, outputDirectoryBookmark)
        }

        let outputs = writeResult.value.outputURLs.enumerated().map { index, outputURL in
            PersistedResponseOutput(
                outputURL: outputURL,
                outputBookmark: AppPaths.bookmark(for: outputURL),
                cost: costShares[index],
                tokenUsage: index == 0 ? totalTokenUsage : nil
            )
        }

        return PersistedResponseBatch(
            outputs: outputs,
            outputDirectoryBookmark: outputDirectoryBookmark,
            totalCost: totalCost,
            totalTokenUsage: totalTokenUsage,
            usedRecoveryDirectory: usedRecoveryDirectory
        )
    }

    private func writeResponses(
        _ responses: [ImageEditResponse],
        for job: ImageTask,
        in directoryURL: URL
    ) throws -> (outputURLs: [URL], directoryBookmark: Data?) {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let outputURLs = try responses.enumerated().map { index, response in
            let outputURL = generateOutputURL(
                for: job,
                in: directoryURL,
                mimeType: response.mimeType,
                outputIndex: responses.count > 1 ? index + 1 : nil,
                outputCount: responses.count
            )
            try response.imageData.write(to: outputURL)
            return outputURL
        }

        return (outputURLs: outputURLs, directoryBookmark: AppPaths.bookmark(for: directoryURL))
    }

    private func splitTotalCost(_ totalCost: Double, across outputCount: Int) -> [Double] {
        guard outputCount > 0 else { return [] }
        guard outputCount > 1 else { return [totalCost] }

        let share = totalCost / Double(outputCount)
        var shares = Array(repeating: share, count: outputCount)
        shares[outputCount - 1] = totalCost - shares.dropLast().reduce(0, +)
        return shares
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
            provider: settings.provider,
            systemPrompt: settings.systemPrompt,
            maskImagePath: job.maskImagePath,
            maskImageBookmark: job.maskImageBookmark,
            openAIOutputFormat: settings.openAIOutputFormat,
            openAIBackground: settings.openAIBackground,
            openAIInputFidelity: settings.openAIInputFidelity,
            openAIOutputCompression: settings.openAIOutputCompression,
            openAINCount: settings.openAINCount,
            remoteBatchId: job.remoteBatchId,
            remoteRequestId: job.remoteRequestId,
            remoteBatchProvider: job.remoteBatchProvider
        )
    }

    private func persistHistoryEntry(_ entry: HistoryEntry, externalJobName: String?) {
        if let externalJobName {
            onHistoryEntryUpdated?(externalJobName, entry)
        } else {
            onImageCompleted?(entry)
        }
    }

    private func finalizeLocalCancellation(
        job: ImageTask,
        batch: BatchJob?,
        message: String = "Cancelled by user"
    ) {
        job.status = "cancelled"
        job.phase = .cancelled
        job.error = message
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
                error: message,
                externalJobName: job.externalJobName,
                sourceImageBookmarks: job.inputBookmarks,
                outputDirectoryBookmark: batch?.outputDirectoryBookmark,
                modelName: batch?.modelName,
                provider: batch?.provider ?? job.provider,
                systemPrompt: batch?.systemPrompt,
                maskImagePath: job.maskImagePath,
                maskImageBookmark: job.maskImageBookmark,
                openAIOutputFormat: batch?.openAIOutputFormat ?? .png,
                openAIBackground: batch?.openAIBackground ?? .auto,
                openAIInputFidelity: batch?.openAIInputFidelity ?? .high,
                openAIOutputCompression: batch?.openAIOutputCompression ?? 100,
                openAINCount: batch?.openAINCount ?? 1,
                remoteBatchId: job.remoteBatchId,
                remoteRequestId: job.remoteRequestId,
                remoteBatchProvider: job.remoteBatchProvider
            )
            persistHistoryEntry(entry, externalJobName: job.externalJobName)
        }
    }

    private func shouldSubmit(task: ImageTask) -> Bool {
        !task.isTerminal &&
        !task.hasRemoteJob &&
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

    private func shouldPollOpenAIBatch(task: ImageTask) -> Bool {
        guard task.remoteBatchId != nil, !task.isTerminal else { return false }
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

    private func shouldContinueOpenAIBatchPolling(remoteBatchID: String) -> Bool {
        guard controlState != .pausedLocal else { return false }
        return allJobs.contains {
            $0.remoteBatchId == remoteBatchID &&
            !$0.isTerminal &&
            ($0.phase == .polling ||
             $0.phase == .submittedRemote ||
             $0.phase == .reconnecting ||
             $0.phase == .stalled ||
             $0.phase == .pausedLocal ||
             $0.phase == .cancelRequested)
        }
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
            if job.status == "pending" || !job.hasRemoteJob {
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

    private func generateOutputURL(
        for task: ImageTask,
        in directoryURL: URL,
        mimeType: String,
        outputIndex: Int? = nil,
        outputCount: Int = 1
    ) -> URL {
        let ext: String
        switch mimeType {
        case "image/png":
            ext = "png"
        case "image/webp":
            ext = "webp"
        default:
            ext = "jpg"
        }

        var baseName: String
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

        if let outputIndex, outputCount > 1 {
            baseName += "_img\(outputIndex)of\(outputCount)"
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

    private func hasTimedOutCancellationRequest(_ task: ImageTask, now: Date) -> Bool {
        guard !task.isTerminal,
              task.phase == .cancelRequested,
              let cancelRequestedAt = task.cancelRequestedAt else {
            return false
        }

        return now.timeIntervalSince(cancelRequestedAt) >= softPollTimeout
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
        let now = Date()

        for batch in activeBatches {
            for task in batch.tasks {
                if hasTimedOutCancellationRequest(task, now: now) {
                    finalizeLocalCancellation(
                        job: task,
                        batch: batch,
                        message: cancellationFinalStatusTimedOutMessage
                    )
                    didChangePersistedState = true
                } else if task.phase == .submitting && !task.hasRemoteJob {
                    task.status = "failed"
                    task.phase = .failed
                    task.error = ambiguousSubmittingRecoveryMessage
                    task.cancelRequestedAt = nil
                    task.stalledAt = nil
                    hadAmbiguousSubmittingTasks = true
                    didChangePersistedState = true
                } else if task.phase == .submitting && task.hasRemoteJob {
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
            if let maskBookmark = batch.maskImageBookmark,
               let resolution = AppPaths.resolveBookmarkToPath(maskBookmark, dependencies: bookmarkDependencies),
               let refreshedBookmark = resolution.refreshedBookmarkData {
                batch.maskImageBookmark = refreshedBookmark
                for task in batch.tasks {
                    task.maskImageBookmark = refreshedBookmark
                }
                didRefresh = true
            }

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
        if entry.canResumeOpenAIBatchPolling {
            resumeOpenAIPollingFromHistory(for: entry)
            return
        }
        if entry.provider == .openAI || entry.remoteBatchProvider == .openAI {
            LogManager.shared.log(.error, payload: "Resume polling ignored: OpenAI history entry is missing a remote batch id or request id.")
            return
        }
        resumeGeminiPollingFromHistory(for: entry)
    }

    private func resumeGeminiPollingFromHistory(for entry: HistoryEntry) {
        guard let jobName = entry.externalJobName else { return }

        if let existingBatch = activeBatches.first(where: { $0.tasks.contains(where: { $0.externalJobName == jobName }) }),
           let existingTask = existingBatch.tasks.first(where: { $0.externalJobName == jobName }) {
            if existingTask.isIssue {
                rearmRemoteJobForPolling(existingTask, in: existingBatch, jobIdentifier: jobName, source: "history")
            } else {
                LogManager.shared.log(.request, payload: "Resume polling requested for existing active job \(jobName).")
            }
            Task {
                await self.startAll()
            }
            return
        }

        let task = ImageTask(
            inputPaths: entry.sourceImagePaths,
            projectId: entry.projectId,
            provider: entry.provider,
            inputBookmarks: entry.sourceImageBookmarks,
            maskImagePath: entry.maskImagePath,
            maskImageBookmark: entry.maskImageBookmark
        )
        task.externalJobName = jobName
        task.status = "processing"
        task.phase = .pausedLocal
        task.submittedAt = entry.timestamp
        task.lastPollState = "JOB_STATE_PENDING"
        task.lastPollUpdatedAt = entry.timestamp
        task.error = "Resuming from history. Reconciling remote status."

        let batch = makeHistoryResumeBatch(for: entry, outputDirectory: outputDirectoryForHistoryResume(entry))
        batch.tasks = [task]
        batch.status = "pending"

        enqueue(batch)
        statusMessage = "Resuming job from history..."
        LogManager.shared.log(.request, payload: "Resume polling enqueued recovered history job \(jobName).")

        Task {
            await self.startAll()
        }
    }

    private func resumeOpenAIPollingFromHistory(for entry: HistoryEntry) {
        guard let remoteBatchId = entry.remoteBatchId,
              let remoteRequestId = entry.remoteRequestId else { return }

        if let existingBatch = activeBatches.first(where: {
            $0.tasks.contains {
                $0.remoteBatchId == remoteBatchId &&
                $0.remoteRequestId == remoteRequestId
            }
        }),
           let existingTask = existingBatch.tasks.first(where: {
               $0.remoteBatchId == remoteBatchId &&
               $0.remoteRequestId == remoteRequestId
           }) {
            if existingTask.isIssue {
                rearmRemoteJobForPolling(existingTask, in: existingBatch, jobIdentifier: remoteBatchId, source: "history")
            } else {
                LogManager.shared.log(.request, payload: "Resume polling requested for existing active OpenAI batch \(remoteBatchId).")
            }
            Task {
                await self.startAll()
            }
            return
        }

        let task = ImageTask(
            inputPaths: entry.sourceImagePaths,
            projectId: entry.projectId,
            provider: .openAI,
            inputBookmarks: entry.sourceImageBookmarks,
            maskImagePath: entry.maskImagePath,
            maskImageBookmark: entry.maskImageBookmark
        )
        task.remoteBatchId = remoteBatchId
        task.remoteRequestId = remoteRequestId
        task.remoteBatchProvider = entry.remoteBatchProvider ?? .openAI
        task.status = "processing"
        task.phase = .pausedLocal
        task.submittedAt = entry.timestamp
        task.lastPollState = "validating"
        task.lastPollUpdatedAt = entry.timestamp
        task.error = "Resuming from history. Reconciling remote status."

        let batch = makeHistoryResumeBatch(for: entry, outputDirectory: outputDirectoryForHistoryResume(entry))
        batch.isTextMode = entry.isTextToImage
        batch.tasks = [task]
        batch.status = "pending"

        enqueue(batch)
        statusMessage = "Resuming OpenAI batch from history..."
        LogManager.shared.log(.request, payload: "Resume polling enqueued recovered OpenAI batch \(remoteBatchId).")

        Task {
            await self.startAll()
        }
    }

    private func outputDirectoryForHistoryResume(_ entry: HistoryEntry) -> String {
        if !entry.outputImagePath.isEmpty {
            return (entry.outputImagePath as NSString).deletingLastPathComponent
        }
        return AppPaths.projectsDirectoryURL
            .appendingPathComponent(entry.projectId.uuidString)
            .appendingPathComponent("Outputs")
            .path(percentEncoded: false)
    }

    private func makeHistoryResumeBatch(for entry: HistoryEntry, outputDirectory: String) -> BatchJob {
        BatchJob(
            prompt: entry.prompt,
            systemPrompt: entry.systemPrompt,
            aspectRatio: entry.aspectRatio,
            imageSize: entry.imageSize,
            outputDirectory: outputDirectory,
            outputDirectoryBookmark: entry.outputDirectoryBookmark,
            useBatchTier: entry.usedBatchTier,
            projectId: entry.projectId,
            modelName: entry.modelName,
            provider: entry.provider,
            maskImagePath: entry.maskImagePath,
            maskImageBookmark: entry.maskImageBookmark,
            openAIOutputFormat: entry.openAIOutputFormat,
            openAIBackground: entry.openAIBackground,
            openAIInputFidelity: entry.openAIInputFidelity,
            openAIOutputCompression: entry.openAIOutputCompression,
            openAINCount: entry.openAINCount
        )
    }

    private func rearmRemoteJobForPolling(_ job: ImageTask, in batch: BatchJob, jobIdentifier: String, source: String) {
        job.status = "processing"
        job.phase = .pausedLocal
        job.error = "Resuming remote job. Reconciling final status."
        job.completedAt = nil
        job.stalledAt = nil
        job.cancelRequestedAt = nil
        job.lastPollUpdatedAt = Date()
        batch.status = "pending"
        controlState = .interrupted
        statusMessage = "Resuming remote job..."
        saveActiveBatches()
        updateProgress()
        LogManager.shared.log(.request, payload: "Resume polling re-armed \(source) job \(jobIdentifier) for task \(job.id.uuidString).")
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
