#if os(iOS)
  import Foundation
  import XCTest
  @testable import CodexCore

  final class CodeModeWebKitEngineTests: XCTestCase {
    func testAutomaticEngineSelectsWorkerHostOnIOS() async throws {
      let session = AutomaticCodeModeEngine().start(
        request: request(source: "text(typeof globalThis.WorkerGlobalScope);"))

      let snapshot = await session.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 15_000
      )
      XCTAssertEqual(snapshot.state, .completed)
      XCTAssertEqual(snapshot.content.first?.textValue, "function")
    }

    func testWorkerRoutesToolsNotificationsOutputAndStoreCompletion() async throws {
      let echo = WebKitEchoTool()
      let notifications = WebKitNotificationRecorder()
      var executionRequest = request(
        source: """
          notify('working');
          const value = await tools.webkit_echo({text: 'hello'});
          text(value);
          store('answer', 42);
          return {ok: true};
          """,
        tools: [echo],
        definitions: [echo.definition]
      )
      executionRequest.notificationHandler = notifications.append
      let engine = WebKitCodeModeEngine()
      let session = engine.start(request: executionRequest)

      let snapshot = await session.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 15_000
      )
      XCTAssertEqual(snapshot.state, .completed)
      XCTAssertEqual(snapshot.content.compactMap(\.textValue), ["echo:hello"])
      XCTAssertEqual(snapshot.completion?.returnedValue, .object(["ok": .bool(true)]))
      XCTAssertEqual(snapshot.completion?.storeWrites, ["answer": .number(42)])
      XCTAssertEqual(notifications.values, ["working"])
    }

    func testWorkerHidesBrowserNetworkAndPrivilegedBridgeGlobals() async throws {
      let engine = WebKitCodeModeEngine()
      let session = engine.start(
        request: request(
          source: """
            const names = [
              'postMessage', 'close', 'fetch', 'XMLHttpRequest', 'WebSocket',
              'EventSource', 'importScripts', 'Worker', 'SharedWorker',
              'indexedDB', 'caches', 'BroadcastChannel', 'eval',
              '__swiftToolCall', '__swiftComplete', '__swiftNotify'
            ];
            text(JSON.stringify({
              globals: names.map(name => typeof globalThis[name]),
              window: typeof globalThis.window,
              document: typeof globalThis.document,
              webkit: typeof globalThis.webkit
            }));
            """
        ))

      let snapshot = await session.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 15_000
      )
      XCTAssertEqual(snapshot.state, .completed)
      let text = try XCTUnwrap(snapshot.content.first?.textValue)
      let value = try XCTUnwrap(parseJSON(text))
      XCTAssertEqual(
        value["globals"]?.arrayValue?.compactMap(\.stringValue),
        Array(repeating: "undefined", count: 16)
      )
      XCTAssertEqual(value["window"]?.stringValue, "undefined")
      XCTAssertEqual(value["document"]?.stringValue, "undefined")
      XCTAssertEqual(value["webkit"]?.stringValue, "undefined")
    }

    func testWorkerCannotRecoverForbiddenAPIsFromItsPrototypeChain() async throws {
      let engine = WebKitCodeModeEngine()
      let session = engine.start(
        request: request(
          source: """
            function recover(name) {
              let prototype = Object.getPrototypeOf(globalThis);
              while (prototype !== null) {
                const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
                if (descriptor) {
                  if ('value' in descriptor && descriptor.value !== undefined) {
                    return typeof descriptor.value;
                  }
                  if (typeof descriptor.get === 'function') {
                    return typeof descriptor.get.call(globalThis);
                  }
                }
                prototype = Object.getPrototypeOf(prototype);
              }
              return 'undefined';
            }
            text(JSON.stringify(
              ['fetch', 'postMessage', 'importScripts', 'indexedDB'].map(recover)
            ));
            """
        ))

      let snapshot = await session.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 15_000
      )
      XCTAssertEqual(snapshot.state, .completed)
      XCTAssertNil(snapshot.completion?.error)
      let text = try XCTUnwrap(snapshot.content.first?.textValue)
      XCTAssertEqual(
        parseJSON(text)?.arrayValue?.compactMap(\.stringValue),
        Array(repeating: "undefined", count: 4)
      )
    }

    func testTerminateBeforePageStartupCancelsPendingWorker() async throws {
      let engine = WebKitCodeModeEngine()
      let cancelled = engine.start(request: request(source: "while (true) {}"))

      cancelled.terminate()
      let terminal = await cancelled.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 1_000
      )
      XCTAssertEqual(terminal.state, .terminated)

      let recovered = engine.start(request: request(source: "text('started-after-cancel');"))
      let recoveredSnapshot = await recovered.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 15_000
      )
      XCTAssertEqual(recoveredSnapshot.state, .completed)
      XCTAssertEqual(recoveredSnapshot.content.first?.textValue, "started-after-cancel")
    }

    func testSynchronousWorkerDoesNotBlockConcurrentCell() async throws {
      let engine = WebKitCodeModeEngine()
      let spinning = engine.start(request: request(source: "while (true) {}"))
      let concurrent = engine.start(request: request(source: "text('concurrent');"))

      let concurrentSnapshot = await concurrent.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 15_000
      )
      XCTAssertEqual(concurrentSnapshot.state, .completed)
      XCTAssertEqual(concurrentSnapshot.content.first?.textValue, "concurrent")

      spinning.terminate()
      let terminal = await spinning.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 1_000
      )
      XCTAssertEqual(terminal.state, .terminated)
    }

    func testTerminateStopsSynchronousWorkerAndSharedHostRecovers() async throws {
      let engine = WebKitCodeModeEngine()
      let spinning = engine.start(
        request: request(
          source: "text('spinning'); await yield_control(); while (true) {}"
        ))

      let running = await spinning.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 15_000
      )
      XCTAssertEqual(running.state, .yielded)
      XCTAssertEqual(running.content.first?.textValue, "spinning")

      spinning.terminate()
      let terminal = await spinning.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 1_000
      )
      XCTAssertEqual(terminal.state, .terminated)
      XCTAssertNil(terminal.completion?.error)

      try await Task.sleep(for: .milliseconds(100))
      let recovered = engine.start(request: request(source: "text('recovered');"))
      let recoveredSnapshot = await recovered.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 10_000
      )
      XCTAssertEqual(recoveredSnapshot.state, .completed)
      XCTAssertEqual(recoveredSnapshot.content.first?.textValue, "recovered")
    }

    func testWorkerEnforcesCumulativeOutputLimit() async throws {
      let options = CodeModeOptions(
        maxContentBlockBytes: 1_024,
        maxCellOutputBytes: 1_024
      )
      let engine = WebKitCodeModeEngine()
      let session = engine.start(
        request: request(
          source: "text('a'.repeat(700)); text('b'.repeat(700));",
          options: options
        ))

      let completion = await session.completion()
      let snapshot = await session.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 1_000
      )
      XCTAssertEqual(
        completion.error,
        "Code-mode cell output exceeded the configured cumulative byte limit."
      )
      XCTAssertEqual(snapshot.content.count, 1)
      XCTAssertEqual(snapshot.content.first?.textValue, String(repeating: "a", count: 700))
    }

    func testRelayRejectsOversizedEventBeforeNativeDecoding() async throws {
      let options = CodeModeOptions(
        maxContentBlockBytes: 1_024,
        maxCellOutputBytes: 4_096
      )
      let engine = WebKitCodeModeEngine()
      let session = engine.start(
        request: request(
          source: "text('x'.repeat(2_000));",
          options: options
        ))

      let completion = await session.completion()
      XCTAssertEqual(
        completion.error,
        "WebKit code-mode worker failed: Code-mode content block exceeded its byte limit."
      )
    }

    private func request(
      source: String,
      tools: [any AgentTool] = [],
      definitions: [ToolDefinition] = [],
      options: CodeModeOptions = CodeModeOptions()
    ) -> CodeModeExecutionRequest {
      CodeModeExecutionRequest(
        source: source,
        definitions: definitions,
        registry: ToolRegistry(tools: tools),
        context: ToolExecutionContext(
          threadID: "webkit-engine-thread",
          turnID: UUID().uuidString,
          approvalPolicy: .never,
          sandboxPolicy: .workspaceWrite
        ),
        initialStore: [:],
        options: options,
        maxOutputTokens: 1_000
      )
    }

    private func parseJSON(_ text: String) -> JSONValue? {
      guard let data = text.data(using: .utf8) else { return nil }
      return try? JSONDecoder.codex.decode(JSONValue.self, from: data)
    }
  }

  private struct WebKitEchoTool: AgentTool {
    let definition = ToolDefinition(
      name: "webkit_echo",
      description: "Echoes text through the WebKit code-mode bridge.",
      parameters: ToolSchemas.object(
        properties: ["text": ToolSchemas.string()],
        required: ["text"]
      )
    )

    func run(arguments: JSONValue, context _: ToolExecutionContext) async throws -> ToolResult {
      ToolResult(content: "echo:\(try arguments.requiredString("text"))")
    }
  }

  private final class WebKitNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
  }
#endif
