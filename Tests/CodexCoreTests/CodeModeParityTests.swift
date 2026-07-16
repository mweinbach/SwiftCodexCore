import XCTest

@testable import CodexCore

final class CodeModeParityTests: XCTestCase {
  func testYieldControlReturnsIncrementalOutputOnlyOnce() async throws {
    let runtime = CodeModeRuntime(registry: ToolRegistry())
    let first = await runtime.execute(
      source: """
        text('first');
        await yield_control();
        await new Promise(resolve => setTimeout(resolve, 50));
        text('second');
        """,
      definitions: [],
      context: context()
    )
    XCTAssertTrue(first.content.contains("first"))
    XCTAssertFalse(first.content.contains("second"))
    let cellID = try XCTUnwrap(first.metadata["cell_id"]?.stringValue)

    let second = await runtime.wait(
      arguments: .object([
        "cell_id": .string(cellID),
        "yield_time_ms": .number(1_000),
      ]))
    XCTAssertFalse(second.content.contains("first"))
    XCTAssertTrue(second.content.contains("second"))
    XCTAssertEqual(second.metadata["running"]?.boolValue, false)
  }

  func testNotifyUsesIndependentCallbackWithoutYieldingOrEnteringCellOutput() async throws {
    let runtime = CodeModeRuntime(
      registry: ToolRegistry(),
      engine: JavaScriptCoreCodeModeEngine()
    )
    let recorder = NotificationRecorder()
    var executionContext = context()
    executionContext.metadata["tool_call_id"] = .string("exec-call")
    let result = await runtime.execute(
      source:
        "notify('working'); await new Promise(resolve => setTimeout(resolve, 50)); text('done');",
      definitions: [],
      context: executionContext,
      notificationHandler: recorder.append
    )
    XCTAssertEqual(result.content, "done")
    XCTAssertEqual(result.metadata["state"]?.stringValue, "completed")
    XCTAssertFalse(result.content.contains("working"))
    let notification = try XCTUnwrap(recorder.notifications.first)
    XCTAssertEqual(notification.text, "working")
    XCTAssertEqual(notification.callID, "exec-call")
    XCTAssertEqual(notification.threadID, executionContext.threadID)
    XCTAssertEqual(notification.turnID, executionContext.turnID)
    XCTAssertEqual(notification.cellID, result.metadata["cell_id"]?.stringValue)
  }

  func testAgentPublishesNotifyEventAndDistinctCustomToolOutput() async throws {
    let provider = CodeModeRecordingProvider(batches: [
      [
        .toolCallCompleted(
          ToolCall(
            callID: "exec-notify",
            name: CodeModeRuntime.execToolName,
            arguments: "notify('working'); text('done');",
            kind: .custom
          )),
        .completed(responseID: "response-1", usage: nil),
      ],
      [.outputTextDelta("finished"), .completed(responseID: "response-2", usage: nil)],
    ])
    let registry = ToolRegistry()
    let agent = CodexAgent(
      configuration: AgentConfiguration(toolMode: .codeModeOnly),
      modelProvider: provider,
      toolRegistry: registry,
      threadManager: ThreadManager(store: InMemoryThreadStore()),
      codeModeRuntime: CodeModeRuntime(
        registry: registry,
        engine: JavaScriptCoreCodeModeEngine()
      )
    )
    let thread = try await agent.createThread()
    var notifications: [CodeModeNotification] = []
    for try await event in agent.startTurn(
      threadID: thread.id,
      input: TurnInput("send progress")
    ).events {
      if case .codeModeNotification(let notification) = event {
        notifications.append(notification)
      }
    }

    XCTAssertEqual(notifications.map(\.text), ["working"])
    XCTAssertEqual(notifications.first?.callID, "exec-notify")
    let outputs = try XCTUnwrap(provider.requests.dropFirst().first).input.filter {
      $0["type"]?.stringValue == "custom_tool_call_output"
        && $0["call_id"]?.stringValue == "exec-notify"
    }
    XCTAssertEqual(outputs.compactMap { $0["output"]?.stringValue }, ["working", "done"])
  }

