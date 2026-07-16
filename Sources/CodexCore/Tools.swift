import Foundation

public struct ToolDefinition: Codable, Sendable, Equatable {
  public var name: String
  public var description: String
  public var parameters: JSONValue
  public var strict: Bool?
  public var outputSchema: JSONValue?
  public var allowedCallers: [ResponseToolCaller]?
  public var deferLoading: Bool?
  public var requiresApproval: Bool
  public var isStateChanging: Bool
  public var exposure: ToolExposure?
  /// Optional namespace used by code mode for exclusions, direct-only
  /// routing, and nested `tools.<namespace>.<name>` access.
  public var namespace: String?

  public init(
    name: String,
    description: String,
    parameters: JSONValue,
    strict: Bool? = nil,
    outputSchema: JSONValue? = nil,
    allowedCallers: [ResponseToolCaller]? = nil,
    deferLoading: Bool? = nil,
    requiresApproval: Bool = false,
    isStateChanging: Bool = false,
    exposure: ToolExposure? = .direct,
    namespace: String? = nil
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.strict = strict
    self.outputSchema = outputSchema
    self.allowedCallers = allowedCallers
    self.deferLoading = deferLoading
    self.requiresApproval = requiresApproval
    self.isStateChanging = isStateChanging
    self.exposure = exposure
    self.namespace = namespace
  }

  public var responseTool: ResponseToolDefinition {
    ResponseToolDefinition(
      name: name,
      description: description,
      parameters: parameters,
      strict: strict,
      outputSchema: outputSchema,
      allowedCallers: allowedCallers,
      deferLoading: deferLoading
    )
  }
}

public enum ToolExposure: String, Codable, Sendable, Equatable, CaseIterable {
  /// Direct model tool and available from code mode.
  case direct
  /// Hidden from the ordinary tool list and discoverable from code mode.
  case deferred
  /// Direct model tool that is intentionally unavailable to nested code.
  case directModelOnly = "direct_model_only"
  /// Never exposed to the model or code-mode runtime.
  case hidden
}

public struct ToolResult: Codable, Sendable, Equatable {
  public var content: String
  public var structuredContent: JSONValue?
  public var isError: Bool
  public var metadata: [String: JSONValue]
  /// Future-compatible typed content emitted by tools. `content` remains the
  /// plain-text compatibility representation.
  public var contentBlocks: [ToolContentBlock]?
  /// Optional value returned to JavaScript callers in code mode. This lets
  /// tools preserve their native programmatic result instead of forcing the
  /// model-facing text representation through a lossy conversion.
  public var codeModeResult: JSONValue?

  public init(
    content: String,
    structuredContent: JSONValue? = nil,
    isError: Bool = false,
    metadata: [String: JSONValue] = [:],
    contentBlocks: [ToolContentBlock]? = nil,
    codeModeResult: JSONValue? = nil
  ) {
    self.content = content
    self.structuredContent = structuredContent
    self.isError = isError
    self.metadata = metadata
    self.contentBlocks = contentBlocks
    self.codeModeResult = codeModeResult
  }

  public var summary: String {
    if content.count <= 120 { return content }
    return String(content.prefix(117)) + "..."
  }

  /// Compatibility serialization of the value sent on the Responses wire.
  /// Prefer `responseOutputValue` when constructing a request so typed image
  /// items remain an array rather than a JSON-encoded string.
  public var responseOutput: String {
    if case .string(let output) = responseOutputValue { return output }
    guard let data = try? JSONEncoder.codexCompact.encode(responseOutputValue) else {
      return content
    }
    return String(data: data, encoding: .utf8) ?? content
  }

  /// Responses accepts either a string or `input_text`/`input_image` content
  /// items for function and custom tool outputs.
  public var responseOutputValue: JSONValue {
    guard let contentBlocks,
      contentBlocks.contains(where: { $0.type != "text" })
    else { return .string(content) }
    let mapped = contentBlocks.compactMap { block in
      block.responseOutputItem.map { (block, $0) }
    }
    guard mapped.count == contentBlocks.count else {
      return .string(responseOutputEnvelope)
    }
    let blockText = contentBlocks.compactMap { $0.fields["text"]?.stringValue }.joined(
      separator: "\n")
    if !content.isEmpty, content != blockText {
      var output = mapped.compactMap { block, item in block.type == "text" ? nil : item }
      output.append(.object(["type": .string("input_text"), "text": .string(content)]))
      return .array(output)
    }
    return .array(mapped.map(\.1))
  }

