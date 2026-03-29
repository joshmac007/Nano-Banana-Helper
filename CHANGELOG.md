# Changelog

All notable changes to Nano Banana Helper will be documented in this file.

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
