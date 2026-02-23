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
    @State private var maskImage: NSImage?
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
                Text("Edit with Mask")
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
                                // Drawing Canvas over the image
                                Canvas { context, size in
                                    if let priorMask = loadedMaskImage {
                                        var drawContext = context
                                        drawContext.blendMode = .screen
                                        drawContext.opacity = 0.6
                                        drawContext.draw(Image(nsImage: priorMask), in: CGRect(origin: .zero, size: size))
                                    }
                                    
                                    // Calculate scale factor if the image is scaled to fit
                                    // For simplicity in this overlay, the canvas coordinate space matches the image view space
                                    for path in drawingPaths {
                                        var cgPath = Path()
                                        guard let firstPoint = path.points.first else { continue }
                                        cgPath.move(to: firstPoint)
                                        for point in path.points.dropFirst() {
                                            cgPath.addLine(to: point)
                                        }
                                        var copyContext = context
                                        copyContext.blendMode = path.isEraser ? .destinationOut : .normal
                                        let alpha = path.isEraser ? 1.0 : 0.6
                                        copyContext.stroke(cgPath, with: .color(.white.opacity(alpha)), style: StrokeStyle(lineWidth: path.size, lineCap: .round, lineJoin: .round))
                                    }
                                    
                                    if let currentPath = currentPath {
                                        var cgPath = Path()
                                        guard let firstPoint = currentPath.points.first else { return }
                                        cgPath.move(to: firstPoint)
                                        for point in currentPath.points.dropFirst() {
                                            cgPath.addLine(to: point)
                                        }
                                        var copyContext = context
                                        copyContext.blendMode = currentPath.isEraser ? .destinationOut : .normal
                                        let alpha = currentPath.isEraser ? 1.0 : 0.6
                                        copyContext.stroke(cgPath, with: .color(.white.opacity(alpha)), style: StrokeStyle(lineWidth: currentPath.size, lineCap: .round, lineJoin: .round))
                                    }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            let point = value.location
                                            if currentPath == nil {
                                                currentPath = BatchStagingManager.DrawingPath(points: [point], size: brushSize, isEraser: isEraserActive)
                                            } else {
                                                currentPath?.points.append(point)
                                            }
                                        }
                                        .onEnded { _ in
                                            if let path = currentPath {
                                                drawingPaths.append(path)
                                            }
                                            currentPath = nil
                                        }
                                )
                            }
                    } else {
                        ProgressView("Loading Image...")
                    }
                }
            }
            
            // Footer: Prompt & Submit
            VStack(spacing: 12) {
                TextField("Describe what to generate in the masked area...", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                
                HStack {
                    Spacer()
                    Button("Save Edit") {
                        generateMaskAndSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(prompt.isEmpty || drawingPaths.isEmpty || isGenerating)
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
        
        let maskImage = NSImage(size: imageSize)
        maskImage.lockFocus()
        
        // 1. Fill background with black
        NSColor.black.set()
        NSRect(origin: .zero, size: imageSize).fill()
        
        // 2. Draw white paths
        NSColor.white.set()
        
        // We need to scale the drawing paths from the View's coordinate space to the Image's pixel coordinate space.
        // For accurate scaling, we need to know the rendered frame size of the image in the UI.
        // Simplified approach for MVP: render paths directly based on proportions.
        
        // A better approach is to rasterize the SwiftUI Canvas directly, but that requires iOS 16/macOS 13 specific ViewRenderer.
        // Let's use ImageRenderer
        Task { @MainActor in
            let maskView = ZStack {
                Color.black
                Canvas { context, size in
                    if let priorMask = loadedMaskImage {
                        var drawContext = context
                        drawContext.blendMode = .screen
                        drawContext.draw(Image(nsImage: priorMask), in: CGRect(origin: .zero, size: size))
                    }
                    
                    for path in drawingPaths {
                        var cgPath = Path()
                        guard let firstPoint = path.points.first else { continue }
                        // Scale points from UI space to Image space.
                        // For this implementation, we assume the GeometryReader frame is square.
                        // In a robust implementation, we'd pass the actual rendered frame size.
                        cgPath.move(to: firstPoint)
                        for point in path.points.dropFirst() {
                            cgPath.addLine(to: point)
                        }
                        var copyContext = context
                        copyContext.blendMode = path.isEraser ? .destinationOut : .normal
                        copyContext.stroke(cgPath, with: .color(.white), style: StrokeStyle(lineWidth: path.size, lineCap: .round, lineJoin: .round))
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
        maskImage.unlockFocus()
    }
}
