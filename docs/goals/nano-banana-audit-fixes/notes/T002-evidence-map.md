# T002 Evidence Map

## Tool And Verification Baseline

- GoalBuddy prompt for T002 required `goal_scout`, but this Codex session does not expose that spawn role, so this task ran as PM fallback.
- GitNexus CLI is available and `gitnexus status` reports Nano-Banana-Helper indexed at current commit `4209a6d`.
- GitNexus MCP tools are not mounted in this Codex session.
- GitNexus CLI `impact --repo Nano-Banana-Helper` is callable but returned `Target not found` for key Swift symbols including `makeImageTasks`, `deleteProject`, `outputDirectoryForHistoryResume`, `StagedImageCell`, and `AppPaths`.
- GitNexus CLI `query --repo Nano-Banana-Helper ...` returned no definitions/processes and warned that FTS indexes are missing/degraded.
- Swift 6 override build command failed with code 65:

```bash
rtk proxy xcodebuild build -quiet -project 'Nano Banana Helper.xcodeproj' -scheme 'Nano Banana Helper' -destination 'platform=macOS,arch=arm64' -derivedDataPath 'build/GoalScoutSwift6DerivedData' SWIFT_VERSION=6.0 MACOSX_DEPLOYMENT_TARGET=26.2 CODE_SIGNING_ALLOWED=NO
```

First hard errors:

- `Nano Banana Helper/Services/HistoryManager.swift:188`: `AppPaths.bookmark(for:)` inferred `@MainActor` cannot be used as `(URL) -> Data?`.
- `Nano Banana Helper/Services/HistoryManager.swift:214`: same.
- `Nano Banana Helper/Views/BookmarkAccessDeniedView.swift:44`: same.

## Finding 1: Swift 6 Concurrency Readiness

Evidence:

