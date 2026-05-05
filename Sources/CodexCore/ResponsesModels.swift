import Foundation

public struct ResponseToolDefinition: Codable, Sendable, Equatable {
    public var fields: [String: JSONValue]

    public var type: String { fields["type"]?.stringValue ?? "function" }
    public var name: String? { fields["name"]?.stringValue }
    public var description: String? { fields["description"]?.stringValue }
    public var parameters: JSONValue? { fields["parameters"] }
    public var requiresNetworkAccess: Bool {
        switch type {
        case "web_search", "web_search_preview", "image_generation", "mcp":
            return true
        default:
            return false
        }
    }

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(name: String, description: String, parameters: JSONValue) {
        self.fields = [
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "parameters": parameters
        ]
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

    public static func raw(type: String, options: [String: JSONValue] = [:]) -> ResponseToolDefinition {
        ResponseToolDefinition(type: type, options: options)
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

    public static func remoteMCP(serverLabel: String, serverURL: URL, requireApproval: String? = nil, headers: [String: String] = [:]) -> ResponseToolDefinition {
        var options: [String: JSONValue] = [
            "server_label": .string(serverLabel),
            "server_url": .string(serverURL.absoluteString)
        ]
        if let requireApproval { options["require_approval"] = .string(requireApproval) }
        if !headers.isEmpty {
            options["headers"] = .object(headers.mapValues(JSONValue.string))
        }
        return ResponseToolDefinition(type: "mcp", options: options)
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
        parallelToolCalls: Bool? = true
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encode(input, forKey: .input)
        try container.encode(tools, forKey: .tools)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(store, forKey: .store)
        try container.encodeIfPresent(previousResponseID, forKey: .previousResponseID)
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
        try container.encodeIfPresent(parallelToolCalls, forKey: .parallelToolCalls)
    }
}

public struct ResponseReasoning: Codable, Sendable, Equatable {
    public var effort: String?
    public var summary: String?

    public init(effort: String? = nil, summary: String? = nil) {
        self.effort = effort
        self.summary = summary
    }

    public init?(effort: ReasoningEffort?, summary: ReasoningSummary?) {
        let summaryValue = summary == ReasoningSummary.none ? nil : summary?.rawValue
        guard effort != nil || summaryValue != nil else { return nil }
        self.effort = effort?.rawValue
        self.summary = summaryValue
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
    case messageCompleted(String)
    case completed(responseID: String?, usage: TokenUsage?)
    case failed(String)
    case raw(JSONValue)
}

public protocol ModelProvider: Sendable {
    var supportsResponseContinuation: Bool { get }

    func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error>
}

public extension ModelProvider {
    var supportsResponseContinuation: Bool { true }
}

public enum ResponseInputBuilder {
    public static func userMessage(_ text: String) -> JSONValue {
        .object([
            "role": .string("user"),
            "content": .array([.object([
                "type": .string("input_text"),
                "text": .string(text)
            ])])
        ])
    }

    public static func assistantMessage(_ text: String) -> JSONValue {
        .object([
            "role": .string("assistant"),
            "content": .array([.object([
                "type": .string("output_text"),
                "text": .string(text)
            ])])
        ])
    }

    public static func developerMessage(_ text: String) -> JSONValue {
        .object([
            "role": .string("developer"),
            "content": .array([.object([
                "type": .string("input_text"),
                "text": .string(text)
            ])])
        ])
    }

    public static func functionCall(_ call: ToolCall) -> JSONValue {
        .object([
            "type": .string("function_call"),
            "id": .string(call.id),
            "call_id": .string(call.callID),
            "name": .string(call.name),
            "arguments": .string(call.arguments)
        ])
    }

    public static func functionCallOutput(callID: String, output: String) -> JSONValue {
        .object([
            "type": .string("function_call_output"),
            "call_id": .string(callID),
            "output": .string(output)
        ])
    }

    public static func injectedUserInstructions(title: String, body: String, metadata _: [String: JSONValue] = [:]) -> JSONValue {
        .object([
            "role": .string("user"),
            "content": .array([.object([
                "type": .string("input_text"),
                "text": .string("# \(title)\n\n<INSTRUCTIONS>\n\(body)\n</INSTRUCTIONS>")
            ])])
        ])
    }

    public static func serverToolOutput(_ item: JSONValue) -> JSONValue {
        item
    }

    public static func replayableServerToolOutput(_ item: JSONValue) -> JSONValue? {
        switch item["type"]?.stringValue {
        case "web_search_call", "image_generation_call":
            return item
        default:
            return nil
        }
    }
}
