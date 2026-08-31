import Foundation
import XCTest
@testable import CodexCore

final class CodeModeToolLifecycleTests: XCTestCase {
  func testJavaScriptCorePublishesActualFileToolLifecycle() async throws {
    try await assertFileToolLifecycle(engine: JavaScriptCoreCodeModeEngine())
  }

  #if os(macOS)
  func testProcessHostPublishesActualFileToolLifecycle() async throws {
    let configured = ProcessInfo.processInfo.environment["SWIFT_CODEX_CODE_MODE_HOST_TEST_EXECUTABLE"]
    let engine = ProcessCodeModeEngine(executableURL: configured.map { URL(fileURLWithPath: $0) })
    guard engine.isAvailable else { throw XCTSkip("The packaged code-mode helper is unavailable") }
    try await assertFileToolLifecycle(engine: engine)
  }
  #endif

  #if os(iOS)
  func testWebKitPublishesActualFileToolLifecycle() async throws {
    try await assertFileToolLifecycle(engine: WebKitCodeModeEngine())
  }
  #endif

  func testDeniedNestedWritePublishesApprovalAndMatchingErrorCompletion() async throws {
    let workspace = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let run = try await runScript(
      "await tools.write_file({path: 'denied.txt', content: 'must not write'});",
      tools: [FileWriteTool()], workspace: workspace,
      approvalHandler: { _ in ApprovalDecision(approved: false, message: "denied by fixture") })
    let started = try XCTUnwrap(run.events.compactMap { event -> ToolCall? in
      if case .toolStarted(let call) = event, call.name == "write_file" { return call }
      return nil
    }.first)
    let completed = try XCTUnwrap(run.events.compactMap { event -> ToolResult? in
      if case .toolCompleted(let call, let result) = event, call.callID == started.callID { return result }
      return nil
    }.first)
    XCTAssertTrue(completed.isError)
    XCTAssertTrue(completed.content.contains("denied by fixture"))
    XCTAssertEqual(run.events.filter { if case .approvalRequested = $0 { return true }; return false }.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("denied.txt").path))
    XCTAssertTrue(run.events.contains { event in
      if case .toolCompleted(let call, let result) = event { return call.name == "exec" && result.isError }
      return false
    })
  }

  func testNestedErrorCompletionPreservesTypedResultAndMedia() async throws {
    let expected = ToolResult(content: "fixture failure", structuredContent: .object(["reason": .string("fixture")]),
      isError: true, metadata: ["source": .string("inner")],
      contentBlocks: [.image(imageURL: "data:image/png;base64,AAAA")],
      codeModeResult: .object(["native": .bool(true)]))
    let run = try await runScript("await tools.typed_failure({});", tools: [TypedFailureTool(result: expected)])
    let result = try XCTUnwrap(run.events.compactMap { event -> ToolResult? in
      if case .toolCompleted(let call, let result) = event, call.name == "typed_failure" { return result }
      return nil
    }.first)
    XCTAssertEqual(result, expected)
  }

  private func assertFileToolLifecycle(engine: any CodeModeEngine) async throws {
    let workspace = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let run = try await runScript("""
      await tools.write_file({path: 'visible.txt', content: 'nested value'});
      text(await tools.read_file({path: 'visible.txt'}));
      """, tools: [FileWriteTool(), FileReadTool()], workspace: workspace, engine: engine,
      approvalHandler: { _ in ApprovalDecision(approved: true) })
    XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("visible.txt"), encoding: .utf8), "nested value")
    let started = run.events.compactMap { event -> ToolCall? in
      if case .toolStarted(let call) = event, call.name != "exec" { return call }
      return nil
    }
    XCTAssertEqual(started.map(\.name), ["write_file", "read_file"])
    XCTAssertEqual(Set(started.map(\.callID)).count, 2)
    XCTAssertEqual(Set(started.compactMap { $0.caller?["cell_id"]?.stringValue }).count, 1)
    for call in started {
      XCTAssertEqual(call.id, call.callID)
      XCTAssertEqual(call.caller?["type"]?.stringValue, "program")
      XCTAssertEqual(call.caller?["caller_id"]?.stringValue, "outer-exec")
      XCTAssertEqual(call.rawArguments?["path"]?.stringValue, "visible.txt")
      XCTAssertEqual(try JSONDecoder.codex.decode(JSONValue.self, from: Data(call.arguments.utf8)), call.rawArguments)
      let completion = try XCTUnwrap(run.events.compactMap { event -> (ToolCall, ToolResult)? in
        if case .toolCompleted(let completedCall, let result) = event, completedCall.callID == call.callID {
          return (completedCall, result)
        }
        return nil
      }.first)
      XCTAssertEqual(completion.0, call)
      XCTAssertFalse(completion.1.isError)
      if call.name == "read_file" { XCTAssertEqual(completion.1.content, "nested value") }
    }
    let writeStart = try XCTUnwrap(run.events.firstIndex { if case .toolStarted(let call) = $0 { return call.name == "write_file" }; return false })
    let approval = try XCTUnwrap(run.events.firstIndex { if case .approvalRequested(let request) = $0 { return request.toolName == "write_file" }; return false })
    let writeEnd = try XCTUnwrap(run.events.firstIndex { if case .toolCompleted(let call, _) = $0 { return call.name == "write_file" }; return false })
    XCTAssertLessThan(writeStart, approval)
    XCTAssertLessThan(approval, writeEnd)
    // Presentation events must not fabricate extra model-visible tool outputs.
    XCTAssertFalse(run.thread.items.contains { $0.payload["call_id"]?.stringValue?.hasPrefix("code_mode_") == true })
    XCTAssertFalse(run.followUpInput.contains { $0["call_id"]?.stringValue?.hasPrefix("code_mode_") == true })
  }

  private func runScript(_ source: String, tools: [any AgentTool], workspace: URL? = nil,
                        engine: any CodeModeEngine = JavaScriptCoreCodeModeEngine(),
                        approvalHandler: ApprovalHandler? = nil) async throws
    -> (events: [AgentEvent], thread: AgentThread, followUpInput: [JSONValue]) {
    let provider = ToolLifecycleModelProvider(source: source)
    let registry = ToolRegistry(tools: tools)
    let agent = CodexAgent(
      configuration: AgentConfiguration(workspaceURL: workspace, approvalPolicy: .onRequest,
        sandboxPolicy: .workspaceWrite, toolMode: .codeModeOnly),
      modelProvider: provider, toolRegistry: registry,
      threadManager: ThreadManager(store: InMemoryThreadStore()), approvalHandler: approvalHandler,
      codeModeRuntime: CodeModeRuntime(registry: registry, engine: engine))
    let thread = try await agent.createThread()
    var events: [AgentEvent] = []
    for try await event in agent.startTurn(threadID: thread.id, input: TurnInput("use actual tools")).events {
      events.append(event)
    }
    return (events, try await agent.getThread(id: thread.id), provider.requests.dropFirst().first?.input ?? [])
  }

  private func temporaryWorkspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodeModeLifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private struct TypedFailureTool: AgentTool {
  let result: ToolResult
  let definition = ToolDefinition(name: "typed_failure", description: "Return a typed failure",
    parameters: ToolSchemas.object(properties: [:]))
  func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult { result }
}

private final class ToolLifecycleModelProvider: ModelProvider, @unchecked Sendable {
  private let lock = NSLock()
  private let source: String
  private var recorded: [ResponsesRequest] = []
  var requests: [ResponsesRequest] { lock.withLock { recorded } }
  init(source: String) { self.source = source }
  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let first = lock.withLock { recorded.append(request); return recorded.count == 1 }
    return AsyncThrowingStream { continuation in
      if first {
        continuation.yield(.toolCallCompleted(ToolCall(callID: "outer-exec", name: "exec", arguments: source, kind: .custom)))
      } else { continuation.yield(.outputTextDelta("finished")) }
      continuation.yield(.completed(responseID: first ? "first" : "second", usage: nil))
      continuation.finish()
    }
  }
}
