# OpenAI Batch Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Fix the two production-readiness issues found in review: non-idempotent OpenAI batch result replay and missing History/Project Gallery resume support for OpenAI remote batches.

**Architecture:** Keep the provider-specific OpenAI behavior behind the existing queue/history interfaces. Make OpenAI terminal result parsing scoped to the unfinished request IDs the caller asked to reconcile, and make history resume use a single remote-resume capability that supports both Gemini `externalJobName` and OpenAI `remoteBatchId` + `remoteRequestId`.

**Tech Stack:** Swift, SwiftUI, Swift Testing, Xcode macOS app target.

---

## Investigation Summary

- Confirmed idempotency bug: `performOpenAIBatchPoll` passes only non-terminal `remoteRequestId`s as `expectedCustomIDs`, but `parseOpenAIBatchResultFiles` returns successes for every output-file line. `applyOpenAIBatchResult` then calls `handleSuccess` without an `!job.isTerminal` guard.
- Confirmed history resume gap: `HistoryView`, `ProjectGalleryView`, and `BatchOrchestrator.resumePollingFromHistory` still gate resume on `externalJobName`. OpenAI entries persist `remoteBatchId` and `remoteRequestId`, so the data exists but is not used.
- Out of scope for this plan: OpenAI uploaded source/mask file cleanup. That is a separate lifecycle/privacy task because it requires persisting uploaded file IDs or returning cleanup metadata from `startOpenAIBatch`.

## File Structure

- Modify `Nano Banana Helper/Services/NanoBananaService.swift`
  - Scope parsed OpenAI batch result lines to `expectedCustomIDs`.
- Modify `Nano Banana Helper/Services/BatchOrchestrator.swift`
  - Add a defensive terminal guard for OpenAI successes.
  - Rehydrate OpenAI history entries into queue tasks with `remoteBatchId`, `remoteRequestId`, provider, and OpenAI settings.
- Modify `Nano Banana Helper/Models/Models.swift`
  - Add a small `HistoryEntry` resume-capability helper.
- Modify `Nano Banana Helper/Views/HistoryView.swift`
  - Show Resume Polling for failed/stale OpenAI entries that have both remote IDs.
- Modify `Nano Banana Helper/Views/ProjectGalleryView.swift`
  - Match HistoryView's remote-resume eligibility.
- Modify `Nano Banana HelperTests/Nano_Banana_HelperTests.swift`
  - Add focused regression tests beside the existing OpenAI batch and history-resume tests.

## Task 1: Make OpenAI Batch Result Replay Idempotent

**Files:**
- Modify: `Nano Banana Helper/Services/NanoBananaService.swift:768-815`
- Modify: `Nano Banana Helper/Services/BatchOrchestrator.swift:930-940`
- Test: `Nano Banana HelperTests/Nano_Banana_HelperTests.swift:3289-3314`

- [x] **Step 1: Write a failing parser-scope test**

Add this test next to `openAIBatchResultParsingPreservesPartialSuccess`:

```swift
@MainActor @Test func openAIBatchResultParsingIgnoresUnexpectedCustomIDs() async throws {
    let service = NanoBananaService()
    let outputData = """
    {"custom_id":"task-already-completed","response":{"status_code":200,"body":{"data":[{"b64_json":"b2s="}],"output_format":"png"}},"error":null}
    {"custom_id":"task-still-pending","response":{"status_code":200,"body":{"data":[{"b64_json":"b2s="}],"output_format":"png"}},"error":null}
    """.data(using: .utf8)!

    let result = try await service.parseOpenAIBatchResultFiles(
        batchID: "batch_123",
        terminalStatus: "completed",
        expectedCustomIDs: ["task-still-pending"],
        outputFileData: outputData,
        errorFileData: nil
    )

    #expect(result.successes.map(\.customID) == ["task-still-pending"])
    #expect(result.failures.isEmpty)
}
```

- [x] **Step 2: Run the focused build to confirm the new test compiles**

Run:

```bash
xcodebuild -project "Nano Banana Helper.xcodeproj" -target "Nano Banana HelperTests" -configuration Debug build
```

Expected: build succeeds; the new test will fail only when the test runner can execute because current parser returns both success IDs.

- [x] **Step 3: Filter OpenAI batch result files by expected IDs**

In `parseOpenAIBatchResultFiles`, add an expected-ID set and skip lines not requested by the caller:

```swift
let expectedCustomIDSet = Set(expectedCustomIDs)
```

Then after each `parseOpenAIBatchResultLine` call in both output and error file loops:

```swift
guard expectedCustomIDSet.contains(parsed.customID) else {
    continue
}
seenCustomIDs.insert(parsed.customID)
```

Keep the existing missing-ID loop:

