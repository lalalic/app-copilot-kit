# AppCopilotKit

An open Swift Package for **on-device iPhone app UI automation and live product demonstrations over MCP**. Extracted from [Neox](https://github.com/lalalic/neox). No third-party runtime dependencies.

- `agent.pilot`: `snapshot`, `tap`, `tap_xy`, `type`, `swipe`, `long_press`, `find`, `scroll_to`, `pick`, `screenshot` (MCP image block).
- `agent.demo`: `step`, `spotlight`, `annotate`, `caption`, `say`, `cursor`, `highlight`, `clear`, `pause`, `resume`, `wait`, `start_recording`, `stop_recording`.
- Built-in MCP Streamable HTTP server using Network.framework (JSON-RPC `initialize`, `tools/list`, `tools/call`, `ping`), with optional Bonjour `_mcp._tcp` announcement.
- Shared `ToolDefinition` / `JSONValue` model supports registration of app-specific tools on the same server.

## Install in Xcode

**File → Add Package Dependencies** → `https://github.com/lalalic/app-copilot-kit` → select release `0.2.0` or later → add `AppCopilotKit` to the iOS app target. Minimum supported iOS: **17**.

### SwiftUI app (development/demo build)

```swift
import SwiftUI
import AppCopilotKit

@main
struct MyApp: App {
    @StateObject private var copilot = AppCopilotSession(name: "my-app", port: 9223)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .appCopilotOverlay(using: copilot)
                .task {
                    #if DEBUG
                    try? copilot.start()
                    #endif
                }
        }
    }
}
```

For trusted remote automation, configure a strong per-run secret with `copilot.server.requireBearerToken(token)` **before** `start()` and pass `Authorization: Bearer <token>` in every MCP request. Avoid unauthenticated listeners even on shared Wi-Fi.

`AppCopilotSession` registers both tools and owns the listener. Existing MCP hosts can register `AppAgentToolProvider().tools` into their own server instead of creating another listener; attach `DemoOverlayView` or `.appCopilotOverlay(using:)` to the app scene for visible demos.

### Drive the app

Once the app is in the **foreground** on the iPhone and its listener is running, connect from a trusted Mac on the same network to `http://<iphone-lan-ip>:9223/mcp` or discover the optional Bonjour service. MCP requests:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"agent.pilot","arguments":{"command":"snapshot"}}}
```

Then use the returned `r0`, `r1`, … refs in `tap`, `type` or `scroll_to` and capture new snapshots/screenshots for assertions. For a demo, call `agent.demo` with `step`, `spotlight`, `say`, etc. and keep `.appCopilotOverlay` attached.

If you need LAN access, include `NSLocalNetworkUsageDescription` in the app's Info.plist and a Bonjour-services declaration (`_mcp._tcp`) when advertising. Enable local networking on the device. iOS may suspend network listeners in the background; keep the app foregrounded during the run and restart on foreground transitions if needed.

## Security and limitations

**The embedded MCP server is unauthenticated and listens on the device network.** Anyone who can reach it can invoke UI automation. Use it only on a trusted development network, with a development/test or explicitly authorized demo build; never expose the port publicly or start it silently in production. Remove/disable the server and `agent.pilot` from normal release builds. `agent.demo` is optional. The package cannot bypass iOS permissions, lock screen, or app lifecycle limitations. Tests should operate only the integrating app's UI, not other apps.

Run `swift test` for portable contract tests, and `xcodebuild -scheme AppCopilotKit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` for iOS compile. Verify real-device MCP call sequences before claiming a physical-device E2E pass.

## License

MIT. See [LICENSE](LICENSE).
