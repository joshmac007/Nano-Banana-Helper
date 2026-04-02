import AppKit
import SwiftUI

struct BookmarkAccessDeniedView: View {
    let message: String
    let onReauthorize: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Grant Access…") {
                onReauthorize()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

enum BookmarkReauthorization {
    enum OutputFolderReauthorizationResult: Equatable {
        case success
        case cancelled
        case wrongFolderSelected
        case bookmarkCreationFailed
    }

    @discardableResult
    static func reauthorizeOutputFolder(
        for project: Project,
        projectManager: ProjectManager,
        historyManager: HistoryManager,
        selectedURLOverride: URL? = nil,
        panelFactory: () -> NSOpenPanel = { NSOpenPanel() },
        runModal: (NSOpenPanel) -> NSApplication.ModalResponse = { $0.runModal() },
        bookmarkCreator: (URL) -> Data? = AppPaths.bookmark(for:),
        showError: (String) -> Void = { message in
            let alert = NSAlert()
            alert.messageText = "Folder Access Not Updated"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    ) -> OutputFolderReauthorizationResult {
        let panel = panelFactory()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.outputDirectory)
        panel.message = "Re-select the existing output directory for \(project.name)"
        panel.prompt = "Grant Access"

        let selectedURL: URL
        if let selectedURLOverride {
            selectedURL = selectedURLOverride
        } else {
            guard runModal(panel) == .OK, let panelURL = panel.url else {
                return .cancelled
            }
            selectedURL = panelURL
        }

        guard selectedURL.path == project.outputDirectory else {
            showError("Select the existing output directory at \(project.outputDirectory). Moved or renamed folders are not supported by this re-authorization flow.")
            return .wrongFolderSelected
        }

        guard let bookmark = bookmarkCreator(selectedURL) else {
            showError("The folder was selected, but a new security-scoped bookmark could not be created.")
            return .bookmarkCreationFailed
        }

        project.outputDirectoryBookmark = bookmark
        projectManager.saveProjects()
        historyManager.repairOutputBookmarksFromFolder(projectId: project.id, folderURL: selectedURL)
        return .success
    }

    static func reauthorizeSourceFolder(
        entryIds: Set<UUID>,
        suggestedFolderURL: URL?,
        historyManager: HistoryManager
    ) {
        guard !entryIds.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggestedFolderURL
        panel.message = "Choose the folder that contains the original source images"
        panel.prompt = "Grant Access"

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        historyManager.repairSourceBookmarksFromFolder(entryIds: entryIds, folderURL: selectedURL)
    }
}
