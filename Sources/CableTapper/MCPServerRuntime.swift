import CableTapperCore
import Foundation
import Logging
import MCP
import Network

enum MCPServerRuntime {
    @MainActor
    static func run(session: PhoneSession, stdio: Bool, host: String, port: Int) async throws {
        session.startHID()
        // Best-effort screen start; tools can retry.
        try? await session.startScreen()

        let router = ToolRouter(session: session)
        let server = Server(
            name: "CableTapper",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            let args = Self.mapArguments(params.arguments)
            let toolResult = await router.call(ToolCall(name: params.name, arguments: args))
            return Self.toMCP(toolResult)
        }

        if stdio {
            FileHandle.standardError.write(Data("cabletapper mcp stdio ready\n".utf8))
            let transport = StdioTransport()
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
            return
        }

        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        FileHandle.standardError.write(
            Data("cabletapper mcp http://\(host):\(port)/mcp (loopback)\n".utf8)
        )
        try await LoopbackHTTPServer(host: host, port: UInt16(port), transport: transport).run()
    }

    private nonisolated static func mapArguments(_ arguments: [String: Value]?) -> [String: ToolValue] {
        guard let arguments else { return [:] }
        var out: [String: ToolValue] = [:]
        for (key, value) in arguments {
            if let s = value.stringValue {
                out[key] = .string(s)
            } else if let i = value.intValue {
                out[key] = .int(i)
            } else if let d = value.doubleValue {
                out[key] = .double(d)
            } else if let b = value.boolValue {
                out[key] = .bool(b)
            } else if let arr = value.arrayValue {
                // modifiers: ["command","shift"]
                let joined = arr.compactMap(\.stringValue).joined(separator: ",")
                out[key] = .string(joined)
            }
        }
        return out
    }

    private nonisolated static func toMCP(_ result: ToolResult) -> CallTool.Result {
        var content: [Tool.Content] = [
            .text(text: result.text, annotations: nil, _meta: nil),
        ]
        if let jpeg = result.jpegData {
            content.append(
                .image(
                    data: jpeg.base64EncodedString(),
                    mimeType: "image/jpeg",
                    annotations: nil,
                    _meta: nil
                )
            )
        }
        return .init(content: content, isError: result.isError)
    }

    private nonisolated static var tools: [Tool] {
        let xy = schema([
            "x": intProp("X in screenshot pixels"),
            "y": intProp("Y in screenshot pixels"),
            "settle_ms": intProp("Max wait for screen settle"),
        ], required: ["x", "y"])

        return [
            Tool(name: "status", description: "Bluetooth/USB status", inputSchema: emptyObject),
            Tool(name: "screenshot", description: "Capture settled iPhone screenshot over USB", inputSchema: emptyObject),
            Tool(
                name: "wait",
                description: "Wait then return a settled screenshot",
                inputSchema: schema(["ms": intProp("Milliseconds to wait")], required: [])
            ),
            Tool(
                name: "find_text",
                description: "OCR the screen; optional query filter",
                inputSchema: schema([
                    "query": stringProp("Substring or exact line"),
                    "exact": boolProp("Match whole line"),
                ], required: [])
            ),
            Tool(name: "tap", description: "Tap screenshot coordinates via Bluetooth AssistiveTouch", inputSchema: xy),
            Tool(
                name: "tap_text",
                description: "OCR-find text and tap its center",
                inputSchema: schema([
                    "text": stringProp("Label to tap"),
                    "exact": boolProp("Exact line match"),
                    "index": intProp("Match index from top"),
                    "settle_ms": intProp("Settle timeout"),
                ], required: ["text"])
            ),
            Tool(name: "double_tap", description: "Double-tap coordinates", inputSchema: xy),
            Tool(
                name: "long_press",
                description: "Long-press coordinates",
                inputSchema: schema([
                    "x": intProp("X"),
                    "y": intProp("Y"),
                    "duration_ms": intProp("Hold duration"),
                    "settle_ms": intProp("Settle timeout"),
                ], required: ["x", "y"])
            ),
            Tool(
                name: "drag",
                description: "Drag from one point to another",
                inputSchema: schema([
                    "from_x": intProp("Start X"),
                    "from_y": intProp("Start Y"),
                    "to_x": intProp("End X"),
                    "to_y": intProp("End Y"),
                    "duration_ms": intProp("Drag duration"),
                    "settle_ms": intProp("Settle timeout"),
                ], required: ["from_x", "from_y", "to_x", "to_y"])
            ),
            Tool(
                name: "flick",
                description: "Fast swipe with momentum",
                inputSchema: schema([
                    "x": intProp("Start X"),
                    "y": intProp("Start Y"),
                    "direction": stringProp("up|down|left|right"),
                    "settle_ms": intProp("Settle timeout"),
                ], required: ["x", "y", "direction"])
            ),
            Tool(
                name: "type_text",
                description: "Type US-keyboard ASCII into the focused field",
                inputSchema: schema([
                    "text": stringProp("Text to type"),
                    "settle_ms": intProp("Settle timeout"),
                ], required: ["text"])
            ),
            Tool(
                name: "press_key",
                description: "Press a key with optional modifiers",
                inputSchema: schema([
                    "key": stringProp("enter|escape|backspace|tab|space|arrows|a|c|v|x|z"),
                    "modifiers": stringProp("comma-separated: command,shift,control,alternate"),
                    "repeat": intProp("Repeat count"),
                    "settle_ms": intProp("Settle timeout"),
                ], required: ["key"])
            ),
            Tool(name: "home", description: "Go to Home Screen", inputSchema: emptyObject),
            Tool(name: "back", description: "Edge-swipe back", inputSchema: emptyObject),
            Tool(name: "dismiss", description: "Dismiss sheets/keyboard with Escape", inputSchema: emptyObject),
            Tool(
                name: "open_app",
                description: "Open an app via Spotlight by exact name",
                inputSchema: schema(["name": stringProp("App name")], required: ["name"])
            ),
        ]
    }

