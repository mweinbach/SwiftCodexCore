import Foundation

public struct AgentGraphEdge: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var parentThreadID: String
    public var childThreadID: String
    public var createdAt: Date
    public var status: String
    public var metadata: [String: JSONValue]

    public init(
        id: String = UUID().uuidString,
        parentThreadID: String,
        childThreadID: String,
        createdAt: Date = Date(),
        status: String = "open",
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.parentThreadID = parentThreadID
        self.childThreadID = childThreadID
        self.createdAt = createdAt
        self.status = status
        self.metadata = metadata
    }
}

public actor AgentGraphStore {
    private var edgesByChild: [String: AgentGraphEdge] = [:]
    private var childrenByParent: [String: Set<String>] = [:]

    public init() {}

    public func link(parentThreadID: String, childThreadID: String, metadata: [String: JSONValue] = [:]) {
        let edge = AgentGraphEdge(parentThreadID: parentThreadID, childThreadID: childThreadID, metadata: metadata)
        edgesByChild[childThreadID] = edge
        childrenByParent[parentThreadID, default: []].insert(childThreadID)
    }

    public func close(childThreadID: String) {
        guard var edge = edgesByChild[childThreadID] else { return }
        edge.status = "closed"
        edgesByChild[childThreadID] = edge
    }

    public func children(of parentThreadID: String) -> [String] {
        Array(childrenByParent[parentThreadID] ?? []).sorted()
    }

    public func parent(of childThreadID: String) -> String? {
        edgesByChild[childThreadID]?.parentThreadID
    }

    public func descendants(of parentThreadID: String) -> [String] {
        var result: [String] = []
        var stack = children(of: parentThreadID)
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: childrenByParent[next] ?? [])
        }
        return result.sorted()
    }

    public func allEdges() -> [AgentGraphEdge] {
        edgesByChild.values.sorted { $0.createdAt < $1.createdAt }
    }
}

public struct SubagentRunResult: Sendable, Equatable {
    public var thread: AgentThread
    public var finalText: String
    public var events: [AgentEvent]

    public init(thread: AgentThread, finalText: String, events: [AgentEvent]) {
        self.thread = thread
        self.finalText = finalText
        self.events = events
    }
}

public final class SubagentManager: Sendable {
    private let threadManager: ThreadManager
    private let graphStore: AgentGraphStore
    private let makeAgent: @Sendable (AgentConfiguration, ThreadManager) -> CodexAgent
    private let baseConfiguration: AgentConfiguration

    public init(
        threadManager: ThreadManager,
        graphStore: AgentGraphStore = AgentGraphStore(),
        baseConfiguration: AgentConfiguration,
        makeAgent: @escaping @Sendable (AgentConfiguration, ThreadManager) -> CodexAgent
    ) {
        self.threadManager = threadManager
        self.graphStore = graphStore
        self.baseConfiguration = baseConfiguration
        self.makeAgent = makeAgent
    }

    public func spawnAndRun(parentThreadID: String, prompt: String, title: String? = nil, model: String? = nil) async throws -> SubagentRunResult {
        let child = try await threadManager.createThread(title: title ?? "Subagent", parentThreadID: parentThreadID, metadata: ["subagent": .bool(true)])
        await graphStore.link(parentThreadID: parentThreadID, childThreadID: child.id)
        var config = baseConfiguration
        if let model { config.model = model }
        let agent = makeAgent(config, threadManager)
        let handle = agent.startTurn(threadID: child.id, input: TurnInput(prompt, metadata: ["subagent_parent_thread_id": .string(parentThreadID)]))
        var events: [AgentEvent] = []
        var finalText = ""
        for try await event in handle.events {
            events.append(event)
            if case .itemCompleted(let item) = event, item.kind == .assistantMessage {
                finalText = item.payload["content"]?.stringValue ?? item.summary ?? finalText
            }
        }
        await graphStore.close(childThreadID: child.id)
        return SubagentRunResult(thread: try await threadManager.getThread(id: child.id), finalText: finalText, events: events)
    }
}

public struct SpawnSubagentTool: AgentTool {
    public let definition = ToolDefinition(
        name: "spawn_subagent",
        description: "Spawn a child agent thread, run a prompt, and return its final answer.",
        parameters: ToolSchemas.object(properties: [
            "prompt": ToolSchemas.string(description: "Prompt for the child agent"),
            "title": ToolSchemas.string(description: "Optional child thread title"),
            "model": ToolSchemas.string(description: "Optional model override")
        ], required: ["prompt"]),
        requiresApproval: false,
        isStateChanging: false
    )

    private let manager: SubagentManager

    public init(manager: SubagentManager) {
        self.manager = manager
    }

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        let result = try await manager.spawnAndRun(
            parentThreadID: context.threadID,
            prompt: try arguments.requiredString("prompt"),
            title: arguments.optionalString("title"),
            model: arguments.optionalString("model")
        )
        return ToolResult(
            content: result.finalText,
            structuredContent: .object([
                "child_thread_id": .string(result.thread.id),
                "event_count": .number(Double(result.events.count))
            ])
        )
    }
}
