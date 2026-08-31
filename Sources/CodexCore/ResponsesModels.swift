import Foundation

public enum ResponseToolCaller: String, Codable, Sendable, Equatable, CaseIterable {
  case direct
  case programmatic
}

public enum ImageDetail: String, Codable, Sendable, Equatable, CaseIterable {
  case low
  case high
  case original
  case auto
}

public struct ResponseToolDefinition: Codable, Sendable, Equatable {
  public var fields: [String: JSONValue]

  public var type: String { fields["type"]?.stringValue ?? "function" }
  public var name: String? { fields["name"]?.stringValue }
  public var description: String? { fields["description"]?.stringValue }
  public var parameters: JSONValue? { fields["parameters"] }
  var isSupportedByResponsesLite: Bool { Self.supportsResponsesLiteToolType(type) }

  static func supportsResponsesLiteToolType(_ type: String) -> Bool {
    // Matches ToolSpec in the pinned upstream tools/src/tool_spec.rs. Namespace
    // payloads are passed through; provider-specific namespace wrapping is not inferred.
    switch type {
    case "function", "custom", "namespace", "web_search", "tool_search": return true
    default: return false
    }
  }

  public var requiresNetworkAccess: Bool {
    switch type {
    case "function", "custom":
      return false
    case "web_search", "web_search_preview", "image_generation", "mcp", "file_search",
      "code_interpreter", "shell", "apply_patch", "computer", "skills", "tool_search",
      "programmatic_tool_calling":
      return true
    default:
      return false
    }
  }

  public init(fields: [String: JSONValue]) {
    self.fields = fields
  }

  public init(
    name: String,
    description: String,
    parameters: JSONValue,
    strict: Bool? = nil,
    outputSchema: JSONValue? = nil,
    allowedCallers: [ResponseToolCaller]? = nil,
    deferLoading: Bool? = nil
  ) {
    var fields: [String: JSONValue] = [
      "type": .string("function"),
      "name": .string(name),
      "description": .string(description),
      "parameters": parameters,
    ]
    if let strict { fields["strict"] = .bool(strict) }
    if let outputSchema { fields["output_schema"] = outputSchema }
    if let allowedCallers {
      fields["allowed_callers"] = .array(allowedCallers.map { .string($0.rawValue) })
    }
    if let deferLoading { fields["defer_loading"] = .bool(deferLoading) }
    self.fields = fields
  }

