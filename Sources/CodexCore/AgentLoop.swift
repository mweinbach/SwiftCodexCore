import Foundation

public actor TurnControl {
    private var steering: [TurnInput] = []
    private var interrupted = false

    public init() {}

    public func steer(_ input: TurnInput) {
        steering.append(input)
    }

    public func interrupt() {
        interrupted = true
    }

    public func drainSteering() -> [TurnInput] {
        let values = steering
        steering.removeAll()
        return values
    }

    public func isInterrupted() -> Bool { interrupted }
}

public final class TurnHandle: Sendable {
    public let threadID: String
    public let turnID: String
    public let events: AsyncThrowingStream<AgentEvent, Error>
    let control: TurnControl

    public init(threadID: String, turnID: String, events: AsyncThrowingStream<AgentEvent, Error>, control: TurnControl) {
        self.threadID = threadID
        self.turnID = turnID
        self.events = events
        self.control = control
    }

    public func steer(_ text: String, metadata: [String: JSONValue] = [:]) async {
        await control.steer(TurnInput(text, metadata: metadata))
    }

    public func steer(_ input: TurnInput) async {
        await control.steer(input)
    }

    public func interrupt() async {
        await control.interrupt()
    }
}

public final class CodexAgent: Sendable {
    private let configuration: AgentConfiguration
    private let modelProvider: any ModelProvider
    private let toolRegistry: ToolRegistry
    private let threadManager: ThreadManager
    private let approvalHandler: ApprovalHandler?
    private let codeModeRuntime: CodeModeRuntime

    public init(
        configuration: AgentConfiguration = AgentConfiguration(),
        modelProvider: any ModelProvider,
        toolRegistry: ToolRegistry = ToolRegistry(),
        threadManager: ThreadManager = ThreadManager(),
        approvalHandler: ApprovalHandler? = nil
    ) {
        self.configuration = configuration
        self.modelProvider = modelProvider
        self.toolRegistry = toolRegistry
        self.threadManager = threadManager
        self.approvalHandler = approvalHandler
        self.codeModeRuntime = CodeModeRuntime(registry: toolRegistry)
    }

    public func createThread(title: String? = nil, metadata: [String: JSONValue] = [:]) async throws -> AgentThread {
        try await threadManager.createThread(title: title, metadata: metadata)
    }

    public func getThread(id: String) async throws -> AgentThread {
        try await threadManager.getThread(id: id)
    }

    public func forkThread(id: String, title: String? = nil) async throws -> AgentThread {
        try await threadManager.forkThread(id: id, title: title)
    }

