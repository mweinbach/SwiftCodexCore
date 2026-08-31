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
  public var annotations: [String: JSONValue]?
  public var outputSchema: JSONValue?

  public init(
    name: String, description: String? = nil,
    inputSchema: JSONValue = ToolSchemas.object(properties: [:]),
    annotations: [String: JSONValue]? = nil, outputSchema: JSONValue? = nil
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.annotations = annotations
    self.outputSchema = outputSchema
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

extension MCPClient {
  public var requiresNetworkAccess: Bool { false }
  public func listResources() async throws -> [MCPResource] { [] }
  public func readResource(uri: String) async throws -> ToolResult {
    throw CodexCoreError.unsupported("MCP resources are not implemented by this client")
  }
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

    public init(
      name: String, command: String, arguments: [String] = [], environment: [String: String] = [:]
    ) {
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
      let result = try await sendRequest(
        method: "initialize",
        params: .object([
          "protocolVersion": .string("2025-06-18"),
          "capabilities": .object([:]),
          "clientInfo": .object(["name": .string("SwiftCodexCore"), "version": .string("0.1.0")]),
        ]))
      try await sendNotification(method: "notifications/initialized", params: .object([:]))
      if let serverInfo = result["serverInfo"]?.objectValue {
        return MCPServerInfo(
          name: serverInfo["name"]?.stringValue ?? name, version: serverInfo["version"]?.stringValue
        )
      }
      return nil
    }

    public func listTools() async throws -> [MCPTool] {
      let result = try await sendRequest(method: "tools/list", params: .object([:]))
      return try parseTools(result["tools"]?.arrayValue ?? [])
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolResult {
      let result = try await sendRequest(
        method: "tools/call",
        params: .object([
          "name": .string(name),
          "arguments": arguments,
        ]))
      return parseMCPToolResult(result)
    }

    public func listResources() async throws -> [MCPResource] {
      let result = try await sendRequest(method: "resources/list", params: .object([:]))
      return (result["resources"]?.arrayValue ?? []).compactMap { value in
        guard let uri = value["uri"]?.stringValue else { return nil }
        return MCPResource(
          uri: uri, name: value["name"]?.stringValue,
          description: value["description"]?.stringValue, mimeType: value["mimeType"]?.stringValue)
      }
    }

    public func readResource(uri: String) async throws -> ToolResult {
      let result = try await sendRequest(
        method: "resources/read", params: .object(["uri": .string(uri)]))
      let contents = result["contents"]?.arrayValue ?? []
      let text = contents.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
      return ToolResult(
        content: text.isEmpty ? result.description : text, structuredContent: result)
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
      guard let stdinPipe else {
        throw CodexCoreError.transportError("MCP server is not connected")
      }
      let data = try JSONEncoder.codexCompact.encode(request)
      stdinPipe.fileHandleForWriting.write(data)
      stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readResponse() throws -> JSONRPCResponse {
      guard let stdoutPipe else {
        throw CodexCoreError.transportError("MCP server is not connected")
      }
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

/// Streamable HTTP transport with stateful sessions and host-owned credentials.
/// OAuth browser authorization remains the host's responsibility; a refreshing
/// AuthorizationProvider can supply fresh headers without rebuilding the client.
public actor StreamableHTTPMCPClient: MCPClient {
  public let name: String
  public let requiresNetworkAccess = true
  private let endpoint: URL
  private let bearerToken: String?
  private let authorizationProvider: (any AuthorizationProvider)?
  private let session: URLSession
  private let idGenerator = LockedCounter()
  private var sessionID: String?
  private var protocolVersion = "2025-06-18"
  private var initializeTask: Task<MCPServerInfo?, Error>?
  private var initialized = false
  private var serverInfo: MCPServerInfo?
  private var closed = false
  private var generation = UUID()

  public init(
    name: String, endpoint: URL, bearerToken: String? = nil, session: URLSession = .shared,
    authorizationProvider: (any AuthorizationProvider)? = nil
  ) {
    self.name = name
    self.endpoint = endpoint
    self.bearerToken = bearerToken
    self.session = session
    self.authorizationProvider = authorizationProvider
  }

  public func connect() async throws { closed = false }

  public func initialize() async throws -> MCPServerInfo? {
    guard !closed else { throw CodexCoreError.invalidState("MCP client is closed") }
    if initialized { return serverInfo }
    if let initializeTask { return try await initializeTask.value }
    let currentGeneration = generation
    let task = Task { try await self.performInitialize() }
    initializeTask = task
    defer { if generation == currentGeneration { initializeTask = nil } }
    return try await task.value
  }

  private func performInitialize() async throws -> MCPServerInfo? {
    let currentGeneration = generation
    sessionID = nil
    let result = try await send(method: "initialize", params: .object([
      "protocolVersion": .string(protocolVersion), "capabilities": .object([:]),
      "clientInfo": .object(["name": .string("SwiftCodexCore"), "version": .string("0.1.0")]),
    ]))
    try Task.checkCancellation()
    guard !closed, generation == currentGeneration else { throw CancellationError() }
    if let negotiated = result["protocolVersion"]?.stringValue { protocolVersion = negotiated }
    _ = try await sendNotification(method: "notifications/initialized", params: .object([:]))
    try Task.checkCancellation()
    guard !closed, generation == currentGeneration else { throw CancellationError() }
    if let info = result["serverInfo"]?.objectValue {
      serverInfo = MCPServerInfo(name: info["name"]?.stringValue ?? name, version: info["version"]?.stringValue)
    }
    initialized = true
    return serverInfo
  }

  public func listTools() async throws -> [MCPTool] {
    try parseTools(await paginatedList(method: "tools/list", key: "tools"))
  }

  public func callTool(name: String, arguments: JSONValue) async throws -> ToolResult {
    parseMCPToolResult(try await send(method: "tools/call", params: .object(["name": .string(name), "arguments": arguments])))
  }

  public func listResources() async throws -> [MCPResource] {
    try await paginatedList(method: "resources/list", key: "resources").compactMap { value in
      guard let uri = value["uri"]?.stringValue else { return nil }
      return MCPResource(uri: uri, name: value["name"]?.stringValue,
        description: value["description"]?.stringValue, mimeType: value["mimeType"]?.stringValue)
    }
  }

  public func readResource(uri: String) async throws -> ToolResult {
    let result = try await send(method: "resources/read", params: .object(["uri": .string(uri)]))
    let text = (result["contents"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    return ToolResult(content: text.isEmpty ? result.description : text, structuredContent: result)
  }

  public func close() async {
    closed = true
    generation = UUID()
    initializeTask?.cancel()
    initializeTask = nil
    initialized = false
    serverInfo = nil
    let previousSessionID = sessionID
    sessionID = nil
    if let previousSessionID {
      var request = URLRequest(url: endpoint, timeoutInterval: 5)
      request.httpMethod = "DELETE"
      request.setValue(previousSessionID, forHTTPHeaderField: "Mcp-Session-Id")
      request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
      if let headers = try? await authorizationHeaders() {
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        _ = try? await session.data(for: request)
      }
    }
  }

  private func paginatedList(method: String, key: String) async throws -> [JSONValue] {
    var values: [JSONValue] = []
    var cursor: String?
    var visited: Set<String> = []
    for _ in 0..<100 {
      let params: JSONValue = .object(cursor.map { ["cursor": .string($0)] } ?? [:])
      let result = try await send(method: method, params: params)
      values.append(contentsOf: result[key]?.arrayValue ?? [])
      guard let next = result["nextCursor"]?.stringValue, !next.isEmpty else { return values }
      guard visited.insert(next).inserted else { throw CodexCoreError.transportError("MCP pagination repeated a cursor") }
      cursor = next
    }
    throw CodexCoreError.transportError("MCP catalog exceeded 100 pages")
  }

  private func send(method: String, params: JSONValue?) async throws -> JSONValue {
    let request = JSONRPCRequest(id: .number(Double(idGenerator.next())), method: method, params: params)
    return try await post(request: request, expectsResponse: true)
  }

  private func sendNotification(method: String, params: JSONValue?) async throws -> JSONValue {
    try await post(request: JSONRPCRequest(id: nil, method: method, params: params), expectsResponse: false)
  }

  private func authorizationHeaders() async throws -> [String: String] {
    if let authorizationProvider { return try await authorizationProvider.authorizationHeaders() }
    return bearerToken.map { ["Authorization": "Bearer \($0)"] } ?? [:]
  }

  private func post(request rpc: JSONRPCRequest, expectsResponse: Bool, canRefresh: Bool = true) async throws -> JSONValue {
    try Task.checkCancellation()
    guard !closed else { throw CodexCoreError.invalidState("MCP client is closed") }
    let currentGeneration = generation
    var request = URLRequest(url: endpoint, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
    if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
    for (key, value) in try await authorizationHeaders() { request.setValue(value, forHTTPHeaderField: key) }
    request.httpBody = try JSONEncoder.codexCompact.encode(rpc)
    let (bytes, response) = try await session.bytes(for: request)
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse else { throw CodexCoreError.transportError("MCP HTTP transport returned no HTTP response") }
    guard !closed, generation == currentGeneration else { throw CancellationError() }
    if http.statusCode == 401, canRefresh, let refreshing = authorizationProvider as? any TokenRefreshingAuthorizationProvider {
      try await refreshing.refreshNow()
      return try await post(request: rpc, expectsResponse: expectsResponse, canRefresh: false)
    }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 404, sessionID != nil {
        sessionID = nil
        initialized = false
      }
      throw CodexCoreError.transportError("MCP HTTP \(http.statusCode); reconnect the server if its session expired")
    }
    if rpc.method == "initialize", let assigned = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
      guard !assigned.isEmpty, assigned.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
        throw CodexCoreError.transportError("MCP returned an invalid session ID")
      }
      sessionID = assigned
    }
    if !expectsResponse { return .object([:]) }
    let isSSE = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
    var data = Data()
    var eventLines: [String] = []
    var receivedBytes = 0
    if isSSE {
      // AsyncBytes.lines omits blank lines, which are SSE event boundaries.
      var lineBytes = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        receivedBytes += 1
        guard receivedBytes <= 16 * 1024 * 1024 else { throw CodexCoreError.transportError("MCP response exceeded 16 MB") }
        if byte == 10 {
          if lineBytes.last == 13 { lineBytes.removeLast() }
          let line = String(decoding: lineBytes, as: UTF8.self)
          lineBytes.removeAll(keepingCapacity: true)
          if line.isEmpty {
            if let result = try decodeResponse(Data(eventLines.joined(separator: "\n").utf8), id: rpc.id) { return result }
            eventLines.removeAll(keepingCapacity: true)
          } else if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            if value != "[DONE]" { eventLines.append(value) }
          }
        } else {
          lineBytes.append(byte)
        }
      }
      if !lineBytes.isEmpty {
        let line = String(decoding: lineBytes, as: UTF8.self)
        if line.hasPrefix("data:") { eventLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)) }
      }
      data = Data(eventLines.joined(separator: "\n").utf8)
    } else {
      for try await byte in bytes {
        try Task.checkCancellation()
        data.append(byte)
        guard data.count <= 16 * 1024 * 1024 else { throw CodexCoreError.transportError("MCP response exceeded 16 MB") }
      }
    }
    guard let result = try decodeResponse(data, id: rpc.id) else {
      throw CodexCoreError.transportError("MCP response did not match the request ID")
    }
    return result
  }

  private func decodeResponse(_ data: Data, id: JSONValue?) throws -> JSONValue? {
    guard !data.isEmpty else { return nil }
    let response = try JSONDecoder.codex.decode(JSONRPCResponse.self, from: data)
    guard response.id == id else { return nil }
    if let error = response.error { throw CodexCoreError.transportError("MCP JSON-RPC error \(error.code): \(error.message)") }
    return response.result
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
      outputSchema: tool.outputSchema,
      requiresApproval: tool.annotations?["readOnlyHint"]?.boolValue != true,
      isStateChanging: tool.annotations?["readOnlyHint"]?.boolValue != true,
      namespace: "mcp__\(serverName)"
    )
  }

  public init(serverName: String, tool: MCPTool, client: any MCPClient) {
    self.serverName = serverName
    self.tool = tool
    self.client = client
  }

  public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    guard !client.requiresNetworkAccess || context.sandboxPolicy.allowNetwork else {
      throw CodexCoreError.approvalRequired(
        "MCP tool \(definition.name) requires network access, but network is disabled by the sandbox policy"
      )
    }
    return try await client.callTool(name: tool.name, arguments: arguments)
  }
}