  public init(type: String, options: [String: JSONValue] = [:]) {
    var fields = options
    fields["type"] = .string(type)
    self.fields = fields
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.fields = try container.decode([String: JSONValue].self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(fields)
  }

  public static func raw(type: String, options: [String: JSONValue] = [:]) -> ResponseToolDefinition
  {
    ResponseToolDefinition(type: type, options: options)
  }

  public static func custom(name: String, description: String, format: JSONValue)
    -> ResponseToolDefinition
  {
    ResponseToolDefinition(
      type: "custom",
      options: [
        "name": .string(name),
        "description": .string(description),
        "format": format,
      ])
  }

  public static func webSearch(
    searchContextSize: String? = nil,
    userLocation: JSONValue? = nil,
    filters: JSONValue? = nil,
    externalWebAccess: Bool? = nil
  ) -> ResponseToolDefinition {
    var options: [String: JSONValue] = [:]
    if let searchContextSize { options["search_context_size"] = .string(searchContextSize) }
    if let userLocation { options["user_location"] = userLocation }
    if let filters { options["filters"] = filters }
    if let externalWebAccess { options["external_web_access"] = .bool(externalWebAccess) }
    return ResponseToolDefinition(type: "web_search", options: options)
  }

  public static func webSearchPreview() -> ResponseToolDefinition {
    ResponseToolDefinition(type: "web_search_preview")
  }

  public static func imageGeneration(
    model: String? = nil,
    size: String? = nil,
    quality: String? = nil,
    outputFormat: String? = nil,
    background: String? = nil,
    moderation: String? = nil
  ) -> ResponseToolDefinition {
    var options: [String: JSONValue] = [:]
    if let model { options["model"] = .string(model) }
    if let size { options["size"] = .string(size) }
    if let quality { options["quality"] = .string(quality) }
    if let outputFormat { options["output_format"] = .string(outputFormat) }
    if let background { options["background"] = .string(background) }
    if let moderation { options["moderation"] = .string(moderation) }
    return ResponseToolDefinition(type: "image_generation", options: options)
  }

  public static func fileSearch(
    vectorStoreIDs: [String], maxNumberOfResults: Int? = nil, filters: JSONValue? = nil
  ) -> ResponseToolDefinition {
    var options: [String: JSONValue] = [
      "vector_store_ids": .array(vectorStoreIDs.map(JSONValue.string))
    ]
    if let maxNumberOfResults { options["max_num_results"] = .number(Double(maxNumberOfResults)) }
    if let filters { options["filters"] = filters }
    return ResponseToolDefinition(type: "file_search", options: options)
  }

  public static func codeInterpreter(
    container: JSONValue? = nil, allowedCallers: [ResponseToolCaller]? = nil
  ) -> ResponseToolDefinition {
    var options: [String: JSONValue] = [:]
    if let container { options["container"] = container }
    if let allowedCallers {
      options["allowed_callers"] = .array(allowedCallers.map { .string($0.rawValue) })
    }
    return ResponseToolDefinition(type: "code_interpreter", options: options)
  }

  public static func hostedShell(allowedCallers: [ResponseToolCaller]? = nil)
    -> ResponseToolDefinition
  {
    var options: [String: JSONValue] = [:]
    if let allowedCallers {
      options["allowed_callers"] = .array(allowedCallers.map { .string($0.rawValue) })
    }
    return ResponseToolDefinition(type: "shell", options: options)
  }

  public static func applyPatch(allowedCallers: [ResponseToolCaller]? = nil)
    -> ResponseToolDefinition
  {
    var options: [String: JSONValue] = [:]
    if let allowedCallers {
      options["allowed_callers"] = .array(allowedCallers.map { .string($0.rawValue) })
    }
    return ResponseToolDefinition(type: "apply_patch", options: options)
  }

  public static func computerUse(environment: String? = nil) -> ResponseToolDefinition {
    var options: [String: JSONValue] = [:]
    if let environment { options["environment"] = .string(environment) }
    return ResponseToolDefinition(type: "computer", options: options)
  }

  public static func skills() -> ResponseToolDefinition {
    ResponseToolDefinition(type: "skills")
  }

  public static func toolSearch() -> ResponseToolDefinition {
    ResponseToolDefinition(type: "tool_search")
  }

  public static func programmaticToolCalling() -> ResponseToolDefinition {
    ResponseToolDefinition(type: "programmatic_tool_calling")
  }

  public static func remoteMCP(
    serverLabel: String,
    serverURL: URL,
    requireApproval: String? = nil,
    headers: [String: String] = [:],
    allowedCallers: [ResponseToolCaller]? = nil,
    deferLoading: Bool? = nil
  ) -> ResponseToolDefinition {
    var options: [String: JSONValue] = [
      "server_label": .string(serverLabel),
      "server_url": .string(serverURL.absoluteString),
    ]
    if let requireApproval { options["require_approval"] = .string(requireApproval) }
    if !headers.isEmpty {
      options["headers"] = .object(headers.mapValues(JSONValue.string))
    }
    if let allowedCallers {
      options["allowed_callers"] = .array(allowedCallers.map { .string($0.rawValue) })
    }
    if let deferLoading { options["defer_loading"] = .bool(deferLoading) }
    return ResponseToolDefinition(type: "mcp", options: options)
  }
}

public enum ResponseVerbosity: String, Codable, Sendable, Equatable, CaseIterable {
  case low
  case medium
  case high
}

public struct ResponseTextOptions: Codable, Sendable, Equatable {
  public var verbosity: ResponseVerbosity?
  public var format: JSONValue?

