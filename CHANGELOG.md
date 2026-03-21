# Changelog

All notable changes to Nano Banana Helper will be documented in this file.

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