- `README.md:9`, `README.md:42`, `README.md:44` market Swift 6 and Swift concurrency.
- `Nano Banana Helper.xcodeproj/project.pbxproj:450`, `509`, `531`, `554`, `575`, `596` set `SWIFT_VERSION = 5.0`.
- App configs also set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` at `project.pbxproj:447`, `506`.
- Likely nonisolated helper/model boundaries:
  - `Nano Banana Helper/Models/Models.swift:3-47`: `ModelProvider` and `OpenAIOutputFormat` computed properties.
  - `Nano Banana Helper/Models/ModelCatalog.swift:26-120`: `CuratedModelCatalog`.
  - `Nano Banana Helper/Models/AppPaths.swift:5-130`: static path/bookmark helpers.
  - `Nano Banana Helper/Services/NanoBananaService.swift:76-96`: `OpenAIBatchRequestLine.encodedJSONLineData()`.
  - `Nano Banana Helper/Services/NanoBananaService.swift:151-196`: `PollRetryState`, `RequestBuildArtifacts`.
  - `Nano Banana Helper/Services/HistoryManager.swift:185-216` and `Nano Banana Helper/Views/BookmarkAccessDeniedView.swift:36-46`: default callback parameters currently fail in Swift 6.

Worker candidate:

- `Nano Banana Helper/Models/Models.swift`
- `Nano Banana Helper/Models/ModelCatalog.swift`
- `Nano Banana Helper/Models/AppPaths.swift`
- `Nano Banana Helper/Services/NanoBananaService.swift`
- `Nano Banana Helper/Services/HistoryManager.swift`
- `Nano Banana Helper/Views/BookmarkAccessDeniedView.swift`
- Tests only if the Swift 6 build exposes test-only conformances after app target compiles.

Verify:

- Swift 6 override build above.
- Focused full unit target after code changes:
  `rtk proxy xcodebuild test -quiet -project 'Nano Banana Helper.xcodeproj' -scheme 'Nano Banana Helper' -destination 'platform=macOS,arch=arm64' -derivedDataPath 'build/GoalVerifyDerivedData' -only-testing:'Nano Banana HelperTests' MACOSX_DEPLOYMENT_TARGET=26.2 CODE_SIGNING_ALLOWED=NO`

## Finding 2: OpenAI Mask Multi-File Poisoning

Evidence:

- `Nano Banana Helper/Models/BatchStagingManager.swift:264-298`: `makeImageTasks()` uses `maskFile?.path` in both multi-input and per-source non-multi-input task creation.
- In non-multi-input mode, `stagedFiles.flatMap` creates one independent `ImageTask` per source, each with the same `maskImagePath` and `maskImageBookmark` at lines `284-292`.
- `Nano Banana Helper/Services/NanoBananaService.swift:895-915`: OpenAI Batch Tier validates mask dimensions/format against each request primary image before upload.
- `Nano Banana Helper/Services/BatchOrchestrator.swift:757-840`: one thrown validation error in `submitOpenAIBatch` catches once and calls `handleError` for every submission item.
- Existing tests cover image variation expansion at `Nano Banana HelperTests/Nano_Banana_HelperTests.swift:775-830`, single mask metadata at `3264-3278`, and format mismatch validation at `3530-3549`, but not multi-file non-multi-input mask behavior.

Worker candidate:

- `Nano Banana Helper/Models/BatchStagingManager.swift`
- `Nano Banana Helper/Views/InspectorView.swift` only if UI copy/validation is needed.
- `Nano Banana HelperTests/Nano_Banana_HelperTests.swift`

Verify:

- Add regression that multiple non-multi-input staged files do not all inherit one mask, or that staging rejects/clears mask for ambiguous multi-file independent tasks.
- Run focused test file with the main unit command above.

## Finding 3: Last Project Deletion

Evidence:

- `Nano Banana Helper/Services/ProjectManager.swift:108-119`: `deleteProject(_:)` removes the project and sets `currentProject = projects.first`; if the last project is deleted, this becomes `nil`.
- `Nano Banana Helper/Views/SettingsView.swift:229-265`: Projects tab delete button has no `.disabled(projectManager.projects.count <= 1)`.
- `Nano Banana Helper/Views/ProjectListView.swift:68-71` and `Nano Banana Helper/Views/SidebarView.swift:76-79`, `104-107` already guard the last-project delete UI.
- `Nano Banana Helper/Views/InspectorView.swift:421` silently returns if `currentProject` is nil.
- Existing ProjectManager tests cover usage/history behavior but no direct last-project deletion invariant.

Worker candidate:

- `Nano Banana Helper/Services/ProjectManager.swift`
- `Nano Banana Helper/Views/SettingsView.swift`
- `Nano Banana HelperTests/Nano_Banana_HelperTests.swift`

Verify:

- Add ProjectManager regression that deleting the last project is a no-op or preserves a current project.
- Add Settings UI guard if feasible with code-level review; current unit suite likely sufficient for service invariant.

## Finding 4: History Resume Output Directory Preservation

Evidence:

- `Nano Banana Helper/Services/BatchOrchestrator.swift:1115-1129`: in-progress remote history entry persists `outputImagePath: ""` and optional `outputDirectoryBookmark`, but no output directory path.
- `Nano Banana Helper/Models/Models.swift:192-196`: `HistoryEntry` has source/output bookmarks but no explicit output directory path.
- `Nano Banana Helper/Services/BatchOrchestrator.swift:2261-2269`: resume with empty output path uses app-support `projects/<projectId>/Outputs`.
- `Nano Banana Helper/Services/BatchOrchestrator.swift:2309-2341`: `withAccessibleOutputDirectory` only falls back to a path if it equals `AppPaths.defaultOutputDirectory.path`; the reconstructed app-support path is rejected without a bookmark, then completion falls into recovery handling.
- Existing tests cover bookmark preservation at `Nano Banana HelperTests/Nano_Banana_HelperTests.swift:2305-2335` and recovery fallback at `3389-3435`, but no case for remote resume entry with empty output path and nil bookmark preserving the original output directory.

Worker candidate:

- `Nano Banana Helper/Models/Models.swift`
- `Nano Banana Helper/Services/BatchOrchestrator.swift`
- `Nano Banana HelperTests/Nano_Banana_HelperTests.swift`

Verify:

- Add persisted field/backward-compatible coding for the intended output directory path, or otherwise ensure resume can reconstruct `settings.outputDirectory` for nil-bookmark default path cases.
- Add test for `outputImagePath == ""`, `outputDirectoryBookmark == nil`, default output directory path retained on resume.

## Finding 5: Staging Thumbnails Main-Thread I/O

Evidence:

- `Nano Banana Helper/Views/StagingView.swift:68-85`: staged files render a `StagedImageCell` for each visible URL.
- `Nano Banana Helper/Views/StagingView.swift:227-252`: `thumbnail` computed property calls `AppPaths.loadImageData` and `NSImage(data:)` synchronously during body rendering.
- `Nano Banana Helper/Views/ResultsView.swift:808-960`: existing async/cached `ResultsImageLoader` uses `Task`, `NSCache`, bookmark-aware `AppPaths.withAccessibleURL`, and ImageIO `CGImageSourceCreateThumbnailAtIndex`.
- `Nano Banana Helper/Views/ProjectGalleryView.swift:101`, `205` also has a state thumbnail pattern but still uses full data loading.

Worker candidate:

- `Nano Banana Helper/Views/StagingView.swift`
- Potentially reuse/extract thumbnail loading from `Nano Banana Helper/Views/ResultsView.swift` only if Judge allows the larger scope.
- `Nano Banana HelperTests/Nano_Banana_HelperTests.swift` only if a testable loader abstraction is added.

Verify:

- Code review evidence that `StagedImageCell.body` no longer performs `Data(contentsOf:)`/`AppPaths.loadImageData` directly.
- Existing unit test command; UI perf is not directly covered by current tests.

## Recommended Worker Slices

1. Swift 6 readiness slice: model/helper nonisolated cleanup and Swift 6 override build loop.
2. Data/queue safety slice: OpenAI mask staging, last-project invariant, history resume output directory preservation, each with unit regressions.
3. Staging thumbnail slice: move staging thumbnail load off body/main path using existing Results loader pattern.

The data/queue safety slice can be split by Judge if GitNexus/verification suggests risk, but the files are mostly disjoint except the shared test file.
