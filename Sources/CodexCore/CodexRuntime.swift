import Foundation

/// High-level facade for apps that want Codex-like thread/turn semantics without building their own app-server layer.
public actor CodexRuntime {
  public let threadManager: ThreadManager
  public let toolRegistry: ToolRegistry
  public let mcpRegistry: MCPRegistry

  private var configuration: AgentConfiguration
  private let modelProvider: any ModelProvider
  private let approvalHandler: ApprovalHandler?
  private let codeModeRuntime: CodeModeRuntime
  private var activeTurnsByThreadID: [String: TurnHandle] = [:]

  public init(
    configuration: AgentConfiguration = AgentConfiguration(),
    modelProvider: any ModelProvider,
    threadStore: any ThreadStore = InMemoryThreadStore(),
    tools: [any AgentTool] = defaultBuiltinTools(),
    approvalHandler: ApprovalHandler? = nil,
    codeModeEngine: any CodeModeEngine = AutomaticCodeModeEngine(),
    codeModeTokenCounter: any CodeModeTokenCounting = EstimatedCodeModeTokenCounter()
  ) {
    self.configuration = configuration
    self.modelProvider = modelProvider
    self.threadManager = ThreadManager(store: threadStore)
    let toolRegistry = ToolRegistry(tools: tools)
    self.toolRegistry = toolRegistry
    self.codeModeRuntime = CodeModeRuntime(
      registry: toolRegistry,
      engine: codeModeEngine,
      tokenCounter: codeModeTokenCounter
    )
    self.mcpRegistry = MCPRegistry()
    self.approvalHandler = approvalHandler
  }

  public func currentConfiguration() -> AgentConfiguration { configuration }

  public func updateConfiguration(_ configuration: AgentConfiguration) {
    self.configuration = configuration
  }

  public func appendSystemInstructions(_ text: String) {
    configuration.systemPromptMode = .append
    configuration.additionalSystemInstructions.append(text)
  }

  public func replaceSystemPrompt(_ text: String) {
    configuration.systemPromptMode = .replace
    configuration.instructions = text
    configuration.additionalSystemInstructions.removeAll()
  }

  public func enableWebSearch(
    searchContextSize: String? = nil,
    userLocation: JSONValue? = nil,
    filters: JSONValue? = nil,
    externalWebAccess: Bool? = nil
  ) {
    configuration.serverTools.removeAll {
      $0.type == "web_search" || $0.type == "web_search_preview"
    }
    configuration.serverTools.append(
      .webSearch(
        searchContextSize: searchContextSize, userLocation: userLocation, filters: filters,
        externalWebAccess: externalWebAccess))
  }

  public func enableImageGeneration(
    model: String? = nil, size: String? = nil, quality: String? = nil, outputFormat: String? = nil
  ) {
    configuration.serverTools.removeAll { $0.type == "image_generation" }
    configuration.serverTools.append(
      .imageGeneration(model: model, size: size, quality: quality, outputFormat: outputFormat))
  }

  public func addServerTool(_ tool: ResponseToolDefinition) {
    configuration.serverTools.append(tool)
  }

  public func createThread(title: String? = nil, metadata: [String: JSONValue] = [:]) async throws
    -> AgentThread
  {
    try await threadManager.createThread(title: title, metadata: metadata)
  }

  public func listThreads(includeArchived: Bool = false) async throws -> [AgentThread] {
    try await threadManager.listThreads(includeArchived: includeArchived)
  }

  public func readThread(id: String) async throws -> AgentThread {
    try await threadManager.getThread(id: id)
  }

  public func forkThread(id: String, title: String? = nil) async throws -> AgentThread {
    try await threadManager.forkThread(id: id, title: title)
  }

  public func rollbackThread(id: String, toItemID itemID: String) async throws -> AgentThread {
    try await threadManager.rollbackThread(id: id, toItemID: itemID)
  }

  public func archiveThread(id: String) async throws {
    await codeModeRuntime.terminateCells(threadID: id, clearStore: true)
    try await threadManager.archiveThread(id: id)
  }

  public func registerTool(_ tool: any AgentTool) async {
    await toolRegistry.register(tool)
  }

  public func connectMCP(_ client: any MCPClient, initialize: Bool = true) async throws {
    guard !client.requiresNetworkAccess || configuration.sandboxPolicy.allowNetwork else {
      throw CodexCoreError.approvalRequired(
        "MCP client \(client.name) requires network access, but network is disabled by the sandbox policy"
      )
    }
    try await mcpRegistry.addClient(client, initialize: initialize)
    await mcpRegistry.registerAdapters(into: toolRegistry)
  }

  public func refreshMCPTools(serverName: String? = nil) async throws {
    try await mcpRegistry.refreshTools(for: serverName)
    await mcpRegistry.registerAdapters(into: toolRegistry)
  }

  public func startTurn(threadID: String, input: TurnInput) throws -> TurnHandle {
    if let active = activeTurnsByThreadID[threadID] {
      throw CodexCoreError.invalidState(
        "Thread \(threadID) already has active turn \(active.turnID)")
    }
    let agent = makeAgent(configuration: configuration)
    let rawHandle = agent.startTurn(threadID: threadID, input: input)
    let stream = AsyncThrowingStream<AgentEvent, Error>.makeStream()
    let handle = TurnHandle(
      threadID: rawHandle.threadID,
      turnID: rawHandle.turnID,
      events: stream.stream,
      control: rawHandle.control,
      interruptHandler: { await rawHandle.interrupt() }
    )
    activeTurnsByThreadID[threadID] = handle
    let task = Task {
      do {
        for try await event in rawHandle.events {
          stream.continuation.yield(event)
          if case .turnCompleted(_, let turnID, _, _) = event {
            self.clearActiveTurn(threadID: threadID, turnID: turnID)
          }
        }
        self.clearActiveTurn(threadID: threadID, turnID: rawHandle.turnID)
        stream.continuation.finish()
      } catch {
        self.clearActiveTurn(threadID: threadID, turnID: rawHandle.turnID)
        stream.continuation.finish(throwing: error)
      }
    }
    stream.continuation.onTermination = { @Sendable _ in
      task.cancel()
      Task { await self.clearActiveTurn(threadID: threadID, turnID: rawHandle.turnID) }
    }
    return handle
  }

  @discardableResult
  public func sendMessage(threadID: String, text: String, metadata: [String: JSONValue] = [:])
    async throws -> String
  {
    let handle = try startTurn(threadID: threadID, input: TurnInput(text, metadata: metadata))
    var final = ""
    for try await event in handle.events {
      if case .itemCompleted(let item) = event, item.kind == .assistantMessage {
        final = item.payload["content"]?.stringValue ?? item.summary ?? final
      }
    }
    return final
  }

  public func steer(
    threadID: String, expectedTurnID: String? = nil, text: String,
    metadata: [String: JSONValue] = [:]
  ) async throws {
    guard let handle = activeTurnsByThreadID[threadID] else {
      throw CodexCoreError.invalidState("No active turn for thread \(threadID)")
    }
    if let expectedTurnID, expectedTurnID != handle.turnID {
      throw CodexCoreError.invalidState(
        "Expected active turn \(expectedTurnID), found \(handle.turnID)")
    }
    await handle.steer(text, metadata: metadata)
  }

  public func interrupt(threadID: String, expectedTurnID: String? = nil) async throws {
    guard let handle = activeTurnsByThreadID[threadID] else {
      throw CodexCoreError.invalidState("No active turn for thread \(threadID)")
    }
    if let expectedTurnID, expectedTurnID != handle.turnID {
      throw CodexCoreError.invalidState(
        "Expected active turn \(expectedTurnID), found \(handle.turnID)")
    }
    await handle.interrupt()
    await codeModeRuntime.terminateCells(threadID: threadID)
    activeTurnsByThreadID.removeValue(forKey: threadID)
  }

  public func activeTurn(threadID: String) -> TurnHandle? {
    activeTurnsByThreadID[threadID]
  }

  private func clearActiveTurn(threadID: String, turnID: String) {
    guard activeTurnsByThreadID[threadID]?.turnID == turnID else { return }
    activeTurnsByThreadID.removeValue(forKey: threadID)
  }

  public func installSubagentTool(maxDepth _: Int = 4) async {
    let manager = SubagentManager(
      threadManager: threadManager,
      baseConfiguration: configuration,
      makeAgent: { [modelProvider, toolRegistry, approvalHandler] config, sharedThreadManager in
        CodexAgent(
          configuration: config,
          modelProvider: modelProvider,
          toolRegistry: toolRegistry,
          threadManager: sharedThreadManager,
          approvalHandler: approvalHandler
        )
      }
    )
    await toolRegistry.register(SpawnSubagentTool(manager: manager))
  }

  private func makeAgent(configuration: AgentConfiguration) -> CodexAgent {
    CodexAgent(
      configuration: configuration,
      modelProvider: modelProvider,
      toolRegistry: toolRegistry,
      threadManager: threadManager,
      approvalHandler: approvalHandler,
      codeModeRuntime: codeModeRuntime
    )
  }
}