  public init(verbosity: ResponseVerbosity? = nil, format: JSONValue? = nil) {
    self.verbosity = verbosity
    self.format = format
  }
}

/// A server-side context-management strategy. GPT-5.6 can emit an encrypted
/// compaction item once the rendered context crosses `compactThreshold`.
public struct ResponseContextManagement: Codable, Sendable, Equatable {
  public var type: String
  public var compactThreshold: Int

  enum CodingKeys: String, CodingKey {
    case type
    case compactThreshold = "compact_threshold"
  }

  public init(type: String = "compaction", compactThreshold: Int) {
    self.type = type
    self.compactThreshold = compactThreshold
  }
}

private enum ResponsesLiteWireShape {
  static func input(
    _ input: [JSONValue],
    tools: [ResponseToolDefinition],
    instructions: String?
  ) -> [JSONValue] {
    var shaped = input.map(normalizingImageInput)
    let existingAdditionalTools = shaped.filter {
      $0["type"]?.stringValue == "additional_tools"
    }
    shaped.removeAll { $0["type"]?.stringValue == "additional_tools" }

    let supportedTools: [JSONValue]
    if existingAdditionalTools.isEmpty {
      supportedTools =
        tools
        .filter(\.isSupportedByResponsesLite)
        .map { .object($0.fields) }
    } else {
      supportedTools =
        existingAdditionalTools
        .flatMap { $0["tools"]?.arrayValue ?? [] }
        .filter {
          ResponseToolDefinition.supportsResponsesLiteToolType($0["type"]?.stringValue ?? "")
        }
    }
    var seenTools = Set<JSONValue>()
    let uniqueTools = supportedTools.filter { seenTools.insert($0).inserted }
    shaped.insert(
      .object([
        "type": .string("additional_tools"),
        "role": .string("developer"),
        "tools": .array(uniqueTools),
      ]),
      at: 0
    )

    if let instructions, !instructions.isEmpty,
      !shaped.contains(where: { isDeveloperMessage($0, containing: instructions) })
    {
      let insertionIndex = shaped.first?["type"]?.stringValue == "additional_tools" ? 1 : 0
      shaped.insert(ResponseInputBuilder.developerMessage(instructions), at: insertionIndex)
    }

    return shaped
  }

  static func reasoning(_ reasoning: ResponseReasoning?) -> ResponseReasoning {
    var reasoning = reasoning ?? ResponseReasoning()
    reasoning.context = ReasoningContext.allTurns.rawValue
    return reasoning
  }

  private static func isDeveloperMessage(_ value: JSONValue, containing text: String) -> Bool {
    guard value["role"]?.stringValue == "developer",
      let content = value["content"]?.arrayValue
    else {
      return false
    }
    return content.contains { $0["text"]?.stringValue == text }
  }

  private static func normalizingImageInput(_ value: JSONValue) -> JSONValue {
    switch value {
    case .array(let values):
      return .array(values.map(normalizingImageInput))
    case .object(var fields):
      if fields["type"]?.stringValue == "input_image" {
        if let imageURL = fields["image_url"]?.stringValue,
          imageURL.lowercased().hasPrefix("http://")
            || imageURL.lowercased().hasPrefix("https://")
        {
          return .object([
            "type": .string("input_text"),
            "text": .string("image content omitted because remote image URLs are not supported"),
          ])
        }
        fields.removeValue(forKey: "detail")
      }
      return .object(fields.mapValues(normalizingImageInput))
    case .null, .bool, .number, .string:
      return value
    }
  }
}

public struct ResponsesCompactionRequest: Codable, Sendable, Equatable {
  public var model: String
  public var input: [JSONValue]
  public var tools: [ResponseToolDefinition]?
  public var instructions: String?
  public var reasoning: ResponseReasoning?
  public var parallelToolCalls: Bool?
  public var previousResponseID: String?
  public var promptCacheKey: String?
  public var promptCacheRetention: String?
  public var serviceTier: String?
  /// Internal request-shaping signal for the Responses Lite wire contract.
  /// This is not serialized as a JSON field.
  public var useResponsesLite: Bool = false

  enum CodingKeys: String, CodingKey {
    case model
    case input
    case tools
    case instructions
    case reasoning
    case parallelToolCalls = "parallel_tool_calls"
    case previousResponseID = "previous_response_id"
    case promptCacheKey = "prompt_cache_key"
    case promptCacheRetention = "prompt_cache_retention"
    case serviceTier = "service_tier"
  }