```swift
for customID in expectedCustomIDs where !seenCustomIDs.contains(customID) {
    failures.append(
        OpenAIBatchLineFailure(
            customID: customID,
            message: "OpenAI batch \(terminalStatus) before this request produced a result."
        )
    )
}
```

- [x] **Step 4: Add a defensive terminal guard before handling successes**

In `applyOpenAIBatchResult`, change the success guard to match the failure guard:

```swift
guard let job = batch.tasks.first(where: { $0.remoteRequestId == success.customID }),
      !job.isTerminal else { continue }
```

- [x] **Step 5: Re-run verification**

Run:

```bash
xcodebuild -project "Nano Banana Helper.xcodeproj" -target "Nano Banana HelperTests" -configuration Debug build
```

Expected: build succeeds.

If the scheme test runner is available, also run:

```bash
xcodebuild -project "Nano Banana Helper.xcodeproj" -scheme "Nano Banana Helper" -configuration Debug -destination 'platform=macOS' test -only-testing:"Nano Banana HelperTests/Nano_Banana_HelperTests/openAIBatchResultParsingPreservesPartialSuccess" -only-testing:"Nano Banana HelperTests/Nano_Banana_HelperTests/openAIBatchResultParsingIgnoresUnexpectedCustomIDs"
```

Expected: both tests pass. If it still fails on `Nano Banana HelperUITests.xctest` linker setup before unit execution, record that blocker and keep the target build result as compile evidence.

## Task 2: Add a Shared History Resume Eligibility Helper

**Files:**
- Modify: `Nano Banana Helper/Models/Models.swift:174-230`
- Test: `Nano Banana HelperTests/Nano_Banana_HelperTests.swift`

- [x] **Step 1: Write the failing model helper test**

Add this test near `remoteBatchFieldsRoundTripThroughQueueAndHistory`:

```swift
@Test func historyEntryRemotePollingEligibilitySupportsOpenAIAndGemini() {
    let geminiEntry = HistoryEntry(
        projectId: UUID(),
        sourceImagePaths: ["/tmp/source.png"],
        outputImagePath: "",
        prompt: "prompt",
        aspectRatio: "1:1",
        imageSize: "1K",
        usedBatchTier: true,
        cost: 0,
        status: "failed",
        externalJobName: "batches/gemini-job"
    )
    let openAIEntry = HistoryEntry(
        projectId: UUID(),
        sourceImagePaths: ["/tmp/source.png"],
        outputImagePath: "",
        prompt: "prompt",
        aspectRatio: "1:1",
        imageSize: "1K",
        usedBatchTier: true,
        cost: 0,
        status: "failed",
        provider: .openAI,
        remoteBatchId: "batch_openai_123",
        remoteRequestId: "task-a",
        remoteBatchProvider: .openAI
    )
    let incompleteOpenAIEntry = HistoryEntry(
        projectId: UUID(),
        sourceImagePaths: ["/tmp/source.png"],
        outputImagePath: "",
        prompt: "prompt",
        aspectRatio: "1:1",
        imageSize: "1K",
        usedBatchTier: true,
        cost: 0,
        status: "failed",
        provider: .openAI,
        remoteBatchId: "batch_openai_123",
        remoteBatchProvider: .openAI
    )

    #expect(geminiEntry.canResumeRemotePolling)
    #expect(openAIEntry.canResumeRemotePolling)
    #expect(incompleteOpenAIEntry.canResumeRemotePolling == false)
}
```

- [x] **Step 2: Implement the helper**

Add this computed property to `HistoryEntry` near `remoteJobIdForDisplay`:

```swift
var canResumeRemotePolling: Bool {
    if externalJobName != nil {
        return true
    }
    return remoteBatchProvider == .openAI &&
        remoteBatchId != nil &&
        remoteRequestId != nil
}
```

- [x] **Step 3: Update HistoryView resume affordances**

In `HistoryView`, replace `entry.externalJobName != nil` checks used for resume buttons with:

```swift
entry.canResumeRemotePolling
```

Keep the rescue dialog only for failed entries that cannot resume:

```swift
if entry.canResumeRemotePolling {
    Button("Resume Polling (No Cost)") {
        onResumePolling?(entry)
    }
} else {
    Button("Rescue with Job ID...") {
        entryToRescue = entry
        rescueJobID = ""
        showingRescueDialog = true
    }
}
```

For `HistoryRowView`, use the same condition:

```swift
if entry.canResumeRemotePolling {
    Button(action: { onResumePolling?(entry) }) {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.orange)
    }
    .buttonStyle(.plain)
    .help("Resume Polling")
} else {
    Button(action: { onRescue?() }) {
        Image(systemName: "lifepreserver")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.blue)
    }
    .buttonStyle(.plain)
    .help("Rescue ID")
}
```

- [x] **Step 4: Update ProjectGalleryView resume affordance**

Replace:

```swift
if entry.status == "failed" && entry.externalJobName != nil {
```

