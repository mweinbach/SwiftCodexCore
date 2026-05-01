import Foundation

public struct ToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public var requiresApproval: Bool
    public var isStateChanging: Bool

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        requiresApproval: Bool = false,
        isStateChanging: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresApproval = requiresApproval
        self.isStateChanging = isStateChanging
    }

    public var responseTool: ResponseToolDefinition {
        ResponseToolDefinition(name: name, description: description, parameters: parameters)
    }
}

public struct ToolResult: Codable, Sendable, Equatable {
    public var content: String
    public var structuredContent: JSONValue?
    public var isError: Bool
    public var metadata: [String: JSONValue]

    public init(content: String, structuredContent: JSONValue? = nil, isError: Bool = false, metadata: [String: JSONValue] = [:]) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
        self.metadata = metadata
    }

    public var summary: String {
        if content.count <= 120 { return content }
        return String(content.prefix(117)) + "..."
    }
}

public struct ToolExecutionContext: Sendable {
    public var threadID: String
    public var turnID: String
    public var workspaceURL: URL?
    public var approvalPolicy: ApprovalPolicy
    public var sandboxPolicy: SandboxPolicy
    public var approvalHandler: ApprovalHandler?
    public var metadata: [String: JSONValue]

    public init(
        threadID: String,
        turnID: String,
        workspaceURL: URL? = nil,
        approvalPolicy: ApprovalPolicy,
        sandboxPolicy: SandboxPolicy,
        approvalHandler: ApprovalHandler? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.workspaceURL = workspaceURL
        self.approvalPolicy = approvalPolicy
        self.sandboxPolicy = sandboxPolicy
        self.approvalHandler = approvalHandler
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

    public func run(name: String, arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard let tool = tools[name] else { throw CodexCoreError.missingTool(name) }
        try await authorizeIfNeeded(tool: tool, arguments: arguments, context: context)
        return try await tool.run(arguments: arguments, context: context)
    }

    private func authorizeIfNeeded(tool: any AgentTool, arguments: JSONValue, context: ToolExecutionContext) async throws {
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
        let decision = try await approvalHandler(request)
        guard decision.approved else {
            throw CodexCoreError.approvalRequired(decision.message ?? "Tool \(definition.name) was rejected")
        }
    }
}

public extension JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue, !value.isEmpty else {
            throw CodexCoreError.invalidJSON("Missing required string field '\(key)'")
        }
        return value
    }

    func optionalString(_ key: String) -> String? { self[key]?.stringValue }

    func optionalBool(_ key: String) -> Bool? { self[key]?.boolValue }
}

public enum ToolSchemas {
    public static func object(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false)
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
        parameters: ToolSchemas.object(properties: [
            "text": ToolSchemas.string(description: "Text to echo")
        ], required: ["text"])
    )

    public init() {}

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        ToolResult(content: try arguments.requiredString("text"))
    }
}
