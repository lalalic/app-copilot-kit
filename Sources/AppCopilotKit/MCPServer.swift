import Foundation
import Network

/// MCP (Model Context Protocol) server using Streamable HTTP transport.
///
/// Runs a lightweight HTTP server via Network.framework that speaks
/// JSON-RPC 2.0 over POST — compatible with VS Code, Claude Desktop,
/// and any MCP client.
///
/// ```swift
/// let server = MCPServer(name: "my-app", port: 9223)
/// server.register(tools: myToolProvider.tools)
/// try server.start()
/// ```
///
/// VS Code `.vscode/mcp.json`:
/// ```json
/// { "servers": { "my-app": { "url": "http://localhost:9223/mcp" } } }
/// ```
@MainActor
public final class MCPServer {

    /// Server identity shown to MCP clients.
    public let name: String

    /// Server version shown to MCP clients.
    public let version: String

    /// TCP port the server listens on.
    public let port: UInt16

    /// Optional Bonjour service name; when set the listener advertises `_mcp._tcp`.
    public let bonjourName: String?

    private var listener: NWListener?
    private var toolHandlers: [String: ToolHandler] = [:]
    private var mcpTools: [[String: Any]] = []
    // Dedicated queue for all network I/O — avoids blocking on MainActor
    private let httpQueue = DispatchQueue(label: "mcp-server-http", qos: .userInitiated)
    // Snapshot of state for nonisolated access from httpQueue
    // Written on MainActor during register/start, read on httpQueue — safe by construction
    nonisolated(unsafe) private var _snapshotName: String = ""
    nonisolated(unsafe) private var _snapshotVersion: String = ""
    nonisolated(unsafe) private var _snapshotTools: [[String: Any]] = []
    nonisolated(unsafe) private var _snapshotHandlers: [String: ToolHandler] = [:]
    nonisolated(unsafe) private var _snapshotToolNames: [String] = []

    /// Whether the server is currently listening.
    @Published public private(set) var isRunning = false

    /// Log callback for debugging.
    public var onLog: ((String) -> Void)?

    /// Called for every HTTP request line (e.g. "POST /mcp") — safe to call from the network queue.
    public nonisolated(unsafe) var onRequest: ((String) -> Void)?

    /// Called on every tools/call with the tool name and compact JSON of its arguments.
    public nonisolated(unsafe) var onToolCall: ((UUID, String, String) -> Void)?

    /// Called after a tool handler has returned or failed.
    public nonisolated(unsafe) var onToolCallFinished: ((UUID) -> Void)?

    public init(name: String = "mcp-server", version: String = "1.0.0", port: UInt16 = 9223, bonjourName: String? = nil) {
        self.name = name
        self.version = version
        self.port = port
        self.bonjourName = bonjourName
    }

    deinit {
        listener?.cancel()
    }

    // MARK: - Tool Registration

    /// Register tools from CopilotSDK `ToolDefinition` array.
    public func register(tools: [ToolDefinition]) {
        for tool in tools {
            toolHandlers[tool.name] = tool.handler
            mcpTools.append(buildMCPSchema(tool))
        }
        refreshSnapshots()
    }

    /// Register a single tool by name, description, schema, and handler.
    public func register(name: String, description: String,
                         inputSchema: [String: Any] = ["type": "object", "properties": [String: Any]()],
                         handler: @escaping ToolHandler) {
        toolHandlers[name] = handler
        mcpTools.append([
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ])
        refreshSnapshots()
    }

    /// Unregister a tool by name.
    public func unregister(name: String) {
        toolHandlers.removeValue(forKey: name)
        mcpTools.removeAll { ($0["name"] as? String) == name }
        refreshSnapshots()
    }

    private func refreshSnapshots() {
        _snapshotName = name
        _snapshotVersion = version
        _snapshotTools = mcpTools
        _snapshotHandlers = toolHandlers
        _snapshotToolNames = toolNames
    }

    /// All registered tool names.
    public var toolNames: [String] {
        Array(toolHandlers.keys).sorted()
    }

    /// Optional root directory for serving static files at `/assets/`.
    nonisolated(unsafe) private var _staticFileRoot: URL?

    /// Set a root directory to serve static files from via GET `/assets/...`.
    public func setStaticFileRoot(_ url: URL?) {
        _staticFileRoot = url
    }

    // MARK: - Server Lifecycle

