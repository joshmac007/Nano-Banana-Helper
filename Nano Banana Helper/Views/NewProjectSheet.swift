import SwiftUI
import UniformTypeIdentifiers

struct NewProjectSheet: View {
    @Binding var projectName: String
    var onCreate: (URL, Data?) -> Void
    var onCancel: () -> Void
    
    @State private var isSelectingFolder = false
    @State private var selectedURL: URL?
    @State private var selectedBookmark: Data?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Project")
                .font(.headline)
            
            VStack(alignment: .leading) {
                TextField("Project Name", text: $projectName)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    TextField("Location", text: .constant(selectedURL?.path ?? ""))
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
                Button("Create") {
                    guard let selectedURL else { return }
                    onCreate(selectedURL, selectedBookmark)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(projectName.isEmpty || selectedURL == nil)
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
                selectedURL = url
                selectedBookmark = AppPaths.bookmark(for: url)
            }
        }
    }
}
