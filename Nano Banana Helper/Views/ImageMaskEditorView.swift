import SwiftUI
import AppKit

struct ImageMaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    
    let inputImageURL: URL
    let inputBookmark: Data? // Added for security-scoped resource access
    let initialPaths: [BatchStagingManager.DrawingPath]?
    let initialPrompt: String?
    let initialMaskData: Data?
    let onSaveMask: (Data, String, [BatchStagingManager.DrawingPath]) -> Void // Returns mask data, prompt, and paths
    
    @State private var baseImage: NSImage?
    @State private var loadedMaskImage: NSImage?
    @State private var drawingPaths: [BatchStagingManager.DrawingPath] = []
    @State private var currentPath: BatchStagingManager.DrawingPath?
    
    @State private var brushSize: Double = 30
    @State private var isEraserActive: Bool = false
    @State private var prompt: String = ""
    @State private var isGenerating: Bool = false
    
    // Convert NSImage to SwiftUI Image
    private var displayImage: Image? {
        if let baseImage = baseImage {
            return Image(nsImage: baseImage)
        }
        return nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Region Edit (Gemini)")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            // Toolbar
            HStack {
                Text("Brush Size:")
                Slider(value: $brushSize, in: 5...100)
                    .frame(width: 150)
                
                // Hidden buttons for keyboard shortcuts
                Button("") { brushSize = max(5, brushSize - 5) }
                    .keyboardShortcut("[", modifiers: [])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                
                Button("") { brushSize = min(100, brushSize + 5) }
                    .keyboardShortcut("]", modifiers: [])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                
                Spacer()
                
                Picker("Tool", selection: $isEraserActive) {
                    Text("Brush").tag(false)
                    Text("Eraser").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                
                Button(action: {
                    if !drawingPaths.isEmpty {
                        drawingPaths.removeLast()
                    }
                }) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(drawingPaths.isEmpty)
                
                Button(action: {
                    drawingPaths.removeAll()
                }) {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(drawingPaths.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            
            // Canvas Area
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.1)
                    
                    if let image = displayImage {
                        image
                            .resizable()
                            .scaledToFit()
                            .overlay {
                                GeometryReader { overlayGeo in
                                    let overlaySize = overlayGeo.size
                                    let previewImageRect = fittedImageRect(in: overlaySize)
                                    Canvas { context, size in
                                        let imageRect = fittedImageRect(in: size)
                                        if let priorMask = loadedMaskImage {
                                            var drawContext = context
                                            drawContext.blendMode = .screen
                                            drawContext.opacity = 0.6
                                            drawContext.draw(Image(nsImage: priorMask), in: imageRect)
                                        }

                                        for path in drawingPaths {
                                            draw(path: path, in: size, imageRect: imageRect, using: context, alpha: path.isEraser ? 1.0 : 0.6)
                                        }

                                        if let currentPath = currentPath {
                                            draw(path: currentPath, in: size, imageRect: imageRect, using: context, alpha: currentPath.isEraser ? 1.0 : 0.6)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { value in
                                                guard let normalizedPoint = normalizePoint(value.location, in: previewImageRect) else { return }
                                                let normalizedBrush = normalizedBrushSize(for: previewImageRect.size)
                                                if currentPath == nil {
                                                    currentPath = BatchStagingManager.DrawingPath(
                                                        points: [normalizedPoint],
                                                        size: normalizedBrush,
                                                        isEraser: isEraserActive
                                                    )
                                                } else {
                                                    currentPath?.points.append(normalizedPoint)
                                                    currentPath?.size = normalizedBrush
                                                    currentPath?.isEraser = isEraserActive
                                                }
                                            }
                                            .onEnded { _ in
                                                if let path = currentPath, !path.points.isEmpty {
                                                    drawingPaths.append(path)
                                                }
                                                currentPath = nil
                                            }
                                    )
                                }
                            }
                    } else {
                        ProgressView("Loading Image...")
                    }
                }
            }
            
            // Footer: Prompt & Submit
            VStack(spacing: 12) {
                TextField("Describe the edit for the selected region...", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                
                HStack {
                    Spacer()
                    Button("Save Edit") {
                        generateMaskAndSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || drawingPaths.isEmpty || isGenerating)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 750)
        .onAppear {
            if let initialPaths = initialPaths {
                drawingPaths = initialPaths
            }
            if let initialPrompt = initialPrompt {
                prompt = initialPrompt
            }
            loadImage()
        }
    }
    
    private func loadImage() {
        if let initialData = initialMaskData {
            self.loadedMaskImage = NSImage(data: initialData)
        }
        
        // Try direct load first (works for drag-and-drop and accessible paths)
        if let image = NSImage(contentsOfFile: inputImageURL.path) {
            self.baseImage = image
            return
        }
        
        // Try resolving via bookmark
        if let data = inputBookmark {
            let image = AppPaths.withResolvedBookmark(data) { resolvedURL in
                return NSImage(contentsOfFile: resolvedURL.path)
            }?.flatMap { $0 }
            
            if let img = image {
                self.baseImage = img
            }
        }
    }
    
    private func generateMaskAndSave() {
        guard let baseImage = baseImage else { return }
        isGenerating = true
        
        // Render the mask off-screen
        // The mask needs to be the exact pixel dimensions of the original image
        let imageSize = baseImage.size
        
        Task { @MainActor in
            let maskView = ZStack {
                Color.black
                Canvas { context, size in
                    let fullImageRect = CGRect(origin: .zero, size: size)
                    if let priorMask = loadedMaskImage {
                        var drawContext = context
                        drawContext.blendMode = .screen
                        drawContext.draw(Image(nsImage: priorMask), in: fullImageRect)
                    }
                    
                    for path in drawingPaths {
                        draw(path: path, in: size, imageRect: fullImageRect, using: context, alpha: 1.0)
                    }
                }
            }
            .frame(width: imageSize.width, height: imageSize.height) // Render at true image resolution
            
            let renderer = ImageRenderer(content: maskView)
            renderer.proposedSize = .init(width: imageSize.width, height: imageSize.height)
            
            if let nsImage = renderer.nsImage,
               let tiffData = nsImage.tiffRepresentation,
               let bitmapImage = NSBitmapImageRep(data: tiffData),
               let pngData = bitmapImage.representation(using: .png, properties: [:]) {
                
                onSaveMask(pngData, prompt, drawingPaths)
                dismiss()
            } else {
                isGenerating = false
                print("Failed to generate mask image data")
            }
        }
    }

    private func fittedImageRect(in containerSize: CGSize) -> CGRect {
        guard
            let baseImage = baseImage,
            containerSize.width > 0,
            containerSize.height > 0,
            baseImage.size.width > 0,
            baseImage.size.height > 0
        else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let imageAspect = baseImage.size.width / baseImage.size.height
        let containerAspect = containerSize.width / containerSize.height

        if imageAspect > containerAspect {
            let width = containerSize.width
            let height = width / imageAspect
            return CGRect(
                x: 0,
                y: (containerSize.height - height) / 2,
                width: width,
                height: height
            )
        } else {
            let height = containerSize.height
            let width = height * imageAspect
            return CGRect(
                x: (containerSize.width - width) / 2,
                y: 0,
                width: width,
                height: height
            )
        }
    }

    private func normalizePoint(_ point: CGPoint, in imageRect: CGRect) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        guard imageRect.contains(point) else { return nil }
        let x = (point.x - imageRect.minX) / imageRect.width
        let y = (point.y - imageRect.minY) / imageRect.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func denormalizePoint(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + (point.x * imageRect.width),
            y: imageRect.minY + (point.y * imageRect.height)
        )
    }

    private func normalizedBrushSize(for canvasSize: CGSize) -> CGFloat {
        let base = max(1, min(canvasSize.width, canvasSize.height))
        return CGFloat(brushSize) / base
    }

    private func lineWidth(for path: BatchStagingManager.DrawingPath, in canvasSize: CGSize) -> CGFloat {
        let base = max(1, min(canvasSize.width, canvasSize.height))
        let candidate = path.size * base
        // Backward-compat fallback: older in-memory paths may have absolute pixel widths.
        if path.size > 1 { return path.size }
        return max(1, candidate)
    }

    private func draw(
        path: BatchStagingManager.DrawingPath,
        in canvasSize: CGSize,
        imageRect: CGRect,
        using context: GraphicsContext,
        alpha: Double
    ) {
        guard let firstPoint = path.points.first else { return }
        let usesNormalizedPoints = path.points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
        var cgPath = Path()
        let startPoint = usesNormalizedPoints ? denormalizePoint(firstPoint, in: imageRect) : firstPoint
        cgPath.move(to: startPoint)
        for point in path.points.dropFirst() {
            let drawPoint = usesNormalizedPoints ? denormalizePoint(point, in: imageRect) : point
            cgPath.addLine(to: drawPoint)
        }
        var copyContext = context
        copyContext.blendMode = path.isEraser ? .destinationOut : .normal
        copyContext.stroke(
            cgPath,
            with: .color(.white.opacity(alpha)),
            style: StrokeStyle(
                lineWidth: lineWidth(for: path, in: imageRect.size),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
}
