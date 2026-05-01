import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct JSONRPCRequest: Codable, Sendable, Equatable {
    public var jsonrpc: String = "2.0"
    public var id: JSONValue?
    public var method: String
    public var params: JSONValue?

    public init(id: JSONValue? = nil, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse: Codable, Sendable, Equatable {
    public var jsonrpc: String
    public var id: JSONValue?
    public var result: JSONValue?
    public var error: JSONRPCError?
}

public struct JSONRPCError: Codable, Sendable, Equatable, Error {
    public var code: Int
    public var message: String
    public var data: JSONValue?
}

public struct MCPServerInfo: Codable, Sendable, Equatable {
    public var name: String
    public var version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

public struct MCPTool: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String?
    public var inputSchema: JSONValue

    public init(name: String, description: String? = nil, inputSchema: JSONValue = ToolSchemas.object(properties: [:])) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPResource: Codable, Sendable, Equatable, Identifiable {
    public var id: String { uri }
    public var uri: String
    public var name: String?
    public var description: String?
    public var mimeType: String?
}

public protocol MCPClient: Sendable {
    var name: String { get }
    var requiresNetworkAccess: Bool { get }
    func connect() async throws
    func initialize() async throws -> MCPServerInfo?
    func listTools() async throws -> [MCPTool]
    func callTool(name: String, arguments: JSONValue) async throws -> ToolResult
    func listResources() async throws -> [MCPResource]
    func readResource(uri: String) async throws -> ToolResult
    func close() async
}

public extension MCPClient {
    var requiresNetworkAccess: Bool { false }
    func listResources() async throws -> [MCPResource] { [] }
    func readResource(uri: String) async throws -> ToolResult { throw CodexCoreError.unsupported("MCP resources are not implemented by this client") }
}

/// Minimal stdio MCP client. Requests are serialized by actor isolation and read one newline-delimited JSON-RPC response at a time.
#if os(macOS)
public actor StdioMCPClient: MCPClient {
    public let name: String
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var nextID: Int = 1
    private var connected = false

    public init(name: String, command: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }

    public func connect() async throws {
        guard !connected else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment { env[key] = value }
            process.environment = env
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.connected = true
        _ = stderr
    }

    public func initialize() async throws -> MCPServerInfo? {
        try await connect()
        let result = try await sendRequest(method: "initialize", params: .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("SwiftCodexCore"), "version": .string("0.1.0")])
        ]))
        try await sendNotification(method: "notifications/initialized", params: .object([:]))
        if let serverInfo = result["serverInfo"]?.objectValue {
            return MCPServerInfo(name: serverInfo["name"]?.stringValue ?? name, version: serverInfo["version"]?.stringValue)
        }
        return nil
    }

    public func listTools() async throws -> [MCPTool] {
        let result = try await sendRequest(method: "tools/list", params: .object([:]))
        return try parseTools(result["tools"]?.arrayValue ?? [])
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolResult {
        let result = try await sendRequest(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments
        ]))
        return parseMCPToolResult(result)
    }

    public func listResources() async throws -> [MCPResource] {
        let result = try await sendRequest(method: "resources/list", params: .object([:]))
        return (result["resources"]?.arrayValue ?? []).compactMap { value in
            guard let uri = value["uri"]?.stringValue else { return nil }
            return MCPResource(uri: uri, name: value["name"]?.stringValue, description: value["description"]?.stringValue, mimeType: value["mimeType"]?.stringValue)
        }
    }

    public func readResource(uri: String) async throws -> ToolResult {
        let result = try await sendRequest(method: "resources/read", params: .object(["uri": .string(uri)]))
        let contents = result["contents"]?.arrayValue ?? []
        let text = contents.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        return ToolResult(content: text.isEmpty ? result.description : text, structuredContent: result)
    }

    public func close() async {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        connected = false
    }

    private func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        try await connect()
        let id = nextID
        nextID += 1
        let request = JSONRPCRequest(id: .number(Double(id)), method: method, params: params)
        try write(request)
        while true {
            let response = try readResponse()
            guard let responseID = response.id.map(rpcIDString) else { continue }
            guard responseID == String(id) else { continue }
            if let error = response.error {
                throw CodexCoreError.transportError("MCP JSON-RPC error \(error.code): \(error.message)")
            }
            return response.result ?? .object([:])
        }
    }

    private func sendNotification(method: String, params: JSONValue?) async throws {
        try await connect()
        try write(JSONRPCRequest(id: nil, method: method, params: params))
    }

    private func write(_ request: JSONRPCRequest) throws {
        guard let stdinPipe else { throw CodexCoreError.transportError("MCP server is not connected") }
        let data = try JSONEncoder.codexCompact.encode(request)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readResponse() throws -> JSONRPCResponse {
        guard let stdoutPipe else { throw CodexCoreError.transportError("MCP server is not connected") }
        var data = Data()
        while true {
            let byte = stdoutPipe.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty { throw CodexCoreError.transportError("MCP server closed stdout") }
            if byte[0] == 0x0A { break }
            data.append(byte)
        }
        return try JSONDecoder.codex.decode(JSONRPCResponse.self, from: data)
    }
}
#endif

