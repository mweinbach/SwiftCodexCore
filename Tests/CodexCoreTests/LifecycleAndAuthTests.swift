import Foundation
import XCTest
@testable import CodexCore

final class LifecycleAndAuthTests: XCTestCase, @unchecked Sendable {
  func testBrowserLoginCanDeferPersistenceUntilHostChecksItsGeneration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CodexAuthStore(codexHome: root)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LoginTokenFixtureProtocol.self]
    let client = CodexChatGPTAuthClient(store: store, session: URLSession(configuration: configuration))
    let login = client.makeBrowserLoginSession()
    var callback = URLComponents(url: login.redirectURI, resolvingAgainstBaseURL: false)!
    callback.queryItems = [URLQueryItem(name: "state", value: login.state), URLQueryItem(name: "code", value: "fixture")]
    let session = try await client.finishBrowserLogin(login, callbackURL: callback.url!, persist: false)
    let beforeCommit = try await store.loadSession()
    XCTAssertNil(beforeCommit)
    XCTAssertEqual(session.accessToken, "fixture-access")
    try await store.saveSession(session)
    let afterCommit = try await store.loadSession()
    XCTAssertEqual(afterCommit?.accessToken, "fixture-access")
  }
  func testInterruptCancelsSilentModelStreamAndReleasesTurnAfterTeardown() async throws {
    let started = expectation(description: "model stream started")
    let terminated = expectation(description: "model stream cancelled")
    let provider = SilentLifecycleProvider(started: started, terminated: terminated)
    let runtime = CodexRuntime(modelProvider: provider, tools: [])
    let thread = try await runtime.createThread()
    let handle = try await runtime.startTurn(threadID: thread.id, input: TurnInput("go"))
    let consumer = Task { try await collect(handle) }
    await fulfillment(of: [started], timeout: 2)
    try await runtime.interrupt(threadID: thread.id)
    await fulfillment(of: [terminated], timeout: 2)
    let events = try await consumer.value
    XCTAssertTrue(events.contains { if case .turnCompleted(_, _, .interrupted, _) = $0 { return true }; return false })
    XCTAssertFalse(events.contains { if case .error = $0 { return true }; return false })
    let active = await runtime.activeTurn(threadID: thread.id)
    XCTAssertNil(active)
  }

  func testInterruptCancelsToolAndSkipsRemainingBatchWithReplayableOutput() async throws {
    let started = expectation(description: "tool started")
    let state = LifecycleState()
    let provider = ScriptedModelProvider(batches: [[
      .toolCallCompleted(ToolCall(callID: "one", name: "pause", arguments: "{}")),
      .toolCallCompleted(ToolCall(callID: "two", name: "after", arguments: "{}")),
      .completed(responseID: "r1", usage: nil),
    ]])
    let runtime = CodexRuntime(modelProvider: provider, tools: [
      LifecyclePauseTool(started: started, state: state), LifecycleAfterTool(state: state),
    ])
    let thread = try await runtime.createThread()
    let handle = try await runtime.startTurn(threadID: thread.id, input: TurnInput("go"))
    let consumer = Task { try await collect(handle) }
    await fulfillment(of: [started], timeout: 2)
    await handle.interrupt()
    _ = try await consumer.value
    let result = await state.snapshot()
    XCTAssertTrue(result.cancelled)
    XCTAssertEqual(result.afterCalls, 0)
    let saved = try await runtime.readThread(id: thread.id)
    XCTAssertEqual(saved.items.filter { $0.kind == .toolResult }.count, 1)
    XCTAssertEqual(saved.items.first { $0.kind == .toolResult }?.payload["call_id"], .string("one"))
  }

  func testExpiredSessionRequestsShareOneRefresh() async throws {
    let state = LifecycleState()
    let provider = ChatGPTAuthProvider(session: expiredSession, refreshHandler: { session in
      await state.refreshed()
      try await Task.sleep(for: .milliseconds(80))
      var session = session
      session.expiresAt = .distantFuture
      return session
    })
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 { group.addTask { _ = try await provider.authorizationHeaders() } }
      try await group.waitForAll()
    }
    let count = await state.snapshot().refreshes
    XCTAssertEqual(count, 1)
  }

  func testSignOutPreventsLateRefreshFromRestoringCredentials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileAuthStore(fileURL: root.appendingPathComponent("auth.json"))
    try await store.saveSession(expiredSession)
    let started = expectation(description: "refresh started")
    let provider = ChatGPTAuthProvider(session: expiredSession, store: store, refreshHandler: { session in
      started.fulfill()
      try? await Task.sleep(for: .milliseconds(100))
      var session = session
      session.expiresAt = .distantFuture
      return session
    })
    let refresh = Task { try await provider.authorizationHeaders() }
    await fulfillment(of: [started], timeout: 2)
    try await provider.invalidate()
    _ = await refresh.result
    let saved = try await store.loadSession()
    XCTAssertNil(saved)
    do {
      _ = try await provider.authorizationHeaders()
      XCTFail("Signed-out providers must reject new requests")
    } catch CodexCoreError.authError { }
  }

  private var expiredSession: AuthSession {
    AuthSession(mode: .chatGPT, accessToken: "test-only", refreshToken: "test-only", expiresAt: .distantPast)
  }
}

private func collect(_ handle: TurnHandle) async throws -> [AgentEvent] {
  var events: [AgentEvent] = []
  for try await event in handle.events { events.append(event) }
  return events
}

private struct SilentLifecycleProvider: ModelProvider {
  let started: XCTestExpectation
  let terminated: XCTestExpectation
  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.onTermination = { _ in terminated.fulfill() }
      started.fulfill()
    }
  }
}

private actor LifecycleState {
  var cancelled = false
  var afterCalls = 0
  var refreshes = 0
  func cancel() { cancelled = true }
  func after() { afterCalls += 1 }
  func refreshed() { refreshes += 1 }
  func snapshot() -> (cancelled: Bool, afterCalls: Int, refreshes: Int) { (cancelled, afterCalls, refreshes) }
}

private struct LifecyclePauseTool: AgentTool {
  let started: XCTestExpectation
  let state: LifecycleState
  let definition = ToolDefinition(name: "pause", description: "Cooperative wait", parameters: ToolSchemas.object(properties: [:]))
  func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    started.fulfill()
    do { try await Task.sleep(for: .seconds(30)) }
    catch { await state.cancel(); throw error }
    return ToolResult(content: "finished")
  }
}

private struct LifecycleAfterTool: AgentTool {
  let state: LifecycleState
  let definition = ToolDefinition(name: "after", description: "Second batched tool", parameters: ToolSchemas.object(properties: [:]))
  func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    await state.after()
    return ToolResult(content: "finished")
  }
}

private final class LoginTokenFixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh"}"#.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() { }
}
