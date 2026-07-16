import Foundation

public enum AgentRole: String, Codable, Sendable, CaseIterable {
  case system
  case developer
  case user
  case assistant
  case tool
}

public enum ThreadStatus: String, Codable, Sendable {
  case active
  case archived
}

public enum TurnStatus: String, Codable, Sendable {
  case running
  case completed
  case interrupted
  case failed
}

public enum ThreadItemKind: String, Codable, Sendable {
  case userMessage
  case developerMessage
  case assistantMessage
  case reasoning
  case plan
  case toolCall
  case toolResult
  case commandExecution
  case fileChange
  case mcpToolCall
  case dynamicToolCall
  case subagentToolCall
  case webSearch
  case imageGeneration
  case contextCompaction
  case warning
  case error
  case rawModelEvent
}

public struct AgentMessage: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var role: AgentRole
  public var content: String
  public var name: String?
  public var createdAt: Date
  public var metadata: [String: JSONValue]

  public init(
    id: String = UUID().uuidString,
    role: AgentRole,
    content: String,
    name: String? = nil,
    createdAt: Date = Date(),
    metadata: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.name = name
    self.createdAt = createdAt
    self.metadata = metadata
  }
}

public struct ThreadItem: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var threadID: String
  public var turnID: String?
  public var kind: ThreadItemKind
  public var createdAt: Date
  public var summary: String?
  public var payload: JSONValue

  public init(
    id: String = UUID().uuidString,
    threadID: String,
    turnID: String? = nil,
    kind: ThreadItemKind,
    createdAt: Date = Date(),
    summary: String? = nil,
    payload: JSONValue = .object([:])
  ) {
    self.id = id
    self.threadID = threadID
    self.turnID = turnID
    self.kind = kind
    self.createdAt = createdAt
    self.summary = summary
    self.payload = payload
  }
}

public struct AgentThread: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var title: String?
  public var parentThreadID: String?
  public var status: ThreadStatus
  public var createdAt: Date
  public var updatedAt: Date
  public var items: [ThreadItem]
  public var metadata: [String: JSONValue]

  public init(
    id: String = UUID().uuidString,
    title: String? = nil,
    parentThreadID: String? = nil,
    status: ThreadStatus = .active,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    items: [ThreadItem] = [],
    metadata: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.title = title
    self.parentThreadID = parentThreadID
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.items = items
    self.metadata = metadata
  }
}

public struct TurnInput: Codable, Sendable, Equatable {
  public var text: String
  /// Responses API content blocks for multimodal turns. When omitted, `text`
  /// is encoded as a single `input_text` block.
  public var content: [JSONValue]?
  public var metadata: [String: JSONValue]

  public init(_ text: String, metadata: [String: JSONValue] = [:]) {
    self.text = text
    self.content = nil
    self.metadata = metadata
  }

  public init(content: [JSONValue], text: String? = nil, metadata: [String: JSONValue] = [:]) {
    self.content = content
    self.text = text ?? content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    self.metadata = metadata
  }
}

public struct AgentConfiguration: Codable, Sendable, Equatable {
  public var model: String
  public var instructions: String
  public var systemPromptMode: SystemPromptMode
  public var additionalSystemInstructions: [String]
  public var developerInstructions: String?
  public var maxToolIterations: Int
  public var workspaceURL: URL?
  public var approvalPolicy: ApprovalPolicy
  public var sandboxPolicy: SandboxPolicy
  public var includeReasoningDeltas: Bool
  public var reasoningEffort: ReasoningEffort?
  /// Exact wire value for a model-defined effort not yet represented by
  /// `ReasoningEffort`. When set, this takes precedence.
  public var reasoningEffortName: String?
  public var reasoningSummary: ReasoningSummary?
  public var reasoningMode: ReasoningMode?
  public var reasoningContext: ReasoningContext?
  public var serviceTier: String?
  public var promptCacheKey: String?
  public var promptCacheOptions: PromptCacheOptions?
  public var safetyIdentifier: String?
  public var maxOutputTokens: Int?
  public var parallelToolCalls: Bool?
  public var multiAgent: MultiAgentConfiguration?
  public var contextManagement: [ResponseContextManagement]?
  public var responseIncludes: [String]?
  public var toolChoice: JSONValue?
  public var textOptions: ResponseTextOptions?
  /// Applies the request-shaping rules advertised by Codex's
  /// `use_responses_lite` model metadata.
  public var useResponsesLite: Bool?
  public var backgroundAccessEnabled: Bool
  public var projectInstructionOptions: ProjectInstructionOptions
  public var skillOptions: SkillInjectionOptions
  public var serverTools: [ResponseToolDefinition]
  /// Controls whether local tools are exposed directly or through Codex's
  /// JavaScript `exec` runtime. Dynamic model metadata can set this value.
  public var toolMode: AgentToolMode?
  public var codeModeOptions: CodeModeOptions?

