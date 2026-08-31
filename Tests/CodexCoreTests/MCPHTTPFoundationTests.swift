import Foundation
import XCTest
@testable import CodexCore

final class MCPHTTPFoundationTests: XCTestCase, @unchecked Sendable {
  override func tearDown() { MCPTestURLProtocol.handler = nil; super.tearDown() }

  func testStatefulSessionPaginatedSSECatalogAndClose() async throws {
    MCPTestURLProtocol.handler = { request in
      if request.httpMethod == "DELETE" {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "session-one")
        return (204, [:], "")
      }
      let rpc = try self.rpc(request)
      let id = rpc["id"] ?? .null
      if rpc["method"]?.stringValue == "initialize" {
        XCTAssertNil(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
        return self.response(id: id, result: .object([
          "protocolVersion": .string("2025-06-18"), "serverInfo": .object(["name": .string("fixture")]),
        ]), headers: ["Mcp-Session-Id": "session-one"])
      }
      XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "session-one")
      XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
      if rpc["method"]?.stringValue == "notifications/initialized" { return (202, [:], "") }
      let second = rpc["params"]?["cursor"]?.stringValue == "next"
      var result: [String: JSONValue] = ["tools": .array([.object([
        "name": .string(second ? "beta" : "alpha"), "inputSchema": ToolSchemas.object(properties: [:]),
        "annotations": .object(["readOnlyHint": .bool(true)]),
      ])])]
      if !second { result["nextCursor"] = .string("next") }
      let payload = self.response(id: id, result: .object(result)).2
      return (200, ["Content-Type": "text/event-stream"],
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n" +
        "data: \(payload)\n\n")
    }
    let client = makeClient()
    let info = try await client.initialize()
    XCTAssertEqual(info?.name, "fixture")
    let tools = try await client.listTools()
    XCTAssertEqual(tools.map(\.name), ["alpha", "beta"])
    XCTAssertEqual(tools.first?.annotations?["readOnlyHint"], .bool(true))
    await client.close()
    do { _ = try await client.listTools(); XCTFail("Closed session must reject calls") }
    catch CodexCoreError.invalidState { }
  }

  func testRefreshingAuthorizationRetriesUnauthorizedOnce() async throws {
    let auth = MCPTestAuthorization()
    MCPTestURLProtocol.handler = { request in
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" { return (401, [:], "") }
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new")
      return self.response(id: try self.rpc(request)["id"] ?? .null, result: .object(["tools": .array([])]))
    }
    let client = makeClient(auth: auth)
    let tools = try await client.listTools()
    XCTAssertTrue(tools.isEmpty)
    let refreshes = await auth.refreshes
    XCTAssertEqual(refreshes, 1)
  }

  func testMismatchedResponseIDFailsInsteadOfAcceptingOtherResult() async throws {
    MCPTestURLProtocol.handler = { _ in self.response(id: .number(999), result: .object(["tools": .array([])])) }
    do { _ = try await makeClient().listTools(); XCTFail("Wrong response ID must fail") }
    catch CodexCoreError.transportError(let message) { XCTAssertTrue(message.contains("request ID")) }
  }

  func testRefreshingAndDisconnectingRemovesStaleTools() async throws {
    let runtime = CodexRuntime(modelProvider: ScriptedModelProvider(batches: []), tools: [])
    let client = MutableMCPFixture()
    try await runtime.connectMCP(client)
    try await runtime.connectMCP(client)
    let closedByReconnect = await client.closed
    XCTAssertFalse(closedByReconnect, "Reconnecting the same instance must not close its new connection")
    await client.setNames(["new"])
    try await runtime.refreshMCPTools()
    let refreshed = await runtime.toolRegistry.listDefinitions().map(\.name)
    XCTAssertEqual(refreshed, ["mcp__fixture__new"])
    await runtime.disconnectMCP(serverName: "fixture")
    let remaining = await runtime.toolRegistry.listDefinitions()
    XCTAssertTrue(remaining.isEmpty)
    let closed = await client.closed
    XCTAssertTrue(closed)
  }

  func testMutationApprovalIsConservativeAndReadOnlyHintIsPreserved() {
    let unknown = MCPToolAdapter(serverName: "fixture", tool: MCPTool(name: "write"), client: MutableMCPFixture())
    XCTAssertTrue(unknown.definition.requiresApproval)
    let read = MCPToolAdapter(serverName: "fixture", tool: MCPTool(name: "read", annotations: ["readOnlyHint": .bool(true)]), client: MutableMCPFixture())
    XCTAssertFalse(read.definition.requiresApproval)
  }

  private func makeClient(auth: (any AuthorizationProvider)? = nil) -> StreamableHTTPMCPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MCPTestURLProtocol.self]
    return StreamableHTTPMCPClient(name: "fixture", endpoint: URL(string: "https://mcp.test/mcp")!,
      session: URLSession(configuration: config), authorizationProvider: auth)
  }

  private func rpc(_ request: URLRequest) throws -> JSONValue {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
    }
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  private func response(id: JSONValue, result: JSONValue, headers: [String: String] = [:]) -> (Int, [String: String], String) {
    let value = JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    let body = String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    return (200, ["Content-Type": "application/json"].merging(headers, uniquingKeysWith: { _, new in new }), body)
  }
}

private actor MCPTestAuthorization: TokenRefreshingAuthorizationProvider {
  var refreshes = 0
  func authorizationHeaders() async throws -> [String: String] { ["Authorization": refreshes == 0 ? "Bearer old" : "Bearer new"] }
  func refreshNow() async throws { refreshes += 1 }
}

private actor MutableMCPFixture: MCPClient {
  let name = "fixture"
  var names = ["old"]
  var closed = false
  func setNames(_ names: [String]) { self.names = names }
  func connect() async throws { }
  func initialize() async throws -> MCPServerInfo? { nil }
  func listTools() async throws -> [MCPTool] { names.map { MCPTool(name: $0) } }
  func callTool(name: String, arguments: JSONValue) async throws -> ToolResult { ToolResult(content: name) }
  func close() async { closed = true }
}

private final class MCPTestURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], String))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      guard let handler = Self.handler else { throw URLError(.badServerResponse) }
      let (status, headers, body) = try handler(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() { }
}
