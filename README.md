# Nano Banana Helper

Nano Banana Helper is a macOS workbench for high-throughput image generation and editing with Gemini and OpenAI. It stages image and text jobs, runs standard or provider-side Batch Tier workflows, tracks usage and cost, resumes remote work when possible, and preserves returned outputs even when the selected output folder is unavailable.

![MainScreen](https://github.com/joshmac007/Nano-Banana-Helper/blob/main/MainScreen.jpeg)

![Latest Release](https://img.shields.io/github/v/release/joshmac007/Nano-Banana-Helper?color=success&label=Release)
![Version](https://img.shields.io/badge/version-2.0-blue.svg)
![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)

## What It Does

- Batch image edits and text-to-image generations from a project workspace.
- Switch between Gemini and OpenAI with separate API keys and model selections.
- Run fast standard requests or provider-side Batch Tier jobs for non-urgent high-volume work.
- Track estimated spend, token usage, model usage, project totals, and output history.
- Resume eligible remote jobs from History or queue issue states.
- Save completed provider output into a recovery folder if the selected output folder cannot be accessed.

## Major Features

### Providers and Models

- **Gemini** support for standard and Batch Tier generation through the Gemini image models.
- **OpenAI** support for `gpt-image-2` generation, edits, masks, multi-input edits, multi-output responses, and Batch Tier.
- Provider-scoped settings for API keys, model defaults, documentation links, and pricing behavior.
- Backward-compatible migration from the older single-provider Gemini config.

### Image and Text Workflows

- Drag in individual images, masks, or folders.
- Generate images from text prompts without source files.
- Edit one image, repeat variations for one image, or merge multiple images into one output with multi-input mode.
- Use OpenAI masks for compatible edit workflows.
- Select output size and aspect ratio, including `Auto` behavior where supported.
- Use system prompts and saved prompt presets.

### OpenAI Advanced Controls

OpenAI workflows expose provider-specific options in the Inspector:

- Output format: `PNG`, `JPEG`, or `WebP`
- Background: automatic, transparent, or opaque where the selected model and format support it
- Input fidelity where supported
- Output compression for compressed formats
- Images per request, up to 4

### Batch Tier

Batch Tier follows the selected provider:

- Gemini uses Gemini `batchGenerateContent`.
- OpenAI uses the OpenAI Batch API with JSONL request generation, uploaded file references, polling, cancellation, partial result handling, and result-file parsing.

The queue stores remote identifiers so eligible failed, stalled, or interrupted provider jobs can be reconciled instead of blindly resubmitted.

### Queue and Recovery

- Pause, resume, cancel, and reconcile high-volume queues.
- Preserve active batch state across app restarts.
- Detect ambiguous submitting work on launch to avoid unsafe duplicate submissions.
- Track remote batch IDs, remote request IDs, provider, mask metadata, output directory intent, and cancellation timestamps.
- Write returned images to `Recovered Outputs` under app support if the selected output directory fails after the provider has already returned data.

### Results and History

- Browse completed and failed jobs by project.
- Open a detail viewer with full-resolution output preview, prompt and system prompt text, provider/model metadata, output ratio, size, Batch Tier context, and cost details.
- Reuse settings from prior history entries.
- Resume eligible Gemini remote jobs and OpenAI remote batches from History.

### Usage and Cost Tracking

- Gemini pricing uses model-aware per-image rates.
- OpenAI pricing uses provider-reported token usage when available.
- OpenAI estimates are approximate before completion because final usage depends on returned provider token details.
- Usage dashboard and reports include session spend, project totals, token totals, model breakdowns, and exportable cost data.

## Supported Providers and Models

| Provider | Model | Display Name | Notes |
| --- | --- | --- | --- |
| Gemini | `gemini-3.1-flash-image-preview` | Nano Banana 2 | Default Gemini option |
| Gemini | `gemini-3-pro-image-preview` | Nano Banana Pro | Higher-quality Gemini image work |
| Gemini | `gemini-2.5-flash-image` | Nano Banana | Legacy Gemini option |
| OpenAI | `gpt-image-2` | GPT Image 2 | OpenAI generation, edits, masks, and Batch Tier |

## Requirements

- macOS compatible with the current app deployment target. The checked-in Xcode project is configured with `MACOSX_DEPLOYMENT_TARGET = 26.2`.
- Xcode with Swift 6 support for building from source.
- A Gemini API key, an OpenAI API key, or both.

## Installation

### Prebuilt App

1. Open the repository's GitHub Releases page.
2. Download the latest `Nano Banana Helper.dmg`.
3. Open the DMG and drag the app into Applications.
4. On first launch, open Settings and configure Gemini, OpenAI, or both.

### Build From Source

```bash
git clone https://github.com/joshmac007/Nano-Banana-Helper.git
cd "Nano Banana Helper"
xed .
```

Select the `Nano Banana Helper` scheme and run it on My Mac.

The release DMG can be built with:

```bash
./build-dmg.sh
```

## Quick Start

1. Open Settings.
2. Choose Gemini or OpenAI.
3. Add the API key for that provider.
4. Select a model.
5. Create or select a project and output folder.
6. Choose Image mode or Text mode in the Inspector.
7. Configure prompt, system prompt, size, aspect ratio, Batch Tier, and provider-specific options.
8. Start the batch and monitor progress from the queue and Results view.

## Image Mode

Image mode edits existing images.

- Drop in one or more images.
- Use single-image variations, independent per-file processing, or multi-input merge mode.
- Add an OpenAI mask when the selected OpenAI workflow supports it.
- Start a standard request or enable Batch Tier for provider-side asynchronous processing.

Mask note: OpenAI masks must match the primary source image dimensions and format, include alpha, and stay under provider size limits. For multiple independent source files, the app avoids applying one shared mask to every source because that can invalidate the whole provider batch.

## Text Mode

Text mode generates images from prompts without input images.

- Enter a prompt and optional system prompt.
- Choose image count, size, and aspect ratio.
- With OpenAI, request up to 4 images from one request.
- Enable Batch Tier for non-urgent provider-side work.

## App Data and Recovery

The app stores user data under application support in `NanoBananaProAssistant`, including:

- `config.json` for provider and model settings
- `projects.json` and per-project metadata
- `saved_prompts.json`
- `active_batch.json` for interrupted queue recovery
- `cost_summary.json` and `usage_ledger.json`
- `Recovered Outputs/` for returned images that could not be written to the selected output folder

The app uses security-scoped bookmarks for sandboxed file and output-folder access.

## Development Notes

- Language: Swift 6.0
- UI: SwiftUI with Observation
- Architecture: MVVM-style views, models, and services
- Concurrency: async/await, actors, task groups
- Dependencies: Apple SDKs only
- Tests: Swift Testing unit coverage plus XCTest UI test target

Useful local commands:

```bash
xcodebuild -project "Nano Banana Helper.xcodeproj" -scheme "Nano Banana Helper" -destination 'platform=macOS' test MACOSX_DEPLOYMENT_TARGET=26.2
./build-dmg.sh
```

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

1. Fork the project.
2. Create a feature branch.
3. Commit focused changes with tests where practical.
4. Push the branch.
5. Open a pull request.

## License

Distributed under the MIT License. See `LICENSE` for more information.