  public init(
    model: String = OpenAIModel.gpt56Sol.rawValue,
    instructions: String = "",
    systemPromptMode: SystemPromptMode = .append,
    additionalSystemInstructions: [String] = [],
    developerInstructions: String? = nil,
    maxToolIterations: Int = 24,
    workspaceURL: URL? = nil,
    approvalPolicy: ApprovalPolicy = .onRequest,
    sandboxPolicy: SandboxPolicy = .workspaceWrite,
    includeReasoningDeltas: Bool = true,
    reasoningEffort: ReasoningEffort? = nil,
    reasoningEffortName: String? = nil,
    reasoningSummary: ReasoningSummary? = nil,
    reasoningMode: ReasoningMode? = nil,
    reasoningContext: ReasoningContext? = nil,
    serviceTier: String? = nil,
    promptCacheKey: String? = nil,
    promptCacheOptions: PromptCacheOptions? = nil,
    safetyIdentifier: String? = nil,
    maxOutputTokens: Int? = nil,
    parallelToolCalls: Bool? = true,
    multiAgent: MultiAgentConfiguration? = nil,
    contextManagement: [ResponseContextManagement]? = nil,
    responseIncludes: [String]? = ["reasoning.encrypted_content"],
    toolChoice: JSONValue? = nil,
    textOptions: ResponseTextOptions? = nil,
    useResponsesLite: Bool? = nil,
    backgroundAccessEnabled: Bool = false,
    projectInstructionOptions: ProjectInstructionOptions = ProjectInstructionOptions(),
    skillOptions: SkillInjectionOptions = SkillInjectionOptions(),
    serverTools: [ResponseToolDefinition] = [],
    toolMode: AgentToolMode? = nil,
    codeModeOptions: CodeModeOptions? = nil
  ) {
    self.model = model
    self.instructions = instructions
    self.systemPromptMode = systemPromptMode
    self.additionalSystemInstructions = additionalSystemInstructions
    self.developerInstructions = developerInstructions
    self.maxToolIterations = maxToolIterations
    self.workspaceURL = workspaceURL
    self.approvalPolicy = approvalPolicy
    self.sandboxPolicy = sandboxPolicy
    self.includeReasoningDeltas = includeReasoningDeltas
    self.reasoningEffort = reasoningEffort
    self.reasoningEffortName = reasoningEffortName
    self.reasoningSummary = reasoningSummary
    self.reasoningMode = reasoningMode
    self.reasoningContext = reasoningContext
    self.serviceTier = serviceTier
    self.promptCacheKey = promptCacheKey
    self.promptCacheOptions = promptCacheOptions
    self.safetyIdentifier = safetyIdentifier
    self.maxOutputTokens = maxOutputTokens
    self.parallelToolCalls = parallelToolCalls
    self.multiAgent = multiAgent
    self.contextManagement = contextManagement
    self.responseIncludes = responseIncludes
    self.toolChoice = toolChoice
    self.textOptions = textOptions
    self.useResponsesLite = useResponsesLite
    self.backgroundAccessEnabled = backgroundAccessEnabled
    self.projectInstructionOptions = projectInstructionOptions
    self.skillOptions = skillOptions
    self.serverTools = serverTools
    self.toolMode = toolMode
    self.codeModeOptions = codeModeOptions
  }
}

public enum AgentToolMode: String, Codable, Sendable, Equatable, CaseIterable {
  case direct
  case codeMode = "code_mode"
  case codeModeOnly = "code_mode_only"
}

