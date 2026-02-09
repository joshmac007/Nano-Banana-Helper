import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(BatchOrchestrator.self) private var orchestrator
    
    var body: some View {
        MainLayoutView()
    }
}
