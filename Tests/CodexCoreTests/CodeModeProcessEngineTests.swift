#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import CodexCore

  final class CodeModeProcessEngineTests: XCTestCase {
    func testProtocolStreamsIncrementalTypedOutputAndStoreCompletion() async throws {
      let host = try makeFixtureHost(
        body: """
          printf '%s\n' '{"block":{"notification":true,"text":"working","type":"text"},"type":"emit","yield":true}'
          /bin/sleep 0.05
          printf '%s\n' '{"block":{"image_url":"data:image/png;base64,AAAA","type":"image"},"type":"emit","yield":false}'
          printf '%s\n' '{"completion":{"deletes":["old"],"error":null,"value":"done","writes":{"answer":42}},"type":"complete"}'
          """
      )
      let session = makeEngine(host).start(request: request(initialStore: ["old": .bool(true)]))

      let first = await session.wait(cursor: 0, yieldVersion: 0, timeoutMilliseconds: 1_000)
      XCTAssertEqual(first.state, .yielded)
      XCTAssertEqual(first.content.map(\.type), ["text"])
      XCTAssertEqual(first.content.first?.textValue, "working")

      let second = await session.wait(
        cursor: first.nextCursor,
        yieldVersion: first.yieldVersion,
        timeoutMilliseconds: 1_000
      )
      XCTAssertEqual(second.state, .completed)
      XCTAssertEqual(second.content.map(\.type), ["image"])
      XCTAssertEqual(second.completion?.returnedValue, .string("done"))
      XCTAssertEqual(second.completion?.storeWrites, ["answer": .number(42)])
      XCTAssertEqual(second.completion?.storeDeletes, ["old"])
    }

    func testProtocolProxiesNestedToolCallsThroughParentRegistry() async throws {
      let directory = try makeTemporaryDirectory()
      let responseURL = directory.appendingPathComponent("tool-result.json")
      let host = try makeFixtureHost(
        in: directory,
        body: """
          printf '%s\n' '{"arguments":"{\\"text\\":\\"hello\\"}","id":"call-1","name":"fixture_echo","type":"tool_call"}'
          IFS= read -r tool_result
          printf '%s' "$tool_result" > '\(responseURL.path)'
          printf '%s\n' '{"completion":{"deletes":[],"error":null,"value":null,"writes":{}},"type":"complete"}'
          """
      )
      let echo = ProcessFixtureEchoTool()
      let session = makeEngine(host).start(
        request: request(tools: [echo], definitions: [echo.definition]))
      let completion = await session.completion()
      XCTAssertNil(completion.error)

      let data = try Data(contentsOf: responseURL)
      let response = try JSONDecoder.codex.decode(JSONValue.self, from: data)
      XCTAssertEqual(response["type"]?.stringValue, "tool_result")
      XCTAssertEqual(response["id"]?.stringValue, "call-1")
      XCTAssertEqual(response["ok"]?.boolValue, true)
      XCTAssertEqual(response["payload"]?.stringValue, "echo:hello")
    }

    func testProtocolIgnoresToolCallsAfterCompletion() async throws {
      let host = try makeFixtureHost(
        body: """
          printf '%s\n' '{"completion":{"deletes":[],"error":null,"value":null,"writes":{}},"type":"complete"}'
          printf '%s\n' '{"arguments":"{}","id":"late-call","name":"fixture_counting","type":"tool_call"}'
          /bin/sleep 0.05
          """
      )
      let counter = ProcessCounter()
      let tool = ProcessCountingTool(counter: counter)
      let session = makeEngine(host).start(
        request: request(tools: [tool], definitions: [tool.definition]))

      let completion = await session.completion()
      XCTAssertNil(completion.error)
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertEqual(counter.value, 0)
    }

    func testParentProtocolRejectsMultipleBlocksThatCrossCellOutputLimit() async throws {
      let firstText = String(repeating: "a", count: 700)
      let secondText = String(repeating: "b", count: 700)
      let host = try makeFixtureHost(
        body: """
          printf '%s\n' '{"block":{"text":"\(firstText)","type":"text"},"type":"emit","yield":false}'
          printf '%s\n' '{"block":{"text":"\(secondText)","type":"text"},"type":"emit","yield":false}'
          printf '%s\n' '{"completion":{"deletes":[],"error":null,"value":null,"writes":{}},"type":"complete"}'
          """
      )
      let options = CodeModeOptions(
        maxContentBlockBytes: 1_024,
        maxCellOutputBytes: 1_024
      )
      let session = makeEngine(host).start(request: request(options: options))

      let completion = await session.completion()
      let snapshot = await session.wait(
        cursor: 0,
        yieldVersion: 0,
        timeoutMilliseconds: 1_000
      )
      XCTAssertEqual(
        completion.error,
        "Code-mode host exceeded the configured cumulative output byte limit."
      )
      XCTAssertEqual(snapshot.content.count, 1)
      XCTAssertEqual(snapshot.content.first?.textValue, firstText)
    }

    func testTerminateEscalatesToSIGKILLAndPreservesTerminalSnapshot() async throws {
      let directory = try makeTemporaryDirectory()
      let pidURL = directory.appendingPathComponent("pid")
      let host = try makeFixtureHost(
        in: directory,
        body: """
          printf '%s\n' '{"block":{"text":"before termination","type":"text"},"type":"emit","yield":true}'
          printf '%s' "$$" > '\(pidURL.path)'
          trap '' TERM
          while :; do :; done
          """
      )
      let session = makeEngine(host, graceMilliseconds: 50).start(request: request())
      let yielded = await session.wait(cursor: 0, yieldVersion: 0, timeoutMilliseconds: 1_000)
      XCTAssertEqual(yielded.state, .yielded)
      XCTAssertEqual(yielded.content.first?.textValue, "before termination")
      let pid = try await waitForPID(at: pidURL)

      session.terminate()
      let terminal = await session.wait(cursor: 0, yieldVersion: 0, timeoutMilliseconds: 1_000)
      XCTAssertEqual(terminal.state, .terminated)
      XCTAssertEqual(terminal.content.first?.textValue, "before termination")
      XCTAssertNil(terminal.completion?.error)
      let processExited = await waitUntilProcessExits(pid: pid)
      XCTAssertTrue(processExited)
    }

    func testRuntimeTerminationKeepsSIGKILLEscalationAliveAfterCellRemoval() async throws {
      let directory = try makeTemporaryDirectory()
      let pidURL = directory.appendingPathComponent("runtime-pid")
      let host = try makeFixtureHost(
        in: directory,
        body: """
          printf '%s\n' '{"type":"yield"}'
          printf '%s' "$$" > '\(pidURL.path)'
          trap '' TERM
          while :; do :; done
          """
      )
      let runtime = CodeModeRuntime(
        registry: ToolRegistry(),
        engine: makeEngine(host, graceMilliseconds: 50)
      )
      let started = await runtime.execute(
        source: "fixture source",
        definitions: [],
        context: request().context
      )
      let cellID = try XCTUnwrap(started.metadata["cell_id"]?.stringValue)
      let pid = try await waitForPID(at: pidURL)

      let terminated = await runtime.wait(
        arguments: .object([
          "cell_id": .string(cellID),
          "terminate": .bool(true),
        ]))
      XCTAssertEqual(terminated.metadata["state"]?.stringValue, "terminated")
      let processExited = await waitUntilProcessExits(pid: pid)
      XCTAssertTrue(processExited)
    }

    func testRealJavaScriptHostWhenExplicitlyConfigured() async throws {
      guard
        let path = ProcessInfo.processInfo.environment[
          "SWIFT_CODEX_CODE_MODE_HOST_TEST_EXECUTABLE"],
        FileManager.default.isExecutableFile(atPath: path)
      else {
        throw XCTSkip("Set SWIFT_CODEX_CODE_MODE_HOST_TEST_EXECUTABLE to test the built helper")
      }
      let echo = ProcessFixtureEchoTool()
      let engine = makeEngine(URL(fileURLWithPath: path))
      let session = engine.start(
        request: request(
          source: """
            notify('working');
            const result = await tools.fixture_echo({text: 'hello'});
            text(result);
            text(typeof globalThis.__swiftComplete);
            store('answer', 42);
            """,
          tools: [echo],
          definitions: [echo.definition]
        ))

      let first = await session.wait(cursor: 0, yieldVersion: 0, timeoutMilliseconds: 1_000)
      XCTAssertEqual(first.state, .yielded)
      XCTAssertEqual(first.content.first?.textValue, "working")
      let second = await session.wait(
        cursor: first.nextCursor,
        yieldVersion: first.yieldVersion,
        timeoutMilliseconds: 2_000
      )
      XCTAssertEqual(second.state, .completed)
      XCTAssertEqual(second.content.compactMap(\.textValue), ["echo:hello", "undefined"])
      XCTAssertEqual(second.completion?.storeWrites, ["answer": .number(42)])
    }

    func testRealJavaScriptHostRejectsCumulativeCellOutput() async throws {
      guard
        let path = ProcessInfo.processInfo.environment[
          "SWIFT_CODEX_CODE_MODE_HOST_TEST_EXECUTABLE"],
        FileManager.default.isExecutableFile(atPath: path)
      else {
        throw XCTSkip("Set SWIFT_CODEX_CODE_MODE_HOST_TEST_EXECUTABLE to test the built helper")
      }
      let options = CodeModeOptions(
        maxContentBlockBytes: 1_024,
        maxCellOutputBytes: 1_024
      )
      let session = makeEngine(URL(fileURLWithPath: path)).start(
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

    private func makeEngine(_ executableURL: URL, graceMilliseconds: Int = 100)
      -> ProcessCodeModeEngine
    {
      ProcessCodeModeEngine(
        executableURL: executableURL,
        terminationGracePeriodMilliseconds: graceMilliseconds
      )
    }

    private func request(
      source: String = "fixture source",
      initialStore: [String: JSONValue] = [:],
      tools: [any AgentTool] = [],
      definitions: [ToolDefinition] = [],
      options: CodeModeOptions = CodeModeOptions()
    ) -> CodeModeExecutionRequest {
      CodeModeExecutionRequest(
        source: source,
        definitions: definitions,
        registry: ToolRegistry(tools: tools),
        context: ToolExecutionContext(
          threadID: "process-engine-thread",
          turnID: UUID().uuidString,
          approvalPolicy: .never,
          sandboxPolicy: .workspaceWrite
        ),
        initialStore: initialStore,
        options: options,
        maxOutputTokens: 1_000
      )
    }

    private func makeFixtureHost(in directory: URL? = nil, body: String) throws -> URL {
      let directory = try directory ?? makeTemporaryDirectory()
      let executableURL = directory.appendingPathComponent("fixture-host.sh")
      let source = """
        #!/bin/sh
        IFS= read -r start_message
        \(body)
        """
      try Data(source.utf8).write(to: executableURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
      return executableURL
    }

    private func makeTemporaryDirectory() throws -> URL {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "SwiftCodexCore-process-tests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
      return directory
    }

    private func waitForPID(at url: URL) async throws -> Int32 {
      for _ in 0..<100 {
        if let text = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(text) {
          return pid
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTFail("Fixture host did not publish its process identifier")
      return -1
    }

    private func waitUntilProcessExits(pid: Int32) async -> Bool {
      for _ in 0..<100 {
        if Darwin.kill(pid, 0) == -1, errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return false
    }
  }

  private struct ProcessFixtureEchoTool: AgentTool {
    let definition = ToolDefinition(
      name: "fixture_echo",
      description: "Echo fixture",
      parameters: ToolSchemas.object(
        properties: ["text": ToolSchemas.string()],
        required: ["text"]
      )
    )

    func run(arguments: JSONValue, context _: ToolExecutionContext) async throws -> ToolResult {
      ToolResult(content: "echo:\(try arguments.requiredString("text"))")
    }
  }

  private final class ProcessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
  }

  private struct ProcessCountingTool: AgentTool {
    let counter: ProcessCounter
    let definition = ToolDefinition(
      name: "fixture_counting",
      description: "Increments a fixture counter",
      parameters: ToolSchemas.object(properties: [:])
    )

    func run(arguments _: JSONValue, context _: ToolExecutionContext) async throws -> ToolResult {
      counter.increment()
      return ToolResult(content: "counted")
    }
  }
#endif