  func testConcurrentCellsMergeOnlyKeysTheyWrite() async throws {
    let runtime = CodeModeRuntime(registry: ToolRegistry())
    let first = await runtime.execute(
      source:
        "store('alpha', 1); await yield_control(); await new Promise(resolve => setTimeout(resolve, 80));",
      definitions: [],
      context: context()
    )
    let second = await runtime.execute(
      source:
        "store('beta', 2); await yield_control(); await new Promise(resolve => setTimeout(resolve, 30));",
      definitions: [],
      context: context()
    )
    for result in [first, second] {
      let cellID = try XCTUnwrap(result.metadata["cell_id"]?.stringValue)
      _ = await runtime.wait(
        arguments: .object([
          "cell_id": .string(cellID), "yield_time_ms": .number(1_000),
        ]))
    }
    let check = await runtime.execute(
      source: "text(JSON.stringify({alpha: load('alpha'), beta: load('beta')}));",
      definitions: [],
      context: context()
    )
    XCTAssertEqual(check.content, #"{"alpha":1,"beta":2}"#)
  }

  func testTerminationPreventsLaterNestedToolExecution() async throws {
    let counter = Counter()
    let tool = CountingTool(counter: counter)
    let runtime = CodeModeRuntime(
      registry: ToolRegistry(tools: [tool]),
      engine: JavaScriptCoreCodeModeEngine()
    )
    let first = await runtime.execute(
      source:
        "await yield_control(); await new Promise(resolve => setTimeout(resolve, 80)); await tools.counting({});",
      definitions: [tool.definition],
      context: context()
    )
    let cellID = try XCTUnwrap(first.metadata["cell_id"]?.stringValue)
    _ = await runtime.wait(
      arguments: .object([
        "cell_id": .string(cellID), "terminate": .bool(true),
      ]))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(counter.value, 0)
  }

  func testPrivilegedHostBridgesAndRuntimeInternalsAreHiddenFromUserSource() async throws {
    let counter = Counter()
    let tool = CountingTool(counter: counter)
    let runtime = CodeModeRuntime(
      registry: ToolRegistry(tools: [tool]),
      engine: JavaScriptCoreCodeModeEngine()
    )
    let result = await runtime.execute(
      source: """
        const privileged = [
          '__swiftToolCall', '__swiftSetTimer', '__swiftEmit', '__swiftNotify',
          '__swiftYield', '__swiftComplete'
        ].map(name => typeof globalThis[name]);
        const internals = [
          typeof __host, typeof __bridge, typeof __complete, typeof __writes,
          typeof __pending, typeof __resolveTool, typeof __fireTimer
        ];
        if (typeof globalThis.__swiftComplete === 'function') {
          globalThis.__swiftComplete(JSON.stringify({
            value: null, error: null, writes: {forged: true}, deletes: []
          }));
          await tools.counting({});
        }
        text(JSON.stringify({privileged, internals}));
        """,
      definitions: [tool.definition],
      context: context()
    )

    XCTAssertFalse(result.isError)
    XCTAssertEqual(
      result.content,
      #"{"privileged":["undefined","undefined","undefined","undefined","undefined","undefined"],"internals":["undefined","undefined","undefined","undefined","undefined","undefined","undefined"]}"#
    )
    XCTAssertEqual(counter.value, 0)

    let serializerAttack = await runtime.execute(
      source: """
        JSON.stringify = () => '{"value":null,"error":null,"writes":{"forged":true},"deletes":[]}';
        Object.prototype.toJSON = () => ({value: null, error: null, writes: {forged: true}, deletes: []});
        Array.prototype.toJSON = Object.prototype.toJSON;
        store('legit', 42);
        """,
      definitions: [],
      context: context()
    )
    XCTAssertFalse(serializerAttack.isError)

    let storeCheck = await runtime.execute(
      source: "text(`${load('legit')}:${typeof load('forged')}`);",
      definitions: [],
      context: context()
    )
    XCTAssertEqual(storeCheck.content, "42:undefined")
  }

  func testConcurrentWaitAndTerminateBothReceiveTerminalSnapshot() async throws {
    let runtime = CodeModeRuntime(
      registry: ToolRegistry(),
      engine: JavaScriptCoreCodeModeEngine()
    )
    let started = await runtime.execute(
      source: "await yield_control(); await new Promise(resolve => setTimeout(resolve, 2_000));",
      definitions: [],
      context: context()
    )
    let cellID = try XCTUnwrap(started.metadata["cell_id"]?.stringValue)
    let waiting = Task {
      await runtime.wait(
        arguments: .object([
          "cell_id": .string(cellID), "yield_time_ms": .number(5_000),
        ]))
    }
    try await Task.sleep(for: .milliseconds(50))
    let terminating = await runtime.wait(
      arguments: .object([
        "cell_id": .string(cellID), "terminate": .bool(true),
      ]))
    let waited = await waiting.value

    for result in [waited, terminating] {
      XCTAssertFalse(result.isError)
      XCTAssertEqual(result.metadata["state"]?.stringValue, "terminated")
      XCTAssertEqual(result.metadata["running"]?.boolValue, false)
    }
  }

  func testTerminateCellsPreservesStoreUnlessExplicitlyCleared() async throws {
    let runtime = CodeModeRuntime(
      registry: ToolRegistry(),
      engine: JavaScriptCoreCodeModeEngine()
    )
    let executionContext = context()
    let stored = await runtime.execute(
      source: "store('answer', 42);",
      definitions: [],
      context: executionContext
    )
    XCTAssertFalse(stored.isError)

    await runtime.terminateCells(threadID: executionContext.threadID)
    let preserved = await runtime.execute(
      source: "text(load('answer'));",
      definitions: [],
      context: executionContext
    )
    XCTAssertEqual(preserved.content, "42")

    await runtime.terminateCells(threadID: executionContext.threadID, clearStore: true)
    let cleared = await runtime.execute(
      source: "text(typeof load('answer'));",
      definitions: [],
      context: executionContext
    )
    XCTAssertEqual(cleared.content, "undefined")
  }

  func testTurnCompletionTerminatesYieldedCells() async throws {
    let provider = ScriptedModelProvider(batches: [
      [
        .toolCallCompleted(
          ToolCall(
            callID: "exec-call",
            name: CodeModeRuntime.execToolName,
            arguments:
              "await yield_control(); await new Promise(resolve => setTimeout(resolve, 5_000));",
            kind: .custom
          )),
        .completed(responseID: "response-1", usage: nil),
      ],
      [
        .outputTextDelta("done"),
        .completed(responseID: "response-2", usage: nil),
      ],
    ])
    let registry = ToolRegistry()
    let runtime = CodeModeRuntime(
      registry: registry,
      engine: JavaScriptCoreCodeModeEngine()
    )
    let agent = CodexAgent(
      configuration: AgentConfiguration(toolMode: .codeModeOnly),
      modelProvider: provider,
      toolRegistry: registry,
      threadManager: ThreadManager(store: InMemoryThreadStore()),
      codeModeRuntime: runtime
    )
    let thread = try await agent.createThread()
    var cellID: String?
    for try await event in agent.startTurn(
      threadID: thread.id,
      input: TurnInput("start a background cell")
    ).events {
      if case .toolCompleted(let call, let result) = event,
        call.name == CodeModeRuntime.execToolName
      {
        cellID = result.metadata["cell_id"]?.stringValue
      }
    }

    let completedCellID = try XCTUnwrap(cellID)
    let afterTurn = await runtime.wait(
      arguments: .object([
        "cell_id": .string(completedCellID),
        "yield_time_ms": .number(250),
      ]))
    XCTAssertTrue(afterTurn.isError)
    XCTAssertTrue(afterTurn.content.contains("Unknown or completed"))
  }

  func testTurnHandleInterruptTerminatesCellsImmediately() async throws {
    let provider = InterruptibleCellProvider()
    let registry = ToolRegistry()
    let runtime = CodeModeRuntime(
      registry: registry,
      engine: JavaScriptCoreCodeModeEngine()
    )
    let agent = CodexAgent(
      configuration: AgentConfiguration(toolMode: .codeModeOnly),
      modelProvider: provider,
      toolRegistry: registry,
      threadManager: ThreadManager(store: InMemoryThreadStore()),
      codeModeRuntime: runtime
    )
    let thread = try await agent.createThread()
    let handle = agent.startTurn(
      threadID: thread.id,
      input: TurnInput("start an interruptible cell")
    )
    var resultAfterInterrupt: ToolResult?
    for try await event in handle.events {
      if case .toolCompleted(let call, let result) = event,
        call.name == CodeModeRuntime.execToolName,
        let cellID = result.metadata["cell_id"]?.stringValue
      {
        await handle.interrupt()
        resultAfterInterrupt = await runtime.wait(
          arguments: .object([
            "cell_id": .string(cellID),
            "yield_time_ms": .number(250),
          ]))
      }
    }

    XCTAssertTrue(resultAfterInterrupt?.isError == true)
    XCTAssertTrue(resultAfterInterrupt?.content.contains("Unknown or completed") == true)
  }

  func testTypedImagesSurviveAsContentBlocksAndRemoteURLsFail() async throws {
    let runtime = CodeModeRuntime(registry: ToolRegistry())
    let imageResult = await runtime.execute(
      source: "image('data:image/png;base64,AAAA', 'original');",
      definitions: [],
      context: context()
    )
    XCTAssertEqual(imageResult.contentBlocks?.first?.type, "image")
    XCTAssertEqual(imageResult.contentBlocks?.first?.fields["detail"]?.stringValue, "original")
    XCTAssertTrue(imageResult.responseOutput.contains("image_url"))
    XCTAssertEqual(
      imageResult.responseOutputValue.arrayValue?.first?["type"]?.stringValue, "input_image")

    let errorResult = await runtime.execute(
      source: "text('before'); image('https://example.com/image.png');",
      definitions: [],
      context: context()
    )
    XCTAssertTrue(errorResult.isError)
    XCTAssertTrue(errorResult.content.contains("before"))
    XCTAssertTrue(errorResult.content.contains("remote image URLs"))
  }

  func testMCPImageAndGeneratedImageHelpersMatchUpstreamShapes() async throws {
    let runtime = CodeModeRuntime(registry: ToolRegistry())
    let result = await runtime.execute(
      source: """
        image({type: 'image', data: 'AAAA', mimeType: 'image/png', _meta: {'codex/imageDetail': 'original'}});
        generatedImage({image_url: 'data:image/png;base64,BBBB', output_hint: 'save it'});
        """,
      definitions: [],
      context: context()
    )
    XCTAssertFalse(result.isError)
    XCTAssertEqual(result.contentBlocks?.map(\.type), ["image", "image", "text"])
    XCTAssertEqual(
      result.contentBlocks?[0].fields["image_url"]?.stringValue, "data:image/png;base64,AAAA")
    XCTAssertEqual(result.contentBlocks?[0].fields["detail"]?.stringValue, "original")
    XCTAssertEqual(result.contentBlocks?[1].fields["detail"]?.stringValue, "high")
    XCTAssertEqual(result.contentBlocks?[2].textValue, "save it")
  }

  func testExecPragmaIsStrictAndRemovedBeforeEvaluation() async throws {
    let runtime = CodeModeRuntime(registry: ToolRegistry())
    let valid = await runtime.execute(
      source: "// @exec: {\"yield_time_ms\": 250, \"max_output_tokens\": 100}\ntext('ok');",
      definitions: [],
      context: context()
    )
    XCTAssertEqual(valid.content, "ok")

    for source in [
      "",
      "// @exec: {}",
      "// @exec: {\"unknown\": 1}\ntext('no');",
      "// @exec: {\"yield_time_ms\": 1.5}\ntext('no');",
    ] {
      let invalid = await runtime.execute(source: source, definitions: [], context: context())
      XCTAssertTrue(invalid.isError, "Expected invalid source: \(source)")
    }
  }

  func testInjectedTokenCounterControlsOutputBudget() async throws {
    let runtime = CodeModeRuntime(
      registry: ToolRegistry(),
      tokenCounter: CharacterTokenCounter()
    )
    let result = await runtime.execute(
      source: "// @exec: {\"max_output_tokens\": 2}\ntext('abcd');",
      definitions: [],
      context: context()
    )
    XCTAssertEqual(result.content, "ab\n[output truncated]")
  }

  func testNonFiniteTimersAndNonJSONReturnValuesFailSafely() async throws {
    let runtime = CodeModeRuntime(registry: ToolRegistry())
    let timer = await runtime.execute(
      source: "await new Promise(resolve => setTimeout(resolve, Infinity)); text('fired');",
      definitions: [],
      context: context()
    )
    XCTAssertEqual(timer.content, "fired")

    let bigInt = await runtime.execute(
      source: "return 1n;",
      definitions: [],
      context: context()
    )
    XCTAssertTrue(bigInt.isError)
    XCTAssertTrue(bigInt.content.lowercased().contains("bigint"))
  }

  func testNativeProgrammaticToolResultIsReturnedToJavaScript() async throws {
    let tool = ProgrammaticResultTool()
    let runtime = CodeModeRuntime(registry: ToolRegistry(tools: [tool]))
    let result = await runtime.execute(
      source: "const value = await tools.programmatic_result({}); text(value.answer);",
      definitions: [tool.definition],
      context: context()
    )
    XCTAssertEqual(result.content, "42")
  }

  func testNamespacedAndIllegalToolNamesAreNormalizedAndCallable() async throws {
    let tool = NamedTool(name: "mcp__my-server__bad.tool")
    let options = CodeModeOptions()
    let bindings = CodeModeToolCatalog.bindings(definitions: [tool.definition], options: options)
    XCTAssertEqual(bindings.first?.publicName, "mcp__my_server__bad_tool")
    XCTAssertEqual(bindings.first?.nestedPath, ["my_server", "bad_tool"])

    let runtime = CodeModeRuntime(registry: ToolRegistry(tools: [tool]))
    let result = await runtime.execute(
      source: "const result = await tools.my_server.bad_tool({}); text(result);",
      definitions: [tool.definition],
      context: context(),
      options: options
    )
    XCTAssertEqual(result.content, "called")

    let excluded = CodeModeToolCatalog.bindings(
      definitions: [tool.definition],
      options: CodeModeOptions(excludedToolNamespaces: ["mcp__my-server"])
    )
    XCTAssertTrue(excluded.isEmpty)
  }

  func testCodeModeOnlyExecDescriptionIncludesEveryEagerToolSchema() throws {
    let eager = ToolDefinition(
      name: "schema_tool",
      description: "Uses a typed input and output.",
      parameters: ToolSchemas.object(
        properties: ["query": ToolSchemas.string(description: "Search query")],
        required: ["query"]
      ),
      outputSchema: ToolSchemas.object(
        properties: ["matches": .object(["type": .string("number")])],
        required: ["matches"]
      )
    )
    let deferred = ToolDefinition(
      name: "deferred_tool",
      description: "Loaded later.",
      parameters: ToolSchemas.object(properties: ["hidden": ToolSchemas.string()]),
      exposure: .deferred
    )
    let description = try XCTUnwrap(
      CodeModeRuntime.execResponseTool(
        definitions: [eager, deferred],
        codeModeOnly: true
      ).description
    )

    XCTAssertTrue(description.contains("### `tools.schema_tool`"))
    XCTAssertTrue(description.contains("await tools.schema_tool(args)"))
    XCTAssertTrue(description.contains("Input JSON Schema:"))
    XCTAssertTrue(description.contains("Output JSON Schema:"))
    XCTAssertTrue(description.contains("\"query\""))
    XCTAssertTrue(description.contains("\"matches\""))
    XCTAssertFalse(description.contains("### `tools.deferred_tool`"))

    let ordinaryDescription = try XCTUnwrap(
      CodeModeRuntime.execResponseTool(definitions: [eager]).description
    )
    XCTAssertFalse(ordinaryDescription.contains("Input JSON Schema:"))
  }

  func testHiddenAndDirectOnlyToolsAreNotNested() {
    let hidden = NamedTool(name: "hidden", exposure: .hidden)
    let hiddenInDirectNamespace = NamedTool(
      name: "hidden_namespaced", exposure: .hidden, namespace: "direct_only")
    let direct = NamedTool(name: "direct", exposure: .directModelOnly)
    let reservedExec = NamedTool(name: "exec")
    let reservedWait = NamedTool(name: "wait")
    XCTAssertTrue(
      CodeModeToolCatalog.bindings(
        definitions: [
          hidden.definition, direct.definition, reservedExec.definition, reservedWait.definition,
        ],
        options: CodeModeOptions()
      ).isEmpty)
    XCTAssertEqual(
      CodeModeToolCatalog.directModelDefinitions(
        definitions: [hidden.definition, hiddenInDirectNamespace.definition, direct.definition],
        options: CodeModeOptions(directOnlyToolNamespaces: ["direct_only"])
      ).map(\.name),
      ["direct"]
    )
  }

  func testNestedToolsCanExecuteInParallelAndReturnCodexEnvelope() async throws {
    let tool = DelayedEchoTool()
    let runtime = CodeModeRuntime(registry: ToolRegistry(tools: [tool]))
    let start = ContinuousClock.now
    let result = await runtime.execute(
      source: """
        const values = await Promise.all([
          tools.delayed_echo({text: 'a', milliseconds: 100}),
          tools.delayed_echo({text: 'b', milliseconds: 100})
        ]);
        text(values.join(','));
        """,
      definitions: [tool.definition],
      context: context()
    )
    XCTAssertEqual(result.content, "a,b")
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(190))
  }

