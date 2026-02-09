import SwiftUI

struct BottomDockView: View {
    @Environment(BatchOrchestrator.self) private var orchestrator
    @Binding var isQueueOpen: Bool
    
    var body: some View {
        HStack(spacing: 0) {
            // Main clickable area
            HStack(spacing: 16) {
                // Left: Status Indicator
                if orchestrator.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
                
                Text(orchestrator.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                // Progress Bar (Always Visible, but inactive state if 0)
                ProgressView(value: orchestrator.isRunning ? orchestrator.currentProgress : 0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
                    .opacity(orchestrator.isRunning || orchestrator.currentProgress > 0 ? 1.0 : 0.3)
                
                Spacer()
                
                // Toggle Drawer Button (Explicit button, but entire bar is also tappable)
                HStack(spacing: 6) {
                    Text(isQueueOpen ? "Hide Queue" : "Show Queue")
                    Image(systemName: "chevron.up")
                        .rotationEffect(.degrees(isQueueOpen ? 180 : 0))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isQueueOpen.toggle()
                }
            }
        }
        .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
        .overlay(Divider(), alignment: .top)
    }
    
    private var statusColor: Color {
        if orchestrator.failedJobs.count > 0 { return .red }
        if orchestrator.completedJobs.count > 0 && !orchestrator.isRunning { return .green }
        return .secondary
    }
}