  public init(
    model: String,
    input: [JSONValue],
    tools: [ResponseToolDefinition]? = nil,
    instructions: String? = nil,
    reasoning: ResponseReasoning? = nil,
    parallelToolCalls: Bool? = nil,
    previousResponseID: String? = nil,
    promptCacheKey: String? = nil,
    promptCacheRetention: String? = nil,
    serviceTier: String? = nil,
    useResponsesLite: Bool = false
  ) {
    self.model = model
    self.input = input
    self.tools = tools
    self.instructions = instructions
    self.reasoning = reasoning
    self.parallelToolCalls = parallelToolCalls
    self.previousResponseID = previousResponseID
    self.promptCacheKey = promptCacheKey
    self.promptCacheRetention = promptCacheRetention
    self.serviceTier = serviceTier
    self.useResponsesLite = useResponsesLite
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    if useResponsesLite {
      try container.encode(
        ResponsesLiteWireShape.input(input, tools: tools ?? [], instructions: instructions),
        forKey: .input
      )
      try container.encode(ResponsesLiteWireShape.reasoning(reasoning), forKey: .reasoning)
      try container.encode(false, forKey: .parallelToolCalls)
    } else {
      try container.encode(input, forKey: .input)
      try container.encodeIfPresent(tools, forKey: .tools)
      try container.encodeIfPresent(instructions, forKey: .instructions)
      try container.encodeIfPresent(reasoning, forKey: .reasoning)
      try container.encodeIfPresent(parallelToolCalls, forKey: .parallelToolCalls)
    }
    try container.encodeIfPresent(previousResponseID, forKey: .previousResponseID)
    try container.encodeIfPresent(promptCacheKey, forKey: .promptCacheKey)
    try container.encodeIfPresent(promptCacheRetention, forKey: .promptCacheRetention)
    try container.encodeIfPresent(serviceTier, forKey: .serviceTier)
  }
}

public struct ResponsesCompactionResult: Codable, Sendable, Equatable {
  public var id: String?
  public var object: String?
  public var createdAt: Double?
  public var output: [JSONValue]

  enum CodingKeys: String, CodingKey {
    case id
    case object
    case createdAt = "created_at"
    case output
  }

  public init(
    id: String? = nil, object: String? = nil, createdAt: Double? = nil, output: [JSONValue]
  ) {
    self.id = id
    self.object = object
    self.createdAt = createdAt
    self.output = output
  }
}

public struct ResponsesRequest: Codable, Sendable, Equatable {
  public var model: String
  public var instructions: String?
  public var input: [JSONValue]
  public var tools: [ResponseToolDefinition]
  public var stream: Bool
  public var reasoning: ResponseReasoning?
  public var background: Bool?
  public var store: Bool?
  public var previousResponseID: String?
  public var metadata: [String: JSONValue]
  public var parallelToolCalls: Bool?
  public var include: [String]?
  public var serviceTier: String?
  public var promptCacheKey: String?
  public var promptCacheOptions: PromptCacheOptions?
  public var safetyIdentifier: String?
  public var maxOutputTokens: Int?
  public var toolChoice: JSONValue?
  public var text: ResponseTextOptions?
  public var multiAgent: MultiAgentConfiguration?
  public var contextManagement: [ResponseContextManagement]?
  /// Internal request-shaping signal used by Codex model metadata. This is
  /// intentionally not serialized as a JSON field; it controls the wire
  /// envelope and transport header.
  public var useResponsesLite: Bool = false

  enum CodingKeys: String, CodingKey {
    case model
    case instructions
    case input
    case tools
    case stream
    case reasoning
    case background
    case store
    case previousResponseID = "previous_response_id"
    case metadata
    case parallelToolCalls = "parallel_tool_calls"
    case include
    case serviceTier = "service_tier"
    case promptCacheKey = "prompt_cache_key"
    case promptCacheOptions = "prompt_cache_options"
    case safetyIdentifier = "safety_identifier"
    case maxOutputTokens = "max_output_tokens"
    case toolChoice = "tool_choice"
    case text
    case multiAgent = "multi_agent"
    case contextManagement = "context_management"
  }