  private func context() -> ToolExecutionContext {
    ToolExecutionContext(
      threadID: "thread-parity",
      turnID: UUID().uuidString,
      approvalPolicy: .never,
      sandboxPolicy: .workspaceWrite
    )
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0
  var value: Int { lock.withLock { storage } }
  func increment() { lock.withLock { storage += 1 } }
}

private final class NotificationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CodeModeNotification] = []
  var notifications: [CodeModeNotification] { lock.withLock { storage } }
  func append(_ notification: CodeModeNotification) {
    lock.withLock { storage.append(notification) }
  }
}

private final class CodeModeRecordingProvider: ModelProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var batches: [[ModelStreamEvent]]
  private var requestStorage: [ResponsesRequest] = []

  init(batches: [[ModelStreamEvent]]) {
    self.batches = batches
  }

  var requests: [ResponsesRequest] { lock.withLock { requestStorage } }

  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let events = lock.withLock {
      requestStorage.append(request)
      return batches.isEmpty
        ? [.completed(responseID: nil, usage: nil)]
        : batches.removeFirst()
    }
    return AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }
}

private struct CountingTool: AgentTool {
  let counter: Counter
  let definition = ToolDefinition(
    name: "counting",
    description: "Increments a counter.",
    parameters: ToolSchemas.object(properties: [:])
  )
  func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    counter.increment()
    return ToolResult(content: "counted")
  }
}

