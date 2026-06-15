// Graph feature completely removed for App Store (MAS) readiness.
// Sandbox does not support the required features for full graph execution/orchestration in a distributable build.
// MCP servers also limited (HTTP only; stdio not allowed).
// This file is stubbed to allow compilation but provides no functionality.

import SwiftUI

struct AgentGraphView: View {
    var body: some View {
        VStack {
            Text("Agent Graph")
                .font(.largeTitle)
            Text("This feature has been removed for the Mac App Store version.")
                .foregroundStyle(.secondary)
            Text("App Store sandbox restrictions prevent process spawning, arbitrary tool execution, and full MCP server support required for a robust agent graph.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .padding()
            Text("For non-MAS builds, the feature can be re-enabled from source.")
                .font(.caption2)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.backgroundGradient)
    }
}