    /// Start listening for MCP connections.
    public func start() throws {
        guard listener == nil else { return }
        // Snapshot MainActor-isolated state for use on httpQueue
        _snapshotName = name
        _snapshotVersion = version
        _snapshotTools = mcpTools
        _snapshotHandlers = toolHandlers
        _snapshotToolNames = toolNames

        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))

        if let bonjourName {
            listener.service = NWListener.Service(name: bonjourName, type: "_mcp._tcp")
        }

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true

                case .failed(let error):
                    self.isRunning = false
                    self.log("MCP Server failed: \(error)")
                case .cancelled:
                    self.isRunning = false
                    self.log("MCP Server stopped")
                default:
                    break
                }
            }
        }

        let queue = httpQueue
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.setupConnection(connection, queue: queue)
        }

        listener.start(queue: httpQueue)
        self.listener = listener
    }

    /// Stop the server.
    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - HTTP Connection Handling (runs on httpQueue, NOT MainActor)

    /// Set up a new connection — called from httpQueue via newConnectionHandler.
    nonisolated private func setupConnection(_ connection: NWConnection, queue: DispatchQueue) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveHTTPData(connection: connection, accumulated: Data())
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        // Auto-cancel after 900s to prevent CLOSE_WAIT buildup.
        // Generous so a large file transfer over slow WiFi isn't cut mid-stream.
        // Every response path cancels its connection after sending, so this only
        // sweeps connections that never complete a request.
        queue.asyncAfter(deadline: .now() + 900) { [weak connection] in
            connection?.cancel()
        }
        connection.start(queue: queue)
    }

    /// Accumulate TCP data until full HTTP request is received, then process it.
    nonisolated private func receiveHTTPData(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var data = accumulated
            if let content, !content.isEmpty {
                data.append(content)
            }

            // Check if we have a complete HTTP request
            if let raw = String(data: data, encoding: .utf8),
               let headerEnd = raw.range(of: "\r\n\r\n") {
                let headers = String(raw[raw.startIndex..<headerEnd.lowerBound])
                var expectedContentLength = 0
                for line in headers.split(separator: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        let valStr = line.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                        expectedContentLength = Int(valStr) ?? 0
                        break
                    }
                }

                let headerEndOffset = raw.distance(from: raw.startIndex, to: headerEnd.upperBound)
                let bodyLength = data.count - headerEndOffset

                if expectedContentLength == 0 || bodyLength >= expectedContentLength {
                    self.processHTTPRequest(raw: String(data: data, encoding: .utf8) ?? raw, connection: connection)
                    return
                }
            }

            if isComplete || (content == nil && accumulated.isEmpty) {
                if data.isEmpty {
                    connection.cancel()
                } else if let raw = String(data: data, encoding: .utf8) {
                    self.processHTTPRequest(raw: raw, connection: connection)
                } else {
                    connection.cancel()
                }
                return
            }

            self.receiveHTTPData(connection: connection, accumulated: data)
        }
    }

    // MARK: - HTTP Request Router (nonisolated — runs on httpQueue)

    nonisolated private func processHTTPRequest(raw: String, connection: NWConnection) {
        let lines = raw.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            sendHTTP(connection: connection, status: 400, body: nil)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTP(connection: connection, status: 400, body: nil)
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Extract Range header (case-insensitive) for static file requests
        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = line.split(separator: ":", maxSplits: 1).last
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                break
            }
        }

        if let onRequest { onRequest("\(method) \(path)") }

        // Extract body
        var body: Data?
        if let bodyStart = raw.range(of: "\r\n\r\n") {
            let bodyStr = String(raw[bodyStart.upperBound...])
            if !bodyStr.isEmpty {
                body = bodyStr.data(using: .utf8)
            }
        }

        // CORS preflight (kept for completeness — MCP clients are not browsers)
        if method == "OPTIONS" {
            sendHTTP(connection: connection, status: 204, body: nil)
            return
        }

        switch (method, path) {
        case ("POST", "/mcp"):
            handleMCPPostNonisolated(body: body, connection: connection)

        case ("GET", "/mcp"):
            sendHTTP(connection: connection, status: 405, body: nil)

        case ("DELETE", "/mcp"):
            sendHTTP(connection: connection, status: 200, body: nil)

        case ("GET", "/"):
            let info: [String: Any] = [
                "name": _snapshotName,
                "mcp_endpoint": "/mcp",
                "protocol": "MCP (Streamable HTTP)"
            ]
            sendJSON(connection: connection, status: 200, json: info)

        default:
            // Static file serving: GET /files/... (alias /public/... kept for compatibility)
            if method == "GET", path.hasPrefix("/files/") || path.hasPrefix("/public/"), let root = _staticFileRoot {
                let prefix = path.hasPrefix("/files/") ? "/files/" : "/public/"
                let relativePath = String(path.dropFirst(prefix.count))
                serveStaticFile(relativePath: relativePath, root: root, rangeHeader: rangeHeader, connection: connection)
            } else {
                sendHTTP(connection: connection, status: 404, body: "Not found".data(using: .utf8))
            }
        }
    }

    // MARK: - MCP JSON-RPC Handler (nonisolated)

    nonisolated private func handleMCPPostNonisolated(body: Data?, connection: NWConnection) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendJSONRPCError(connection: connection, id: nil, code: -32700, message: "Parse error")
            return
        }

        let id = json["id"]
        let method = json["method"] as? String
        let params = json["params"] as? [String: Any] ?? [:]

        guard id != nil else {
            sendHTTP(connection: connection, status: 202, body: nil)
            return
        }

        guard let method else {
            sendJSONRPCError(connection: connection, id: id, code: -32600, message: "Missing method")
            return
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2025-03-26",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": _snapshotName, "version": _snapshotVersion]
            ]
            sendJSONRPCResult(connection: connection, id: id, result: result)

        case "tools/list":
            sendJSONRPCResult(connection: connection, id: id, result: ["tools": _snapshotTools])

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                sendJSONRPCError(connection: connection, id: id, code: -32602, message: "Missing tool name")
                return
            }
            guard let handler = _snapshotHandlers[toolName] else {
                sendJSONRPCError(connection: connection, id: id, code: -32602,
                    message: "Tool '\(toolName)' not found. Available: \(_snapshotToolNames.joined(separator: ", "))")
                return
            }

            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let jsonArgs = Self.toJSONValue(arguments)
            let callID = UUID()
            if let onToolCall {
                let argsPreview: String
                if let data = try? JSONSerialization.data(withJSONObject: Self.jsonValueToAny(jsonArgs), options: [.sortedKeys]) {
                    argsPreview = String(data: data, encoding: .utf8) ?? ""
                } else { argsPreview = "" }
                onToolCall(callID, toolName, argsPreview)
            }

            // Tool handlers may need MainActor — run in a detached task
            Task.detached { [weak self] in
                defer { self?.onToolCallFinished?(callID) }
                do {
                    let result = try await handler(jsonArgs)
                    // Image results come back as "b64:<mime>,<base64>"; everything else is text.
                    // (Never infer from length/newlines — a long single-line JSON result is text.)
                    let content: [[String: Any]]
                    if result.hasPrefix("b64:"), let comma = result.firstIndex(of: ",") {
                        let mime = String(result[result.index(result.startIndex, offsetBy: 4)..<comma])
                        let payload = String(result[result.index(after: comma)...])
                        content = [["type": "image", "data": payload, "mimeType": mime.isEmpty ? "image/png" : mime]]
                    } else {
                        content = [["type": "text", "text": result]]
                    }
                    self?.sendJSONRPCResult(connection: connection, id: id, result: [
                        "content": content, "isError": false
                    ])
                } catch {
                    self?.sendJSONRPCResult(connection: connection, id: id, result: [
                        "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                        "isError": true
                    ])
                }
            }

        case "ping":
            sendJSONRPCResult(connection: connection, id: id, result: [:] as [String: Any])

        default:
            sendJSONRPCError(connection: connection, id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - HTTP Response Helpers (nonisolated for httpQueue access)

    nonisolated private func sendJSONRPCResult(connection: NWConnection, id: Any?, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id { response["id"] = id }
        sendJSON(connection: connection, status: 200, json: response)
    }

    nonisolated private func sendJSONRPCError(connection: NWConnection, id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { response["id"] = id }
        sendJSON(connection: connection, status: 200, json: response)
    }

    nonisolated private func sendJSON(connection: NWConnection, status: Int, json: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            connection.cancel()
            return
        }
        sendHTTP(connection: connection, status: status, body: jsonData, contentType: "application/json")
    }

    nonisolated private func sendHTTP(connection: NWConnection, status: Int, body: Data?,
                          contentType: String = "application/json",
                          extraHeaders: [String: String] = [:]) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 403: statusText = "Forbidden"
        case 405: statusText = "Method Not Allowed"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var headers = [
            "HTTP/1.1 \(status) \(statusText)",
            "Connection: close"
        ]

        if let body, !body.isEmpty {
            headers.append("Content-Type: \(contentType)")
            headers.append("Content-Length: \(body.count)")
        }

        for (key, value) in extraHeaders {
            headers.append("\(key): \(value)")
        }

        headers.append("")
        headers.append("")

        var responseData = Data(headers.joined(separator: "\r\n").utf8)
        if let body { responseData.append(body) }

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - MCP Tool Schema Builder

    private func buildMCPSchema(_ tool: ToolDefinition) -> [String: Any] {
        var schema: [String: Any] = ["name": tool.name]
        if let desc = tool.description { schema["description"] = desc }

        if let params = tool.parameters, case .object = params {
            schema["inputSchema"] = jsonValueToAny(params)
        } else {
            schema["inputSchema"] = [
                "type": "object",
                "properties": [:] as [String: Any]
            ]
        }

        return schema
    }

    // MARK: - JSON Conversion

    /// Convert Foundation types to `JSONValue`.
    nonisolated public static func toJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let str as String:
            return .string(str)
        case let num as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(num) {
                return .bool(num.boolValue)
            }
            if num.doubleValue == Double(num.intValue) {
                return .int(num.intValue)
            }
            return .double(num.doubleValue)
        case let dict as [String: Any]:
            return .object(dict.mapValues { toJSONValue($0) })
        case let arr as [Any]:
            return .array(arr.map { toJSONValue($0) })
        case is NSNull:
            return .null
        default:
            return .string(String(describing: value))
        }
    }

    /// Convert `JSONValue` to Foundation types for JSON serialization.
    nonisolated public static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .object(let dict): return dict.mapValues { jsonValueToAny($0) }
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        }
    }

    // Private instance version for internal use
    private func jsonValueToAny(_ value: JSONValue) -> Any {
        Self.jsonValueToAny(value)
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    // MARK: - Static File Serving

    nonisolated private func serveStaticFile(relativePath: String, root: URL, rangeHeader: String?, connection: NWConnection) {
        // Security: prevent path traversal
        let cleaned = relativePath.replacingOccurrences(of: "..", with: "")
        let fileURL = root.appendingPathComponent(cleaned)

        // Reject path siblings and symlinks escaping the configured root.
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath.hasPrefix(rootPath + "/") else {
            sendHTTP(connection: connection, status: 403, body: "Forbidden".data(using: .utf8))
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value, fileSize > 0 else {
            sendHTTP(connection: connection, status: 404, body: "Not found".data(using: .utf8))
            return
        }

        let mime = Self.mime(forExtension: fileURL.pathExtension.lowercased())

        // Parse Range: bytes=a-b | bytes=a- | bytes=-suffix
        var start: UInt64 = 0
        var end: UInt64 = fileSize - 1
        var isRange = false
        if let rangeHeader, rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst("bytes=".count)
            let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let head = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let tail = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if let s = UInt64(head) {
                start = min(s, fileSize - 1)
                if let e = UInt64(tail) { end = min(e, fileSize - 1) }
                isRange = true
            } else if head.isEmpty, let suffix = UInt64(tail) {
                start = fileSize > suffix ? fileSize - suffix : 0
                isRange = true
            }
        }
        if end < start { end = start }
        let contentLength = end - start + 1

        var headers: [String]
        if isRange {
            headers = [
                "HTTP/1.1 206 Partial Content",
                "Content-Type: \(mime)",
                "Content-Range: bytes \(start)-\(end)/\(fileSize)",
                "Content-Length: \(contentLength)",
                "Accept-Ranges: bytes",
                "Connection: close"
            ]
        } else {
            headers = [
                "HTTP/1.1 200 OK",
                "Content-Type: \(mime)",
                "Content-Length: \(contentLength)",
                "Accept-Ranges: bytes",
                "Connection: close"
            ]
        }

        let headerData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            sendHTTP(connection: connection, status: 500, body: "Read error".data(using: .utf8))
            return
        }
        if start > 0 { try? handle.seek(toOffset: start) }

        connection.send(content: headerData, completion: .contentProcessed { error in
            if error != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            Self.streamFileChunks(connection: connection, handle: handle, remaining: contentLength)
        })
    }

    /// Stream file contents in 1MB chunks — memory stays bounded for multi-GB videos.
    nonisolated private static func streamFileChunks(connection: NWConnection, handle: FileHandle, remaining: UInt64) {
        guard remaining > 0 else {
            try? handle.close()
            connection.cancel()
            return
        }
        let size = min(Int(remaining), 1 << 20)
        guard let chunk = try? handle.read(upToCount: size), !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        let sent = UInt64(chunk.count)
        connection.send(content: chunk, completion: .contentProcessed { error in
            if error != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            streamFileChunks(connection: connection, handle: handle, remaining: remaining - sent)
        })
    }

    nonisolated private static func mime(forExtension ext: String) -> String {
        switch ext {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "json": return "application/json"
        case "srt": return "text/plain"
        case "html", "htm": return "text/html"
        case "js": return "application/javascript"
        case "css": return "text/css"
        default: return "application/octet-stream"
        }
    }
}