with:

```swift
if entry.status == "failed" && entry.canResumeRemotePolling {
```

- [x] **Step 5: Re-run the target build**

Run:

```bash
xcodebuild -project "Nano Banana Helper.xcodeproj" -target "Nano Banana HelperTests" -configuration Debug build
```

Expected: build succeeds.

## Task 3: Rehydrate OpenAI Remote Batch History Entries

**Files:**
- Modify: `Nano Banana Helper/Services/BatchOrchestrator.swift:2145-2212`
- Test: `Nano Banana HelperTests/Nano_Banana_HelperTests.swift:2190-2300`

- [x] **Step 1: Write the failing OpenAI history resume test**

Add this test near the existing `resumePollingFromHistory...` tests:

```swift
@MainActor @Test func resumePollingFromOpenAIHistoryRehydratesRemoteBatchFieldsAndSettings() throws {
    let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
    let projectId = UUID()
    let orchestrator = BatchOrchestrator(
        activeBatchURL: activeBatchURL,
        autoStartEnqueuedBatches: false,
        processQueueOverride: { _ in }
    )
    let entry = HistoryEntry(
        projectId: projectId,
        sourceImagePaths: ["/tmp/source.png"],
        outputImagePath: "",
        prompt: "prompt",
        aspectRatio: "1:1",
        imageSize: "1K",
        usedBatchTier: true,
        cost: 0,
        status: "failed",
        provider: .openAI,
        systemPrompt: "system",
        openAIOutputFormat: .webp,
        openAIBackground: .opaque,
        openAIInputFidelity: .low,
        openAIOutputCompression: 72,
        openAINCount: 3,
        remoteBatchId: "batch_openai_123",
        remoteRequestId: "task-openai-a",
        remoteBatchProvider: .openAI
    )

    orchestrator.resumePollingFromHistory(for: entry)

    let persistedState = try loadPersistedQueueState(from: activeBatchURL)
    let batch = try #require(persistedState.batches.first)
    let task = try #require(batch.tasks.first)

    #expect(batch.provider == .openAI)
    #expect(batch.useBatchTier)
    #expect(batch.modelName == nil)
    #expect(batch.systemPrompt == "system")
    #expect(batch.openAIOutputFormat == .webp)
    #expect(batch.openAIBackground == .opaque)
    #expect(batch.openAIInputFidelity == .low)
    #expect(batch.openAIOutputCompression == 72)
    #expect(batch.openAINCount == 3)
    #expect(task.remoteBatchId == "batch_openai_123")
    #expect(task.remoteRequestId == "task-openai-a")
    #expect(task.remoteBatchProvider == .openAI)
    #expect(task.externalJobName == nil)
    #expect(task.status == "processing")
    #expect(task.phase == .pausedLocal)
}
```

- [x] **Step 2: Split history resume by provider remote identity**

Refactor `resumePollingFromHistory(for:)` into a small dispatcher:

```swift
func resumePollingFromHistory(for entry: HistoryEntry) {
    if entry.provider == .openAI && entry.usedBatchTier {
        resumeOpenAIPollingFromHistory(for: entry)
        return
    }
    resumeGeminiPollingFromHistory(for: entry)
}
```

Move the existing Gemini logic into `resumeGeminiPollingFromHistory(for:)` unchanged except for private method naming.

- [x] **Step 3: Implement OpenAI history recovery**

Add a private helper:

```swift
private func resumeOpenAIPollingFromHistory(for entry: HistoryEntry) {
    guard let remoteBatchId = entry.remoteBatchId,
          let remoteRequestId = entry.remoteRequestId else { return }

    if let existingBatch = activeBatches.first(where: {
        $0.tasks.contains(where: { $0.remoteBatchId == remoteBatchId && $0.remoteRequestId == remoteRequestId })
    }),
       let existingTask = existingBatch.tasks.first(where: {
           $0.remoteBatchId == remoteBatchId && $0.remoteRequestId == remoteRequestId
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
```

- [x] **Step 4: Extract shared output-directory and batch construction helpers**

To avoid duplicating the existing Gemini resume setup, add:

```swift
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
```

Update Gemini resume to call these helpers too, preserving Gemini `externalJobName` behavior.

- [x] **Step 5: Add an existing-active OpenAI history resume test**

Add a second test to prove failed active OpenAI tasks re-arm instead of creating a duplicate batch:

