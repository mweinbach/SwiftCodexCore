import XCTest

@testable import CodexCore

final class CodexCoreTests: XCTestCase {
  func testJSONValueRoundTrip() throws {
    let value: JSONValue = .object([
      "name": .string("codex"),
      "count": .number(3),
      "enabled": .bool(true),
      "items": .array([.string("a"), .null]),
    ])
    let data = try JSONEncoder.codexCompact.encode(value)
    let decoded = try JSONDecoder.codex.decode(JSONValue.self, from: data)
    XCTAssertEqual(value, decoded)
  }

  func testJSONValueHandlesNumbersOutsideIntegerRangeWithoutTrapping() throws {
    let boundary = JSONValue.number(Double(Int64.max))
    let huge = JSONValue.number(1e300)

    XCTAssertFalse(boundary.description.isEmpty)
    XCTAssertFalse(huge.description.isEmpty)
    XCTAssertNoThrow(try JSONEncoder.codexCompact.encode(boundary))
    XCTAssertNoThrow(try JSONEncoder.codexCompact.encode(huge))
    XCTAssertEqual(JSONValue.number(.infinity).description, "inf")
    XCTAssertThrowsError(try JSONEncoder.codexCompact.encode(JSONValue.number(.infinity)))
  }

  func testToolRegistryEcho() async throws {
    let registry = ToolRegistry(tools: [EchoTool()])
    let result = try await registry.run(
      name: "echo",
      arguments: .object(["text": .string("hello")]),
      context: ToolExecutionContext(
        threadID: "t", turnID: "u", approvalPolicy: .never, sandboxPolicy: .readOnly)
    )
    XCTAssertEqual(result.content, "hello")
  }

  func testFileReadCannotEscapeWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftCodexCoreTests-\(UUID().uuidString)")
    let workspace = root.appendingPathComponent("workspace")
    let outside = root.appendingPathComponent("outside.txt")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try "secret".write(to: outside, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let registry = ToolRegistry(tools: [FileReadTool()])
    let context = ToolExecutionContext(
      threadID: "t",
      turnID: "u",
      workspaceURL: workspace,
      approvalPolicy: .never,
      sandboxPolicy: .workspaceWrite
    )
    do {
      _ = try await registry.run(
        name: "read_file",
        arguments: .object(["path": .string("../outside.txt")]),
        context: context
      )
      XCTFail("Expected read outside workspace to fail")
    } catch CodexCoreError.approvalRequired(let message) {
      XCTAssertTrue(message.contains("outside readable roots"))
    }
  }

  func testAgentLoopRunsToolThenFinalAnswer() async throws {
    let provider = ScriptedModelProvider(batches: [
      [
        .toolCallCompleted(
          ToolCall(callID: "call_echo", name: "echo", arguments: "{\"text\":\"pong\"}")),
        .completed(responseID: "r1", usage: nil),
      ],
      [
        .outputTextDelta("pong"),
        .completed(responseID: "r2", usage: nil),
      ],
    ])
    let registry = ToolRegistry(tools: [EchoTool()])
    let manager = ThreadManager(store: InMemoryThreadStore())
    let agent = CodexAgent(modelProvider: provider, toolRegistry: registry, threadManager: manager)
    let thread = try await agent.createThread()
    let handle = agent.startTurn(threadID: thread.id, input: TurnInput("ping"))
    var sawTool = false
    var sawFinal = false
    for try await event in handle.events {
      if case .toolCompleted(let call, let result) = event {
        sawTool = call.name == "echo" && result.content == "pong"
      }
      if case .itemCompleted(let item) = event, item.kind == .assistantMessage,
        item.payload["content"]?.stringValue == "pong"
      {
        sawFinal = true
      }
    }
    XCTAssertTrue(sawTool)
    XCTAssertTrue(sawFinal)
  }

  func testRuntimeClearsActiveTurnWhenStreamingHandleCompletes() async throws {
    let provider = ScriptedModelProvider(batches: [
      [
        .outputTextDelta("done"),
        .completed(responseID: "r1", usage: nil),
      ]
    ])
    let runtime = CodexRuntime(modelProvider: provider, tools: [])
    let thread = try await runtime.createThread()
    let handle = try await runtime.startTurn(threadID: thread.id, input: TurnInput("go"))

    for try await _ in handle.events {}

    let active = await runtime.activeTurn(threadID: thread.id)
    XCTAssertNil(active)
  }

  func testRuntimeRejectsOverlappingTurnsOnSameThread() async throws {
    let provider = DelayedModelProvider(delayNanoseconds: 500_000_000)
    let runtime = CodexRuntime(modelProvider: provider, tools: [])
    let thread = try await runtime.createThread()
    let handle = try await runtime.startTurn(threadID: thread.id, input: TurnInput("first"))

    do {
      _ = try await runtime.startTurn(threadID: thread.id, input: TurnInput("second"))
      XCTFail("Expected overlapping turn to fail")
    } catch CodexCoreError.invalidState(let message) {
      XCTAssertTrue(message.contains("already has active turn"))
    }

    await handle.interrupt()
    for try await _ in handle.events {}
  }

  func testAgentLoopAddsReasoningAndDisablesForegroundStore() async throws {
    let provider = RecordingModelProvider(batches: [
      [
        .outputTextDelta("done"),
        .completed(responseID: "r1", usage: nil),
      ]
    ])
    let config = AgentConfiguration(
      model: "gpt-5.4",
      reasoningEffort: .high,
      reasoningSummary: .auto,
      backgroundAccessEnabled: true
    )
    let runtime = CodexRuntime(configuration: config, modelProvider: provider, tools: [])
    let thread = try await runtime.createThread()
    let handle = try await runtime.startTurn(threadID: thread.id, input: TurnInput("go"))

    for try await _ in handle.events {}

    let request = try XCTUnwrap(provider.requests.first)
    XCTAssertEqual(request.reasoning?.effort, "high")
    XCTAssertEqual(request.reasoning?.summary, "auto")
    XCTAssertEqual(request.store, false)
    XCTAssertEqual(request.promptCacheKey, thread.id)
    XCTAssertEqual(request.include, ["reasoning.encrypted_content"])
  }

  func testAgentLoopThreadsGPT56ControlsAndOmitsMultiAgentReasoningSummary() async throws {
    let provider = RecordingModelProvider(batches: [
      [.outputTextDelta("done"), .completed(responseID: "r1", usage: nil)]
    ])
    let config = AgentConfiguration(
      model: OpenAIModel.gpt56Sol.rawValue,
      reasoningEffort: .max,
      reasoningSummary: .auto,
      reasoningMode: .pro,
      reasoningContext: .allTurns,
      serviceTier: "priority",
      promptCacheKey: "thread:stable",
      promptCacheOptions: PromptCacheOptions(mode: .explicit),
      safetyIdentifier: "stable-user-hash",
      maxOutputTokens: 64_000,
      multiAgent: MultiAgentConfiguration(maxConcurrentSubagents: 3),
      contextManagement: [ResponseContextManagement(compactThreshold: 320_000)],
      responseIncludes: ["reasoning.encrypted_content"],
      toolChoice: .string("auto"),
      textOptions: ResponseTextOptions(verbosity: .low)
    )
    let runtime = CodexRuntime(configuration: config, modelProvider: provider, tools: [])
    let thread = try await runtime.createThread()
    let handle = try await runtime.startTurn(threadID: thread.id, input: TurnInput("go"))
    for try await _ in handle.events {}

    let request = try XCTUnwrap(provider.requests.first)
    XCTAssertEqual(
      request.reasoning, ResponseReasoning(effort: "max", mode: "pro", context: "all_turns"))
    XCTAssertNil(request.reasoning?.summary)
    XCTAssertEqual(request.serviceTier, "priority")
    XCTAssertEqual(request.promptCacheKey, "thread:stable")
    XCTAssertEqual(request.promptCacheOptions, PromptCacheOptions(mode: .explicit))
    XCTAssertEqual(request.safetyIdentifier, "stable-user-hash")
    XCTAssertEqual(request.maxOutputTokens, 64_000)
    XCTAssertEqual(request.multiAgent?.maxConcurrentSubagents, 3)
    XCTAssertEqual(
      request.contextManagement, [ResponseContextManagement(compactThreshold: 320_000)])
    XCTAssertEqual(request.text?.verbosity, .low)
  }