private struct NamedTool: AgentTool {
  let definition: ToolDefinition
  init(name: String, exposure: ToolExposure = .direct, namespace: String? = nil) {
    definition = ToolDefinition(
      name: name,
      description: "Named test tool.",
      parameters: ToolSchemas.object(properties: [:]),
      exposure: exposure,
      namespace: namespace
    )
  }
  func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    ToolResult(content: "called")
  }
}

private struct DelayedEchoTool: AgentTool {
  let definition = ToolDefinition(
    name: "delayed_echo",
    description: "Echoes after a delay.",
    parameters: ToolSchemas.object(
      properties: [
        "text": ToolSchemas.string(),
        "milliseconds": .object(["type": .string("number")]),
      ], required: ["text", "milliseconds"])
  )
  func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    let milliseconds = CodeModeNumericLimits.timerMilliseconds(
      arguments["milliseconds"]?.doubleValue ?? 0
    )
    try await Task.sleep(for: .milliseconds(milliseconds))
    return ToolResult(content: try arguments.requiredString("text"))
  }
}

private struct ProgrammaticResultTool: AgentTool {
  let definition = ToolDefinition(
    name: "programmatic_result",
    description: "Returns a native object.",
    parameters: ToolSchemas.object(properties: [:])
  )
  func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    ToolResult(
      content: "human-readable",
      codeModeResult: .object(["answer": .number(42)])
    )
  }
}

private struct CharacterTokenCounter: CodeModeTokenCounting {
  func countTokens(in text: String) -> Int { text.count }
}

private final class InterruptibleCellProvider: ModelProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var requestCount = 0

  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let index = lock.withLock {
      defer { requestCount += 1 }
      return requestCount
    }
    if index == 0 {
      return AsyncThrowingStream { continuation in
        continuation.yield(
          .toolCallCompleted(
            ToolCall(
              callID: "interrupt-exec",
              name: CodeModeRuntime.execToolName,
              arguments:
                "await yield_control(); await new Promise(resolve => setTimeout(resolve, 5_000));",
              kind: .custom
            )))
        continuation.yield(.completed(responseID: "response-1", usage: nil))
        continuation.finish()
      }
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        try await Task.sleep(for: .milliseconds(100))
        continuation.yield(.raw(.object(["type": .string("heartbeat")])))
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }
}