public actor MCPRegistry {
  private var clients: [String: any MCPClient] = [:]
  private var adapters: [String: MCPToolAdapter] = [:]
  private var registeredAdapterNames: Set<String> = []
  private var generations: [String: UUID] = [:]

  public init() {}

  public func addClient(_ client: any MCPClient, initialize: Bool = true) async throws {
    let generation = UUID()
    generations[client.name] = generation
    do {
      try await client.connect()
      if initialize { _ = try await client.initialize() }
      let tools = try await client.listTools()
      guard generations[client.name] == generation else { throw CancellationError() }
      let previous = clients[client.name]
      clients[client.name] = client
      replaceTools(tools, serverName: client.name, client: client)
      if let previous {
        let previousObject = previous as AnyObject
        let nextObject = client as AnyObject
        if previousObject !== nextObject { await previous.close() }
      }
    } catch {
      await client.close()
      throw error
    }
  }

  public func removeClient(named name: String) async {
    generations[name] = UUID()
    let client = clients.removeValue(forKey: name)
    adapters = adapters.filter { $0.value.serverName != name }
    await client?.close()
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
      let generation = generations[name]
      let tools = try await client.listTools()
      guard generations[name] == generation, clients[name] != nil else { continue }
      replaceTools(tools, serverName: name, client: client)
    }
  }

  private func replaceTools(_ tools: [MCPTool], serverName: String, client: any MCPClient) {
    adapters = adapters.filter { $0.value.serverName != serverName }
    for tool in tools {
      let adapter = MCPToolAdapter(serverName: serverName, tool: tool, client: client)
      adapters[adapter.definition.name] = adapter
    }
  }

  public func registerAdapters(into registry: ToolRegistry) async {
    let currentNames = Set(adapters.keys)
    let obsolete = registeredAdapterNames.subtracting(currentNames)
    let replacements: [any AgentTool] = Array(adapters.values)
    registeredAdapterNames = currentNames
    await registry.replaceTools(replacements, removing: obsolete)
  }

  public func toolDefinitions() -> [ToolDefinition] {
    adapters.values.map(\.definition).sorted { $0.name < $1.name }
  }
}

