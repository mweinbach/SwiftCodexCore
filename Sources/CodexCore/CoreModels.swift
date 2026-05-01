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
    public var metadata: [String: JSONValue]

    public init(_ text: String, metadata: [String: JSONValue] = [:]) {
        self.text = text
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
    public var projectInstructionOptions: ProjectInstructionOptions
    public var skillOptions: SkillInjectionOptions
    public var serverTools: [ResponseToolDefinition]

    public init(
        model: String = "gpt-5.4",
        instructions: String = "",
        systemPromptMode: SystemPromptMode = .append,
        additionalSystemInstructions: [String] = [],
        developerInstructions: String? = nil,
        maxToolIterations: Int = 24,
        workspaceURL: URL? = nil,
        approvalPolicy: ApprovalPolicy = .onRequest,
        sandboxPolicy: SandboxPolicy = .workspaceWrite,
        includeReasoningDeltas: Bool = true,
        projectInstructionOptions: ProjectInstructionOptions = ProjectInstructionOptions(),
        skillOptions: SkillInjectionOptions = SkillInjectionOptions(),
        serverTools: [ResponseToolDefinition] = []
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
        self.projectInstructionOptions = projectInstructionOptions
        self.skillOptions = skillOptions
        self.serverTools = serverTools
    }
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
        SandboxPolicy(allowShellCommands: false, allowFileRead: true, allowFileWrite: false, allowNetwork: false)
    }

    public static var workspaceWrite: SandboxPolicy {
        SandboxPolicy(allowShellCommands: true, allowFileRead: true, allowFileWrite: true, allowNetwork: false)
    }

    public static var dangerFullAccess: SandboxPolicy {
        SandboxPolicy(allowShellCommands: true, allowFileRead: true, allowFileWrite: true, allowNetwork: true)
    }
}

public struct ToolCall: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var callID: String
    public var name: String
    public var arguments: String
    public var rawArguments: JSONValue?

    public init(id: String = UUID().uuidString, callID: String, name: String, arguments: String, rawArguments: JSONValue? = nil) {
        self.id = id
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.rawArguments = rawArguments
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}