  private var responseOutputEnvelope: String {
    let envelope: JSONValue = .object([
      "content": .array((contentBlocks ?? []).map { .object($0.fields) }),
      "structuredContent": structuredContent ?? .null,
      "isError": .bool(isError),
    ])
    guard let data = try? JSONEncoder.codexCompact.encode(envelope) else { return content }
    return String(data: data, encoding: .utf8) ?? content
  }
}

/// A future-compatible typed content block shared by local, MCP, and code-mode
/// tools. Unknown fields survive round trips.
public struct ToolContentBlock: Codable, Sendable, Equatable {
  public var fields: [String: JSONValue]
  public var type: String { fields["type"]?.stringValue ?? "unknown" }

  public init(fields: [String: JSONValue]) { self.fields = fields }

  public init(from decoder: Decoder) throws {
    fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(fields)
  }

  public static func text(_ text: String) -> ToolContentBlock {
    ToolContentBlock(fields: ["type": .string("text"), "text": .string(text)])
  }

  public static func image(imageURL: String, detail: ImageDetail? = nil) -> ToolContentBlock {
    var fields: [String: JSONValue] = ["type": .string("image"), "image_url": .string(imageURL)]
    if let detail { fields["detail"] = .string(detail.rawValue) }
    return ToolContentBlock(fields: fields)
  }

  public static func audio(data: String, mimeType: String) -> ToolContentBlock {
    ToolContentBlock(fields: [
      "type": .string("audio"),
      "data": .string(data),
      "mime_type": .string(mimeType),
    ])
  }

  public static func resource(uri: String, name: String? = nil, mimeType: String? = nil)
    -> ToolContentBlock
  {
    var fields: [String: JSONValue] = ["type": .string("resource_link"), "uri": .string(uri)]
    if let name { fields["name"] = .string(name) }
    if let mimeType { fields["mime_type"] = .string(mimeType) }
    return ToolContentBlock(fields: fields)
  }

  fileprivate var responseOutputItem: JSONValue? {
    switch type {
    case "text":
      guard let text = fields["text"]?.stringValue else { return nil }
      return .object(["type": .string("input_text"), "text": .string(text)])
    case "image":
      let imageURL: String?
      if let url = fields["image_url"]?.stringValue {
        imageURL = url
      } else if let data = fields["data"]?.stringValue {
        if data.lowercased().hasPrefix("data:") {
          imageURL = data
        } else {
          let mimeType =
            fields["mimeType"]?.stringValue
            ?? fields["mime_type"]?.stringValue
            ?? "application/octet-stream"
          imageURL = "data:\(mimeType);base64,\(data)"
        }
      } else {
        imageURL = nil
      }
      guard let imageURL else { return nil }
      var item: [String: JSONValue] = [
        "type": .string("input_image"),
        "image_url": .string(imageURL),
      ]
      if let detail = fields["detail"]?.stringValue { item["detail"] = .string(detail) }
      return .object(item)
    default:
      return nil
    }
  }
}

public struct ToolExecutionContext: Sendable {
  public var threadID: String
  public var turnID: String
  public var workspaceURL: URL?
  public var approvalPolicy: ApprovalPolicy
  public var sandboxPolicy: SandboxPolicy
  public var approvalHandler: ApprovalHandler?
  public var approvalEventHandler: (@Sendable (ApprovalRequest) async -> Void)?
  public var metadata: [String: JSONValue]