public final class StreamableHTTPMCPClient: MCPClient, Sendable {
    public let name: String
    public let requiresNetworkAccess = true
    private let endpoint: URL
    private let bearerToken: String?
    private let session: URLSession
    private let idGenerator = LockedCounter()

    public init(name: String, endpoint: URL, bearerToken: String? = nil, session: URLSession = .shared) {
        self.name = name
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.session = session
    }

    public func connect() async throws { }

    public func initialize() async throws -> MCPServerInfo? {
        let result = try await send(method: "initialize", params: .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("SwiftCodexCore"), "version": .string("0.1.0")])
        ]))
        _ = try? await sendNotification(method: "notifications/initialized", params: .object([:]))
        if let serverInfo = result["serverInfo"]?.objectValue {
            return MCPServerInfo(name: serverInfo["name"]?.stringValue ?? name, version: serverInfo["version"]?.stringValue)
        }
        return nil
    }

    public func listTools() async throws -> [MCPTool] {
        let result = try await send(method: "tools/list", params: .object([:]))
        return try parseTools(result["tools"]?.arrayValue ?? [])
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolResult {
        let result = try await send(method: "tools/call", params: .object(["name": .string(name), "arguments": arguments]))
        return parseMCPToolResult(result)
    }

    public func listResources() async throws -> [MCPResource] {
        let result = try await send(method: "resources/list", params: .object([:]))
        return (result["resources"]?.arrayValue ?? []).compactMap { value in
            guard let uri = value["uri"]?.stringValue else { return nil }
            return MCPResource(uri: uri, name: value["name"]?.stringValue, description: value["description"]?.stringValue, mimeType: value["mimeType"]?.stringValue)
        }
    }

    public func readResource(uri: String) async throws -> ToolResult {
        let result = try await send(method: "resources/read", params: .object(["uri": .string(uri)]))
        let text = (result["contents"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        return ToolResult(content: text.isEmpty ? result.description : text, structuredContent: result)
    }

    public func close() async { }

    private func send(method: String, params: JSONValue?) async throws -> JSONValue {
        let id = idGenerator.next()
        let request = JSONRPCRequest(id: .number(Double(id)), method: method, params: params)
        return try await post(request: request, expectsResponse: true)
    }

    private func sendNotification(method: String, params: JSONValue?) async throws -> JSONValue {
        let request = JSONRPCRequest(id: nil, method: method, params: params)
        return try await post(request: request, expectsResponse: false)
    }

    private func post(request rpc: JSONRPCRequest, expectsResponse: Bool) async throws -> JSONValue {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder.codexCompact.encode(rpc)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexCoreError.transportError("MCP HTTP transport returned no HTTP response") }
        if !expectsResponse, http.statusCode == 202 { return .object([:]) }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexCoreError.transportError("MCP HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let jsonData: Data
        if text.contains("data:") {
            let jsonLines = text.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                return value == "[DONE]" ? nil : value
            }
            guard let last = jsonLines.last, let data = last.data(using: .utf8) else { return .object([:]) }
            jsonData = data
        } else {
            jsonData = data
        }
        let responseObject = try JSONDecoder.codex.decode(JSONRPCResponse.self, from: jsonData)
        if let error = responseObject.error {
            throw CodexCoreError.transportError("MCP JSON-RPC error \(error.code): \(error.message)")
        }
        return responseObject.result ?? .object([:])
    }
}

public struct MCPToolAdapter: AgentTool {
    public let serverName: String
    public let tool: MCPTool
    private let client: any MCPClient

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "mcp__\(serverName)__\(tool.name)",
            description: tool.description ?? "MCP tool \(tool.name) from server \(serverName)",
            parameters: tool.inputSchema,
            requiresApproval: false,
            isStateChanging: false
        )
    }

    public init(serverName: String, tool: MCPTool, client: any MCPClient) {
        self.serverName = serverName
        self.tool = tool
        self.client = client
    }

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard !client.requiresNetworkAccess || context.sandboxPolicy.allowNetwork else {
            throw CodexCoreError.approvalRequired("MCP tool \(definition.name) requires network access, but network is disabled by the sandbox policy")
        }
        return try await client.callTool(name: tool.name, arguments: arguments)
    }
}

