import SwiftUI
import UniformTypeIdentifiers

struct NewProjectSheet: View {
    @Binding var projectName: String
    @Binding var projectDirectory: String
    @Binding var projectDirectoryBookmark: Data?
    var onCreate: () -> Void
    var onCancel: () -> Void
    
    @State private var isSelectingFolder = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Project")
                .font(.headline)
            
            VStack(alignment: .leading) {
                TextField("Project Name", text: $projectName)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    TextField("Location", text: $projectDirectory)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    
                    Button("Browse...") {
                        isSelectingFolder = true
                    }
                }
            }
            .padding()
            
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create", action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .disabled(projectName.isEmpty || projectDirectory.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .fileImporter(
            isPresented: $isSelectingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                projectDirectory = url.path
                projectDirectoryBookmark = AppPaths.bookmark(for: url)
            }
        }
    }
}
