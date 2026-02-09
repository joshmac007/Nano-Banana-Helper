import SwiftUI

struct ResultsView: View {
    @Environment(BatchOrchestrator.self) private var orchestrator
    @Environment(ProjectManager.self) private var projectManager // Inject ProjectManager
    @State private var selectedTask: ImageTask?
    @State private var iconSize: CGFloat = 200
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar / Filter Bar
            HStack {
                Text("Recent Results")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                // Icon Size Slider
                HStack {
                    Image(systemName: "photo")
                        .font(.caption)
                    Slider(value: $iconSize, in: 100...400)
                        .frame(width: 120)
                    Image(systemName: "photo.fill")
                        .font(.caption)
                }
                .padding(.horizontal)
            }
            .padding()
            .background(.background.secondary)
            
            Divider()
            
            if orchestrator.completedJobs.isEmpty {
                ContentUnavailableView {
                    Label("No Results Yet", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Completed batch jobs will appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSize), spacing: 16)], spacing: 16) {
                        ForEach(orchestrator.completedJobs.filter { $0.projectId == projectManager.currentProject?.id }.reversed()) { task in
                            ResultCard(task: task, size: iconSize)
                                .onTapGesture {
                                    selectedTask = task
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $selectedTask) { task in
            ResultDetailView(task: task)
        }
    }
}

struct ResultCard: View {
    let task: ImageTask
    let size: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image Preview
            ZStack {
                if let path = task.outputPath,
                   let nsImage = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size * 9/16) // Default aspect ratio hint
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: size, height: size * 9/16)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
                
                // Hover overlay or status could go here
            }
            // Footer
            HStack {
                Text(task.filename)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
            }
            .padding(8)
            .background(.background.secondary)
        }
        .cornerRadius(8)
        .shadow(radius: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct ResultDetailView: View {
    let task: ImageTask
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding()
            }
            
            if let path = task.outputPath,
               let nsImage = NSImage(contentsOfFile: path) {
                
                VStack {
                    // Comparison Toggle
                    if let inputPath = task.inputPaths.first,
                       let inputImage = NSImage(contentsOfFile: inputPath) {
                        
                        ComparisonView(before: inputImage, after: nsImage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding()
                    } else {
                        // Fallback if no input available
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    }
                }
            } else {
                ContentUnavailableView("Image Not Found", systemImage: "exclamationmark.triangle")
            }
            
            HStack {
                if let path = task.outputPath {
                     Button("Open File") {
                         NSWorkspace.shared.open(URL(fileURLWithPath: path))
                     }
                     .buttonStyle(.bordered)
                     
                     Button("Show in Finder") {
                         NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                     }
                     .buttonStyle(.bordered)
                }
            }
            .padding(.bottom)
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

struct ComparisonView: View {
    let before: NSImage
    let after: NSImage
    @State private var sliderValue: CGFloat = 0.5
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background (After Image)
                Image(nsImage: after)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                
                // Foreground (Before Image) - Masked
                Image(nsImage: before)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: geometry.size.width * sliderValue)
                            Spacer()
                        }
                    )
                
                // Slider Handle
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .overlay(
                        Circle()
                            .fill(.white)
                            .frame(width: 24, height: 24)
                            .shadow(radius: 2)
                            .overlay(
                                Image(systemName: "chevron.left.chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.black)
                            )
                    )
                    .position(x: geometry.size.width * sliderValue, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let location = value.location.x
                                sliderValue = min(max(location / geometry.size.width, 0), 1)
                            }
                    )
                
                // Labels
                VStack {
                    Spacer()
                    HStack {
                        Text("Original")
                            .font(.caption)
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)
                            .opacity(sliderValue > 0.1 ? 1 : 0)
                        
                        Spacer()
                        
                        Text("Result")
                            .font(.caption)
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)
                            .opacity(sliderValue < 0.9 ? 1 : 0)
                    }
                    .padding()
                }
            }
        }
        .background(Color.black.opacity(0.1))
    }
}
