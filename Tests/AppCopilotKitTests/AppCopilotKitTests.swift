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
    func testRegisterTools() throws {
        let server = MCPServer(name: "fixture", port: 9229)
        server.register(tools: [ToolDefinition(name: "fixture.echo", description: "Echo") { _ in "ok" }])
        XCTAssertEqual(server.toolNames, ["fixture.echo"])
        server.unregister(name: "fixture.echo")
        XCTAssertTrue(server.toolNames.isEmpty)
    }
}