private func parseTools(_ values: [JSONValue]) throws -> [MCPTool] {
  values.compactMap { value in
    guard let name = value["name"]?.stringValue else { return nil }
    return MCPTool(
      name: name, description: value["description"]?.stringValue,
      inputSchema: value["inputSchema"] ?? ToolSchemas.object(properties: [:]),
      annotations: value["annotations"]?.objectValue, outputSchema: value["outputSchema"])
  }
}

func parseMCPToolResult(_ result: JSONValue) -> ToolResult {
  let content = result["content"]?.arrayValue ?? []
  let contentBlocks = content.compactMap { item -> ToolContentBlock? in
    guard case .object(let fields) = item else { return nil }
    return ToolContentBlock(fields: fields)
  }
  let pieces = content.map { item -> String in
    if let text = item["text"]?.stringValue { return text }
    if let json = item["json"] { return json.description }
    return item.description
  }
  return ToolResult(
    content: pieces.isEmpty ? result.description : pieces.joined(separator: "\n"),
    structuredContent: result["structuredContent"],
    isError: result["isError"]?.boolValue ?? false,
    metadata: result["_meta"]?.objectValue ?? [:],
    contentBlocks: contentBlocks.isEmpty ? nil : contentBlocks,
    codeModeResult: result
  )
}

func rpcIDString(_ id: JSONValue) -> String {
  switch id {
  case .number(let value):
    if let integer = Int64(exactly: value) {
      return String(integer)
    }
    return String(value)
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