```swift
@MainActor @Test func resumePollingFromHistoryRearmsExistingOpenAIRemoteJob() throws {
    let activeBatchURL = try makeTemporaryDirectory().appendingPathComponent("active_batch.json")
    let projectId = UUID()
    let orchestrator = BatchOrchestrator(
        activeBatchURL: activeBatchURL,
        autoStartEnqueuedBatches: false,
        processQueueOverride: { _ in }
    )
    let batch = BatchJob(
        prompt: "prompt",
        outputDirectory: "/tmp",
        useBatchTier: true,
        projectId: projectId,
        provider: .openAI
    )
    let task = ImageTask(inputPaths: ["/tmp/source.png"], projectId: projectId, provider: .openAI)
    task.status = "failed"
    task.phase = .failed
    task.error = "write failed"
    task.remoteBatchId = "batch_openai_123"
    task.remoteRequestId = "task-openai-a"
    task.remoteBatchProvider = .openAI
    batch.tasks = [task]

    orchestrator.enqueue(batch)
    let entry = HistoryEntry(
        projectId: projectId,
        sourceImagePaths: ["/tmp/source.png"],
        outputImagePath: "",
        prompt: "prompt",
        aspectRatio: "1:1",
        imageSize: "1K",
        usedBatchTier: true,
        cost: 0,
        status: "failed",
        provider: .openAI,
        remoteBatchId: "batch_openai_123",
        remoteRequestId: "task-openai-a",
        remoteBatchProvider: .openAI
    )

    orchestrator.resumePollingFromHistory(for: entry)

    #expect(orchestrator.failedJobs.isEmpty)
    let resumedTask = try #require(orchestrator.processingJobs.first)
    #expect(resumedTask.remoteBatchId == "batch_openai_123")
    #expect(resumedTask.remoteRequestId == "task-openai-a")
    #expect(resumedTask.phase == .pausedLocal)

    let persistedState = try loadPersistedQueueState(from: activeBatchURL)
    #expect(persistedState.batches.count == 1)
}
```

- [x] **Step 6: Re-run verification**

Run:

```bash
xcodebuild -project "Nano Banana Helper.xcodeproj" -target "Nano Banana HelperTests" -configuration Debug build
```

Expected: build succeeds.

If available, run focused scheme tests for the history resume cases:

```bash
xcodebuild -project "Nano Banana Helper.xcodeproj" -scheme "Nano Banana Helper" -configuration Debug -destination 'platform=macOS' test -only-testing:"Nano Banana HelperTests/Nano_Banana_HelperTests/resumePollingFromHistoryPreservesSavedModelName" -only-testing:"Nano Banana HelperTests/Nano_Banana_HelperTests/resumePollingFromHistoryRearmsExistingFailedRemoteJob" -only-testing:"Nano Banana HelperTests/Nano_Banana_HelperTests/resumePollingFromOpenAIHistoryRehydratesRemoteBatchFieldsAndSettings" -only-testing:"Nano Banana HelperTests/Nano_Banana_HelperTests/resumePollingFromHistoryRearmsExistingOpenAIRemoteJob"
```

Expected: all selected tests pass, unless blocked by the existing UI-test bundle linker issue.

## Task 4: Final Verification and Packaging

**Files:**
- No source edits unless a verification failure requires them.

- [x] **Step 1: Confirm no stale OpenAI disabled copy remains**

Run:

```bash
rg -n "OpenAI Batch Tier is not implemented|Deferred for OpenAI|Batch Tier remains disabled|disabled\\(stagingManager.provider == \\.openAI\\)" "Nano Banana Helper" CONTEXT.md
```

Expected: no matches.

- [x] **Step 2: Run test-target compile verification**

Run:

```bash
xcodebuild -project "Nano Banana Helper.xcodeproj" -target "Nano Banana HelperTests" -configuration Debug build
```

Expected: build succeeds.

- [x] **Step 3: Run app build or DMG build**

Run:

```bash
./build-dmg.sh
```

Expected: Release build succeeds and `Nano Banana Helper.dmg` is regenerated.

- [x] **Step 4: Run GitNexus scope check**

Run GitNexus `detect_changes` with:

```json
{"repo":"Nano-Banana-Helper","scope":"all"}
```

Expected: no unexpected high-risk scope. If GitNexus cannot map Swift symbols, record that limitation and use the changed-file list plus Xcode build evidence.

- [x] **Step 5: Review dirty worktree before final response**

Run:

```bash
git status --short --branch
git diff --stat
```

Expected: only the intended fix files plus the regenerated DMG are changed. Preserve pre-existing local changes in `Nano Banana Helper/Views/BottomDockView.swift` and unrelated test additions unless the user explicitly asks to include or revert them.

## Self-Review

- Spec coverage: Task 1 fixes OpenAI batch result idempotency; Tasks 2-3 fix History/Project Gallery resume for OpenAI remote batches; Task 4 verifies build/package/scope.
- Placeholder scan: no TBD/TODO/fill-in-later steps.
- Type consistency: plan uses existing `remoteBatchId`, `remoteRequestId`, `remoteBatchProvider`, `remoteJobIdForDisplay`, `OpenAIOutputFormat`, `OpenAIBackground`, `OpenAIInputFidelity`, and `openAINCount` names.