public actor MCPRegistry {
    private var clients: [String: any MCPClient] = [:]
    private var adapters: [String: MCPToolAdapter] = [:]

    public init() {}

    public func addClient(_ client: any MCPClient, initialize: Bool = true) async throws {
        clients[client.name] = client
        try await client.connect()
        if initialize { _ = try await client.initialize() }
        try await refreshTools(for: client.name)
    }

    public func removeClient(named name: String) async {
        if let client = clients.removeValue(forKey: name) { await client.close() }
        adapters = adapters.filter { !$0.key.hasPrefix("mcp__\(name)__") }
    }

    public func listClients() -> [String] {
        clients.keys.sorted()
    }

    public func refreshTools(for serverName: String? = nil) async throws {
        let selected: [(String, any MCPClient)]
        if let serverName, let client = clients[serverName] {
            selected = [(serverName, client)]
        } else {
            selected = clients.map { ($0.key, $0.value) }
        }
        for (name, client) in selected {
            let tools = try await client.listTools()
            for tool in tools {
                let adapter = MCPToolAdapter(serverName: name, tool: tool, client: client)
                adapters[adapter.definition.name] = adapter
            }
        }
    }

    public func registerAdapters(into registry: ToolRegistry) async {
        for adapter in adapters.values {
            await registry.register(adapter)
        }
    }

    public func toolDefinitions() -> [ToolDefinition] {
        adapters.values.map(\.definition).sorted { $0.name < $1.name }
    }
}

private func parseTools(_ values: [JSONValue]) throws -> [MCPTool] {
    values.compactMap { value in
        guard let name = value["name"]?.stringValue else { return nil }
        return MCPTool(name: name, description: value["description"]?.stringValue, inputSchema: value["inputSchema"] ?? ToolSchemas.object(properties: [:]))
    }
}

private func parseMCPToolResult(_ result: JSONValue) -> ToolResult {
    let content = result["content"]?.arrayValue ?? []
    let pieces = content.map { item -> String in
        if let text = item["text"]?.stringValue { return text }
        if let json = item["json"] { return json.description }
        return item.description
    }
    return ToolResult(
        content: pieces.isEmpty ? result.description : pieces.joined(separator: "\n"),
        structuredContent: result["structuredContent"],
        isError: result["isError"]?.boolValue ?? false,
        metadata: result["_meta"]?.objectValue ?? [:]
    )
}

private func rpcIDString(_ id: JSONValue) -> String {
    switch id {
    case .number(let value): return String(Int(value))
    case .string(let value): return value
    default: return id.description
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 1
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}