public struct CodeModeOptions: Codable, Sendable, Equatable {
  public var excludedToolNamespaces: [String]
  public var directOnlyToolNamespaces: [String]
  public var directServerToolTypes: [String]
  public var maxConcurrentCells: Int
  public var maxNestedToolOutputTokens: Int
  public var defaultYieldTimeMilliseconds: Int
  public var defaultMaxOutputTokens: Int
  public var allowOriginalImageDetail: Bool
  public var maxContentBlockBytes: Int
  public var maxCellOutputBytes: Int

  enum CodingKeys: String, CodingKey {
    case excludedToolNamespaces
    case directOnlyToolNamespaces
    case directServerToolTypes
    case maxConcurrentCells
    case maxNestedToolOutputTokens
    case defaultYieldTimeMilliseconds
    case defaultMaxOutputTokens
    case allowOriginalImageDetail
    case maxContentBlockBytes
    case maxCellOutputBytes
  }

  public init(
    excludedToolNamespaces: [String] = [],
    directOnlyToolNamespaces: [String] = [],
    directServerToolTypes: [String] = ["web_search", "web_search_preview"],
    maxConcurrentCells: Int = 8,
    maxNestedToolOutputTokens: Int = 20_000,
    defaultYieldTimeMilliseconds: Int = 10_000,
    defaultMaxOutputTokens: Int = 10_000,
    allowOriginalImageDetail: Bool = true,
    maxContentBlockBytes: Int = 8 * 1024 * 1024,
    maxCellOutputBytes: Int = 32 * 1024 * 1024
  ) {
    self.excludedToolNamespaces = excludedToolNamespaces
    self.directOnlyToolNamespaces = directOnlyToolNamespaces
    self.directServerToolTypes = directServerToolTypes
    self.maxConcurrentCells = max(1, maxConcurrentCells)
    self.maxNestedToolOutputTokens = max(1, maxNestedToolOutputTokens)
    self.defaultYieldTimeMilliseconds = max(250, min(defaultYieldTimeMilliseconds, 300_000))
    self.defaultMaxOutputTokens = max(1, defaultMaxOutputTokens)
    self.allowOriginalImageDetail = allowOriginalImageDetail
    self.maxContentBlockBytes = CodeModeOutputByteLimits.contentBlockBytes(maxContentBlockBytes)
    self.maxCellOutputBytes = CodeModeOutputByteLimits.cellOutputBytes(maxCellOutputBytes)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      excludedToolNamespaces: try container.decodeIfPresent(
        [String].self, forKey: .excludedToolNamespaces) ?? [],
      directOnlyToolNamespaces: try container.decodeIfPresent(
        [String].self, forKey: .directOnlyToolNamespaces) ?? [],
      directServerToolTypes: try container.decodeIfPresent(
        [String].self, forKey: .directServerToolTypes) ?? ["web_search", "web_search_preview"],
      maxConcurrentCells: try container.decodeIfPresent(Int.self, forKey: .maxConcurrentCells) ?? 8,
      maxNestedToolOutputTokens: try container.decodeIfPresent(
        Int.self, forKey: .maxNestedToolOutputTokens) ?? 20_000,
      defaultYieldTimeMilliseconds: try container.decodeIfPresent(
        Int.self, forKey: .defaultYieldTimeMilliseconds) ?? 10_000,
      defaultMaxOutputTokens: try container.decodeIfPresent(
        Int.self, forKey: .defaultMaxOutputTokens) ?? 10_000,
      allowOriginalImageDetail: try container.decodeIfPresent(
        Bool.self, forKey: .allowOriginalImageDetail) ?? true,
      maxContentBlockBytes: try container.decodeIfPresent(Int.self, forKey: .maxContentBlockBytes)
        ?? 8 * 1024 * 1024,
      maxCellOutputBytes: try container.decodeIfPresent(Int.self, forKey: .maxCellOutputBytes)
        ?? CodeModeOutputByteLimits.defaultCellOutputBytes
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(excludedToolNamespaces, forKey: .excludedToolNamespaces)
    try container.encode(directOnlyToolNamespaces, forKey: .directOnlyToolNamespaces)
    try container.encode(directServerToolTypes, forKey: .directServerToolTypes)
    try container.encode(maxConcurrentCells, forKey: .maxConcurrentCells)
    try container.encode(maxNestedToolOutputTokens, forKey: .maxNestedToolOutputTokens)
    try container.encode(defaultYieldTimeMilliseconds, forKey: .defaultYieldTimeMilliseconds)
    try container.encode(defaultMaxOutputTokens, forKey: .defaultMaxOutputTokens)
    try container.encode(allowOriginalImageDetail, forKey: .allowOriginalImageDetail)
    try container.encode(maxContentBlockBytes, forKey: .maxContentBlockBytes)
    try container.encode(maxCellOutputBytes, forKey: .maxCellOutputBytes)
  }
}

