import XCTest
@testable import AppCopilotKit

final class AppCopilotKitTests: XCTestCase {
    func testJSONRoundTrip() throws {
        let original: JSONValue = .object([
            "command": .string("tap"), "ref": .string("r1"),
            "enabled": .bool(true), "count": .int(3), "nested": .array([.null, .double(0.5)])
        ])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), original)
    }

    @MainActor
    func testHTTPToolsListAndCall() async throws {
        let server = MCPServer(name: "app-copilot-test", port: 19227)
        server.register(tools: [ToolDefinition(name: "fixture.echo", description: "Echo") { args in
            guard case .object(let map) = args,
                  case .string(let value) = map["text"] else { return "missing text" }
            return value
        }])
        try server.start()
        try server.start() // SwiftUI .task/onAppear can run more than once.
        defer { server.stop() }
        for _ in 0..<40 where !server.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(server.isRunning, "MCP listener must be live")

        func request(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
            var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:19227/mcp")!)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var payload: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
            if let params { payload["params"] = params }
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let initialized = try await request("initialize")
        XCTAssertEqual(((initialized["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String, "app-copilot-test")
        let listed = try await request("tools/list")
        let tools = ((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(tools.first?["name"] as? String, "fixture.echo")
        let called = try await request("tools/call", params: [
            "name": "fixture.echo", "arguments": ["text": "hello from MCP"]
        ])
        let content = ((called["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        XCTAssertEqual(content.first?["text"] as? String, "hello from MCP")
    }

    @MainActor
    func testAuthenticationRequiredForToolCalls() async throws {
        let server = MCPServer(name: "auth-test", port: 19228)
        server.requireBearerToken(String(repeating: "z", count: 48))
        server.register(tools: [ToolDefinition(name: "fixture.echo") { _ in "secret" }])
        try server.start()
        defer { server.stop() }
        for _ in 0..<40 where !server.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(server.isRunning)
        func response(_ token: String?) async throws -> (Int, String) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:19228/mcp")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "fixture.echo", "arguments": [:] as [String: Any]]
            ])
            let (data, http) = try await URLSession.shared.data(for: request)
            return ((http as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        let denied = try await response(nil)
        XCTAssertEqual(denied.0, 403)
        XCTAssertFalse(denied.1.contains("secret"))
        let wrong = try await response(String(repeating: "x", count: 48))
        XCTAssertEqual(wrong.0, 403)
        let allowed = try await response(String(repeating: "z", count: 48))
        XCTAssertEqual(allowed.0, 200)
        XCTAssertTrue(allowed.1.contains("secret"))
    }

    @MainActor
    func testRegisterTools() throws {
        let server = MCPServer(name: "fixture", port: 9229)
        server.register(tools: [ToolDefinition(name: "fixture.echo", description: "Echo") { _ in "ok" }])
        XCTAssertEqual(server.toolNames, ["fixture.echo"])
        server.unregister(name: "fixture.echo")
        XCTAssertTrue(server.toolNames.isEmpty)
    }
}

#if os(iOS)
import SwiftUI
import UIKit

@MainActor
final class AppCopilotInteractionTests: XCTestCase {
    func testRegisteredActionByRefCoordinateAndStaleRef() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let registry = AppCopilotActionRegistry.shared
        var calls = 0
        var frame = CGRect(x: 24, y: 80, width: 120, height: 44)
        registry.register(id: "test.action", label: "Test Button",
                          frame: { _ in frame }, acceptsHit: { _, _ in true },
                          perform: { calls += 1 })
        defer {
            registry.unregister(id: "test.action")
            window.isHidden = true
        }
        let scanner = AccessibilityScanner(window: window)
        let snapshot = scanner.scan()
        XCTAssertTrue(snapshot.contains("[action:test.action]"))
        guard let element = scanner.elements.first(where: { $0.label == "Test Button" }) else {
            XCTFail("Registered control absent from snapshot")
            return
        }
        let engine = InteractionEngine(scanner: scanner)
        let outcome = engine.tap(ref: element.ref)
        XCTAssertTrue(outcome.contains("Dispatched registered action"), outcome)
        XCTAssertEqual(calls, 1)
        // Coordinate dispatch uses the same public SwiftUI action bridge.
        let coordinateResult = await engine.tapXY(x: 40, y: 94)
        XCTAssertEqual(coordinateResult,
                       "Dispatched registered action 'test.action' [Test Button]")
        XCTAssertEqual(calls, 2)
        frame = CGRect(x: 200, y: 400, width: 120, height: 44)
        XCTAssertTrue(engine.tap(ref: element.ref).hasPrefix("Error:"))
        XCTAssertEqual(calls, 2, "Stale refs may never dispatch a moved control")

        // Fresh snapshots do not recycle r0, r1... for unrelated controls.
        let previous = element.ref
        scanner.scan()
        XCTAssertNil(scanner.element(for: previous))
        XCTAssertFalse(scanner.elements.contains { $0.ref == previous })
    }

    func testUIKitControlWithTargetDispatchesAndNoTargetErrors() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var calls = 0
        let active = UIButton(type: .system)
        active.frame = CGRect(x: 20, y: 60, width: 150, height: 50)
        active.setTitle("UIKit Active", for: .normal)
        active.accessibilityLabel = "UIKit Active"
        active.addAction(UIAction { _ in calls += 1 }, for: .touchUpInside)
        controller.view.addSubview(active)

        let inert = UIButton(type: .system)
        inert.frame = CGRect(x: 20, y: 140, width: 150, height: 50)
        inert.setTitle("UIKit Inert", for: .normal)
        inert.accessibilityLabel = "UIKit Inert"
        controller.view.addSubview(inert)

        let scanner = AccessibilityScanner(window: window)
        _ = scanner.scan()
        let engine = InteractionEngine(scanner: scanner)
        guard let activeRef = scanner.elements.first(where: { $0.label == "UIKit Active" })?.ref,
              let inertRef = scanner.elements.first(where: { $0.label == "UIKit Inert" })?.ref else {
            XCTFail("UIKit controls missing from snapshot")
            return
        }
        XCTAssertTrue(engine.tap(ref: activeRef).contains("Tapped"))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(engine.tap(ref: inertRef).hasPrefix("Error:"))
        XCTAssertEqual(calls, 1)
    }

    func testDisabledSwiftUIButtonCannotDispatch() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        var calls = 0
        let view = VStack {
            Button("Disabled") { calls += 1 }
                .frame(width: 180, height: 64)
                .appCopilotAction(id: "test.disabled", label: "Disabled") { calls += 1 }
        }.disabled(true)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        let action = AppCopilotActionRegistry.shared.visibleActions(in: window)
            .first(where: { $0.id == "test.disabled" })
        XCTAssertNotNil(action, "Disabled actions should remain discoverable")
        XCTAssertEqual(action?.isEnabled, false)
        XCTAssertFalse(AppCopilotActionRegistry.shared.invoke(
            id: "test.disabled", in: window
        ))
        XCTAssertEqual(calls, 0)
    }

    func testSameActionIdentifierInTwoWindows() {
        let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let second = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        var firstCount = 0
        var secondCount = 0
        let firstHost = UIHostingController(rootView:
            Button("Shared") {}
                .frame(width: 180, height: 64)
                .appCopilotAction(id: "test.shared", label: "Shared") { firstCount += 1 }
        )
        let secondHost = UIHostingController(rootView:
            Button("Shared") {}
                .frame(width: 180, height: 64)
                .appCopilotAction(id: "test.shared", label: "Shared") { secondCount += 1 }
        )
        first.rootViewController = firstHost
        first.makeKeyAndVisible()
        firstHost.view.frame = first.bounds
        firstHost.view.layoutIfNeeded()
        second.rootViewController = secondHost
        second.makeKeyAndVisible()
        secondHost.view.frame = second.bounds
        secondHost.view.layoutIfNeeded()
        defer {
            first.isHidden = true
            second.isHidden = true
        }
        XCTAssertEqual(AppCopilotActionRegistry.shared.visibleActions(in: first)
            .filter { $0.id == "test.shared" }.count, 1)
        XCTAssertEqual(AppCopilotActionRegistry.shared.visibleActions(in: second)
            .filter { $0.id == "test.shared" }.count, 1)
        XCTAssertTrue(AppCopilotActionRegistry.shared.invoke(id: "test.shared", in: first))
        XCTAssertTrue(AppCopilotActionRegistry.shared.invoke(id: "test.shared", in: second))
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)
    }

    func testClippedSwiftUIActionNotExposed() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let view = ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 500)
                Button("Below") {}
                    .frame(width: 180, height: 64)
                    .appCopilotAction(id: "test.clipped", label: "Below") {}
            }
        }.frame(width: 250, height: 110)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        XCTAssertFalse(AppCopilotActionRegistry.shared.visibleActions(in: window)
            .contains(where: { $0.id == "test.clipped" }))
        XCTAssertFalse(AppCopilotActionRegistry.shared.invoke(
            id: "test.clipped", in: window
        ))
    }

    func testSwiftUIButtonAnchorDispatch() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        var calls = 0
        let view = Button("SwiftUI Test") { calls += 1 }
            .frame(width: 180, height: 64)
            .appCopilotAction(id: "test.swiftui", label: "SwiftUI Test") { calls += 1 }
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        let scanner = AccessibilityScanner(window: window)
        let snapshot = scanner.scan()
        XCTAssertTrue(snapshot.contains("[action:test.swiftui]"))
        guard let element = scanner.elements.first(where: { $0.label == "SwiftUI Test" && $0.traits == "registered-action" }) else {
            XCTFail("SwiftUI anchor not registered")
            return
        }
        let engine = InteractionEngine(scanner: scanner)
        let outcome = engine.tap(ref: element.ref)
        XCTAssertTrue(outcome.contains("Dispatched registered action"), outcome)
        XCTAssertEqual(calls, 1)
        let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        let result = AppCopilotActionRegistry.shared.invoke(at: center, in: window)
        XCTAssertTrue(result?.contains("Dispatched registered action") == true)
        XCTAssertEqual(calls, 2)
        // An overlay in the very same UIHostingController must block the
        // background action even though both views share a controller.
        let shield = UIView(frame: element.frame)
        shield.backgroundColor = .opaqueSeparator
        shield.isUserInteractionEnabled = true
        host.view.addSubview(shield)
        XCTAssertFalse(AppCopilotActionRegistry.shared.visibleActions(in: window)
            .contains { $0.id == "test.swiftui" }, "Covered actions must be invisible")
        XCTAssertFalse(AppCopilotActionRegistry.shared.invoke(
            id: "test.swiftui", in: window
        ))
        shield.removeFromSuperview()
        host.view.isHidden = true
        XCTAssertFalse(AppCopilotActionRegistry.shared.visibleActions(in: window)
            .contains { $0.id == "test.swiftui" }, "Hidden SwiftUI controls must never be tappable")
    }
}
#endif
