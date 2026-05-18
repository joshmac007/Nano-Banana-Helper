# Changelog

All notable changes to Nano Banana Helper will be documented in this file.

## [2.0] - 2026-05-17

Version 2.0 is the multi-provider release. The app moves from a Gemini-focused batch workbench into a Gemini and OpenAI image operations tool with OpenAI `gpt-image-2`, provider-side Batch Tier support, stronger recovery, Swift 6 project settings, and broader regression coverage.

Release boundary reviewed: `v1.4.2..0af3507`, covering 40 tracked files with 9,094 insertions and 766 deletions. One untracked local file, `docs/complexity-diagram.html`, was present during review and is not included in this release summary unless it is intentionally added.

### Added
- **OpenAI provider support**: Settings now supports Gemini and OpenAI as first-class providers, with provider selection, separate API keys, separate model selections, provider documentation links, and backward-compatible migration from the old single Gemini config.
- **GPT Image 2 workflows**: Added OpenAI `gpt-image-2` support for text-to-image generation, image editing, multi-input edits, masks, and multi-output responses.
- **OpenAI advanced controls**: The Inspector now exposes OpenAI output format (`PNG`, `JPEG`, `WebP`), background handling where supported, input fidelity, output compression, and images per request.
- **OpenAI Batch Tier**: Batch Tier now routes OpenAI work through the OpenAI Batch API, including request JSONL generation, file upload handling, batch creation, status polling, cancellation, result-file download, and batch result parsing.
- **Provider-aware remote identity**: Queue, history, and result records now persist provider, remote batch ID, remote request ID, remote batch provider, OpenAI advanced settings, mask metadata, and cancellation timestamps.
- **OpenAI history resume**: OpenAI remote batches can be resumed from History and active queue issue states when both remote batch ID and remote request ID are available.
- **Recovered Outputs folder**: Returned provider images are preserved in an app-managed `Recovered Outputs` directory if the selected output folder cannot be accessed at completion time.
- **Output directory preservation for resumed history**: History entries now preserve the intended output directory path so resumed remote jobs do not unnecessarily fall back to app-support output paths.
- **Result detail viewer**: Results now include a richer detail popup with full-resolution viewing, generation metadata, prompt and system-prompt text, provider/model details, output ratio, size, tier context, and output actions.
- **Async staging thumbnails**: Staged image thumbnails now load asynchronously through a bookmark-aware ImageIO thumbnail path instead of reading full image data during SwiftUI rendering.
- **Goal and release documentation**: Added release notes and audit-fix documentation under `docs/releases/`, `docs/goals/`, and `docs/superpowers/plans/`.

### Changed
- **Provider-aware pricing**: Pricing now handles Gemini per-image rates and OpenAI token-based usage. OpenAI preflight estimates are labeled approximate until provider-reported usage is returned.
- **OpenAI usage accounting**: OpenAI costs now use returned text/image token usage when available, with aggregate-token fallback behavior when detailed token fields are absent.
- **Model catalog**: The curated model list now includes Gemini image models and OpenAI `gpt-image-2`, provider-scoped defaults, masking capability labels, Batch Tier support flags, and legacy selected-model preservation.
- **Batch Tier semantics**: The Batch Tier toggle now maps to the active provider: Gemini uses `batchGenerateContent`; OpenAI uses the OpenAI Batch API.
- **Queue recovery model**: The queue now tracks richer control and task phases including local pause, remote submission, reconnecting, cancel requested, stalled, expired, and terminal cancellation states.
- **Cancellation UX**: Cancelled, cancelling, stalled, expired, and locally paused jobs now report clearer status messages while remote state is being reconciled.
- **OpenAI aspect sizing**: OpenAI edit requests with `Auto` aspect now infer size from the source image aspect while preserving the selected output size tier.
- **Mask behavior**: Shared OpenAI masks are preserved for one source or merged multi-input work, but dropped for multiple independent per-file tasks where one shared mask could poison the batch.
- **Bottom dock spend summary**: The queue dock now reports selected-project spend when session spend is empty instead of falling back to an unrelated global total.
- **Cost estimator explanation**: Projected-cost explanatory copy has been moved into contextual help instead of occupying the visible pricing row.
- **Swift project configuration**: App and test targets are now promoted to Swift 6.0 project settings.
- **Build script**: DMG build cleanup was tightened to reduce stale build artifact issues.

