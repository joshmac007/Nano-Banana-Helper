# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Open in Xcode
xed .

# Build DMG (cleans derived data, builds Release, creates DMG in project root)
./build-dmg.sh

# Build from command line (Debug) — must override team ID
xcodebuild -project "Nano Banana Helper.xcodeproj" -scheme "Nano Banana Helper" -configuration Debug DEVELOPMENT_TEAM=46BZ85ALNS

# Run all tests (deployment target override needed if host macOS < SDK)
xcodebuild -project "Nano Banana Helper.xcodeproj" -scheme "Nano Banana Helper" -destination 'platform=macOS' test MACOSX_DEPLOYMENT_TARGET=26.2

# Run a single unit test (Swift Testing framework) — target ID uses underscores
xcodebuild -project "Nano Banana Helper.xcodeproj" -scheme "Nano Banana Helper" -destination 'platform=macOS' test MACOSX_DEPLOYMENT_TARGET=26.2 -only-testing:Nano_Banana_HelperTests/ClassName/testName

# Run a single UI test (XCTest framework)
xcodebuild -project "Nano Banana Helper.xcodeproj" -scheme "Nano Banana Helper" -destination 'platform=macOS' test -only-testing:Nano-Banana-HelperUITests/ClassName/testName
```

**Always build a DMG after any code change.** Run `./build-dmg.sh` at the end of every task. The DMG is stored at `Nano Banana Helper.dmg` in the project root.

## Architecture Overview

MVVM with SwiftUI Observation framework. Three-layer structure:

```
Views/           → SwiftUI views, consume @Environment objects
Services/        → Business logic, API clients, coordination
Models/          → Data structures, @Observable state managers
```

**No external dependencies** — pure Apple SDK (SwiftUI, Foundation, Observation, UserNotifications, AppKit, UniformTypeIdentifiers).

**Sandbox**: App runs with App Sandbox enabled. Entitlements are set in build settings (no `.entitlements` file): outgoing/incoming network connections, user-selected file access (read-write), Downloads folder (read-write), Hardened Runtime.

**File system sync**: Xcode uses `PBXFileSystemSynchronizedRootGroup` — the file system IS the source of truth. Create files in the correct directory; no need to manually add them to the Xcode project.

### Key State Objects

| Object | File | Role |
|--------|------|------|
| `BatchOrchestrator` | Services/ | Job queue, concurrent execution, polling. Created at App level, injected via `.environment()` |
| `ProjectManager` | Services/ | Project CRUD, cost tracking, persistence. Created as `@State` in `MainLayoutView` |
| `BatchStagingManager` | Models/ | Staged files, batch configuration (prompt, aspect ratio, size). Passed as `@Bindable`. `generationMode` (`.image` or `.text`) controls API call path — `.image` edits existing images, `.text` generates from scratch |
| `PromptLibrary` | Models/ | Saved prompt templates (user/system types) |
| `HistoryManager` | Services/ | Global history aggregation |
| `LogManager` | Models/Models.swift | In-memory session logger (`@Observable @MainActor` singleton) |
| `AppConfig` | Services/NanoBananaService.swift | API key, model name. `@MainActor` struct persisted to `config.json`. Defined alongside request/response/error types (`ImageEditRequest`, `ImageEditResponse`, `BatchJobInfo`, `NanoBananaError`) |
| `TokenUsage` | Models/BillingModels.swift | `nonisolated` struct with prompt/candidates/total token counts. Decoded from API `usageMetadata` |
| `CostSummary` | Models/Models.swift | Extended with `totalTokens`, `inputTokens`, `outputTokens`, `byModel`. Custom `Codable` for backward compat (new fields default to 0/empty) |
| `AppPaths` | Models/AppPaths.swift | Centralized path management, security-scoped bookmark helpers |
| `Project` | Models/Models.swift | `@Observable class` — domain model grouping batch jobs. Properties: id, name, outputDirectory, totalCost, presets |
| `HistoryEntry` | Models/Models.swift | Core data type for a completed image edit with token usage, model name, cost metadata |
| `ImageTask` | Models/Models.swift | `@Observable class` — single image task within a batch, multi-input support |
| `BatchJob` | Models/Models.swift | `@Observable class` — batch container with `isTextMode` flag |
| `JobPhase` | Models/Models.swift | Enum: `.pending`, `.submitting`, `.polling`, `.reconnecting`, `.downloading`, `.completed`, `.failed` |
| `ImageSize` | Models/Models.swift | Enum: `512`, `1K`, `2K`, `4K` with `standardCost`/`batchCost`/`calculateCost()` |
| `AspectRatio` | Models/AspectRatio.swift | Supported output ratios with categories (auto, square, landscape, portrait) |
| `GenerationMode` | Models/BatchStagingManager.swift | Enum: `.image` (edit existing) or `.text` (generate from scratch) |
| `Constants` | Models/Constants.swift | App-wide constants (`maxTextImageVariations = 4`) |

### View Hierarchy

```
Nano_Banana_HelperApp (@main) → ContentView → MainLayoutView
  NavigationSplitView: SidebarView | WorkbenchView (Staging/Results/History) + InspectorView
  ProgressQueueView, BottomDockView
  Sheets: SettingsView, NewProjectSheet, CostReportView, UsageDashboardView (inside Settings)