  func testAgentLoopPreservesMultimodalTurnsAndPrunesBeforeCompaction() async throws {
    let compaction: JSONValue = .object([
      "type": .string("compaction"),
      "id": .string("cmp_1"),
      "encrypted_content": .string("opaque"),
    ])
    let provider = RecordingModelProvider(batches: [
      [.responseItemCompleted(compaction), .completed(responseID: "r1", usage: nil)],
      [.outputTextDelta("done"), .completed(responseID: "r2", usage: nil)],
    ])
    let config = AgentConfiguration(
      contextManagement: [ResponseContextManagement(compactThreshold: 320_000)]
    )
    let runtime = CodexRuntime(configuration: config, modelProvider: provider, tools: [])
    let thread = try await runtime.createThread()
    let image = ResponseInputBuilder.inputImage(
      urlString: "data:image/png;base64,abc", detail: .original)

    for try await _ in try await runtime.startTurn(
      threadID: thread.id,
      input: TurnInput(content: [ResponseInputBuilder.inputText("inspect"), image])
    ).events {}
    for try await _ in try await runtime.startTurn(
      threadID: thread.id, input: TurnInput("continue")
    ).events {}

    let firstInput = try XCTUnwrap(provider.requests.first?.input)
    XCTAssertTrue(firstInput.contains { $0["content"]?.arrayValue?.last == image })
    XCTAssertEqual(provider.requests.first?.contextManagement?.first?.compactThreshold, 320_000)

    let secondInput = try XCTUnwrap(provider.requests.last?.input)
    XCTAssertTrue(secondInput.contains(compaction))
    XCTAssertEqual(
      secondInput.last?["content"]?.arrayValue?.first?["text"]?.stringValue, "continue")
    XCTAssertFalse(
      secondInput.contains { item in
        item["content"]?.arrayValue?.contains { $0["text"]?.stringValue == "inspect" } == true
      })
  }

  func testNetworkServerToolsAreFilteredWhenSandboxDisallowsNetwork() async throws {
    let provider = RecordingModelProvider(batches: [
      [.outputTextDelta("done"), .completed(responseID: "r1", usage: nil)]
    ])
    let config = AgentConfiguration(
      sandboxPolicy: .workspaceWrite,
      serverTools: [
        .webSearch(searchContextSize: "medium"),
        .imageGeneration(model: "gpt-image-2"),
        .raw(type: "local_preview"),
      ]
    )
    let agent = CodexAgent(
      configuration: config, modelProvider: provider, toolRegistry: ToolRegistry(),
      threadManager: ThreadManager(store: InMemoryThreadStore()))
    let thread = try await agent.createThread()
    let handle = agent.startTurn(threadID: thread.id, input: TurnInput("no network tools"))
    for try await _ in handle.events {}

    let request = try XCTUnwrap(provider.requests.first)
    XCTAssertEqual(request.tools.map(\.type), ["local_preview"])
  }