### Fixed
- **Gemini batch auth after provider switch**: Gemini batch polling and cancellation continue to use the Gemini API key path even after multi-provider settings were introduced.
- **OpenAI Batch result replay**: OpenAI batch result parsing now scopes result lines to expected custom IDs and skips unexpected rows so replay does not duplicate terminal local jobs.
- **OpenAI duplicate completion accounting**: Replayed or repeated OpenAI results do not create duplicate completion side effects for already-terminal tasks.
- **OpenAI partial success handling**: Batch result parsing now preserves success and failure rows separately so partial results can be applied without flattening the whole batch into a generic failure.
- **OpenAI resume identity rules**: OpenAI history rows now require both remote batch ID and remote request ID before advertising Resume or Rescue actions.
- **Timed-out cancellation recovery**: Launch recovery finalizes stale cancellation rows locally instead of leaving them indefinitely in cancelling state.
- **Interrupted queue recovery**: Launch recovery now separates terminal-only queues, resumable remote polling states, and ambiguous submitting tasks so the app avoids unsafe duplicate submission.
- **Output write failures**: If the primary output directory fails after an API response is already returned, completed image bytes are written to recovery storage and the history/ledger entry records that fallback.
- **Last-project deletion**: Project deletion now refuses to remove the final project and repairs `currentProject` when possible. Settings also disables the final-project delete action.
- **Security-scoped access**: Input, mask, source, and output bookmarks are refreshed and preserved in more queue and history paths.
- **OpenAI mask validation**: Mask handling now validates file size, dimensions, format, and alpha-channel requirements before OpenAI edit submission.
- **OpenAI aspect ratio guardrails**: Extreme aspect ratios that OpenAI does not support are rejected with guidance instead of being sent to the provider.