public enum ReasoningEffort: String, Codable, Sendable, Equatable, CaseIterable {
  case none
  case minimal
  case low
  case medium
  case high
  case xhigh
  case max
  /// Codex can advertise `ultra` for hosted multi-agent execution. The public
  /// GPT-5.6 Responses API currently tops out at `max`.
  case ultra
}

public enum ReasoningSummary: String, Codable, Sendable, Equatable, CaseIterable {
  case none
  case auto
  case concise
  case detailed
}

public enum ReasoningMode: String, Codable, Sendable, Equatable, CaseIterable {
  case standard
  case pro
}

public enum ReasoningContext: String, Codable, Sendable, Equatable, CaseIterable {
  case auto
  case currentTurn = "current_turn"
  case allTurns = "all_turns"
}

public enum ApprovalPolicy: String, Codable, Sendable, Equatable {
  /// Never ask. Tools that require approval fail unless explicitly allowed by sandbox policy.
  case never
  /// Ask only for tools that mark themselves as risky.
  case onRequest
  /// Ask for every state-changing tool execution.
  case always
}

public struct SandboxPolicy: Codable, Sendable, Equatable {
  public var allowShellCommands: Bool
  public var allowFileRead: Bool
  public var allowFileWrite: Bool
  public var allowNetwork: Bool
  public var writableRoots: [URL]

  public init(
    allowShellCommands: Bool,
    allowFileRead: Bool,
    allowFileWrite: Bool,
    allowNetwork: Bool,
    writableRoots: [URL] = []
  ) {
    self.allowShellCommands = allowShellCommands
    self.allowFileRead = allowFileRead
    self.allowFileWrite = allowFileWrite
    self.allowNetwork = allowNetwork
    self.writableRoots = writableRoots
  }

  public static var readOnly: SandboxPolicy {
    SandboxPolicy(
      allowShellCommands: false, allowFileRead: true, allowFileWrite: false, allowNetwork: false)
  }

  public static var workspaceWrite: SandboxPolicy {
    SandboxPolicy(
      allowShellCommands: true, allowFileRead: true, allowFileWrite: true, allowNetwork: false)
  }

  public static var dangerFullAccess: SandboxPolicy {
    SandboxPolicy(
      allowShellCommands: true, allowFileRead: true, allowFileWrite: true, allowNetwork: true)
  }
}

public struct ToolCall: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var callID: String
  public var name: String
  public var arguments: String
  public var rawArguments: JSONValue?
  /// Opaque Responses linkage for calls made from hosted programs or agents.
  public var caller: JSONValue?
  public var kind: ToolCallKind?

  public init(
    id: String = UUID().uuidString,
    callID: String,
    name: String,
    arguments: String,
    rawArguments: JSONValue? = nil,
    caller: JSONValue? = nil,
    kind: ToolCallKind? = .function
  ) {
    self.id = id
    self.callID = callID
    self.name = name
    self.arguments = arguments
    self.rawArguments = rawArguments
    self.caller = caller
    self.kind = kind
  }
}

public enum ToolCallKind: String, Codable, Sendable, Equatable {
  case function
  case custom
}

public struct TokenUsage: Codable, Sendable, Equatable {
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var totalTokens: Int?
  public var cachedInputTokens: Int?
  public var cacheWriteTokens: Int?
  public var reasoningOutputTokens: Int?

  public init(
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    totalTokens: Int? = nil,
    cachedInputTokens: Int? = nil,
    cacheWriteTokens: Int? = nil,
    reasoningOutputTokens: Int? = nil
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
    self.cachedInputTokens = cachedInputTokens
    self.cacheWriteTokens = cacheWriteTokens
    self.reasoningOutputTokens = reasoningOutputTokens
  }
}
