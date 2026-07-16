import Foundation
import XCTest

@testable import CodexCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class OpenAIResponsesWebSocketTests: XCTestCase {
  override func tearDown() {
    WebSocketURLProtocol.handler = nil
    super.tearDown()
  }

  func testPreferredModelUsesWebSocketWireContract() async throws {
    let response = HTTPURLResponse(
      url: URL(string: "wss://example.test/v1/responses?tenant=one")!,
      statusCode: 101,
      httpVersion: nil,
      headerFields: ["X-Models-Etag": "catalog-v2"]
    )
    let task = FakeResponsesWebSocketTask(
      response: response,
      incoming: [
        .success(.text(#"{"type":"response.output_text.delta","delta":"hello"}"#)),
        .success(.text(#"{"type":"response.completed","response":{"id":"resp_ws"}}"#)),
      ]
    )
    let factory = FakeResponsesWebSocketFactory(tasks: [task])
    let client = makeClient(
      endpoint: URL(string: "https://example.test/v1/responses?tenant=one")!,
      factory: factory,
      extraHeaders: ["X-Test-Header": "present"]
    )

    let events = try await collect(
      client.streamResponse(
        ResponsesRequest(
          model: "gpt-5.6-sol",
          input: [ResponseInputBuilder.userMessage("hello")],
          useResponsesLite: true
        )))

    XCTAssertTrue(events.contains(.outputTextDelta("hello")))
    XCTAssertTrue(events.contains(.completed(responseID: "resp_ws", usage: nil)))
    let request = try XCTUnwrap(factory.requests.first)
    XCTAssertEqual(request.url?.scheme, "wss")
    XCTAssertEqual(request.url?.path, "/v1/responses")
    XCTAssertEqual(request.url?.query, "tenant=one")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ws-test")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test-Header"), "present")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "x-openai-internal-codex-responses-lite"), "true")
    XCTAssertTrue(
      request.value(forHTTPHeaderField: "OpenAI-Beta")?.contains(
        "responses_websockets=2026-02-06") == true)
    XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Client-Request-Id"))
    XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
    XCTAssertTrue(task.didResume)
    XCTAssertTrue(task.didCancel)

    guard case .text(let sent) = try XCTUnwrap(task.sentMessages.first) else {
      return XCTFail("Expected a text frame")
    }
    let payload = try JSONDecoder.codex.decode(JSONValue.self, from: Data(sent.utf8))
    XCTAssertEqual(payload["type"]?.stringValue, "response.create")
    XCTAssertEqual(payload["model"]?.stringValue, "gpt-5.6-sol")
    XCTAssertNil(payload["useResponsesLite"])
  }

  func testProviderGateKeepsPreferredModelOnHTTP() async throws {
    let factory = FakeResponsesWebSocketFactory(tasks: [])
    let requests = WebSocketLocked<[URLRequest]>([])
    WebSocketURLProtocol.handler = { request in
      requests.withValue { $0.append(request) }
      return WebSocketURLProtocol.response(
        for: request,
        body: #"{"id":"resp_http","output_text":"http"}"#
      )
    }
    let client = makeClient(
      factory: factory,
      supportsWebSockets: false
    )

    let events = try await collect(
      client.streamResponse(
        ResponsesRequest(
          model: "gpt-5.6-sol",
          input: [ResponseInputBuilder.userMessage("hello")]
        )))

    XCTAssertTrue(events.contains(.outputTextDelta("http")))
    XCTAssertEqual(factory.requests.count, 0)
    XCTAssertEqual(requests.value.count, 1)
  }

  func testEarlyWebSocketFailureFallsBackOnceWithStableIdentity() async throws {
    let task = FakeResponsesWebSocketTask(
      incoming: [.failure(URLError(.networkConnectionLost))]
    )
    let factory = FakeResponsesWebSocketFactory(tasks: [task])
    let httpRequests = WebSocketLocked<[URLRequest]>([])
    WebSocketURLProtocol.handler = { request in
      httpRequests.withValue { $0.append(request) }
      return WebSocketURLProtocol.response(
        for: request,
        body: #"{"id":"resp_fallback","output_text":"fallback"}"#
      )
    }
    let client = makeClient(factory: factory)
    let request = ResponsesRequest(
      model: "gpt-5.6-sol",
      input: [ResponseInputBuilder.userMessage("hello")]
    )

    let first = try await collect(client.streamResponse(request))
    let second = try await collect(client.streamResponse(request))

    XCTAssertTrue(first.contains(.outputTextDelta("fallback")))
    XCTAssertTrue(second.contains(.outputTextDelta("fallback")))
    XCTAssertEqual(factory.requests.count, 1)
    XCTAssertEqual(httpRequests.value.count, 2)
    let webSocketRequest = try XCTUnwrap(factory.requests.first)
    let firstHTTP = httpRequests.value[0]
    XCTAssertEqual(
      webSocketRequest.value(forHTTPHeaderField: "X-Client-Request-Id"),
      firstHTTP.value(forHTTPHeaderField: "X-Client-Request-Id")
    )
    XCTAssertEqual(
      webSocketRequest.value(forHTTPHeaderField: "Idempotency-Key"),
      firstHTTP.value(forHTTPHeaderField: "Idempotency-Key")
    )
  }

  func testWebSocketDoesNotReplayAfterSemanticOutputOrCancellation() async throws {
    let semanticTask = FakeResponsesWebSocketTask(incoming: [
      .success(.text(#"{"type":"response.output_text.delta","delta":"partial"}"#)),
      .failure(URLError(.networkConnectionLost)),
    ])
    let cancellationTask = FakeResponsesWebSocketTask(
      incoming: [.failure(CancellationError())]
    )
    let factory = FakeResponsesWebSocketFactory(tasks: [semanticTask, cancellationTask])
    let httpAttempts = WebSocketLocked(0)
    WebSocketURLProtocol.handler = { request in
      httpAttempts.withValue { $0 += 1 }
      return WebSocketURLProtocol.response(for: request, body: #"{"output_text":"duplicate"}"#)
    }

    let semanticClient = makeClient(factory: factory)
    var received: [ModelStreamEvent] = []
    do {
      for try await event in semanticClient.streamResponse(
        ResponsesRequest(
          model: "gpt-5.6-sol",
          input: [ResponseInputBuilder.userMessage("hello")]
        ))
      {
        received.append(event)
      }
      XCTFail("Expected the interrupted semantic stream to fail")
    } catch {
      XCTAssertFalse(error is CancellationError)
    }
    XCTAssertTrue(received.contains(.outputTextDelta("partial")))
    XCTAssertEqual(httpAttempts.value, 0)

    let cancellationClient = makeClient(factory: factory)
    do {
      _ = try await collect(
        cancellationClient.streamResponse(
          ResponsesRequest(
            model: "gpt-5.6-sol",
            input: [ResponseInputBuilder.userMessage("cancel")]
          )))
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(httpAttempts.value, 0)
  }

  private func makeClient(
    endpoint: URL = URL(string: "https://example.test/v1/responses")!,
    factory: FakeResponsesWebSocketFactory,
    extraHeaders: [String: String] = [:],
    supportsWebSockets: Bool = true
  ) -> OpenAIResponsesClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WebSocketURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let manager = OpenAIModelsManager(
      auth: WebSocketAuthProvider(),
      options: .init(
        endpoint: URL(string: "https://example.test/v1/models")!,
        cacheURL: nil
      ),
      session: session,
      fallbackModels: [
        OpenAIModelInfo(fields: [
          "slug": .string("gpt-5.6-sol"),
          "prefer_websockets": .bool(true),
          "visibility": .string("list"),
        ])
      ]
    )
    return OpenAIResponsesClient(
      auth: WebSocketAuthProvider(),
      options: .init(
        endpoint: endpoint,
        extraHeaders: extraHeaders,
        supportsWebSockets: supportsWebSockets
      ),
      session: session,
      modelsManager: manager,
      transportPolicy: .init(maximumRetryCount: 0),
      sleeper: { _ in },
      webSocketFactory: factory
    )
  }

  private func collect(
    _ stream: AsyncThrowingStream<ModelStreamEvent, Error>
  ) async throws -> [ModelStreamEvent] {
    var events: [ModelStreamEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }
}

private struct WebSocketAuthProvider: AuthorizationProvider {
  func authorizationHeaders() async throws -> [String: String] {
    ["Authorization": "Bearer ws-test"]
  }
}

private final class FakeResponsesWebSocketFactory: ResponsesWebSocketTaskFactory,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var tasks: [FakeResponsesWebSocketTask]
  private var capturedRequests: [URLRequest] = []

  init(tasks: [FakeResponsesWebSocketTask]) {
    self.tasks = tasks
  }

  var requests: [URLRequest] { lock.withLock { capturedRequests } }

  func makeTask(
    with request: URLRequest,
    maximumMessageSize _: Int
  ) -> any ResponsesWebSocketTasking {
    lock.withLock {
      capturedRequests.append(request)
      guard !tasks.isEmpty else {
        return FakeResponsesWebSocketTask(incoming: [.failure(URLError(.unsupportedURL))])
      }
      return tasks.removeFirst()
    }
  }
}

private final class FakeResponsesWebSocketTask: ResponsesWebSocketTasking, @unchecked Sendable {
  private let lock = NSLock()
  private let responseValue: URLResponse?
  private var incoming: [Result<ResponsesWebSocketMessage, Error>]
  private var sent: [ResponsesWebSocketMessage] = []
  private var resumed = false
  private var cancelled = false

  init(
    response: URLResponse? = nil,
    incoming: [Result<ResponsesWebSocketMessage, Error>]
  ) {
    responseValue = response
    self.incoming = incoming
  }

  var response: URLResponse? { responseValue }
  var sentMessages: [ResponsesWebSocketMessage] { lock.withLock { sent } }
  var didResume: Bool { lock.withLock { resumed } }
  var didCancel: Bool { lock.withLock { cancelled } }

  func resume() {
    lock.withLock { resumed = true }
  }

  func send(_ message: ResponsesWebSocketMessage) async throws {
    lock.withLock { sent.append(message) }
  }

  func receive() async throws -> ResponsesWebSocketMessage {
    let result: Result<ResponsesWebSocketMessage, Error> = lock.withLock {
      guard !incoming.isEmpty else { return .failure(URLError(.networkConnectionLost)) }
      return incoming.removeFirst()
    }
    return try result.get()
  }

  func cancel() {
    lock.withLock { cancelled = true }
  }
}

private final class WebSocketLocked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) { storage = value }

  var value: Value { lock.withLock { storage } }

  @discardableResult
  func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    try lock.withLock { try body(&storage) }
  }
}

private final class WebSocketURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}

  static func response(
    for request: URLRequest,
    statusCode: Int = 200,
    body: String
  ) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(body.utf8))
  }
}