    public func startTurn(threadID: String, input: TurnInput) -> TurnHandle {
        let turnID = UUID().uuidString
        let control = TurnControl()
        let stream = AsyncThrowingStream<AgentEvent, Error> { continuation in
            let task = Task {
                do {
                    try await runTurn(threadID: threadID, turnID: turnID, initialInput: input, control: control, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.yield(.error(String(describing: error)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
        return TurnHandle(threadID: threadID, turnID: turnID, events: stream, control: control)
    }

    private func runTurn(
        threadID: String,
        turnID: String,
        initialInput: TurnInput,
        control: TurnControl,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        continuation.yield(.turnStarted(threadID: threadID, turnID: turnID))

        let userItem = ThreadItem(
            threadID: threadID,
            turnID: turnID,
            kind: .userMessage,
            summary: initialInput.text,
            payload: userMessagePayload(initialInput)
        )
        try await threadManager.appendItem(userItem, to: threadID)
        continuation.yield(.itemCompleted(userItem))

        var promptAssembly = try PromptAssembler.build(configuration: configuration, userText: initialInput.text, threadID: threadID, turnID: turnID)
        var responseInputs = try await buildInputItems(threadID: threadID, prefixItems: promptAssembly.inputPrefixItems)
        var accumulatedUserText = initialInput.text
        var lastResponseID: String?
        var finalUsage: TokenUsage?
        var status: TurnStatus = .completed
        var nextInputUsesPreviousResponse = false
        let promptCacheKey = try await effectivePromptCacheKey(threadID: threadID)

        for iteration in 0..<configuration.maxToolIterations {
            if await control.isInterrupted() {
                status = .interrupted
                break
            }

            let steeringInputs = await control.drainSteering()
            if !steeringInputs.isEmpty {
                for steering in steeringInputs {
                    let steeringItem = ThreadItem(
                        threadID: threadID,
                        turnID: turnID,
                        kind: .userMessage,
                        summary: steering.text,
                        payload: userMessagePayload(steering, steering: true)
                    )
                    try await threadManager.appendItem(steeringItem, to: threadID)
                    continuation.yield(.itemCompleted(steeringItem))
                }
                accumulatedUserText += "\n" + steeringInputs.map(\.text).joined(separator: "\n")
                promptAssembly = try PromptAssembler.build(configuration: configuration, userText: accumulatedUserText, threadID: threadID, turnID: turnID)
                if nextInputUsesPreviousResponse {
                    responseInputs.append(contentsOf: steeringInputs.map(responseInput))
                } else {
                    responseInputs = try await buildInputItems(threadID: threadID, prefixItems: promptAssembly.inputPrefixItems)
                }
            }

            let registeredToolDefinitions = await toolRegistry.listDefinitions()
            let directLocalTools: [ResponseToolDefinition]
            switch configuration.toolMode ?? .direct {
            case .direct:
                directLocalTools = registeredToolDefinitions
                    .filter { ($0.exposure ?? .direct) == .direct || $0.exposure == .directModelOnly }
                    .map(\.responseTool)
            case .codeMode:
                directLocalTools = registeredToolDefinitions
                    .filter { ($0.exposure ?? .direct) == .direct || $0.exposure == .directModelOnly }
                    .map(\.responseTool) + CodeModeRuntime.responseTools(definitions: registeredToolDefinitions)
            case .codeModeOnly:
                directLocalTools = registeredToolDefinitions
                    .filter { $0.exposure == .directModelOnly }
                    .map(\.responseTool) + CodeModeRuntime.responseTools(definitions: registeredToolDefinitions)
            }
            let toolDefinitions = toolsAllowedBySandbox(directLocalTools + configuration.serverTools)
            let useResponseContinuation = nextInputUsesPreviousResponse && modelProvider.supportsResponseContinuation
            let reasoningSummary = configuration.multiAgent?.enabled == true ? nil : configuration.reasoningSummary
            let request = ResponsesRequest(
                model: configuration.model,
                instructions: promptAssembly.instructions,
                input: responseInputs,
                tools: toolDefinitions,
                stream: true,
                reasoning: ResponseReasoning(
                    effort: configuration.reasoningEffort,
                    summary: reasoningSummary,
                    mode: configuration.reasoningMode,
                    context: configuration.reasoningContext
                ),
                store: false,
                previousResponseID: useResponseContinuation ? lastResponseID : nil,
                metadata: ["thread_id": .string(threadID), "turn_id": .string(turnID), "iteration": .number(Double(iteration))],
                parallelToolCalls: configuration.parallelToolCalls,
                include: configuration.responseIncludes,
                serviceTier: configuration.serviceTier,
                promptCacheKey: promptCacheKey,
                promptCacheOptions: configuration.promptCacheOptions,
                safetyIdentifier: configuration.safetyIdentifier,
                maxOutputTokens: configuration.maxOutputTokens,
                toolChoice: configuration.toolChoice,
                text: configuration.textOptions,
                multiAgent: configuration.multiAgent,
                contextManagement: configuration.contextManagement
            )
            nextInputUsesPreviousResponse = false

            var assistantBuffer = ""
            var completedMessage: String?
            var toolCalls: [ToolCall] = []
            let assistantItemID = UUID().uuidString
            var didStartAssistantItem = false

            for try await event in modelProvider.streamResponse(request) {
                if await control.isInterrupted() {
                    status = .interrupted
                    break
                }
                switch event {
                case .outputTextDelta(let delta):
                    assistantBuffer += delta
                    if !didStartAssistantItem {
                        let item = ThreadItem(id: assistantItemID, threadID: threadID, turnID: turnID, kind: .assistantMessage, summary: "Assistant response", payload: .object([:]))
                        continuation.yield(.itemStarted(item))
                        didStartAssistantItem = true
                    }
                    continuation.yield(.itemDelta(itemID: assistantItemID, delta: delta))
                case .reasoningDelta(let delta):
                    if configuration.includeReasoningDeltas { continuation.yield(.reasoningDelta(delta)) }
                case .toolCallDelta(let callID, let name, let argumentsDelta):
                    let item = ThreadItem(threadID: threadID, turnID: turnID, kind: .rawModelEvent, summary: "tool args delta", payload: .object([
                        "call_id": .string(callID),
                        "name": name.map(JSONValue.string) ?? .null,
                        "arguments_delta": .string(argumentsDelta)
                    ]))
                    continuation.yield(.itemDelta(itemID: item.id, delta: argumentsDelta))
                case .toolCallCompleted(let call):
                    toolCalls.append(call)
                case .serverToolCompleted(let name, let item):
                    let kind: ThreadItemKind = name == "image_generation" ? .imageGeneration : (name == "web_search" ? .webSearch : .dynamicToolCall)
                    let serverItem = ThreadItem(
                        threadID: threadID,
                        turnID: turnID,
                        kind: kind,
                        summary: name,
                        payload: .object(["name": .string(name), "item": item])
                    )
                    try await threadManager.appendItem(serverItem, to: threadID)
                    continuation.yield(.itemCompleted(serverItem))
                case .responseItemCompleted(let responseItem):
                    let itemType = responseItem["type"]?.stringValue ?? "response_item"
                    let responseItemRecord = ThreadItem(
                        threadID: threadID,
                        turnID: turnID,
                        kind: itemType == "reasoning" ? .reasoning : (itemType == "compaction" ? .contextCompaction : .dynamicToolCall),
                        summary: itemType,
                        payload: .object(["item": responseItem])
                    )
                    try await threadManager.appendItem(responseItemRecord, to: threadID)
                    continuation.yield(.itemCompleted(responseItemRecord))
                case .messageCompleted(let text):
                    completedMessage = text
                case .modelCatalogETag(let etag):
                    continuation.yield(.modelCatalogChanged(etag: etag))
                case .completed(let responseID, let usage):
                    lastResponseID = responseID
                    finalUsage = usage
                case .failed(let message):
                    throw CodexCoreError.modelError(message)
                case .raw:
                    continue
                }
            }

            if status == .interrupted { break }

            if !toolCalls.isEmpty {
                if didStartAssistantItem || !assistantBuffer.isEmpty || completedMessage != nil {
                    let text = completedMessage ?? assistantBuffer
                    let item = ThreadItem(
                        id: assistantItemID,
                        threadID: threadID,
                        turnID: turnID,
                        kind: .assistantMessage,
                        summary: text,
                        payload: .object(["role": .string("assistant"), "content": .string(text), "response_id": JSONValue.stringOrNull(lastResponseID)])
                    )
                    try await threadManager.appendItem(item, to: threadID)
                    continuation.yield(.itemCompleted(item))
                }
                var toolOutputs: [JSONValue] = []
                for call in toolCalls {
                    let callItem = ThreadItem(
                        id: call.id,
                        threadID: threadID,
                        turnID: turnID,
                        kind: call.name.hasPrefix("mcp__") ? .mcpToolCall : .toolCall,
                        summary: call.name,
                        payload: .object([
                            "call_id": .string(call.callID),
                            "name": .string(call.name),
                            "arguments": .string(call.arguments),
                            "raw_arguments": call.rawArguments ?? .null,
                            "caller": call.caller ?? .null,
                            "tool_call_kind": .string((call.kind ?? .function).rawValue)
                        ])
                    )
                    try await threadManager.appendItem(callItem, to: threadID)
                    continuation.yield(.toolStarted(call: call))
                    continuation.yield(.itemCompleted(callItem))

                    let context = ToolExecutionContext(
                        threadID: threadID,
                        turnID: turnID,
                        workspaceURL: configuration.workspaceURL,
                        approvalPolicy: configuration.approvalPolicy,
                        sandboxPolicy: configuration.sandboxPolicy,
                        approvalHandler: approvalHandler,
                        approvalEventHandler: { request in
                            continuation.yield(.approvalRequested(request))
                        },
                        metadata: ["tool_call_id": .string(call.callID)]
                    )
                    let result: ToolResult
                    if call.kind == .custom && call.name == CodeModeRuntime.execToolName {
                        result = await codeModeRuntime.execute(
                            source: call.arguments,
                            definitions: registeredToolDefinitions,
                            context: context
                        )
                    } else {
                        do {
                            let arguments = try decodeArguments(call)
                            if call.name == CodeModeRuntime.waitToolName,
                               (configuration.toolMode ?? .direct) != .direct {
                                result = await codeModeRuntime.wait(arguments: arguments)
                            } else {
                                result = try await toolRegistry.run(name: call.name, arguments: arguments, context: context)
                            }
                        } catch {
                            result = ToolResult(content: String(describing: error), isError: true)
                        }
                    }
                    let resultItem = ThreadItem(
                        threadID: threadID,
                        turnID: turnID,
                        kind: .toolResult,
                        summary: result.summary,
                        payload: .object([
                            "call_id": .string(call.callID),
                            "name": .string(call.name),
                            "content": .string(result.content),
                            "structured_content": result.structuredContent ?? .null,
                            "is_error": .bool(result.isError),
                            "metadata": .object(result.metadata),
                            "caller": call.caller ?? .null,
                            "tool_call_kind": .string((call.kind ?? .function).rawValue)
                        ])
                    )
                    try await threadManager.appendItem(resultItem, to: threadID)
                    continuation.yield(.toolCompleted(call: call, result: result))
                    continuation.yield(.itemCompleted(resultItem))
                    if call.kind == .custom {
                        toolOutputs.append(ResponseInputBuilder.customToolCallOutput(callID: call.callID, output: result.content))
                    } else {
                        toolOutputs.append(ResponseInputBuilder.functionCallOutput(callID: call.callID, output: result.content, caller: call.caller))
                    }
                }
                if lastResponseID != nil && modelProvider.supportsResponseContinuation {
                    responseInputs = toolOutputs
                    nextInputUsesPreviousResponse = true
                } else {
                    responseInputs = try await buildInputItems(threadID: threadID, prefixItems: promptAssembly.inputPrefixItems)
                }
                continue
            }

            let finalText = completedMessage ?? assistantBuffer
            if !finalText.isEmpty {
                let item = ThreadItem(
                    id: assistantItemID,
                    threadID: threadID,
                    turnID: turnID,
                    kind: .assistantMessage,
                    summary: finalText,
                    payload: .object(["role": .string("assistant"), "content": .string(finalText), "response_id": JSONValue.stringOrNull(lastResponseID)])
                )
                try await threadManager.appendItem(item, to: threadID)
                continuation.yield(.itemCompleted(item))
            }
            status = .completed
            break
        }

        if status == .running { status = .completed }
        continuation.yield(.turnCompleted(threadID: threadID, turnID: turnID, status: status, usage: finalUsage))
    }

    private func toolsAllowedBySandbox(_ tools: [ResponseToolDefinition]) -> [ResponseToolDefinition] {
        guard !configuration.sandboxPolicy.allowNetwork else { return tools }
        return tools.filter { !$0.requiresNetworkAccess }
    }

    private func buildInputItems(threadID: String, prefixItems: [JSONValue] = []) async throws -> [JSONValue] {
        let thread = try await threadManager.getThread(id: threadID)
        var input: [JSONValue] = prefixItems
        let replayStart = thread.items.lastIndex(where: { $0.kind == .contextCompaction }) ?? thread.items.startIndex
        for item in thread.items[replayStart...] {
            switch item.kind {
            case .userMessage:
                if let blocks = item.payload["response_content"]?.arrayValue {
                    input.append(ResponseInputBuilder.userMessage(content: blocks))
                } else if let content = item.payload["content"]?.stringValue {
                    input.append(ResponseInputBuilder.userMessage(content))
                }
            case .developerMessage:
                if let content = item.payload["content"]?.stringValue { input.append(ResponseInputBuilder.developerMessage(content)) }
            case .assistantMessage:
                if let content = item.payload["content"]?.stringValue, !content.isEmpty { input.append(ResponseInputBuilder.assistantMessage(content)) }
            case .toolCall, .mcpToolCall, .subagentToolCall:
                if let callID = item.payload["call_id"]?.stringValue,
                   let name = item.payload["name"]?.stringValue,
                   let arguments = item.payload["arguments"]?.stringValue {
                    input.append(ResponseInputBuilder.functionCall(ToolCall(
                        id: item.id,
                        callID: callID,
                        name: name,
                        arguments: arguments,
                        rawArguments: item.payload["raw_arguments"],
                        caller: nonNull(item.payload["caller"]),
                        kind: ToolCallKind(rawValue: item.payload["tool_call_kind"]?.stringValue ?? "function") ?? .function
                    )))
                }
            case .dynamicToolCall, .reasoning, .contextCompaction:
                if let responseItem = item.payload["item"],
                   let replayableItem = ResponseInputBuilder.replayableServerToolOutput(responseItem) {
                    input.append(replayableItem)
                } else if let callID = item.payload["call_id"]?.stringValue,
                          let name = item.payload["name"]?.stringValue,
                          let arguments = item.payload["arguments"]?.stringValue {
                    input.append(ResponseInputBuilder.functionCall(ToolCall(
                        id: item.id,
                        callID: callID,
                        name: name,
                        arguments: arguments,
                        rawArguments: item.payload["raw_arguments"],
                        caller: nonNull(item.payload["caller"]),
                        kind: ToolCallKind(rawValue: item.payload["tool_call_kind"]?.stringValue ?? "function") ?? .function
                    )))
                }
            case .toolResult:
                if let callID = item.payload["call_id"]?.stringValue,
                   let content = item.payload["content"]?.stringValue {
                    let kind = ToolCallKind(rawValue: item.payload["tool_call_kind"]?.stringValue ?? "function") ?? .function
                    if kind == .custom {
                        input.append(ResponseInputBuilder.customToolCallOutput(callID: callID, output: content))
                    } else {
                        input.append(ResponseInputBuilder.functionCallOutput(callID: callID, output: content, caller: nonNull(item.payload["caller"])))
                    }
                }
            case .webSearch, .imageGeneration:
                if let item = item.payload["item"],
                   let replayableItem = ResponseInputBuilder.replayableServerToolOutput(item) {
                    input.append(replayableItem)
                }
            default:
                continue
            }
        }
        return input
    }

    private func responseInput(_ input: TurnInput) -> JSONValue {
        ResponseInputBuilder.userMessage(content: input.content ?? [ResponseInputBuilder.inputText(input.text)])
    }

    private func userMessagePayload(_ input: TurnInput, steering: Bool = false) -> JSONValue {
        var fields: [String: JSONValue] = [
            "role": .string("user"),
            "content": .string(input.text),
            "metadata": .object(input.metadata)
        ]
        if let content = input.content {
            fields["response_content"] = .array(content)
        }
        if steering {
            fields["steering"] = .bool(true)
        }
        return .object(fields)
    }

    private func effectivePromptCacheKey(threadID: String) async throws -> String {
        if let configured = configuration.promptCacheKey, !configured.isEmpty {
            return configured
        }
        var thread = try await threadManager.getThread(id: threadID)
        var visited = Set([thread.id])
        while let parentID = thread.parentThreadID {
            guard visited.insert(parentID).inserted else {
                throw CodexCoreError.invalidState("Thread ancestry contains a cycle at \(parentID)")
            }
            thread = try await threadManager.getThread(id: parentID)
        }
        return thread.id
    }

    private func decodeArguments(_ call: ToolCall) throws -> JSONValue {
        if let raw = call.rawArguments { return raw }
        guard let data = call.arguments.data(using: .utf8) else { throw CodexCoreError.invalidJSON("Tool arguments are not UTF-8") }
        return try JSONDecoder.codex.decode(JSONValue.self, from: data)
    }

    private func nonNull(_ value: JSONValue?) -> JSONValue? {
        value == .null ? nil : value
    }
}

public final class CollectingEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentEvent] = []

    public init() {}

    public func append(_ event: AgentEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    public var events: [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
