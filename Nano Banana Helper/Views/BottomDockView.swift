import SwiftUI

struct BottomDockView: View {
    @Environment(BatchOrchestrator.self) private var orchestrator
    @Environment(ProjectManager.self) private var projectManager
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

                Group {
                    if projectManager.sessionCost > 0 {
                        Text("Session: $\(projectManager.sessionCost, specifier: "%.2f")")
                    } else if projectManager.costSummary.totalSpent > 0 {
                        Text("Total: $\(projectManager.costSummary.totalSpent, specifier: "%.2f")")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

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
        switch orchestrator.aggregateTone {
        case .issue:
            return .red
        case .cancelled:
            return .orange
        case .success:
            return .green
        case .neutral:
            return .secondary
        }
    }
}
