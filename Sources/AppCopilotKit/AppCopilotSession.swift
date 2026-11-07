#if os(iOS)
import SwiftUI

/// One opt-in MCP endpoint for UI testing and interactive product demonstrations.
/// Start it only in trusted development or demonstration builds.
@MainActor
public final class AppCopilotSession: ObservableObject {
    public let agent: AppAgentToolProvider
    public let server: MCPServer

    public init(name: String, port: UInt16 = 9223, bonjourName: String? = nil) {
        let agent = AppAgentToolProvider()
        self.agent = agent
        self.server = MCPServer(name: name, port: port, bonjourName: bonjourName)
        self.server.register(tools: agent.tools)
    }

    public func start() throws { try server.start() }
    public func stop() { server.stop() }
}

public extension View {
    /// Host demo captions, spotlights, and pointer overlays in the app's scene.
    /// The environment object is injected on the overlay itself to avoid
    /// SwiftUI environment propagation differences across iOS versions.
    func appCopilotOverlay(using session: AppCopilotSession) -> some View {
        overlay {
            DemoOverlayView().environmentObject(session.agent.demoRuntime)
        }
    }
}
#endif
