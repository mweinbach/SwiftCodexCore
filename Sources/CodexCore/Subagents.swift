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

public enum SubagentRunState: String, Codable, Sendable, Equatable {
    case running, completed, interrupted, failed
}

public struct SubagentSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String { threadID }
    public var threadID: String
    public var parentThreadID: String
    public var turnID: String
    public var state: SubagentRunState
    public var finalText: String
    public var error: String?

    public var jsonValue: JSONValue {
        .object([
            "thread_id": .string(threadID), "parent_thread_id": .string(parentThreadID),
            "turn_id": .string(turnID), "state": .string(state.rawValue),
            "final_text": .string(finalText), "error": error.map(JSONValue.string) ?? .null,
        ])
    }
}

/// Local child-agent lifecycle. Active and starting runs share a bounded budget;
/// ancestry is checked against durable threads so resumed children keep their depth.
public actor SubagentManager {
    private struct Entry {
        var snapshot: SubagentSnapshot
        var configuration: AgentConfiguration
        var modelOverride: String?
        var handle: TurnHandle?
        var task: Task<Void, Never>?
        var events: [AgentEvent] = []
    }
    private let threadManager: ThreadManager
    private let graphStore: AgentGraphStore
    private let makeAgent: @Sendable (AgentConfiguration, ThreadManager) -> CodexAgent
    private var baseConfiguration: AgentConfiguration
    public let maxDepth: Int
    public let maxConcurrentAgents: Int
    private var entries: [String: Entry] = [:]
    private var pendingRuns = 0
    private var generation = UUID()
    private var isShutDown = false

    public init(
        threadManager: ThreadManager,
        graphStore: AgentGraphStore = AgentGraphStore(),
        baseConfiguration: AgentConfiguration,
        maxDepth: Int = 4,
        maxConcurrentAgents: Int = 4,
        makeAgent: @escaping @Sendable (AgentConfiguration, ThreadManager) -> CodexAgent
    ) {
        self.threadManager = threadManager
        self.graphStore = graphStore
        self.baseConfiguration = baseConfiguration
        self.maxDepth = max(0, maxDepth)
        self.maxConcurrentAgents = max(1, maxConcurrentAgents)
        self.makeAgent = makeAgent
    }

    public func spawn(parentThreadID: String, prompt: String, title: String? = nil, model: String? = nil) async throws -> SubagentSnapshot {
        try Task.checkCancellation()
        let currentGeneration = generation
        try reserveRun()
        defer { pendingRuns -= 1 }
        var cursor: String? = parentThreadID
        var depth = 0
        var visited: Set<String> = []
        while let id = cursor {
            guard visited.insert(id).inserted else { throw CodexCoreError.invalidState("Agent ancestry contains a cycle") }
            let ancestor = try await threadManager.getThread(id: id)
            guard ancestor.metadata["subagent"]?.boolValue == true else { break }
            depth += 1
            cursor = ancestor.parentThreadID
        }
        guard depth < maxDepth else { throw CodexCoreError.invalidState("Maximum subagent depth (\(maxDepth)) reached") }
        try Task.checkCancellation()
        guard !isShutDown, generation == currentGeneration else { throw CancellationError() }
        let child = try await threadManager.createThread(title: title ?? "Subagent", parentThreadID: parentThreadID, metadata: ["subagent": .bool(true)])
        await graphStore.link(parentThreadID: parentThreadID, childThreadID: child.id)
        guard !Task.isCancelled, !isShutDown, generation == currentGeneration else {
            try? await threadManager.archiveThread(id: child.id)
            await graphStore.close(childThreadID: child.id)
            throw CancellationError()
        }
        var config = baseConfiguration
        if let model { config.model = model }
        return launch(threadID: child.id, parentThreadID: parentThreadID, prompt: prompt, configuration: config, modelOverride: model)
    }

    /// Steers an active child, or starts another turn on a completed child.
    public func send(threadID: String, text: String) async throws -> SubagentSnapshot {
        try Task.checkCancellation()
        guard !isShutDown else { throw CodexCoreError.invalidState("Subagent manager was shut down") }
        guard let entry = entries[threadID] else { throw CodexCoreError.missingThread(threadID) }
        if let handle = entry.handle {
            await handle.steer(text)
            return entries[threadID]?.snapshot ?? entry.snapshot
        }
        try reserveRun()
        defer { pendingRuns -= 1 }
        return launch(threadID: threadID, parentThreadID: entry.snapshot.parentThreadID, prompt: text,
                      configuration: entry.configuration, modelOverride: entry.modelOverride)
    }

    /// Running turns keep their starting configuration. New children and later
    /// turns inherit updated policy/model defaults, preserving explicit overrides.
    public func updateConfiguration(_ configuration: AgentConfiguration) {
        baseConfiguration = configuration
        for id in Array(entries.keys) {
            var updated = configuration
            if let model = entries[id]?.modelOverride { updated.model = model }
            entries[id]?.configuration = updated
        }
    }

    /// Returns a terminal snapshot or the current state after a bounded wait.
    public func wait(threadID: String, timeoutMilliseconds: Int = 10_000) async throws -> SubagentSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(max(0, min(timeoutMilliseconds, 60_000))))
        while true {
            try Task.checkCancellation()
            guard let entry = entries[threadID] else { throw CodexCoreError.missingThread(threadID) }
            if entry.snapshot.state != .running || ContinuousClock.now >= deadline { return entry.snapshot }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @discardableResult
    public func interrupt(threadID: String) async throws -> SubagentSnapshot {
        guard let entry = entries[threadID] else { throw CodexCoreError.missingThread(threadID) }
        // Stop the owner before enumerating descendants, so it cannot create
        // another child while an earlier descendant is still tearing down.
        await entry.handle?.interrupt()
        await entry.task?.value
        await interruptDescendants(parentThreadID: threadID)
        return entries[threadID]?.snapshot ?? entry.snapshot
    }

    public func interruptDescendants(parentThreadID: String) async {
        let children = entries.values.filter { $0.snapshot.parentThreadID == parentThreadID }.map { $0.snapshot.threadID }
        for child in children { _ = try? await interrupt(threadID: child) }
    }

    public func interruptAll() async {
        generation = UUID()
        let active = entries.values.filter { $0.handle != nil }.map { $0.snapshot.threadID }
        for id in active { _ = try? await interrupt(threadID: id) }
    }

    public func shutdown() async {
        isShutDown = true
        await interruptAll()
    }

    public func list(parentThreadID: String? = nil) -> [SubagentSnapshot] {
        entries.values.map(\.snapshot).filter { entry in
            parentThreadID.map { canControl(threadID: entry.threadID, requesterThreadID: $0) } ?? true
        }.sorted { $0.threadID < $1.threadID }
    }

    public func canControl(threadID: String, requesterThreadID: String) -> Bool {
        var cursor = entries[threadID]?.snapshot.parentThreadID
        var visited: Set<String> = []
        while let id = cursor, visited.insert(id).inserted {
            if id == requesterThreadID { return true }
            cursor = entries[id]?.snapshot.parentThreadID
        }
        return false
    }

    public func spawnAndRun(parentThreadID: String, prompt: String, title: String? = nil, model: String? = nil) async throws -> SubagentRunResult {
        let child = try await spawn(parentThreadID: parentThreadID, prompt: prompt, title: title, model: model)
        return try await withTaskCancellationHandler {
            await entries[child.threadID]?.task?.value
            try Task.checkCancellation()
            guard let entry = entries[child.threadID] else { throw CodexCoreError.missingThread(child.threadID) }
            if let error = entry.snapshot.error { throw CodexCoreError.modelError(error) }
            return SubagentRunResult(thread: try await threadManager.getThread(id: child.threadID), finalText: entry.snapshot.finalText, events: entry.events)
        } onCancel: {
            Task { _ = try? await self.interrupt(threadID: child.threadID) }
        }
    }

    private func reserveRun() throws {
        guard !isShutDown else { throw CodexCoreError.invalidState("Subagent manager was shut down") }
        let running = entries.values.filter { $0.handle != nil }.count
        guard running + pendingRuns < maxConcurrentAgents else {
            throw CodexCoreError.invalidState("Maximum concurrent subagents (\(maxConcurrentAgents)) reached; wait for an agent to finish")
        }
        pendingRuns += 1
    }

    private func launch(threadID: String, parentThreadID: String, prompt: String, configuration: AgentConfiguration,
                        modelOverride: String? = nil) -> SubagentSnapshot {
        let agent = makeAgent(configuration, threadManager)
        let handle = agent.startTurn(threadID: threadID, input: TurnInput(prompt, metadata: ["subagent_parent_thread_id": .string(parentThreadID)]))
        let snapshot = SubagentSnapshot(threadID: threadID, parentThreadID: parentThreadID, turnID: handle.turnID, state: .running, finalText: "")
        entries[threadID] = Entry(snapshot: snapshot, configuration: configuration, modelOverride: modelOverride, handle: handle)
        let task = Task { await self.consume(handle) }
        entries[threadID]?.task = task
        return snapshot
    }

    private func consume(_ handle: TurnHandle) async {
        var terminalState: SubagentRunState = .completed
        do {
            for try await event in handle.events {
                guard var entry = entries[handle.threadID], entry.snapshot.turnID == handle.turnID else { return }
                entry.events.append(event)
                if entry.events.count > 256 { entry.events.removeFirst(entry.events.count - 256) }
                if case .itemCompleted(let item) = event, item.kind == .assistantMessage {
                    entry.snapshot.finalText = item.payload["content"]?.stringValue ?? item.summary ?? entry.snapshot.finalText
                }
                if case .turnCompleted(_, _, let status, _) = event {
                    switch status {
                    case .completed: terminalState = .completed
                    case .interrupted: terminalState = .interrupted
                    case .failed, .running:
                        terminalState = .failed
                        entry.snapshot.error = entry.snapshot.error ?? "The child turn did not complete successfully"
                    }
                }
                entries[handle.threadID] = entry
            }
            await handle.waitForCompletion()
        } catch {
            terminalState = .failed
            entries[handle.threadID]?.snapshot.error = String(describing: error)
        }
        entries[handle.threadID]?.handle = nil
        entries[handle.threadID]?.snapshot.state = terminalState
        await graphStore.close(childThreadID: handle.threadID)
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
