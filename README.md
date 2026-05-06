# Nano Banana Helper

Nano Banana Helper is a macOS workbench for high-throughput image generation and editing with Gemini and OpenAI. It helps stage image jobs, run standard or provider-side Batch Tier workflows, track costs, recover returned outputs, and organize work by project.

![MainScreen](https://github.com/joshmac007/Nano-Banana-Helper/blob/main/MainScreen.jpeg)

![Latest Release](https://img.shields.io/github/v/release/joshmac007/Nano-Banana-Helper?color=success&label=Release)
![Version](https://img.shields.io/badge/version-2.0-blue.svg)
![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)

## Features

### Core Capabilities
- **Batch Orchestration**: Process hundreds of images concurrently with robust queue management, including pause, resume, and cancel capabilities.
- **Provider Selection**: Switch between Gemini and OpenAI in Settings, with separate API keys and model defaults for each provider.
- **Smart Staging**: Drag and drop support for individual images, masks, or entire directories.
- **Text-to-Image**: Generate images from text prompts without input images. Create 1-4 queued generations per run, with OpenAI able to return up to 4 images per request.
- **Multi-Input Mode**: Merge multiple input images into a single output using advanced prompt instructions.
- **Cost Estimation**: Real-time cost calculation based on provider, image size, count, token usage, and selected model tier.
- **Usage Analytics**: Track token usage and estimated spend over time using rich dashboard charts, filtering by session, models, or specific time ranges.
- **Model Selection**: Choose Gemini image models or OpenAI GPT Image 2 in Settings.

### Advanced Tools
- **Inspector Panel**: 
  - Fine-tune aspect ratios including panoramic (4:1, 8:1) and vertical (1:4, 1:8) formats.
  - Select output resolution (512, 1K, 2K, 4K).
  - Toggle **Batch Tier** for provider-side asynchronous processing on non-urgent jobs.
  - Configure OpenAI output format, background, input fidelity, compression, and images per request.
- **Prompt Library**: Save and reuse your most effective prompt templates.
- **History Tracking**: Comprehensive log of all jobs with parameters, costs, and status. Resumable workflows from history.
- **Result Details**: Review generated outputs with prompt metadata, system prompts, model details, output ratio, size, and tier context.

### Project Management
- **Project Gallery**: Organize work into distinct projects with isolated output directories.
- **Auto-Saving**: Active batches and application state are automatically preserved.
- **Recovered Outputs**: Returned provider images are saved into an app-managed recovery folder if the selected output folder cannot be accessed.

## Technology Stack

- **Language**: Swift 6.0
- **UI Framework**: SwiftUI
- **Concurrency**: Swift Async/Await, Actors, TaskGroups
- **Architecture**: MVVM with Observation framework (@Observable)
- **Persistence**: Directory-based storage + JSON state management

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0+ (for building from source)
- A Gemini API key, an OpenAI API key, or both

## Supported Providers and Models

| Provider | Model | Display Name | Best For |
|----------|-------|--------------|----------|
| Gemini | `gemini-3.1-flash-image-preview` | Nano Banana 2 | Speed, high-volume workflows (default Gemini option) |
| Gemini | `gemini-3-pro-image-preview` | Nano Banana Pro | Complex, high-quality image editing |
| Gemini | `gemini-2.5-flash-image` | Nano Banana | Legacy/stable Gemini workflows |
| OpenAI | `gpt-image-2` | GPT Image 2 | OpenAI generation, edits, masks, and Batch Tier |

## Installation

### Pre-built App (Recommended)

The easiest way to install Nano Banana Helper is to download the compiled version:
1. Go to the **Releases** section on the right sidebar of this GitHub repository.
2. Download the latest `Nano Banana Helper.dmg` file.
3. Open the `.dmg` and drag the app into your Applications folder.

### Build from Source (Developers)

1. **Clone the repository**
   ```bash
   git clone https://github.com/joshmac007/Nano-Banana-Helper.git
   cd Nano-Banana-Helper
   ```

2. **Open in Xcode**
   Double-click `Nano Banana Helper.xcodeproj` or run:
   ```bash
   xed .
   ```

3. **Build and Run**
   Select "Nano Banana Helper" scheme and target "My Mac". Press `Cmd+R` to build and run.

## Usage Guide

1. **Setup Provider**: On first launch, go to **Settings** (`Cmd+,`) and choose Gemini or OpenAI.
2. **Add API Key**: Enter the API key for the selected provider. You can store separate Gemini and OpenAI keys.
3. **Select Model** (optional): In Settings, choose your preferred image generation model for the active provider.
4. **Create a Project**: Use the "+" button in the gallery to start a new workspace.

### Image Mode (Edit Existing Images)
5. **Stage Images**: Drag images onto the "Drop Zone" in the Workbench. OpenAI workflows can also use a mask image.
6. **Configure**:
   - Enter your prompt in the Inspector.
   - Choose your desired resolution and aspect ratio.
   - Enable "Batch Tier" if speed is not critical.
   - For OpenAI, expand **Advanced** to set format, background, fidelity, compression, or images per request.
7. **Execute**: Click **Start Batch**. Monitor progress in the "Results" tab.

### Text Mode (Generate from Scratch)
5. **Select Text Mode**: Click "Text" in the Inspector header mode toggle.
6. **Configure**:
   - Enter your prompt in the Inspector (be descriptive about style, mood, composition).
   - Set the number of variations (1-4 images).
   - Choose resolution and aspect ratio.
   - For OpenAI, optionally request up to 4 images per API call from **Advanced**.
7. **Execute**: Click **Generate Images**. Monitor progress in the "Results" tab.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

1. Fork the project.
2. Create your feature branch (`git checkout -b feature/AmazingFeature`).
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`).
4. Push to the branch (`git push origin feature/AmazingFeature`).
5. Open a Pull Request.

## License

Distributed under the MIT License. See `LICENSE` for more information.
