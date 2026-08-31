import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import CodexCore

final class ModelDefaultsCompatibilityTests: XCTestCase {
  func testBundledLiteDefaultsOmitAutomaticCompactionOnTheWire() async throws {
    for info in OpenAIModelInfo.gpt56FallbackCatalog {
      XCTAssertNotNil(info.automaticCompactionTokenLimit)
      var configuration = AgentConfiguration()
      configuration.applyModelDefaults(info)
      let request = try await captureRequest(configuration: configuration)
      XCTAssertEqual(request.body["model"]?.stringValue, info.slug)
      XCTAssertEqual(request.liteHeader, "true")
      XCTAssertNil(request.body["context_management"],
        "Catalog defaults must not send unsupported server compaction with Responses Lite")
    }
  }

  func testExplicitStandardResponsesKeepsAutomaticCompaction() async throws {
    let info = try XCTUnwrap(OpenAIModelInfo.gpt56FallbackCatalog.first)
    var configuration = AgentConfiguration(useResponsesLite: false)
    configuration.applyModelDefaults(info)
    let request = try await captureRequest(configuration: configuration)
    XCTAssertNil(request.liteHeader)
    XCTAssertEqual(request.body["context_management"]?.arrayValue?.first?["compact_threshold"]?.doubleValue,
      info.automaticCompactionTokenLimit.map(Double.init))
  }

  func testExplicitCompactionIsPreservedForRequestValidation() throws {
    let explicit = [ResponseContextManagement(compactThreshold: 100_000)]
    var configuration = AgentConfiguration(contextManagement: explicit, useResponsesLite: true)
    configuration.applyModelDefaults(try XCTUnwrap(OpenAIModelInfo.gpt56FallbackCatalog.first))
    XCTAssertEqual(configuration.contextManagement, explicit)
    XCTAssertEqual(configuration.useResponsesLite, true)
  }

  private func captureRequest(configuration: AgentConfiguration) async throws -> CapturedModelRequest {
    let capture = ModelRequestCapture()
    ModelDefaultsURLProtocol.handler = { request in
      let body = try JSONDecoder.codex.decode(JSONValue.self, from: Self.bodyData(request))
      capture.store(CapturedModelRequest(body: body,
        liteHeader: request.value(forHTTPHeaderField: "X-OpenAI-Internal-Codex-Responses-Lite")))
    }
    defer { ModelDefaultsURLProtocol.handler = nil }
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [ModelDefaultsURLProtocol.self]
    var clientOptions = OpenAIResponsesClient.Options.chatGPTCodexBackend
    clientOptions.endpoint = URL(string: "https://provider.test/backend-api/codex/responses")!
    clientOptions.supportsWebSockets = false
    let client = OpenAIResponsesClient(auth: ModelDefaultsAuthProvider(), options: clientOptions,
      session: URLSession(configuration: sessionConfiguration))
    let agent = CodexAgent(configuration: configuration, modelProvider: client,
      toolRegistry: ToolRegistry(tools: []), threadManager: ThreadManager(store: InMemoryThreadStore()))
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

private struct CapturedModelRequest: Sendable {
  let body: JSONValue
  let liteHeader: String?
}

private final class ModelRequestCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var captured: CapturedModelRequest?
  var value: CapturedModelRequest? { lock.withLock { captured } }
  func store(_ value: CapturedModelRequest) { lock.withLock { captured = value } }
}

private struct ModelDefaultsAuthProvider: AuthorizationProvider {
  func authorizationHeaders() async throws -> [String: String] { ["Authorization": "Bearer fixture"] }
}

private final class ModelDefaultsURLProtocol: URLProtocol, @unchecked Sendable {
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