  public init(
    threadID: String,
    turnID: String,
    workspaceURL: URL? = nil,
    approvalPolicy: ApprovalPolicy,
    sandboxPolicy: SandboxPolicy,
    approvalHandler: ApprovalHandler? = nil,
    approvalEventHandler: (@Sendable (ApprovalRequest) async -> Void)? = nil,
    metadata: [String: JSONValue] = [:]
  ) {
    self.threadID = threadID
    self.turnID = turnID
    self.workspaceURL = workspaceURL
    self.approvalPolicy = approvalPolicy
    self.sandboxPolicy = sandboxPolicy
    self.approvalHandler = approvalHandler
    self.approvalEventHandler = approvalEventHandler
    self.metadata = metadata
  }
}

public protocol AgentTool: Sendable {
  var definition: ToolDefinition { get }
  func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult
}

public actor ToolRegistry {
  private var tools: [String: any AgentTool] = [:]

  public init(tools: [any AgentTool] = []) {
    for tool in tools { self.tools[tool.definition.name] = tool }
  }

  public func register(_ tool: any AgentTool) {
    tools[tool.definition.name] = tool
  }

  public func unregister(name: String) {
    tools.removeValue(forKey: name)
  }

  public func listDefinitions() -> [ToolDefinition] {
    tools.values.map(\.definition).sorted { $0.name < $1.name }
  }

  public func hasTool(named name: String) -> Bool {
    tools[name] != nil
  }

  public func run(name: String, arguments: JSONValue, context: ToolExecutionContext) async throws
    -> ToolResult
  {
    guard let tool = tools[name] else { throw CodexCoreError.missingTool(name) }
    try await authorizeIfNeeded(tool: tool, arguments: arguments, context: context)
    return try await tool.run(arguments: arguments, context: context)
  }

  private func authorizeIfNeeded(
    tool: any AgentTool, arguments: JSONValue, context: ToolExecutionContext
  ) async throws {
    let definition = tool.definition
    let shouldAsk: Bool
    switch context.approvalPolicy {
    case .never:
      shouldAsk = false
    case .onRequest:
      shouldAsk = definition.requiresApproval
    case .always:
      shouldAsk = definition.isStateChanging || definition.requiresApproval
    }
    guard shouldAsk else { return }
    guard let approvalHandler = context.approvalHandler else {
      throw CodexCoreError.approvalRequired("Tool \(definition.name) requires approval")
    }
    let request = ApprovalRequest(
      threadID: context.threadID,
      turnID: context.turnID,
      toolName: definition.name,
      arguments: arguments,
      reason: "Tool \(definition.name) requested execution"
    )
    await context.approvalEventHandler?(request)
    let decision = try await approvalHandler(request)
    guard decision.approved else {
      throw CodexCoreError.approvalRequired(
        decision.message ?? "Tool \(definition.name) was rejected")
    }
  }
}

extension JSONValue {
  public func requiredString(_ key: String) throws -> String {
    guard let value = self[key]?.stringValue, !value.isEmpty else {
      throw CodexCoreError.invalidJSON("Missing required string field '\(key)'")
    }
    return value
  }

  public func optionalString(_ key: String) -> String? { self[key]?.stringValue }

  public func optionalBool(_ key: String) -> Bool? { self[key]?.boolValue }
}

public enum ToolSchemas {
  public static func object(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    .object([
      "type": .string("object"),
      "properties": .object(properties),
      "required": .array(required.map(JSONValue.string)),
      "additionalProperties": .bool(false),
    ])
  }

  public static func string(description: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["type": .string("string")]
    if let description { object["description"] = .string(description) }
    return .object(object)
  }

  public static func boolean(description: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["type": .string("boolean")]
    if let description { object["description"] = .string(description) }
    return .object(object)
  }

  public static func array(items: JSONValue, description: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["type": .string("array"), "items": items]
    if let description { object["description"] = .string(description) }
    return .object(object)
  }
}

public struct EchoTool: AgentTool {
  public let definition = ToolDefinition(
    name: "echo",
    description: "Echoes the provided text. Useful for smoke testing tool routing.",
    parameters: ToolSchemas.object(
      properties: [
        "text": ToolSchemas.string(description: "Text to echo")
      ], required: ["text"])
  )

  public init() {}

  public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    ToolResult(content: try arguments.requiredString("text"))
  }
}