### Technical
- Added or expanded focused regression coverage for provider config migration, provider/model pricing, OpenAI token usage pricing, provider metadata persistence, OpenAI response parsing, multi-output persistence, recovery output writes, OpenAI Batch request construction, Batch result parsing, replay protection, remote resume, cancellation normalization, last-project deletion, output directory preservation, mask propagation, and Swift 6 readiness.
- The unit test file now contains 137 Swift Testing `@Test` entries.
- Promoted `SWIFT_VERSION` to `6.0` across the Xcode project and kept `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for app targets.
- Added `CONTEXT.md` for project language around providers, local queue semantics, remote batch identity, OpenAI Batch Tier, and recovery behavior.
- Regenerated the release DMG during the v2 work.

## [1.4.2] - 2026-04-12

### Added
- **Persistent Usage Ledger**: Usage tracking now backed by a persistent ledger system that records every batch operation and cost transaction, with support for manual adjustments and reconciliation.
- **Usage Snapshot Builder**: Create point-in-time snapshots of usage data with advanced filtering by date, project, model, and resolution for detailed reporting and analysis.
- **Resizable Queue Drawer**: Queue visualization can now be dynamically resized by dragging, with automatic layout adjustment and improved section headers for better workflow control.

### Changed
- **Request Diagnostics**: All API requests (batch and standard) now emit structured diagnostic logs with timing, status, retry attempts, and detailed error information for improved debuggability.
- **Logging Architecture**: Replaced ad-hoc logging with unified structured logging integrated into existing LogManager for cleaner, more parseable session output.
- **Session Tracking**: Ledger-based session cost tracking replaces previous ad-hoc recording for more accurate usage aggregation and transparency.

### Fixed
- Improved consistency of usage tracking across batch submissions, polling, and image downloads.
- Enhanced queue state recovery with better persistence semantics during high-throughput operations.
- Stabilized concurrent ledger writes during simultaneous batch operations.

### Technical
- Added comprehensive unit tests for ledger filtering, reporting, and snapshot generation.
- Implemented atomic append operations for thread-safe ledger access.
- Backward-compatible migration of existing cost data to ledger format on first launch.

## [1.4.0] - 2026-04-04

### Added
- **Batch Task Controls**: Implemented full pause, resume, and cancel workflow capabilities with accurate UI state management and job tracking.
- **Usage Dashboard Charts**: Enhanced the Usage tab with real-time visual charts to map Spend Over Time, Images Over Time, and usage broken down by models and resolutions.
- **Model Catalog Engine**: Replaced static model parsing with dynamic compatibility fetching from API responses, seamlessly integrating legacy fallback states.
- **File Reordering**: Support for file reordering within the Batch Staging View.

### Changed
- **Centralized & Model-Aware Pricing**: Pricing is now centrally managed by an `AppPricing` engine and integrated across batch orchestration for accurate, real-time projections.
- **Progress Queue UI**: Simplified the progress queue empty state by cleaning up text labels for a more elegant interface.
- **Results View Layout**: Replaced the continuous size slider with a discrete grid column setting for Results. Result cards now use a uniform layout with centered, fit-to-fill crops.
- **Image Loader Orchestration**: `ResultsView` image loading migrated to use `ResultsImageLoader` for coalescing repetitive requests and deduping duplicate in-flight data constraints. Loading states are explicit to remove visual flash.

### Fixed
- **Project Data Persistence**: Fixed issues causing project history and image results to momentarily vanish upon tab switching or app relaunch.
- **Startup Queue Recovery**: Implemented robust recovery and normalized queue states for resuming or clearing interrupted tasks upon application launch.
- **Swift 6 Concurrency**: Resolved actor-isolation warnings and stabilized the test suite by utilizing explicit `@MainActor` annotations.
- **Thumbnail Memory & Performance**: Added proper `ImageIO` thumbnail downsampling for results to dramatically improve scrolling performance and memory footprint over decoding true full-resolution variants.
- **Bookmark Persistence**: Fixed deep macOS sandboxing reauthorization loops surrounding the Output Folder logic by introducing a new `BookmarkAccessDeniedView` and generic URL access helpers (`AppPaths`).

## [1.3.5] - 2026-03-30

### Added
- **Prompts Management View**: Full-featured preset management page in Settings > Prompts, replacing the bare card grid
  - Search presets by name or prompt content
  - Sort by name, date created, or last modified
  - Create new presets with the "+" toolbar button
  - Edit presets via single-click selection + Edit toolbar button, or context menu
  - Keyboard shortcut: Return to edit selected preset
  - Duplicate presets from context menu
  - Set/remove project default preset from context menu
  - Delete presets with confirmation alert
  - Preset rows show: name, user prompt preview (or purple "System prompt only" badge), system prompt indicator, relative timestamp, and gold star for project defaults
  - Collapsible system prompt section in the edit sheet with purple accent

### Changed
- **Settings Tab Routing**: Settings opens to the correct tab via atomic `.sheet(item:)` pattern — sidebar Settings icon opens to API, "Manage All..." opens to Prompts
- **"Manage All..." Menu Entry**: Now reliably opens Settings to the Prompts tab via NotificationCenter bridge (previously called an unresponsive `NSApp.sendAction`)
- **SettingsView**: Removed outer ScrollView and ~140 lines of inline preset code — each tab manages its own scrolling, presets handled by dedicated `PromptsManagementView`

### Fixed
- **System-Only Presets Lost Menu Actions**: Presets with only a system prompt (empty userPrompt) wouldn't show Edit/Duplicate/Delete/Set Default in the presets dropdown menu — fixed guard to check both prompt fields
- **Preset List Rows Not Selectable**: Missing `.tag()` on list rows prevented SwiftUI `List(selection:)` from mapping clicks to the selection binding — added explicit tags
- **Prompts Tab Rendering**: Nested scrollable containers (`List` inside `ScrollView`) caused NSTableView rendering conflicts on macOS — presets now render correctly

## [1.3.4] - 2026-03-29

### Changed
- **Prompt UI Redesign**: Complete overhaul of the prompt management interface
  - **Prompt Bar**: Compact preview bar in Inspector replaces cramped inline TextEditors — click to edit, dropdown for presets
  - **Edit Sheet**: Focused full-size editing sheet with collapsible system prompt section and inline "Save as Preset" footer
  - **Preset Menu**: Native macOS dropdown menu replaces custom popover — load, edit, duplicate, set default, delete presets
  - **Settings Simplified**: Flat preset card grid replaces tag sidebar layout

### Removed
- **Tag System**: Removed tags from presets entirely — unnecessary complexity for a 5-15 preset library
- `PromptPresetPopover` — replaced by native Menu in PromptBarView
- `SavePresetSheet` — replaced by inline save in PromptEditSheet
- Tag CRUD methods from `PromptLibrary` (`addTag`, `removeTag`, `renameTag`)
- Tag sidebar, tag alerts, and tag filtering from Settings

## [1.3.3] - 2026-03-29

### Added
- **Prompt Presets**: Prompts are now saved as bundled pairs (user + system prompt) instead of separate templates
  - New `PromptPreset` data model replaces `SavedPrompt` / `PromptType`
  - Saves both user and system prompt together with optional tags and timestamps
- **Tag System**: Curated tags for organizing presets
  - Create, rename, and delete tags from Settings > Prompts
  - Filter presets by tag in both the Inspector popover and Settings
  - Assign tags when saving presets
- **Preset Library Popover**: New popover browser accessible from the Inspector bookmark icon
  - Search presets by name or prompt content (case-insensitive)
  - Horizontal tag filter chips
  - Context menu: Load, Edit, Duplicate, Delete, Set as Project Default
  - Inline editing for quick name and prompt changes
  - Star indicator for project default preset
- **Project Default Preset**: Projects can have a default preset that auto-loads on project switch
  - "Set as Project Default" option in popover context menu
  - Auto-loads user and system prompt when switching projects
- **Save Preset Sheet**: New modal sheet for saving presets with name field and tag selection
- **Settings > Prompts Tab Redesign**: Split layout with tag sidebar and adaptive preset card grid
  - Tag sidebar with preset counts and right-click context menu (rename/delete)
  - Preset cards showing name, prompt preview, system prompt indicator, tags, and timestamp
  - Edit sheet for full preset editing (name, user prompt, system prompt, tags)

### Changed
- **Inspector Prompt Section**: Stacked TextEditors replace the old tabbed User/System toggle
  - Both user and system prompt editors are always visible simultaneously
  - Placeholder text overlays on empty editors
  - Max height increased from 120pt to 160pt per editor
  - Bookmark icon opens popover browser instead of dropdown menu
  - Save button uses standard SF Symbol instead of custom FloppyIcon
- `PromptLibrary` now uses v2 persistence format (`{version: 2, tags: [...], presets: [...]}`)
- `promptLibrary` is now injected via `.environment()` in the main view hierarchy

### Fixed
- **System Prompt Data Loss**: System prompt is now recorded in history entries and restored on reuse
  - Added `systemPrompt: String?` to `HistoryEntry` with backward-compatible Codable
  - All 4 HistoryEntry creation sites in `BatchOrchestrator` now pass system prompt
  - "Reuse Settings" in history now restores both user and system prompt
  - History list displays system prompt with purple indicator
- **V1 Migration**: Existing `saved_prompts.json` files (old `[SavedPrompt]` array format) automatically migrate to the new v2 `PromptPreset` format, merging same-named user/system pairs

### Removed
- `PromptType` enum (replaced by unified `PromptPreset`)
- `SavedPrompt` struct (replaced by `PromptPreset`)
- `FloppyIcon` custom Canvas view (replaced by SF Symbol `square.and.arrow.down`)
- `PromptLibrary.userPrompts` and `.systemPrompts` computed properties (no longer needed)

## [1.3.2] - 2026-03-29

### Added
- **Billing & Usage Tracking**: Real token usage captured from Gemini API `usageMetadata` responses
  - `TokenUsage` struct stored on each `HistoryEntry` with prompt/candidates/total token counts
  - Model name recorded per history entry
- **Session Spend Indicator**: Bottom dock shows live session cost during batch processing, or total spend when idle
- **Usage Dashboard**: New "Usage" tab in Settings with:
  - Current session stats (cost, tokens, image count)
  - Time-filtered history (Today / 7 Days / 30 Days / All Time)
  - Token breakdown (input vs output)
  - Cost breakdown by model, resolution, and project
  - CSV export with model and token columns
- **Cost Report Enhancements**: "By Model" section, token usage summary card, billing disclaimer

### Changed
- `CostSummary.record()` now accepts optional `tokens` and `modelName` parameters (backward compatible)
- `HistoryEntry` extended with optional `tokenUsage` and `modelName` fields (backward compatible)
- CSV export includes Model, InputTokens, OutputTokens columns
- `BottomDockView` now displays spend indicator from `ProjectManager`

### Fixed
- **Xcode Project Configuration**: Fixed `SDKROOT` from `iphoneos` to `macosx`, removed stray `IPHONEOS_DEPLOYMENT_TARGET` and `TARGETED_DEVICE_FAMILY` from all targets, unified `DEVELOPMENT_TEAM` across targets, added explicit `MACOSX_DEPLOYMENT_TARGET`, created proper `.xcscheme` with test targets

## [1.3.1] - 2026-03-22

### Fixed
- **Critical**: Resolved infinite recursion crash when adjusting image count in Text-to-Image mode
  - Root cause: `@Observable` macro transforms stored properties into computed properties routed through `ObservationRegistrar.withMutation`. Re-assigning the observed property inside a property observer (`willSet` or `didSet`) re-enters the computed setter, causing stack overflow
  - Fix: Removed the property observer entirely; the existing `.disabled()` button guards in InspectorView already prevent out-of-range values

### Technical
- Removed unsafe `willSet` observer from `BatchStagingManager.textImageCount`

## [1.3.0] - 2026-03-22

### Added
- **Text-to-Image Generation**: New generation mode that creates images from text prompts without requiring input images
  - Mode toggle (Image/Text) in Inspector header
  - Variations selector: Generate 1-4 images per request
  - Text mode view in Staging area with helpful prompt tips
  - Output cost only (no input image cost)

### Changed
- **Conditional UI**: Multi-Input toggle is now hidden in Text mode
- **Button Text**: Dynamic button text based on mode ("Start Batch" / "Generate N Images")
- **Output Naming**: Text mode generates unique filenames: `generated_YYYYMMDD_HHMMSS_<uuid8>.png`

### Technical
- Added `GenerationMode` enum with `Sendable` conformance
- Added `textImageCount` property with UI range guards
- Added `isReadyForGeneration` computed property for mode-aware validation
- Added `ImageEditRequest.textOnly()` convenience method
- Added `enqueueTextGeneration()` to `BatchOrchestrator`
- Added `BatchJob.isTextMode` with full Codable support
- Added `ImageSize.calculateTextModeCost()` static method
- Created `Constants.swift` for shared constants

## [1.2.0] - 2026-03-21

### Fixed
- **Critical**: Resolved 400 INVALID_ARGUMENT errors caused by `gemini-3-pro-preview` model being shut down on March 9, 2026
- Default model updated to `gemini-3.1-flash-image-preview` (Nano Banana 2)

### Added
- **Model Selection UI**: Users can now choose between multiple Gemini image models in Settings:
  - `gemini-3.1-flash-image-preview` (Nano Banana 2) - Default, optimized for speed
  - `gemini-2.5-flash-image-preview` (Nano Banana) - Stable option
  - `gemini-3-pro-image-preview` (Nano Banana Pro) - Legacy option
- **512 Resolution**: Added support for 512px output resolution (available on Gemini 3.1 Flash Image)
- **New Aspect Ratios**: Added panoramic/vertical ratios for Gemini 3.1:
  - `4:1` and `8:1` (ultra-wide landscape)
  - `1:4` and `1:8` (ultra-tall portrait)

### Changed
- **Centralized Pricing**: Cost calculations now use a single `ImageSize` enum to ensure consistency across all cost displays
- Pricing for 512 resolution: $0.034 standard / $0.017 batch tier

### Technical
- Added `ImageSize` enum in `Models.swift` with `calculateCost()` static method
- Added `setModelName()` and `getModelName()` methods to `NanoBananaService`
- Updated `CostEstimatorView`, `BatchSettings`, and `BatchJob` to use centralized pricing

## [1.1.0] - 2026-02-13

### Added
- Improved image loading and display
- Enhanced API robustness with config thread safety
- Correct aspect ratio handling
- Batch job submission throttling

### Changed
- Implemented security-scoped bookmarks for persistent file access
- Generate unique output filenames