    private nonisolated static let emptyObject: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    private nonisolated static func schema(_ properties: [String: Value], required: [String]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
        ])
    }

    private nonisolated static func stringProp(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private nonisolated static func intProp(_ description: String) -> Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private nonisolated static func boolProp(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
}

/// Minimal loopback HTTP/1.1 server bridging to StatelessHTTPServerTransport.
actor LoopbackHTTPServer {
    private let host: String
    private let port: UInt16
    private let transport: StatelessHTTPServerTransport

    init(host: String, port: UInt16, transport: StatelessHTTPServerTransport) {
        self.host = host
        self.port = port
        self.transport = transport
    }

    func run() async throws {
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port)!
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { connection in
            Task { await self.handle(connection) }
        }
        listener.start(queue: .global())
        // Park forever.
        try await Task.sleep(for: .seconds(60 * 60 * 24 * 365 * 100))
    }

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: .global())
        do {
            let requestData = try await readHTTPRequest(from: connection)
            let parsed = try parseHTTP(requestData)
            let mcpRequest = HTTPRequest(
                method: parsed.method,
                headers: parsed.headers,
                body: parsed.body,
                path: parsed.path
            )
            let response = await transport.handleRequest(mcpRequest)
            let payload = serialize(response)
            try await send(payload, on: connection)
        } catch {
            let body = Data("Bad Request".utf8)
            let header = Data("HTTP/1.1 400 Bad Request\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            try? await send(header + body, on: connection)
        }
        connection.cancel()
    }

    private func serialize(_ response: HTTPResponse) -> Data {
        let status = response.statusCode
        var headers = response.headers
        let body = response.bodyData ?? Data()
        if headers["Content-Type"] == nil, !body.isEmpty {
            headers["Content-Type"] = "application/json"
        }
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        var out = Data("HTTP/1.1 \(status) \(statusText(status))\r\n".utf8)
        for (k, v) in headers {
            out.append(Data("\(k): \(v)\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "OK"
        }
    }

    private struct ParsedHTTP {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data?
    }

    private func parseHTTP(_ data: Data) throws -> ParsedHTTP {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw CableTapperError.internalError("incomplete HTTP headers")
        }
        let headerData = data.subdata(in: data.startIndex ..< headerRange.lowerBound)
        let body = data.subdata(in: headerRange.upperBound ..< data.endIndex)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw CableTapperError.internalError("invalid HTTP headers")
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { throw CableTapperError.internalError("empty request") }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw CableTapperError.internalError("bad request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let name = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }
        return ParsedHTTP(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: body.isEmpty ? nil : body
        )
    }

    private func readHTTPRequest(from connection: NWConnection) async throws -> Data {
        var buffer = Data()
        // Read until headers complete, then read Content-Length body.
        while true {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(returning: Data())
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex ..< headerEnd.lowerBound)
                let headerText = String(data: headerData, encoding: .utf8) ?? ""
                var contentLength = 0
                for line in headerText.split(separator: "\r\n").dropFirst() {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        let value = line.split(separator: ":").dropFirst().joined(separator: ":")
                            .trimmingCharacters(in: .whitespaces)
                        contentLength = Int(value) ?? 0
                    }
                }
                let bodyStart = headerEnd.upperBound
                let have = buffer.count - bodyStart
                if have >= contentLength {
                    return buffer
                }
            }
        }
        return buffer
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }
}
