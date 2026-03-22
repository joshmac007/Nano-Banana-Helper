# Nano Banana Helper 🍌

Nano Banana Helper is a powerful macOS application for batch processing image edits using Google's generative AI (Gemini). It allows users to orchestrate complex image transformation workflows, manage costs, and organize projects efficiently.

![MainScreen](https://github.com/joshmac007/Nano-Banana-Helper/blob/main/MainScreen.jpeg)

![Version](https://img.shields.io/badge/version-1.3.0-blue.svg)
![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)

## Features

### 🚀 Core Capabilities
- **Batch Orchestration**: Process hundreds of images concurrently with robust queue management.
- **Smart Staging**: Drag and drop support for individual images or entire directories.
- **Text-to-Image**: Generate images from text prompts without input images. Create 1-4 variations per request.
- **Multi-Input Mode**: Merge multiple input images into a single output using advanced prompt instructions.
- **Cost Estimation**: Real-time cost calculation based on image size, count, and selected model tier.
- **Model Selection**: Choose between Nano Banana 2 (fastest), Nano Banana (stable), or Nano Banana Pro (highest quality) in Settings.

### 🛠️ Advanced Tools
- **Inspector Panel**: 
  - Fine-tune aspect ratios including panoramic (4:1, 8:1) and vertical (1:4, 1:8) formats.
  - Select output resolution (512, 1K, 2K, 4K).
  - Toggle **Batch Tier** for 50% cost savings on non-urgent jobs.
- **Prompt Library**: Save and reuse your most effective prompt templates.
- **History Tracking**: Comprehensive log of all jobs with parameters, costs, and status. Resumable workflows from history.

### 🏗️ Project Management
- **Project Gallery**: Organize work into distinct projects with isolated output directories.
- **Auto-Saving**: Active batches and application state are automatically preserved.

## Technology Stack

- **Language**: Swift 6.0
- **UI Framework**: SwiftUI
- **Concurrency**: Swift Async/Await, Actors, TaskGroups
- **Architecture**: MVVM with Observation framework (@Observable)
- **Persistence**: Directory-based storage + JSON state management

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0+ (for building from source)
- A Google Cloud Project with Vertex AI / Gemini API access

## Supported Models

| Model | Display Name | Best For |
|-------|--------------|----------|
| `gemini-3.1-flash-image-preview` | Nano Banana 2 | Speed, high-volume workflows (default) |
| `gemini-2.5-flash-image-preview` | Nano Banana | Stable, reliable image generation |
| `gemini-3-pro-image-preview` | Nano Banana Pro | Complex, multi-turn image editing |

## Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/froggeric/Nano-Banana-Helper.git
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

1. **Setup API Key**: On first launch, go to **Settings** (`Cmd+,`) and enter your Gemini API Key.
2. **Select Model** (optional): In Settings, choose your preferred image generation model.
3. **Create a Project**: Use the "+" button in the gallery to start a new workspace.

### Image Mode (Edit Existing Images)
4. **Stage Images**: Drag images onto the "Drop Zone" in the Workbench.
5. **Configure**: 
   - Enter your prompt in the Inspector.
   - Choose your desired resolution and aspect ratio.
   - Enable "Batch Tier" if speed is not critical to save costs.
6. **Execute**: Click **Start Batch**. Monitor progress in the "Results" tab.

### Text Mode (Generate from Scratch)
4. **Select Text Mode**: Click "Text" in the Inspector header mode toggle.
5. **Configure**: 
   - Enter your prompt in the Inspector (be descriptive about style, mood, composition).
   - Set the number of variations (1-4 images).
   - Choose resolution and aspect ratio.
6. **Execute**: Click **Generate Images**. Monitor progress in the "Results" tab.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

1. Fork the project.
2. Create your feature branch (`git checkout -b feature/AmazingFeature`).
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`).
4. Push to the branch (`git push origin feature/AmazingFeature`).
5. Open a Pull Request.

## License

Distributed under the MIT License. See `LICENSE` for more information.