  public init(
    model: String,
    instructions: String? = nil,
    input: [JSONValue],
    tools: [ResponseToolDefinition] = [],
    stream: Bool = true,
    reasoning: ResponseReasoning? = nil,
    background: Bool? = nil,
    store: Bool? = nil,
    previousResponseID: String? = nil,
    metadata: [String: JSONValue] = [:],
    parallelToolCalls: Bool? = true,
    include: [String]? = nil,
    serviceTier: String? = nil,
    promptCacheKey: String? = nil,
    promptCacheOptions: PromptCacheOptions? = nil,
    safetyIdentifier: String? = nil,
    maxOutputTokens: Int? = nil,
    toolChoice: JSONValue? = nil,
    text: ResponseTextOptions? = nil,
    multiAgent: MultiAgentConfiguration? = nil,
    contextManagement: [ResponseContextManagement]? = nil,
    useResponsesLite: Bool = false
  ) {
    self.model = model
    self.instructions = instructions
    self.input = input
    self.tools = tools
    self.stream = stream
    self.reasoning = reasoning
    self.background = background
    self.store = store
    self.previousResponseID = previousResponseID
    self.metadata = metadata
    self.parallelToolCalls = parallelToolCalls
    self.include = include
    self.serviceTier = serviceTier
    self.promptCacheKey = promptCacheKey
    self.promptCacheOptions = promptCacheOptions
    self.safetyIdentifier = safetyIdentifier
    self.maxOutputTokens = maxOutputTokens
    self.toolChoice = toolChoice
    self.text = text
    self.multiAgent = multiAgent
    self.contextManagement = contextManagement
    self.useResponsesLite = useResponsesLite
  }

  public func encode(to encoder: Encoder) throws {
    if useResponsesLite, contextManagement?.isEmpty == false {
      throw CodexCoreError.invalidInput(
        "Responses Lite does not support context_management. Remove compaction settings or use the standard Responses API."
      )
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    if !useResponsesLite {
      try container.encodeIfPresent(instructions, forKey: .instructions)
    }
    let wireInput =
      useResponsesLite
      ? ResponsesLiteWireShape.input(input, tools: tools, instructions: instructions)
      : input
    try container.encode(wireInput, forKey: .input)
    if !useResponsesLite {
      try container.encode(tools, forKey: .tools)
    }
    try container.encode(stream, forKey: .stream)
    if useResponsesLite {
      try container.encode(ResponsesLiteWireShape.reasoning(reasoning), forKey: .reasoning)
    } else {
      try container.encodeIfPresent(reasoning, forKey: .reasoning)
    }
    try container.encodeIfPresent(background, forKey: .background)
    try container.encodeIfPresent(store, forKey: .store)
    try container.encodeIfPresent(previousResponseID, forKey: .previousResponseID)
    if !metadata.isEmpty {
      try container.encode(metadata, forKey: .metadata)
    }
    if useResponsesLite {
      try container.encode(false, forKey: .parallelToolCalls)
    } else {
      try container.encodeIfPresent(parallelToolCalls, forKey: .parallelToolCalls)
    }
    try container.encodeIfPresent(include, forKey: .include)
    try container.encodeIfPresent(serviceTier, forKey: .serviceTier)
    try container.encodeIfPresent(promptCacheKey, forKey: .promptCacheKey)
    try container.encodeIfPresent(promptCacheOptions, forKey: .promptCacheOptions)
    try container.encodeIfPresent(safetyIdentifier, forKey: .safetyIdentifier)
    try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
    try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
    try container.encodeIfPresent(text, forKey: .text)
    try container.encodeIfPresent(multiAgent, forKey: .multiAgent)
    try container.encodeIfPresent(contextManagement, forKey: .contextManagement)
  }
}

public struct ResponseReasoning: Codable, Sendable, Equatable {
  public var effort: String?
  public var summary: String?
  public var mode: String?
  public var context: String?

