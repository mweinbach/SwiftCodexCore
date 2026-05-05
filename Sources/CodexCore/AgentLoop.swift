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
            payload: .object(["role": .string("user"), "content": .string(initialInput.text), "metadata": .object(initialInput.metadata)])
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
                        payload: .object(["role": .string("user"), "content": .string(steering.text), "metadata": .object(steering.metadata), "steering": .bool(true)])
                    )
                    try await threadManager.appendItem(steeringItem, to: threadID)
                    continuation.yield(.itemCompleted(steeringItem))
                }
                accumulatedUserText += "\n" + steeringInputs.map(\.text).joined(separator: "\n")
                promptAssembly = try PromptAssembler.build(configuration: configuration, userText: accumulatedUserText, threadID: threadID, turnID: turnID)
                if nextInputUsesPreviousResponse {
                    responseInputs.append(contentsOf: steeringInputs.map { ResponseInputBuilder.userMessage($0.text) })
                } else {
                    responseInputs = try await buildInputItems(threadID: threadID, prefixItems: promptAssembly.inputPrefixItems)
                }
            }

            let localToolDefinitions = await toolRegistry.listDefinitions().map(\.responseTool)
            let toolDefinitions = toolsAllowedBySandbox(localToolDefinitions + configuration.serverTools)
            let useResponseContinuation = nextInputUsesPreviousResponse && modelProvider.supportsResponseContinuation
            let request = ResponsesRequest(
                model: configuration.model,
                instructions: promptAssembly.instructions,
                input: responseInputs,
                tools: toolDefinitions,
                stream: true,
                reasoning: ResponseReasoning(effort: configuration.reasoningEffort, summary: configuration.reasoningSummary),
                store: false,
                previousResponseID: useResponseContinuation ? lastResponseID : nil,
                metadata: ["thread_id": .string(threadID), "turn_id": .string(turnID), "iteration": .number(Double(iteration))],
                parallelToolCalls: true
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
                case .messageCompleted(let text):
                    completedMessage = text
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
                        threadID: threadID,
                        turnID: turnID,
                        kind: call.name.hasPrefix("mcp__") ? .mcpToolCall : .toolCall,
                        summary: call.name,
                        payload: .object([
                            "call_id": .string(call.callID),
                            "name": .string(call.name),
                            "arguments": .string(call.arguments),
                            "raw_arguments": call.rawArguments ?? .null
                        ])
                    )
                    try await threadManager.appendItem(callItem, to: threadID)
                    continuation.yield(.toolStarted(call: call))
                    continuation.yield(.itemCompleted(callItem))

                    let arguments = try decodeArguments(call)
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
                    do {
                        result = try await toolRegistry.run(name: call.name, arguments: arguments, context: context)
                    } catch {
                        result = ToolResult(content: String(describing: error), isError: true)
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
                            "metadata": .object(result.metadata)
                        ])
                    )
                    try await threadManager.appendItem(resultItem, to: threadID)
                    continuation.yield(.toolCompleted(call: call, result: result))
                    continuation.yield(.itemCompleted(resultItem))
                    toolOutputs.append(ResponseInputBuilder.functionCallOutput(callID: call.callID, output: result.content))
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
        for item in thread.items {
            switch item.kind {
            case .userMessage:
                if let content = item.payload["content"]?.stringValue { input.append(ResponseInputBuilder.userMessage(content)) }
            case .developerMessage:
                if let content = item.payload["content"]?.stringValue { input.append(ResponseInputBuilder.developerMessage(content)) }
            case .assistantMessage:
                if let content = item.payload["content"]?.stringValue, !content.isEmpty { input.append(ResponseInputBuilder.assistantMessage(content)) }
            case .toolCall, .mcpToolCall, .dynamicToolCall, .subagentToolCall:
                if let callID = item.payload["call_id"]?.stringValue,
                   let name = item.payload["name"]?.stringValue,
                   let arguments = item.payload["arguments"]?.stringValue {
                    input.append(ResponseInputBuilder.functionCall(ToolCall(id: item.id, callID: callID, name: name, arguments: arguments, rawArguments: item.payload["raw_arguments"])))
                }
            case .toolResult:
                if let callID = item.payload["call_id"]?.stringValue,
                   let content = item.payload["content"]?.stringValue {
                    input.append(ResponseInputBuilder.functionCallOutput(callID: callID, output: content))
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

    private func decodeArguments(_ call: ToolCall) throws -> JSONValue {
        if let raw = call.rawArguments { return raw }
        guard let data = call.arguments.data(using: .utf8) else { throw CodexCoreError.invalidJSON("Tool arguments are not UTF-8") }
        return try JSONDecoder.codex.decode(JSONValue.self, from: data)
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