  func testToolApprovalRequestsAreEmittedOnEventStream() async throws {
    let provider = ScriptedModelProvider(batches: [
      [
        .toolCallCompleted(
          ToolCall(callID: "approve", name: "approval_echo", arguments: #"{"text":"approved"}"#)),
        .completed(responseID: "r1", usage: nil),
      ],
      [
        .outputTextDelta("done"),
        .completed(responseID: "r2", usage: nil),
      ],
    ])
    let config = AgentConfiguration(approvalPolicy: .always)
    let agent = CodexAgent(
      configuration: config,
      modelProvider: provider,
      toolRegistry: ToolRegistry(tools: [ApprovalEchoTool()]),
      threadManager: ThreadManager(store: InMemoryThreadStore()),
      approvalHandler: { request in
        ApprovalDecision(approved: request.toolName == "approval_echo")
      }
    )
    let thread = try await agent.createThread()
    let handle = agent.startTurn(threadID: thread.id, input: TurnInput("write a file"))
    var sawApproval = false
    for try await event in handle.events {
      if case .approvalRequested(let request) = event {
        sawApproval = request.toolName == "approval_echo"
      }
    }
    XCTAssertTrue(sawApproval)
  }

  func testToolContinuationUsesPreviousResponseID() async throws {
    let provider = RecordingModelProvider(batches: [
      [
        .toolCallCompleted(
          ToolCall(callID: "call_echo", name: "echo", arguments: #"{"text":"pong"}"#)),
        .completed(responseID: "r1", usage: nil),
      ],
      [
        .outputTextDelta("pong"),
        .completed(responseID: "r2", usage: nil),
      ],
    ])
    let agent = CodexAgent(
      modelProvider: provider, toolRegistry: ToolRegistry(tools: [EchoTool()]),
      threadManager: ThreadManager(store: InMemoryThreadStore()))
    let thread = try await agent.createThread()
    let handle = agent.startTurn(threadID: thread.id, input: TurnInput("ping"))
    for try await _ in handle.events {}

    XCTAssertEqual(provider.requests.count, 2)
    XCTAssertNil(provider.requests[0].previousResponseID)
    XCTAssertEqual(provider.requests[1].previousResponseID, "r1")
    XCTAssertEqual(provider.requests[1].input.count, 1)
    XCTAssertEqual(provider.requests[1].input.first?["type"]?.stringValue, "function_call_output")
  }

  func testToolContinuationReplaysHistoryWhenProviderDoesNotSupportPreviousResponseID() async throws
  {
    let provider = RecordingModelProvider(
      batches: [
        [
          .toolCallCompleted(
            ToolCall(
              id: "fc_echo", callID: "call_echo", name: "echo", arguments: #"{"text":"pong"}"#)),
          .completed(responseID: "r1", usage: nil),
        ],
        [
          .outputTextDelta("pong"),
          .completed(responseID: "r2", usage: nil),
        ],
      ],
      supportsResponseContinuation: false
    )
    let agent = CodexAgent(
      modelProvider: provider, toolRegistry: ToolRegistry(tools: [EchoTool()]),
      threadManager: ThreadManager(store: InMemoryThreadStore()))
    let thread = try await agent.createThread()
    let handle = agent.startTurn(threadID: thread.id, input: TurnInput("ping"))
    for try await _ in handle.events {}

    XCTAssertEqual(provider.requests.count, 2)
    XCTAssertNil(provider.requests[0].previousResponseID)
    XCTAssertNil(provider.requests[1].previousResponseID)
    XCTAssertGreaterThanOrEqual(provider.requests[1].input.count, 3)
    XCTAssertEqual(provider.requests[1].input[0]["role"]?.stringValue, "user")
    let itemTypes = provider.requests[1].input.compactMap { $0["type"]?.stringValue }
    XCTAssertTrue(itemTypes.contains("function_call"))
    XCTAssertTrue(itemTypes.contains("function_call_output"))
    let replayedToolCall = try XCTUnwrap(
      provider.requests[1].input.first { $0["type"]?.stringValue == "function_call" })
    XCTAssertEqual(replayedToolCall["id"]?.stringValue, "fc_echo")
    XCTAssertEqual(replayedToolCall["call_id"]?.stringValue, "call_echo")
  }

  func testProgrammaticToolContinuationPreservesCallerAndReplayableItems() async throws {
    let caller: JSONValue = .object([
      "type": .string("program"), "caller_id": .string("call_program"),
    ])
    let provider = RecordingModelProvider(
      batches: [
        [
          .responseItemCompleted(
            .object([
              "type": .string("program"),
              "id": .string("program_1"),
              "call_id": .string("call_program"),
              "code": .string("await tools.echo({ text: 'pong' })"),
              "fingerprint": .string("opaque"),
            ])),
          .responseItemCompleted(
            .object([
              "type": .string("reasoning"),
              "id": .string("reasoning_1"),
              "encrypted_content": .string("encrypted"),
            ])),
          .toolCallCompleted(
            ToolCall(
              id: "fc_program",
              callID: "call_echo",
              name: "echo",
              arguments: #"{"text":"pong"}"#,
              caller: caller
            )),
          .completed(responseID: "r1", usage: nil),
        ],
        [.outputTextDelta("pong"), .completed(responseID: "r2", usage: nil)],
      ],
      supportsResponseContinuation: false
    )
    let agent = CodexAgent(
      modelProvider: provider,
      toolRegistry: ToolRegistry(tools: [EchoTool()]),
      threadManager: ThreadManager(store: InMemoryThreadStore())
    )
    let thread = try await agent.createThread()
    let handle = agent.startTurn(threadID: thread.id, input: TurnInput("ping"))
    for try await _ in handle.events {}

    let replay = provider.requests[1].input
    XCTAssertTrue(replay.contains { $0["type"]?.stringValue == "program" })
    XCTAssertTrue(replay.contains { $0["type"]?.stringValue == "reasoning" })
    let call = try XCTUnwrap(replay.first { $0["type"]?.stringValue == "function_call" })
    let output = try XCTUnwrap(replay.first { $0["type"]?.stringValue == "function_call_output" })
    XCTAssertEqual(call["caller"], caller)
    XCTAssertEqual(output["caller"], caller)
  }

  func testHostedToolReplaySkipsProgressEvents() async throws {
    let provider = RecordingModelProvider(
      batches: [
        [
          .serverToolCompleted(
            name: "web_search",
            item: .object([
              "item_id": .string("ws_progress"),
              "type": .string("response.web_search_call.completed"),
            ])
          ),
          .serverToolCompleted(
            name: "web_search",
            item: .object([
              "id": .string("ws_final"),
              "status": .string("completed"),
              "type": .string("web_search_call"),
            ])
          ),
          .outputTextDelta("market brief"),
          .completed(responseID: "r1", usage: nil),
        ],
        [
          .outputTextDelta("doc created"),
          .completed(responseID: "r2", usage: nil),
        ],
      ],
      supportsResponseContinuation: false
    )
    let agent = CodexAgent(
      modelProvider: provider, threadManager: ThreadManager(store: InMemoryThreadStore()))
    let thread = try await agent.createThread()

    for try await _ in agent.startTurn(threadID: thread.id, input: TurnInput("research pc market"))
      .events
    {}
    for try await _ in agent.startTurn(threadID: thread.id, input: TurnInput("write a report"))
      .events
    {}

    XCTAssertEqual(provider.requests.count, 2)
    let replayedTypes = provider.requests[1].input.compactMap { $0["type"]?.stringValue }
    XCTAssertTrue(replayedTypes.contains("web_search_call"))
    XCTAssertFalse(replayedTypes.contains("response.web_search_call.completed"))
  }

  func testThreadForkRollback() async throws {
    let manager = ThreadManager(store: InMemoryThreadStore())
    let thread = try await manager.createThread(title: "root")
    let item1 = ThreadItem(threadID: thread.id, kind: .userMessage, summary: "one")
    let item2 = ThreadItem(threadID: thread.id, kind: .assistantMessage, summary: "two")
    _ = try await manager.appendItems([item1, item2], to: thread.id)
    let fork = try await manager.forkThread(id: thread.id, title: "fork")
    XCTAssertEqual(fork.parentThreadID, thread.id)
    let rolled = try await manager.rollbackThread(id: fork.id, toItemID: item1.id)
    XCTAssertEqual(rolled.items.count, 1)
  }

  func testResponseBuiltInToolDefinitionsEncode() throws {
    let tools: [ResponseToolDefinition] = [
      .webSearch(searchContextSize: "medium", externalWebAccess: true),
      .imageGeneration(model: "gpt-image-2", size: "1024x1024", outputFormat: "png"),
      .fileSearch(vectorStoreIDs: ["vs_123"]),
      .codeInterpreter(allowedCallers: [.programmatic]),
      .hostedShell(allowedCallers: [.direct, .programmatic]),
      .applyPatch(),
      .computerUse(environment: "computer"),
      .skills(),
      .toolSearch(),
      .programmaticToolCalling(),
    ]
    let data = try JSONEncoder.codexCompact.encode(tools)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssertTrue(json.contains("\"type\":\"web_search\""))
    XCTAssertTrue(json.contains("\"type\":\"image_generation\""))
    XCTAssertTrue(json.contains("\"external_web_access\":true"))
    XCTAssertTrue(json.contains("\"type\":\"programmatic_tool_calling\""))
    XCTAssertTrue(json.contains("\"allowed_callers\":[\"programmatic\"]"))
  }

  func testGPT56RequestControlsEncode() throws {
    let request = ResponsesRequest(
      model: OpenAIModel.gpt56Sol.rawValue,
      input: [
        ResponseInputBuilder.userMessage(content: [
          ResponseInputBuilder.inputText("inspect this", cacheBreakpoint: true),
          ResponseInputBuilder.inputImage(
            urlString: "data:image/png;base64,abc", detail: .original),
        ])
      ],
      reasoning: ResponseReasoning(effort: .max, summary: .auto, mode: .pro, context: .allTurns),
      store: false,
      include: ["reasoning.encrypted_content"],
      serviceTier: "priority",
      promptCacheKey: "thread:123",
      promptCacheOptions: PromptCacheOptions(mode: .explicit),
      safetyIdentifier: "stable-user-hash",
      maxOutputTokens: 128_000,
      text: ResponseTextOptions(verbosity: .high),
      multiAgent: MultiAgentConfiguration(maxConcurrentSubagents: 4),
      contextManagement: [ResponseContextManagement(compactThreshold: 900_000)]
    )

    let json = try JSONDecoder.codex.decode(
      JSONValue.self, from: JSONEncoder.codexCompact.encode(request))
    XCTAssertEqual(json["model"]?.stringValue, "gpt-5.6-sol")
    XCTAssertEqual(json["reasoning"]?["effort"]?.stringValue, "max")
    XCTAssertEqual(json["reasoning"]?["mode"]?.stringValue, "pro")
    XCTAssertEqual(json["reasoning"]?["context"]?.stringValue, "all_turns")
    XCTAssertEqual(json["prompt_cache_options"]?["mode"]?.stringValue, "explicit")
    XCTAssertEqual(json["prompt_cache_options"]?["ttl"]?.stringValue, "30m")
    XCTAssertEqual(json["multi_agent"]?["max_concurrent_subagents"]?.doubleValue, 4)
    XCTAssertEqual(
      json["context_management"]?.arrayValue?.first?["type"]?.stringValue, "compaction")
    XCTAssertEqual(
      json["context_management"]?.arrayValue?.first?["compact_threshold"]?.doubleValue, 900_000)
    XCTAssertEqual(
      json["input"]?.arrayValue?.first?["content"]?.arrayValue?.last?["detail"]?.stringValue,
      "original")
    XCTAssertEqual(
      json["input"]?.arrayValue?.first?["content"]?.arrayValue?.first?["prompt_cache_breakpoint"]?[
        "mode"]?.stringValue,
      "explicit"
    )
  }

  func testProgrammaticFunctionToolAndCallerLinkageEncode() throws {
    let schema = ToolSchemas.object(
      properties: ["value": ToolSchemas.string()], required: ["value"])
    let definition = ToolDefinition(
      name: "lookup",
      description: "Return structured lookup data.",
      parameters: schema,
      strict: true,
      outputSchema: schema,
      allowedCallers: [.direct, .programmatic]
    ).responseTool
    XCTAssertEqual(definition.fields["strict"]?.boolValue, true)
    XCTAssertEqual(definition.fields["allowed_callers"]?.arrayValue?.count, 2)

    let caller: JSONValue = .object([
      "type": .string("program"), "caller_id": .string("call_program"),
    ])
    let call = ToolCall(
      id: "fc_1", callID: "call_1", name: "lookup", arguments: "{}", caller: caller)
    XCTAssertEqual(ResponseInputBuilder.functionCall(call)["caller"], caller)
    XCTAssertEqual(
      ResponseInputBuilder.functionCallOutput(
        callID: call.callID, output: "{}", caller: call.caller)["caller"], caller)
  }

  func testMultiAgentRequestAddsBetaHeader() async throws {
    StubURLProtocol.handler = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "responses_multi_agent=v1")
      let body = try JSONDecoder.codex.decode(JSONValue.self, from: request.bodyData())
      XCTAssertEqual(body["multi_agent"]?["enabled"]?.boolValue, true)
      return StubURLProtocol.response(for: request, json: #"{"output_text":"ok"}"#)
    }
    defer { StubURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = OpenAIResponsesClient(
      auth: StaticAuthProvider(), session: URLSession(configuration: configuration))
    let request = ResponsesRequest(
      model: OpenAIModel.gpt56Sol.rawValue,
      input: [ResponseInputBuilder.userMessage("review this")],
      multiAgent: MultiAgentConfiguration()
    )
    for try await _ in client.streamResponse(request) {}
  }

  func testResponsesLiteAddsTransportHeaderAndOmitsTopLevelTools() async throws {
    StubURLProtocol.handler = { request in
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "x-openai-internal-codex-responses-lite"),
        "true"
      )
      let body = try JSONDecoder.codex.decode(JSONValue.self, from: request.bodyData())
      XCTAssertNil(body["tools"])
      XCTAssertNil(body["instructions"])
      XCTAssertEqual(body["parallel_tool_calls"]?.boolValue, false)
      XCTAssertEqual(body["reasoning"]?["context"]?.stringValue, "all_turns")
      let input = try XCTUnwrap(body["input"]?.arrayValue)
      XCTAssertEqual(input.first?["type"]?.stringValue, "additional_tools")
      XCTAssertEqual(input.first?["tools"]?.arrayValue?.count, 1)
      XCTAssertEqual(input.dropFirst().first?["role"]?.stringValue, "developer")
      XCTAssertEqual(
        input.dropFirst().first?["content"]?.arrayValue?.first?["text"]?.stringValue,
        "must move to input for real Lite calls"
      )
      XCTAssertEqual(input.last?["role"]?.stringValue, "user")
      let userContent = try XCTUnwrap(input.last?["content"]?.arrayValue)
      XCTAssertNil(userContent[1]["detail"])
      XCTAssertEqual(userContent[1]["image_url"]?.stringValue, "data:image/png;base64,AAAA")
      XCTAssertEqual(userContent[2]["type"]?.stringValue, "input_text")
      XCTAssertNil(userContent[2]["image_url"])
      return StubURLProtocol.response(for: request, json: #"{"output_text":"ok"}"#)
    }
    defer { StubURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = OpenAIResponsesClient(
      auth: StaticAuthProvider(),
      session: URLSession(configuration: configuration)
    )
    let tool = EchoTool().definition.responseTool
    let request = ResponsesRequest(
      model: OpenAIModel.gpt56Sol.rawValue,
      instructions: "must move to input for real Lite calls",
      input: [
        ResponseInputBuilder.userMessage(content: [
          ResponseInputBuilder.inputText("hello"),
          ResponseInputBuilder.inputImage(
            urlString: "data:image/png;base64,AAAA",
            detail: .original
          ),
          ResponseInputBuilder.inputImage(
            urlString: "https://example.com/private.png",
            detail: .high
          ),
        ])
      ],
      tools: [tool, .webSearch()],
      useResponsesLite: true
    )
    for try await _ in client.streamResponse(request) {}

    let preShaped = ResponsesRequest(
      model: OpenAIModel.gpt56Sol.rawValue,
      input: [
        ResponseInputBuilder.developerMessage("already moved"),
        ResponseInputBuilder.additionalTools([tool, .webSearch(), tool]),
        ResponseInputBuilder.userMessage("hello"),
        ResponseInputBuilder.additionalTools([tool]),
      ],
      tools: [tool],
      useResponsesLite: true
    )
    let encoded = try JSONDecoder.codex.decode(
      JSONValue.self,
      from: JSONEncoder.codexCompact.encode(preShaped)
    )
    XCTAssertEqual(
      encoded["input"]?.arrayValue?.filter { $0["type"]?.stringValue == "additional_tools" }.count,
      1
    )
    XCTAssertEqual(encoded["input"]?.arrayValue?.first?["type"]?.stringValue, "additional_tools")
    XCTAssertEqual(encoded["input"]?.arrayValue?.first?["tools"]?.arrayValue?.count, 1)
  }

  func testDynamicModelsCatalogRefreshesFromCodexEndpointAndResponseETag() async throws {
    let fetchCount = Locked(0)
    StubURLProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/backend-api/codex/models"):
        XCTAssertEqual(
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "client_version"
          }?.value,
          "0.99.0"
        )
        fetchCount.withValue { $0 += 1 }
        let etag = "catalog-\(fetchCount.value)"
        return StubURLProtocol.response(
          for: request,
          headers: ["ETag": etag],
          json:
            #"{"models":[{"slug":"gpt-dynamic","display_name":"Dynamic","default_reasoning_level":"max","supported_reasoning_levels":[{"effort":"low"},{"effort":"max"}],"context_window":400000,"visibility":"list","priority":1,"supported_in_api":true,"supports_image_detail_original":true,"tool_mode":"code_mode_only","multi_agent_version":"v3","future_capability":{"enabled":true}}]}"#
        )
      case ("POST", "/backend-api/codex/responses"):
        return StubURLProtocol.response(
          for: request,
          headers: ["X-Models-Etag": "catalog-2"],
          json: #"{"id":"resp_1","output_text":"ok"}"#
        )
      default:
        XCTFail(
          "Unexpected request: \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
        return StubURLProtocol.response(
          for: request, statusCode: 404, json: #"{"error":"not found"}"#)
      }
    }
    defer { StubURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let responsesEndpoint = URL(string: "https://chatgpt.test/backend-api/codex/responses")!
    let manager = OpenAIModelsManager(
      auth: StaticAuthProvider(),
      options: OpenAIModelsManager.Options(
        endpoint: responsesEndpoint.deletingLastPathComponent().appendingPathComponent("models"),
        clientVersion: "0.99.0",
        cacheURL: nil
      ),
      session: session
    )

    let initial = try await manager.refresh()
    XCTAssertEqual(initial.source, .codex)
    XCTAssertEqual(initial.etag, "catalog-1")
    XCTAssertEqual(initial.models.map(\.slug), ["gpt-dynamic"])
    XCTAssertEqual(initial.defaultModel?.defaultReasoningEffort, .max)
    XCTAssertEqual(initial.defaultModel?.supportedReasoningEfforts, [.low, .max])
    XCTAssertEqual(initial.defaultModel?.automaticCompactionTokenLimit, 360_000)
    XCTAssertEqual(initial.defaultModel?["future_capability"]?["enabled"]?.boolValue, true)
    var dynamicConfiguration = AgentConfiguration(reasoningEffort: nil, parallelToolCalls: nil)
    dynamicConfiguration.applyModelDefaults(try XCTUnwrap(initial.defaultModel))
    XCTAssertEqual(dynamicConfiguration.model, "gpt-dynamic")
    XCTAssertEqual(dynamicConfiguration.reasoningEffort, .max)
    XCTAssertEqual(dynamicConfiguration.contextManagement?.first?.compactThreshold, 360_000)
    XCTAssertEqual(dynamicConfiguration.toolMode, .codeModeOnly)

    let client = OpenAIResponsesClient(
      auth: StaticAuthProvider(),
      options: OpenAIResponsesClient.Options(endpoint: responsesEndpoint),
      session: session,
      modelsManager: manager
    )
    var events: [ModelStreamEvent] = []
    for try await event in client.streamResponse(
      ResponsesRequest(
        model: "gpt-dynamic",
        input: [ResponseInputBuilder.userMessage("hello")]
      ))
    {
      events.append(event)
    }

    XCTAssertTrue(events.contains(.modelCatalogETag("catalog-2")))
    let refreshed = await manager.catalog(.offline)
    XCTAssertEqual(refreshed.etag, "catalog-2")
    XCTAssertEqual(fetchCount.value, 2)
  }

  func testResponsesRequestEncodesBackgroundAndStoreFlags() throws {
    let request = ResponsesRequest(
      model: "gpt-5.4",
      input: [ResponseInputBuilder.userMessage("work on this later")],
      stream: false,
      reasoning: ResponseReasoning(effort: .high, summary: .auto),
      background: true,
      store: true
    )

    let json = try JSONDecoder.codex.decode(
      JSONValue.self, from: JSONEncoder.codexCompact.encode(request))
    XCTAssertEqual(json["background"]?.boolValue, true)
    XCTAssertEqual(json["store"]?.boolValue, true)
    XCTAssertEqual(json["stream"]?.boolValue, false)
    XCTAssertEqual(json["reasoning"]?["effort"]?.stringValue, "high")
    XCTAssertEqual(json["reasoning"]?["summary"]?.stringValue, "auto")
  }

  func testResponsesRequestOmitsEmptyMetadata() throws {
    let request = ResponsesRequest(
      model: "gpt-5.4",
      input: [ResponseInputBuilder.userMessage("hello")]
    )

    let json = try JSONDecoder.codex.decode(
      JSONValue.self, from: JSONEncoder.codexCompact.encode(request))
    XCTAssertNil(json["metadata"])
  }

  func testChatGPTCodexBackendDoesNotSendTopLevelMetadata() async throws {
    StubURLProtocol.handler = { request in
      let body = try JSONDecoder.codex.decode(JSONValue.self, from: request.bodyData())
      XCTAssertNil(body["metadata"])
      XCTAssertNil(body["previous_response_id"])
      return StubURLProtocol.response(for: request, json: #"{"output_text":"ok"}"#)
    }
    defer { StubURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = OpenAIResponsesClient(
      auth: StaticAuthProvider(),
      options: OpenAIResponsesClient.Options(
        endpoint: URL(string: "https://chatgpt.test/backend-api/codex/responses")!,
        sendsMetadata: false,
        supportsResponseContinuation: false
      ),
      session: session
    )
    let request = ResponsesRequest(
      model: "gpt-5.4",
      input: [ResponseInputBuilder.userMessage("hello")],
      previousResponseID: "resp_123",
      metadata: ["thread_id": .string("thread_123")]
    )

    var iterator = client.streamResponse(request).makeAsyncIterator()
    _ = try await iterator.next()
  }

  func testOpenAIResponsesClientParsesSSEBodyWithJSONContentType() async throws {
    StubURLProtocol.handler = { request in
      StubURLProtocol.response(
        for: request,
        contentType: "application/json",
        body: """
          event: response.output_text.delta
          data: {"type":"response.output_text.delta","delta":"hewwo"}

          event: response.completed
          data: {"type":"response.completed","response":{"id":"resp_123"}}

          """
      )
    }
    defer { StubURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = OpenAIResponsesClient(
      auth: StaticAuthProvider(),
      options: OpenAIResponsesClient.Options(
        endpoint: URL(string: "https://chatgpt.test/backend-api/codex/responses")!),
      session: session
    )

    let request = ResponsesRequest(
      model: "gpt-5.4", input: [ResponseInputBuilder.userMessage("hello")])
    var events: [ModelStreamEvent] = []
    for try await event in client.streamResponse(request) {
      events.append(event)
    }

    XCTAssertEqual(
      events,
      [
        .outputTextDelta("hewwo"),
        .completed(responseID: "resp_123", usage: nil),
      ])
  }

  func testMultiAgentStreamSeparatesSubagentAndRootOutput() async throws {
    StubURLProtocol.handler = { request in
      StubURLProtocol.response(
        for: request,
        contentType: "text/event-stream",
        body: """
          event: response.output_item.added
          data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","phase":"commentary","agent":{"agent_name":"/root/reviewer"},"content":[]}}

          event: response.output_text.delta
          data: {"type":"response.output_text.delta","output_index":0,"delta":"private draft"}

          event: response.output_item.done
          data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","phase":"commentary","agent":{"agent_name":"/root/reviewer"},"content":[{"type":"output_text","text":"private draft"}]}}

          event: response.output_item.added
          data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","phase":"final_answer","agent":{"agent_name":"/root"},"content":[]}}

          event: response.output_text.delta
          data: {"type":"response.output_text.delta","output_index":1,"delta":"public answer"}

          event: response.output_item.done
          data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","phase":"final_answer","agent":{"agent_name":"/root"},"content":[{"type":"output_text","text":"public answer"}]}}

          event: response.completed
          data: {"type":"response.completed","response":{"id":"resp_multi"}}

          """
      )
    }
    defer { StubURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = OpenAIResponsesClient(
      auth: StaticAuthProvider(), session: URLSession(configuration: configuration))
    let request = ResponsesRequest(
      model: OpenAIModel.gpt56Sol.rawValue,
      input: [ResponseInputBuilder.userMessage("review")],
      multiAgent: MultiAgentConfiguration()
    )
    var events: [ModelStreamEvent] = []
    for try await event in client.streamResponse(request) { events.append(event) }

    XCTAssertTrue(events.contains(.outputTextDelta("public answer")))
    XCTAssertTrue(events.contains(.messageCompleted("public answer")))
    XCTAssertFalse(events.contains(.outputTextDelta("private draft")))
    XCTAssertFalse(events.contains(.messageCompleted("private draft")))
    XCTAssertTrue(
      events.contains { event in
        if case .responseItemCompleted(let item) = event {
          return item["agent"]?["agent_name"]?.stringValue == "/root/reviewer"
        }
        return false
      })
  }

  func testOpenAIResponsesClientBackgroundLifecycleUsesResponseEndpoints() async throws {
    let endpoint = URL(string: "https://example.test/v1/responses")!
    let requests = Locked<[CapturedHTTPRequest]>([])
    StubURLProtocol.handler = { request in
      requests.withValue { $0.append(CapturedHTTPRequest(request)) }
      let path = request.url?.path ?? ""
      let method = request.httpMethod ?? ""

      switch (method, path) {
      case ("POST", "/v1/responses"):
        let body = try JSONDecoder.codex.decode(JSONValue.self, from: request.bodyData())
        XCTAssertEqual(body["background"]?.boolValue, true)
        XCTAssertEqual(body["stream"]?.boolValue, false)
        XCTAssertEqual(body["store"]?.boolValue, true)
        return StubURLProtocol.response(
          for: request,
          json: #"{"id":"resp_123","status":"queued","background":true}"#
        )
      case ("GET", "/v1/responses/resp_123"):
        return StubURLProtocol.response(
          for: request,
          json:
            #"{"id":"resp_123","status":"completed","background":true,"output_text":"done","usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}"#
        )
      case ("POST", "/v1/responses/resp_123/cancel"):
        return StubURLProtocol.response(
          for: request,
          json: #"{"id":"resp_123","status":"cancelled","background":true}"#
        )
      default:
        XCTFail("Unexpected request: \(method) \(path)")
        return StubURLProtocol.response(
          for: request, statusCode: 404, json: #"{"error":{"message":"not found"}}"#)
      }
    }
    defer { StubURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = OpenAIResponsesClient(
      auth: StaticAuthProvider(),
      options: OpenAIResponsesClient.Options(endpoint: endpoint),
      session: session
    )
    let request = ResponsesRequest(
      model: "gpt-5.4", input: [ResponseInputBuilder.userMessage("slow work")])

    let created = try await client.createBackgroundResponse(request)
    XCTAssertEqual(created.id, "resp_123")
    XCTAssertEqual(created.status, "queued")
    XCTAssertFalse(created.isTerminal)

    let retrieved = try await client.retrieveResponse(id: "resp_123")
    XCTAssertEqual(retrieved.outputText, "done")
    XCTAssertEqual(retrieved.usage?.totalTokens, 3)
    XCTAssertTrue(retrieved.isTerminal)

    let cancelled = try await client.cancelResponse(id: "resp_123")
    XCTAssertEqual(cancelled.status, "cancelled")
    XCTAssertTrue(cancelled.isTerminal)

    let captured = requests.value
    XCTAssertEqual(captured.map(\.method), ["POST", "GET", "POST"])
    XCTAssertTrue(captured.allSatisfy { $0.authorization == "Bearer test-token" })
  }

  func testOpenAIResponsesClientStandaloneCompaction() async throws {
    let endpoint = URL(string: "https://example.test/v1/responses")!
    let compaction: JSONValue = .object([
      "type": .string("compaction"),
      "encrypted_content": .string("opaque"),
    ])
    StubURLProtocol.handler = { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.url?.path, "/v1/responses/compact")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "x-openai-internal-codex-responses-lite"),
        "true"
      )
      let body = try JSONDecoder.codex.decode(JSONValue.self, from: request.bodyData())
      XCTAssertEqual(body["model"]?.stringValue, "gpt-5.6-sol")
      XCTAssertNil(body["tools"])
      XCTAssertNil(body["instructions"])
      XCTAssertEqual(body["reasoning"]?["context"]?.stringValue, "all_turns")
      XCTAssertEqual(body["parallel_tool_calls"]?.boolValue, false)
      XCTAssertEqual(body["input"]?.arrayValue?.first?["type"]?.stringValue, "additional_tools")
      XCTAssertEqual(
        body["input"]?.arrayValue?.dropFirst().first?["role"]?.stringValue, "developer")
      XCTAssertEqual(body["input"]?.arrayValue?.last?["type"]?.stringValue, "compaction_trigger")
      return StubURLProtocol.response(
        for: request,
        json:
          #"{"id":"cmp_123","object":"response.compaction","created_at":1,"output":[{"type":"compaction","encrypted_content":"opaque"}]}"#
      )
    }
    defer { StubURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = OpenAIResponsesClient(
      auth: StaticAuthProvider(),
      options: OpenAIResponsesClient.Options(endpoint: endpoint),
      session: URLSession(configuration: configuration)
    )
    let result = try await client.compactResponse(
      ResponsesCompactionRequest(
        model: OpenAIModel.gpt56Sol.rawValue,
        input: [
          ResponseInputBuilder.userMessage("long context"),
          ResponseInputBuilder.compactionTrigger(),
        ],
        tools: [EchoTool().definition.responseTool],
        instructions: "compact carefully",
        reasoning: ResponseReasoning(context: "current_turn"),
        parallelToolCalls: true,
        useResponsesLite: true
      ))

    XCTAssertEqual(result.id, "cmp_123")
    XCTAssertEqual(result.object, "response.compaction")
    XCTAssertEqual(result.output, [compaction])
  }

  func testOpenAIResponsesClientExtractsSnapshotModelEvents() throws {
    let snapshot = OpenAIResponseSnapshot(
      id: "resp_123",
      status: "completed",
      background: true,
      raw: .object([
        "id": .string("resp_123"),
        "status": .string("completed"),
        "output": .array([
          .object([
            "type": .string("function_call"),
            "id": .string("item_call"),
            "call_id": .string("call_1"),
            "name": .string("shell"),
            "arguments": .string(#"{"command":"pwd"}"#),
          ]),
          .object([
            "type": .string("message"),
            "content": .array([
              .object(["text": .string("done")])
            ]),
          ]),
        ]),
      ])
    )

    let events = try OpenAIResponsesClient.modelEvents(from: snapshot)
    XCTAssertTrue(
      events.contains { event in
        if case .toolCallCompleted(let call) = event {
          return call.callID == "call_1" && call.name == "shell"
        }
        return false
      })
    XCTAssertTrue(events.contains(.messageCompleted("done")))
    XCTAssertTrue(events.contains(.completed(responseID: "resp_123", usage: nil)))
  }

  func testMultiAgentSnapshotOnlyCompletesRootFinalMessage() throws {
    let subagentMessage: JSONValue = .object([
      "type": .string("message"),
      "phase": .string("commentary"),
      "agent": .object(["agent_name": .string("/root/reviewer")]),
      "content": .array([
        .object(["type": .string("output_text"), "text": .string("private draft")])
      ]),
    ])
    let rootMessage: JSONValue = .object([
      "type": .string("message"),
      "phase": .string("final_answer"),
      "agent": .object(["agent_name": .string("/root")]),
      "content": .array([
        .object(["type": .string("output_text"), "text": .string("public answer")])
      ]),
    ])
    let snapshot = OpenAIResponseSnapshot(
      id: "resp_multi",
      status: "completed",
      raw: .object([
        "id": .string("resp_multi"),
        "output": .array([subagentMessage, rootMessage]),
        "usage": .object([
          "input_tokens": .number(10),
          "output_tokens": .number(5),
          "total_tokens": .number(15),
          "input_tokens_details": .object([
            "cached_tokens": .number(3),
            "cache_write_tokens": .number(4),
          ]),
          "output_tokens_details": .object(["reasoning_tokens": .number(2)]),
        ]),
      ])
    )

    let events = try OpenAIResponsesClient.modelEvents(from: snapshot)
    XCTAssertTrue(events.contains(.responseItemCompleted(subagentMessage)))
    XCTAssertTrue(events.contains(.messageCompleted("public answer")))
    XCTAssertFalse(events.contains(.messageCompleted("private draft")))
    let completion = try XCTUnwrap(events.last)
    guard case .completed(_, let usage) = completion else {
      return XCTFail("Expected completion event")
    }
    XCTAssertEqual(usage?.cachedInputTokens, 3)
    XCTAssertEqual(usage?.cacheWriteTokens, 4)
    XCTAssertEqual(usage?.reasoningOutputTokens, 2)
  }

  func testPromptAssemblyLoadsAgentsAndExplicitSkill() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftCodexCoreTests-\(UUID().uuidString)")
    let work = root.appendingPathComponent("service")
    let skillDir = root.appendingPathComponent(".agents/skills/report-writer")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try "Run swift test before reporting.".write(
      to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try """
    ---
    name: report-writer
    description: Write concise engineering status reports and summaries.
    ---

    Always include completed work, validation, and risks.
    """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let config = AgentConfiguration(
      workspaceURL: work,
      projectInstructionOptions: ProjectInstructionOptions(
        codexHome: root.appendingPathComponent(".codex"), currentWorkingDirectory: work),
      skillOptions: SkillInjectionOptions(includeUserSkills: false, includeAdminSkills: false)
    )
    let assembly = try PromptAssembler.build(
      configuration: config, userText: "$report-writer summarize this change")
    XCTAssertTrue(assembly.instructions.contains("$report-writer"))
    XCTAssertFalse(assembly.instructions.contains(skillDir.path))
    XCTAssertFalse(assembly.instructions.contains("SKILL.md path"))
    XCTAssertEqual(assembly.projectInstructions.count, 1)
    XCTAssertEqual(assembly.activatedSkills.map(\.name), ["report-writer"])
    let prefixText = assembly.inputPrefixItems.map(\.description).joined(separator: "\n")
    XCTAssertTrue(prefixText.contains("Run swift test"))
    XCTAssertTrue(prefixText.contains("Always include completed work"))
    XCTAssertTrue(assembly.inputPrefixItems.allSatisfy { $0["metadata"] == nil })

    var leanConfig = config
    leanConfig.skillOptions.includeUsageInstructions = false
    let leanAssembly = try PromptAssembler.build(
      configuration: leanConfig,
      userText: "$report-writer summarize this change"
    )
    XCTAssertTrue(leanAssembly.instructions.contains("$report-writer"))
    XCTAssertFalse(leanAssembly.instructions.contains("Available skills are listed below"))
  }

  func testEmbeddedSkillsMaterializeAndActivateThroughNormalRegistry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftCodexCoreTests-\(UUID().uuidString)")
    let work = root.appendingPathComponent("workspace")
    let skillsRoot = root.appendingPathComponent("BundledSkills", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let embedded = EmbeddedAgentSkill(
      name: "artifact-writer",
      description: "Create document, presentation, and spreadsheet artifacts.",
      instructions: "Use the host-provided artifact runtime before inventing a renderer.",
      files: [
        EmbeddedSkillFile(
          relativePath: "scripts/render.mjs", contents: "export const runtime = 'ios';\n")
      ],
      allowImplicitInvocation: false
    )
    var config = AgentConfiguration(
      workspaceURL: work,
      skillOptions: SkillInjectionOptions(
        includeRepoSkills: false,
        includeUserSkills: false,
        includeAdminSkills: false,
        allowImplicitInvocation: true
      )
    )

    let installed = try config.installEmbeddedSkills([embedded], rootURL: skillsRoot)
    XCTAssertEqual(installed.map(\.skill.name), ["artifact-writer"])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: skillsRoot.appendingPathComponent("artifact-writer/SKILL.md").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: skillsRoot.appendingPathComponent("artifact-writer/scripts/render.mjs").path))
    XCTAssertEqual(config.skillOptions.additionalSkillRoots, [skillsRoot])

    let implicit = try PromptAssembler.build(
      configuration: config, userText: "Please create a polished artifact")
    XCTAssertTrue(implicit.availableSkills.contains { $0.name == "artifact-writer" })
    XCTAssertTrue(implicit.activatedSkills.isEmpty)

    let explicit = try PromptAssembler.build(
      configuration: config, userText: "$artifact-writer make the deck")
    XCTAssertEqual(explicit.activatedSkills.map(\.name), ["artifact-writer"])
    let prefixText = explicit.inputPrefixItems.map(\.description).joined(separator: "\n")
    XCTAssertTrue(prefixText.contains("host-provided artifact runtime"))
  }

  func testSkillDiscoveryRecursesAdditionalRoots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftCodexCoreTests-\(UUID().uuidString)")
    let work = root.appendingPathComponent("workspace")
    let skillDir = root.appendingPathComponent("skills/productivity/report-writer")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    ---
    name: report-writer
    description: Write concise engineering status reports.
    ---

    Include validation and risks.
    """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    let config = AgentConfiguration(
      workspaceURL: work,
      projectInstructionOptions: ProjectInstructionOptions(enabled: false),
      skillOptions: SkillInjectionOptions(
        includeRepoSkills: false,
        includeUserSkills: false,
        includeAdminSkills: false,
        includeSystemSkills: false,
        additionalSkillRoots: [root.appendingPathComponent("skills")]
      )
    )
    let assembly = try PromptAssembler.build(
      configuration: config, userText: "$report-writer summarize")
    XCTAssertEqual(assembly.activatedSkills.map(\.name), ["report-writer"])
  }

  func testEmbeddedSkillInstallDoesNotDeleteExistingSkillsWhenValidationFails() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftCodexCoreTests-\(UUID().uuidString)")
    let existing = root.appendingPathComponent("existing")
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    try "keep".write(
      to: existing.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let invalid = EmbeddedAgentSkill(
      name: "invalid",
      description: "Invalid skill",
      instructions: "No-op",
      directoryName: "existing/escape"
    )

    XCTAssertThrowsError(try EmbeddedSkillInstaller.install([invalid], into: root, overwrite: true))
    XCTAssertEqual(
      try String(contentsOf: existing.appendingPathComponent("SKILL.md"), encoding: .utf8), "keep")
  }

  func testEmbeddedSkillInstallerRejectsEscapingFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftCodexCoreTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let embedded = EmbeddedAgentSkill(
      name: "bad-skill",
      description: "Invalid skill",
      instructions: "No-op",
      files: [EmbeddedSkillFile(relativePath: "../escape.txt", contents: "nope")]
    )

    XCTAssertThrowsError(try EmbeddedSkillInstaller.install([embedded], into: root))
  }

  func testCodexAuthCacheRoundTripAndJWTExtraction() throws {
    let exp = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
    let accessPayload: JSONValue = .object([
      "exp": .number(Double(exp)),
      "https://api.openai.com/auth": .object([
        "chatgpt_account_id": .string("acct_123"),
        "organization_id": .string("org_123"),
      ]),
    ])
    let access = try Self.fakeJWT(payload: accessPayload)
    let cache = CodexAuthDotJson(
      authMode: "chatgpt",
      tokens: CodexTokenData(
        idToken: accessPayload, accessToken: access, refreshToken: "refresh", accountID: nil),
      lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let data = try JSONEncoder.codexPretty.encode(cache)
    let decoded = try JSONDecoder.codex.decode(CodexAuthDotJson.self, from: data)
    let session = try XCTUnwrap(decoded.asAuthSession())
    XCTAssertEqual(session.mode, .chatGPT)
    XCTAssertEqual(session.accountID, "acct_123")
    XCTAssertEqual(session.workspaceID, "org_123")
    XCTAssertEqual(session.refreshToken, "refresh")
  }

  func testCodexAuthCacheAcceptsBaseCodexShape() throws {
    let idPayload: JSONValue = .object([
      "https://api.openai.com/auth": .object([
        "chatgpt_account_id": .string("acct_base"),
        "organization_id": .string("org_base"),
      ])
    ])
    let rawIDToken = try Self.fakeJWT(payload: idPayload)
    let access = try Self.fakeJWT(
      payload: .object(["exp": .number(Date().addingTimeInterval(3600).timeIntervalSince1970)]))
    let data = """
      {
        "OPENAI_API_KEY": "sk-base",
        "tokens": {
          "id_token": "\(rawIDToken)",
          "access_token": "\(access)",
          "refresh_token": "refresh-base",
          "account_id": "acct_base"
        },
        "last_refresh": "2026-01-01T00:00:00Z"
      }
      """.data(using: .utf8)!

    let decoded = try JSONDecoder.codex.decode(CodexAuthDotJson.self, from: data)
    let session = try XCTUnwrap(decoded.asAuthSession())
    XCTAssertEqual(decoded.openaiAPIKey, "sk-base")
    XCTAssertEqual(session.accountID, "acct_base")
    XCTAssertEqual(session.workspaceID, "org_base")
    XCTAssertEqual(session.metadata["raw_id_token"]?.stringValue, rawIDToken)
  }

  func testCodexAuthCacheWritesBaseCodexTokenShape() throws {
    let idPayload: JSONValue = .object([
      "https://api.openai.com/auth": .object([
        "chatgpt_account_id": .string("acct_123")
      ])
    ])
    let rawIDToken = try Self.fakeJWT(payload: idPayload)
    let auth = CodexAuthDotJson(
      authMode: "chatgpt",
      openaiAPIKey: "sk-token-exchange",
      tokens: CodexTokenData(
        idToken: idPayload,
        accessToken: "access",
        refreshToken: "refresh",
        accountID: "acct_123",
        rawIDToken: rawIDToken
      ),
      lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let json = try JSONDecoder.codex.decode(
      JSONValue.self, from: JSONEncoder.codexPretty.encode(auth))
    XCTAssertEqual(json["OPENAI_API_KEY"]?.stringValue, "sk-token-exchange")
    XCTAssertEqual(json["tokens"]?["id_token"]?.stringValue, rawIDToken)
    XCTAssertNil(json["tokens"]?["raw_id_token"])
  }

  func testDeviceCodeLoginRejectsInvalidTimeoutsBeforePolling() async {
    let client = CodexChatGPTAuthClient()
    let code = CodexDeviceCode(
      verificationURL: URL(string: "https://example.test/device")!,
      userCode: "TEST",
      deviceAuthID: "device",
      interval: .max
    )

    for timeout in [Double.nan, .infinity, -.infinity, -1] {
      do {
        _ = try await client.completeDeviceCodeLogin(code, timeout: timeout)
        XCTFail("Expected timeout \(timeout) to be rejected")
      } catch CodexCoreError.invalidInput {
        // Expected before any network request or polling sleep.
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testSHA256KnownVector() {
    let digest = SHA256.hash(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  func testCodeModeOnlyExecutesNestedToolsAndUsesCustomOutput() async throws {
    let provider = RecordingModelProvider(
      batches: [
        [
          .toolCallCompleted(
            ToolCall(
              id: "ctc_exec",
              callID: "call_exec",
              name: "exec",
              arguments: #"const result = await tools.echo({text: "nested pong"}); text(result);"#,
              kind: .custom
            )),
          .completed(responseID: "r1", usage: nil),
        ],
        [.outputTextDelta("done"), .completed(responseID: "r2", usage: nil)],
      ],
      supportsResponseContinuation: false
    )
    let configuration = AgentConfiguration(toolMode: .codeModeOnly)
    let agent = CodexAgent(
      configuration: configuration,
      modelProvider: provider,
      toolRegistry: ToolRegistry(tools: [EchoTool()]),
      threadManager: ThreadManager(store: InMemoryThreadStore())
    )
    let thread = try await agent.createThread()
    for try await _ in agent.startTurn(
      threadID: thread.id, input: TurnInput("ping through code mode")
    ).events {}

    XCTAssertEqual(provider.requests.count, 2)
    XCTAssertEqual(provider.requests[0].tools.map(\.type), ["custom", "function"])
    XCTAssertEqual(provider.requests[0].tools.compactMap(\.name), ["exec", "wait"])
    XCTAssertFalse(provider.requests[0].tools.contains { $0.name == "echo" })
    let customOutput = try XCTUnwrap(
      provider.requests[1].input.first { $0["type"]?.stringValue == "custom_tool_call_output" })
    XCTAssertEqual(customOutput["call_id"]?.stringValue, "call_exec")
    XCTAssertEqual(customOutput["output"]?.stringValue, "nested pong")
  }

  func testCodeModeExposureKeepsDirectModelOnlyToolVisible() async throws {
    let provider = RecordingModelProvider(batches: [[.completed(responseID: "r1", usage: nil)]])
    let agent = CodexAgent(
      configuration: AgentConfiguration(toolMode: .codeModeOnly),
      modelProvider: provider,
      toolRegistry: ToolRegistry(tools: [DirectModelOnlyTool(), EchoTool()]),
      threadManager: ThreadManager(store: InMemoryThreadStore())
    )
    let thread = try await agent.createThread()
    for try await _ in agent.startTurn(threadID: thread.id, input: TurnInput("inspect tools"))
      .events
    {}

    XCTAssertEqual(
      Set(provider.requests[0].tools.compactMap(\.name)), Set(["exec", "wait", "direct_only"]))
  }

  func testResponsesLiteStripsImageDetailAndForwardsCustomReasoningEffort() async throws {
    let provider = RecordingModelProvider(batches: [[.completed(responseID: "r1", usage: nil)]])
    let agent = CodexAgent(
      configuration: AgentConfiguration(
        reasoningEffortName: "future_effort",
        reasoningContext: .currentTurn,
        useResponsesLite: true,
        serverTools: [.webSearch()]
      ),
      modelProvider: provider,
      toolRegistry: ToolRegistry(tools: [EchoTool()]),
      threadManager: ThreadManager(store: InMemoryThreadStore())
    )
    let thread = try await agent.createThread()
    let input = TurnInput(content: [
      ResponseInputBuilder.inputText("inspect"),
      ResponseInputBuilder.inputImage(
        urlString: "data:image/png;base64,AAAA",
        detail: .original
      ),
      ResponseInputBuilder.inputImage(
        urlString: "https://example.com/private.png",
        detail: .high
      ),
    ])
    for try await _ in agent.startTurn(threadID: thread.id, input: input).events {}

    let request = try XCTUnwrap(provider.requests.first)
    XCTAssertEqual(request.reasoning?.effort, "future_effort")
    XCTAssertEqual(request.reasoning?.context, "all_turns")
    XCTAssertTrue(request.useResponsesLite)
    XCTAssertNil(request.instructions)
    XCTAssertEqual(request.parallelToolCalls, false)
    XCTAssertEqual(request.tools.compactMap(\.name), ["echo"])
    XCTAssertEqual(request.input.first?["type"]?.stringValue, "additional_tools")
    XCTAssertEqual(request.input.first?["tools"]?.arrayValue?.first?["name"]?.stringValue, "echo")
    XCTAssertEqual(request.input.dropFirst().first?["type"]?.stringValue, "message")
    let image = request.input
      .compactMap { $0["content"]?.arrayValue }
      .flatMap { $0 }
      .first { $0["type"]?.stringValue == "input_image" }
    XCTAssertNotNil(image)
    XCTAssertNil(image?["detail"])
    XCTAssertTrue(request.input.description.contains("remote image URLs are not supported"))
    XCTAssertFalse(request.input.description.contains("https://example.com/private.png"))

    let encoded = try JSONDecoder.codex.decode(
      JSONValue.self,
      from: JSONEncoder.codexCompact.encode(request)
    )
    XCTAssertNil(encoded["tools"])
    XCTAssertNil(encoded["instructions"])
  }

  func testResponsesSnapshotParsesCustomToolCall() throws {
    let raw: JSONValue = .object([
      "id": .string("resp_custom"),
      "output": .array([
        .object([
          "type": .string("custom_tool_call"),
          "id": .string("ctc_1"),
          "call_id": .string("call_1"),
          "name": .string("exec"),
          "input": .string("text('ok')"),
        ])
      ]),
    ])
    let snapshot = OpenAIResponseSnapshot(raw: raw)
    let events = try OpenAIResponsesClient.modelEvents(from: snapshot)
    let call = try XCTUnwrap(
      events.compactMap { event -> ToolCall? in
        if case .toolCallCompleted(let call) = event { return call }
        return nil
      }.first)
    XCTAssertEqual(call.kind, .custom)
    XCTAssertEqual(call.arguments, "text('ok')")
  }

  func testCodeModeWaitAndThreadScopedStore() async throws {
    let runtime = CodeModeRuntime(registry: ToolRegistry(tools: [EchoTool()]))
    let context = ToolExecutionContext(
      threadID: "thread-code-mode",
      turnID: "turn-1",
      approvalPolicy: .never,
      sandboxPolicy: .workspaceWrite
    )
    let definitions = [EchoTool().definition]
    let first = await runtime.execute(
      source: "store('answer', 42); text('stored');",
      definitions: definitions,
      context: context
    )
    XCTAssertEqual(first.content, "stored")
    let second = await runtime.execute(
      source: "text(load('answer'));",
      definitions: definitions,
      context: context
    )
    XCTAssertEqual(second.content, "42")

    let yielded = await runtime.execute(
      source: """
        // @exec: {"yield_time_ms":250}
        await new Promise(resolve => setTimeout(() => { text('later'); resolve(); }, 400));
        """,
      definitions: definitions,
      context: context
    )
    XCTAssertEqual(yielded.metadata["running"]?.boolValue, true)
    let cellID = try XCTUnwrap(yielded.metadata["cell_id"]?.stringValue)
    let completed = await runtime.wait(
      arguments: .object([
        "cell_id": .string(cellID),
        "yield_time_ms": .number(1_000),
        "max_tokens": .number(1),
      ]))
    XCTAssertEqual(completed.content, "late\n[output truncated]")
  }

  private static func fakeJWT(payload: JSONValue) throws -> String {
    let header = try JSONEncoder.codexCompact.encode(JSONValue.object(["alg": .string("none")]))
    let payloadData = try JSONEncoder.codexCompact.encode(payload)
    return [Base64URL.encode(header), Base64URL.encode(payloadData), "sig"].joined(separator: ".")
  }

}

private final class RecordingModelProvider: ModelProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var batches: [[ModelStreamEvent]]
  private var storage: [ResponsesRequest] = []
  let supportsResponseContinuation: Bool

  init(batches: [[ModelStreamEvent]], supportsResponseContinuation: Bool = true) {
    self.batches = batches
    self.supportsResponseContinuation = supportsResponseContinuation
  }

  var requests: [ResponsesRequest] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    lock.lock()
    storage.append(request)
    let events = batches.isEmpty ? [.completed(responseID: nil, usage: nil)] : batches.removeFirst()
    lock.unlock()
    return AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }
}

private final class DelayedModelProvider: ModelProvider, @unchecked Sendable {
  let delayNanoseconds: UInt64

  init(delayNanoseconds: UInt64) {
    self.delayNanoseconds = delayNanoseconds
  }

  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        continuation.yield(.outputTextDelta("done"))
        continuation.yield(.completed(responseID: "delayed", usage: nil))
        continuation.finish()
      }
    }
  }
}

private struct ApprovalEchoTool: AgentTool {
  let definition = ToolDefinition(
    name: "approval_echo",
    description: "Echo text after approval.",
    parameters: ToolSchemas.object(
      properties: [
        "text": ToolSchemas.string(description: "Text to echo")
      ], required: ["text"]),
    requiresApproval: true,
    isStateChanging: true
  )

  func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    ToolResult(content: try arguments.requiredString("text"))
  }
}

private struct DirectModelOnlyTool: AgentTool {
  let definition = ToolDefinition(
    name: "direct_only",
    description: "Must be called directly by the model.",
    parameters: ToolSchemas.object(properties: [:]),
    exposure: .directModelOnly
  )

  func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    ToolResult(content: "direct")
  }
}

private struct StaticAuthProvider: AuthorizationProvider {
  func authorizationHeaders() async throws -> [String: String] {
    ["Authorization": "Bearer test-token"]
  }
}

private struct CapturedHTTPRequest: Sendable, Equatable {
  var method: String
  var path: String
  var authorization: String?

  init(_ request: URLRequest) {
    method = request.httpMethod ?? ""
    path = request.url?.path ?? ""
    authorization = request.value(forHTTPHeaderField: "Authorization")
  }
}

private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    storage = value
  }

  var value: Value {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func withValue(_ body: (inout Value) -> Void) {
    lock.lock()
    body(&storage)
    lock.unlock()
  }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(
        self, didFailWithError: CodexCoreError.transportError("No stub handler registered"))
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
    headers: [String: String] = [:],
    json: String
  ) -> (HTTPURLResponse, Data) {
    response(
      for: request, statusCode: statusCode, headers: headers, contentType: "application/json",
      body: json)
  }

  static func response(
    for request: URLRequest,
    statusCode: Int = 200,
    headers: [String: String] = [:],
    contentType: String,
    body: String
  ) -> (HTTPURLResponse, Data) {
    var headers = headers
    headers["Content-Type"] = contentType
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: headers
    )!
    return (response, Data(body.utf8))
  }
}

extension URLRequest {
  fileprivate func bodyData() throws -> Data {
    if let httpBody {
      return httpBody
    }
    guard let stream = httpBodyStream else {
      return Data()
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      if read < 0 {
        throw stream.streamError
          ?? CodexCoreError.transportError("Could not read request body stream")
      }
      if read == 0 {
        break
      }
      data.append(buffer, count: read)
    }
    return data
  }
}
