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

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **Nano Banana Helper** (107 symbols, 100 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## When Debugging

1. `gitnexus_query({query: "<error or symptom>"})` — find execution flows related to the issue
2. `gitnexus_context({name: "<suspect function>"})` — see all callers, callees, and process participation
3. `READ gitnexus://repo/Nano Banana Helper/process/{processName}` — trace the full execution flow step by step
4. For regressions: `gitnexus_detect_changes({scope: "compare", base_ref: "main"})` — see what your branch changed

## When Refactoring

- **Renaming**: MUST use `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` first. Review the preview — graph edits are safe, text_search edits need manual review. Then run with `dry_run: false`.
- **Extracting/Splitting**: MUST run `gitnexus_context({name: "target"})` to see all incoming/outgoing refs, then `gitnexus_impact({target: "target", direction: "upstream"})` to find all external callers before moving code.
- After any refactor: run `gitnexus_detect_changes({scope: "all"})` to verify only expected files changed.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Tools Quick Reference

| Tool | When to use | Command |
|------|-------------|---------|
| `query` | Find code by concept | `gitnexus_query({query: "auth validation"})` |
| `context` | 360-degree view of one symbol | `gitnexus_context({name: "validateUser"})` |
| `impact` | Blast radius before editing | `gitnexus_impact({target: "X", direction: "upstream"})` |
| `detect_changes` | Pre-commit scope check | `gitnexus_detect_changes({scope: "staged"})` |
| `rename` | Safe multi-file rename | `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` |
| `cypher` | Custom graph queries | `gitnexus_cypher({query: "MATCH ..."})` |

## Impact Risk Levels

| Depth | Meaning | Action |
|-------|---------|--------|
| d=1 | WILL BREAK — direct callers/importers | MUST update these |
| d=2 | LIKELY AFFECTED — indirect deps | Should test |
| d=3 | MAY NEED TESTING — transitive | Test if critical path |

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/Nano Banana Helper/context` | Codebase overview, check index freshness |
| `gitnexus://repo/Nano Banana Helper/clusters` | All functional areas |
| `gitnexus://repo/Nano Banana Helper/processes` | All execution flows |
| `gitnexus://repo/Nano Banana Helper/process/{name}` | Step-by-step execution trace |

## Self-Check Before Finishing

Before completing any code modification task, verify:
1. `gitnexus_impact` was run for all modified symbols
2. No HIGH/CRITICAL risk warnings were ignored
3. `gitnexus_detect_changes()` confirms changes match expected scope
4. All d=1 (WILL BREAK) dependents were updated

## Keeping the Index Fresh

After committing code changes, the GitNexus index becomes stale. Re-run analyze to update it:

```bash
npx gitnexus analyze
```

If the index previously included embeddings, preserve them by adding `--embeddings`:

```bash
npx gitnexus analyze --embeddings
```

To check whether embeddings exist, inspect `.gitnexus/meta.json` — the `stats.embeddings` field shows the count (0 means no embeddings). **Running analyze without `--embeddings` will delete any previously generated embeddings.**

> Claude Code users: A PostToolUse hook handles this automatically after `git commit` and `git merge`.

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
