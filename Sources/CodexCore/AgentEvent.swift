import Foundation

public enum AgentEvent: Sendable, Equatable, CustomStringConvertible {
    case turnStarted(threadID: String, turnID: String)
    case turnCompleted(threadID: String, turnID: String, status: TurnStatus, usage: TokenUsage?)
    case itemStarted(ThreadItem)
    case itemDelta(itemID: String, delta: String)
    case itemCompleted(ThreadItem)
    case reasoningDelta(String)
    case toolStarted(call: ToolCall)
    case toolCompleted(call: ToolCall, result: ToolResult)
    case approvalRequested(ApprovalRequest)
    case warning(String)
    case error(String)

    public var description: String {
        switch self {
        case .turnStarted(let threadID, let turnID): return "turnStarted(thread: \(threadID), turn: \(turnID))"
        case .turnCompleted(_, let turnID, let status, _): return "turnCompleted(turn: \(turnID), status: \(status.rawValue))"
        case .itemStarted(let item): return "itemStarted(\(item.kind.rawValue): \(item.summary ?? item.id))"
        case .itemDelta(let itemID, let delta): return "itemDelta(\(itemID): \(delta))"
        case .itemCompleted(let item): return "itemCompleted(\(item.kind.rawValue): \(item.summary ?? item.id))"
        case .reasoningDelta(let delta): return "reasoningDelta(\(delta))"
        case .toolStarted(let call): return "toolStarted(\(call.name))"
        case .toolCompleted(let call, let result): return "toolCompleted(\(call.name): \(result.summary))"
        case .approvalRequested(let request): return "approvalRequested(\(request.reason))"
        case .warning(let message): return "warning(\(message))"
        case .error(let message): return "error(\(message))"
        }
    }
}

public struct ApprovalRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var threadID: String
    public var turnID: String
    public var toolName: String
    public var arguments: JSONValue
    public var reason: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        turnID: String,
        toolName: String,
        arguments: JSONValue,
        reason: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.turnID = turnID
        self.toolName = toolName
        self.arguments = arguments
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct ApprovalDecision: Codable, Sendable, Equatable {
    public var approved: Bool
    public var message: String?

    public init(approved: Bool, message: String? = nil) {
        self.approved = approved
        self.message = message
    }
}

public typealias ApprovalHandler = @Sendable (ApprovalRequest) async throws -> ApprovalDecision