  public init(
    effort: String? = nil, summary: String? = nil, mode: String? = nil, context: String? = nil
  ) {
    self.effort = effort
    self.summary = summary
    self.mode = mode
    self.context = context
  }

  public init?(
    effort: ReasoningEffort?, summary: ReasoningSummary?, mode: ReasoningMode? = nil,
    context: ReasoningContext? = nil
  ) {
    self.init(effortName: effort?.rawValue, summary: summary, mode: mode, context: context)
  }

  public init?(
    effortName: String?, summary: ReasoningSummary?, mode: ReasoningMode? = nil,
    context: ReasoningContext? = nil
  ) {
    let summaryValue = summary == ReasoningSummary.none ? nil : summary?.rawValue
    guard effortName != nil || summaryValue != nil || mode != nil || context != nil else {
      return nil
    }
    self.effort = effortName
    self.summary = summaryValue
    self.mode = mode?.rawValue
    self.context = context?.rawValue
  }
}

public struct OpenAIResponseSnapshot: Codable, Sendable, Equatable {
  public var id: String?
  public var status: String?
  public var background: Bool?
  public var outputText: String
  public var usage: TokenUsage?
  public var errorMessage: String?
  public var raw: JSONValue

  public init(
    id: String? = nil,
    status: String? = nil,
    background: Bool? = nil,
    outputText: String = "",
    usage: TokenUsage? = nil,
    errorMessage: String? = nil,
    raw: JSONValue = .object([:])
  ) {
    self.id = id
    self.status = status
    self.background = background
    self.outputText = outputText
    self.usage = usage
    self.errorMessage = errorMessage
    self.raw = raw
  }

  public var isTerminal: Bool {
    switch status?.lowercased() {
    case "completed", "failed", "cancelled", "canceled", "incomplete", "expired":
      return true
    default:
      return false
    }
  }
}

public enum ModelStreamEvent: Sendable, Equatable {
  case outputTextDelta(String)
  case reasoningDelta(String)
  case toolCallDelta(callID: String, name: String?, argumentsDelta: String)
  case toolCallCompleted(ToolCall)
  case serverToolCompleted(name: String, item: JSONValue)
  /// A replayable Responses output item such as encrypted reasoning, a
  /// hosted program, or a Multi-agent coordination item.
  case responseItemCompleted(JSONValue)
  /// Provider signal that the dynamic `/models` catalog has changed.
  case modelCatalogETag(String)
  case messageCompleted(String)
  case completed(responseID: String?, usage: TokenUsage?)
  case failed(String)
  case raw(JSONValue)
}

public protocol ModelProvider: Sendable {
  var supportsResponseContinuation: Bool { get }

  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error>
}

extension ModelProvider {
  public var supportsResponseContinuation: Bool { true }
}

public enum ResponseInputBuilder {
  public static func userMessage(_ text: String) -> JSONValue {
    userMessage(content: [inputText(text)])
  }

  public static func userMessage(content: [JSONValue]) -> JSONValue {
    .object([
      "role": .string("user"),
      "content": .array(content),
    ])
  }

  public static func inputText(_ text: String, cacheBreakpoint: Bool = false) -> JSONValue {
    var fields: [String: JSONValue] = [
      "type": .string("input_text"),
      "text": .string(text),
    ]
    if cacheBreakpoint { fields["prompt_cache_breakpoint"] = explicitCacheBreakpoint }
    return .object(fields)
  }

  public static func inputImage(
    url: URL, detail: ImageDetail = .auto, cacheBreakpoint: Bool = false
  ) -> JSONValue {
    inputImage(urlString: url.absoluteString, detail: detail, cacheBreakpoint: cacheBreakpoint)
  }

  public static func inputImage(
    urlString: String, detail: ImageDetail = .auto, cacheBreakpoint: Bool = false
  ) -> JSONValue {
    var fields: [String: JSONValue] = [
      "type": .string("input_image"),
      "image_url": .string(urlString),
      "detail": .string(detail.rawValue),
    ]
    if cacheBreakpoint { fields["prompt_cache_breakpoint"] = explicitCacheBreakpoint }
    return .object(fields)
  }

