import Foundation

/// Nonblocking local-agent controls. Model calls can control only descendants
/// of their current thread; host apps can use SubagentManager directly.
public struct SubagentControlTool: AgentTool {
  public enum Action: String, CaseIterable, Sendable {
    case spawn = "spawn_agent", send = "send_input", wait = "wait_agent"
    case interrupt = "interrupt_agent", list = "list_agents"
  }
  private let manager: SubagentManager
  private let action: Action

  public init(manager: SubagentManager, action: Action) {
    self.manager = manager
    self.action = action
  }

  public var definition: ToolDefinition {
    let properties: [String: JSONValue]
    let required: [String]
    let description: String
    switch action {
    case .spawn:
      properties = ["prompt": ToolSchemas.string(), "title": ToolSchemas.string(), "model": ToolSchemas.string()]
      required = ["prompt"]
      description = "Start a child agent and return its thread ID immediately. Use wait_agent for its result."
    case .send:
      properties = ["thread_id": ToolSchemas.string(), "text": ToolSchemas.string()]
      required = ["thread_id", "text"]
      description = "Steer a running child agent or send a follow-up to a completed child."
    case .wait:
      properties = ["thread_id": ToolSchemas.string(), "timeout_ms": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(60_000)])]
      required = ["thread_id"]
      description = "Wait up to 60 seconds for a child agent and return its current status and final answer."
    case .interrupt:
      properties = ["thread_id": ToolSchemas.string()]
      required = ["thread_id"]
      description = "Stop a child agent and its descendants, waiting for their tool cleanup."
    case .list:
      properties = [:]
      required = []
      description = "List local child agents and their current status."
    }
    return ToolDefinition(name: action.rawValue, description: description,
      parameters: ToolSchemas.object(properties: properties, required: required), namespace: "agents")
  }

  public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
    let output: JSONValue
    switch action {
    case .spawn:
      output = try await manager.spawn(parentThreadID: context.threadID,
        prompt: arguments.requiredString("prompt"), title: arguments.optionalString("title"),
        model: arguments.optionalString("model")).jsonValue
    case .list:
      output = .array(await manager.list(parentThreadID: context.threadID).map(\.jsonValue))
    case .send, .wait, .interrupt:
      let id = try arguments.requiredString("thread_id")
      guard await manager.canControl(threadID: id, requesterThreadID: context.threadID) else {
        throw CodexCoreError.invalidInput("Agent controls can only target descendants of the current thread")
      }
      switch action {
      case .send: output = try await manager.send(threadID: id, text: arguments.requiredString("text")).jsonValue
      case .interrupt: output = try await manager.interrupt(threadID: id).jsonValue
      default:
        let timeout: Int
        if let raw = arguments["timeout_ms"] {
          guard let value = raw.doubleValue, let integer = Int(exactly: value), (0...60_000).contains(integer) else {
            throw CodexCoreError.invalidInput("timeout_ms must be an integer from 0 to 60000")
          }
          timeout = integer
        } else { timeout = 10_000 }
        output = try await manager.wait(threadID: id, timeoutMilliseconds: timeout).jsonValue
      }
    }
    return ToolResult(content: output.description, structuredContent: output)
  }
}