```

All state objects besides `BatchOrchestrator` are created and callbacks wired in `MainLayoutView.onAppear`.

### Data Flow

1. User stages files → `BatchStagingManager.stagedFiles`
2. Configures in `InspectorView` → updates `BatchStagingManager` settings
3. Starts batch → `BatchOrchestrator.enqueue(batch)`
4. Orchestrator submits to `NanoBananaService` (actor-based API client)
5. Callbacks (`onImageCompleted`, `onCostIncurred`, `onHistoryEntryUpdated`) update `HistoryManager`/`ProjectManager`

## Important Patterns

### Default Actor Isolation (Critical)
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all types are `@MainActor` by default. Use `nonisolated` explicitly for types/functions that don't need main actor isolation.

### @Observable State
All managers use Swift Observation (`@Observable` class), not ObservableObject.

**`@Observable` + property observers = infinite recursion** — Never re-assign an `@Observable` property inside its own `willSet` or `didSet`. The macro transforms stored properties into computed properties routed through `ObservationRegistrar.withMutation`, which re-enters the observer. Use UI guards (`.disabled()`) or call-site clamping instead. See `BatchStagingManager.textImageCount` history.

### Actor-Based API Service
`NanoBananaService` is a Swift `actor` for thread-safe API access. All methods are `async`.

### Callback Wiring
Callbacks are wired in `MainLayoutView.onAppear`:
```swift
orchestrator.onImageCompleted = { entry in
    historyManager.addEntry(entry)
}
orchestrator.onHistoryEntryUpdated = { jobName, entry in
    historyManager.updateEntry(byExternalJobName: jobName, with: entry)
}
orchestrator.onCostIncurred = { cost, resolution, projectId, tokenUsage, modelName in
    projectManager.costSummary.record(cost:cost, resolution:resolution, projectId:projectId, tokens:tokenUsage, modelName:modelName)
    projectManager.recordSessionUsage(cost: cost, tokens: tokenUsage)
}
```

### Security-Scoped Bookmarks
File access uses security-scoped bookmarks for persistent sandbox access. See `AppPaths.swift` for `resolveBookmark`, `withResolvedBookmark`, `bookmark(for:)`.

### Async Context in Orchestrator
`BatchOrchestrator.cancel()` is synchronous — cannot use `await service.getModelName()`. Use `AppConfig.load().modelName` (synchronous `@MainActor` property) in non-async methods. `handleSuccess()` and `handleError()` are async and can use `await`.

### nonisolated Structs in Actors
Types passed into/out of `NanoBananaService` (actor) must be `nonisolated`. See `TokenUsage` in `BillingModels.swift`.

### Concurrency
- 5 concurrent job submissions
- 10-second polling interval
- 360 max poll attempts (1 hour timeout)
- `TaskGroup` for throttled concurrent submission and polling in `BatchOrchestrator`
- `enqueueTextGeneration(...)` for text-to-image mode (`.text` generation mode)
- `resumePollingFromHistory(for:)` to resume failed batch jobs from history

## API Integration

**Code signing**: Apple Development cert works for local builds (`DEVELOPMENT_TEAM=46BZ85ALNS`). Developer ID Application cert exists but private key is not in keychain — cannot notarize for distribution. Notarytool profile "NanoBananaHelper" is configured in Keychain.

Google Gemini API with two tiers:
- **Standard**: Synchronous (`:generateContent`)
- **Batch**: Async jobs (`:batchGenerateContent` + polling)

Request payload structure in `NanoBananaService.buildPayload()`. Supports `system_instruction` for system prompts.

## Persistence

Data stored in `~/Library/Application Support/NanoBananaProAssistant/`:
- `config.json` — API key, model
- `projects.json` — Project list
- `projects/{uuid}/history.json` — Per-project history
- `projects/{uuid}/project.json` — Per-project metadata
- `saved_prompts.json` — Prompt library
- `active_batch.json` — Interrupted batch state (for resume)
- `cost_summary.json` — Aggregated cost data

### Data Migration
`AppPaths.migrateIfNeeded()` handles one-time migration from the legacy `NanoBananaPro` directory to `NanoBananaProAssistant`. Called at launch from `ProjectManager`.

### Xcode Project Configuration
- macOS only app — `SDKROOT = macosx` on all targets. Never set `IPHONEOS_DEPLOYMENT_TARGET` or `TARGETED_DEVICE_FAMILY`.
- `MACOSX_DEPLOYMENT_TARGET = 26.2` must be set explicitly (host machine may be older than the Xcode SDK).
- Shared scheme at `xcshareddata/xcschemes/Nano Banana Helper.xcscheme`. Test targets must have `buildForRunning = "NO"` in BuildAction to avoid XCTest frameworks being embedded in the app bundle (adds ~30MB).
- Unit tests use Swift Testing (`@Test` macro), UI tests use XCTest. Both targets need `import Foundation` explicitly.
- When building DMGs, clean derived data first to avoid stale frameworks: `rm -rf ~/Library/Developer/Xcode/DerivedData/Nano_Banana_Helper-*`

### Backward-Compatible Codable
When adding new fields to persisted `Codable` structs (`HistoryEntry`, `CostSummary`), always use `decodeIfPresent` with sensible defaults and write explicit `init(from decoder:)` / `encode(to encoder:)` — synthesized Codable will crash on existing JSON files missing the new fields.

### Dead Code
Three view files compile but are never referenced — do not modify without checking usage:
`ProjectGalleryView.swift`, `ProjectListView.swift`, `DropZoneView.swift`
