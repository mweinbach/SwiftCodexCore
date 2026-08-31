import Foundation
import XCTest

@testable import CodexCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class ResponsesLiteHostedToolsTests: XCTestCase {
  func testAgentHTTPRequestsPreserveWebSearchAndLocalToolShapesInEveryMode() async throws {
    for mode in AgentToolMode.allCases {
      let body = try await captureAgentRequest(mode: mode, allowNetwork: true)
      XCTAssertNil(body["tools"])
      XCTAssertNil(body["instructions"])
      XCTAssertEqual(body["parallel_tool_calls"], .bool(false))
      XCTAssertEqual(body["reasoning"]?["context"], .string("all_turns"))
      let input = try XCTUnwrap(body["input"]?.arrayValue)
      XCTAssertEqual(input.first?["type"], .string("additional_tools"))
      XCTAssertEqual(input.first?["role"], .string("developer"))
      let tools = try XCTUnwrap(input.first?["tools"]?.arrayValue)
      XCTAssertEqual(tools.first { $0["type"] == .string("web_search") },
        .object(Self.webSearch.fields))
      let localTools = tools.filter { $0["type"] != .string("web_search") }
      let names = Set(localTools.compactMap { $0["name"]?.stringValue })
      switch mode {
      case .direct: XCTAssertEqual(names, ["echo"])
      case .codeMode: XCTAssertEqual(names, ["echo", "exec", "wait"])
      case .codeModeOnly: XCTAssertEqual(names, ["exec", "wait"])
      }
      for tool in localTools {
        if tool["name"] == .string("exec") {
          XCTAssertEqual(tool["type"], .string("custom"))
          XCTAssertEqual(tool["format"]?["type"], .string("grammar"))
        } else {
          XCTAssertEqual(tool["type"], .string("function"))
          XCTAssertEqual(tool["parameters"]?["type"], .string("object"))
        }
      }
      XCTAssertFalse(tools.contains { $0["type"] == .string("image_generation") })
    }
  }

  func testLiteWebSearchStillHonorsDisabledNetworkAccess() async throws {
    let body = try await captureAgentRequest(mode: .codeModeOnly, allowNetwork: false)
    let tools = try XCTUnwrap(body["input"]?.arrayValue?.first?["tools"]?.arrayValue)
    XCTAssertFalse(tools.contains { $0["type"] == .string("web_search") })
    XCTAssertTrue(tools.contains { $0["name"] == .string("exec") })
  }

  func testPreShapedNamespacesAndDiscoverySurviveLiteCompaction() throws {
    let namespace = ResponseToolDefinition(type: "namespace", options: [
      "name": .string("fixture"),
      "description": .string("Caller-provided namespace"),
      "tools": .array([.object(EchoTool().definition.responseTool.fields)]),
    ])
    let discovery = ResponseToolDefinition(type: "tool_search", options: [
      "execution": .string("client"),
      "description": .string("Discover tools"),
      "parameters": ToolSchemas.object(properties: [:]),
    ])
    let supported = [namespace, discovery, Self.webSearch]
    let request = ResponsesCompactionRequest(
      model: "gpt-5.6-sol",
      input: [ResponseInputBuilder.additionalTools(supported + supported + [.imageGeneration()])],
      useResponsesLite: true
    )
    let body = try JSONDecoder.codex.decode(JSONValue.self, from: JSONEncoder.codexCompact.encode(request))
    XCTAssertEqual(body["input"]?.arrayValue?.first?["tools"],
      .array(supported.map { .object($0.fields) }))
    XCTAssertNil(body["tools"])
  }

  private static let webSearch = ResponseToolDefinition.webSearch(
    searchContextSize: "medium", externalWebAccess: true)

  private func captureAgentRequest(mode: AgentToolMode, allowNetwork: Bool) async throws -> JSONValue {
    let capture = LiteHostedRequestCapture()
    LiteHostedURLProtocol.handler = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-openai-internal-codex-responses-lite"), "true")
      let body = try JSONDecoder.codex.decode(JSONValue.self, from: Self.bodyData(request))
      capture.store(body)
    }
    defer { LiteHostedURLProtocol.handler = nil }
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [LiteHostedURLProtocol.self]
    var clientOptions = OpenAIResponsesClient.Options.chatGPTCodexBackend
    clientOptions.endpoint = URL(string: "https://provider.test/backend-api/codex/responses")!
    clientOptions.supportsWebSockets = false
    let client = OpenAIResponsesClient(auth: LiteHostedAuthProvider(), options: clientOptions,
      session: URLSession(configuration: sessionConfiguration))
    var sandbox = SandboxPolicy.workspaceWrite
    sandbox.allowNetwork = allowNetwork
    let configuration = AgentConfiguration(
      instructions: "Test Lite hosted tools",
      sandboxPolicy: sandbox,
      useResponsesLite: true,
      serverTools: [Self.webSearch, .imageGeneration()],
      toolMode: mode
    )
    let agent = CodexAgent(configuration: configuration, modelProvider: client,
      toolRegistry: ToolRegistry(tools: [EchoTool()]),
      threadManager: ThreadManager(store: InMemoryThreadStore()))
    let thread = try await agent.createThread()
    for try await _ in agent.startTurn(threadID: thread.id, input: TurnInput("hello")).events { }
    return try XCTUnwrap(capture.value)
  }

  private static func bodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
      if count == 0 { return result }
      result.append(contentsOf: buffer.prefix(count))
    }
  }
}

private final class LiteHostedRequestCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var captured: JSONValue?
  var value: JSONValue? { lock.withLock { captured } }
  func store(_ value: JSONValue) { lock.withLock { captured = value } }
}

private struct LiteHostedAuthProvider: AuthorizationProvider {
  func authorizationHeaders() async throws -> [String: String] { ["Authorization": "Bearer fixture"] }
}

private final class LiteHostedURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> Void)?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      guard let handler = Self.handler else { throw URLError(.badServerResponse) }
      try handler(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(#"{"id":"fixture","output_text":"ok"}"#.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
