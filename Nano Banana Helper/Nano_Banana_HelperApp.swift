//
//  Nano_Banana_HelperApp.swift
//  Nano Banana Helper
//
//  Created by Josh McSwain on 2/2/26.
//

import SwiftUI

@main
struct Nano_Banana_HelperApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var orchestrator = BatchOrchestrator()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(orchestrator)
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task {
                await orchestrator.recoverSavedQueueOnLaunchIfNeeded()
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Start Batch") {
                    Task { await orchestrator.startAll() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(orchestrator.pendingJobs.isEmpty)
                
                Button("Pause Batch") {
                    orchestrator.pause()
                }
                .keyboardShortcut(".", modifiers: [.command])
                
                Button("Cancel Batch") {
                    orchestrator.cancel()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }
}