  public static func inputFile(fileID: String, cacheBreakpoint: Bool = false) -> JSONValue {
    var fields: [String: JSONValue] = [
      "type": .string("input_file"),
      "file_id": .string(fileID),
    ]
    if cacheBreakpoint { fields["prompt_cache_breakpoint"] = explicitCacheBreakpoint }
    return .object(fields)
  }

  public static func assistantMessage(_ text: String) -> JSONValue {
    .object([
      "role": .string("assistant"),
      "content": .array([
        .object([
          "type": .string("output_text"),
          "text": .string(text),
        ])
      ]),
    ])
  }

  public static func developerMessage(_ text: String) -> JSONValue {
    .object([
      "type": .string("message"),
      "role": .string("developer"),
      "content": .array([
        .object([
          "type": .string("input_text"),
          "text": .string(text),
        ])
      ]),
    ])
  }

  public static func additionalTools(_ tools: [ResponseToolDefinition]) -> JSONValue {
    .object([
      "type": .string("additional_tools"),
      "role": .string("developer"),
      "tools": .array(tools.map { .object($0.fields) }),
    ])
  }

  public static func functionCall(_ call: ToolCall) -> JSONValue {
    if call.kind == .custom {
      var fields: [String: JSONValue] = [
        "type": .string("custom_tool_call"),
        "id": .string(call.id),
        "call_id": .string(call.callID),
        "name": .string(call.name),
        "input": .string(call.arguments),
      ]
      if let caller = call.caller { fields["caller"] = caller }
      return .object(fields)
    }
    var fields: [String: JSONValue] = [
      "type": .string("function_call"),
      "id": .string(call.id),
      "call_id": .string(call.callID),
      "name": .string(call.name),
      "arguments": .string(call.arguments),
    ]
    if let caller = call.caller { fields["caller"] = caller }
    return .object(fields)
  }

  public static func functionCallOutput(callID: String, output: String, caller: JSONValue? = nil)
    -> JSONValue
  {
    functionCallOutput(callID: callID, output: .string(output), caller: caller)
  }

  public static func functionCallOutput(callID: String, output: JSONValue, caller: JSONValue? = nil)
    -> JSONValue
  {
    var fields: [String: JSONValue] = [
      "type": .string("function_call_output"),
      "call_id": .string(callID),
      "output": output,
    ]
    if let caller { fields["caller"] = caller }
    return .object(fields)
  }

  public static func customToolCallOutput(callID: String, output: String) -> JSONValue {
    customToolCallOutput(callID: callID, output: .string(output))
  }

  public static func customToolCallOutput(callID: String, output: JSONValue) -> JSONValue {
    .object([
      "type": .string("custom_tool_call_output"),
      "call_id": .string(callID),
      "output": output,
    ])
  }

  /// Requests an immediate compaction pass when used as the final input item.
  public static func compactionTrigger() -> JSONValue {
    .object(["type": .string("compaction_trigger")])
  }

  public static func injectedUserInstructions(
    title: String, body: String, metadata _: [String: JSONValue] = [:]
  ) -> JSONValue {
    .object([
      "role": .string("user"),
      "content": .array([
        .object([
          "type": .string("input_text"),
          "text": .string("# \(title)\n\n<INSTRUCTIONS>\n\(body)\n</INSTRUCTIONS>"),
        ])
      ]),
    ])
  }

  public static func serverToolOutput(_ item: JSONValue) -> JSONValue {
    item
  }

  public static func replayableServerToolOutput(_ item: JSONValue) -> JSONValue? {
    switch item["type"]?.stringValue {
    case "web_search_call", "image_generation_call", "file_search_call", "computer_call",
      "code_interpreter_call", "shell_call", "apply_patch_call", "mcp_call", "tool_search_call",
      "program", "program_output", "reasoning", "multi_agent_call", "multi_agent_call_output",
      "agent_message", "compaction":
      return item
    default:
      return nil
    }
  }

  private static let explicitCacheBreakpoint: JSONValue = .object(["mode": .string("explicit")])
}
