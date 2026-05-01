import Foundation
import CodexCore

@main
struct CodexCoreExample {
    static func main() async throws {
        let model = ScriptedModelProvider(batches: [
            [
                .toolCallCompleted(ToolCall(callID: "call_1", name: "echo", arguments: "{\"text\":\"hello from a tool\"}")),
                .completed(responseID: "resp_1", usage: nil)
            ],
            [
                .outputTextDelta("The tool said: hello from a tool"),
                .completed(responseID: "resp_2", usage: nil)
            ]
        ])
        let registry = ToolRegistry(tools: defaultBuiltinTools(includeShell: false))
        let manager = ThreadManager(store: InMemoryThreadStore())
        let agent = CodexAgent(modelProvider: model, toolRegistry: registry, threadManager: manager)
        let thread = try await agent.createThread(title: "Example")
        let handle = agent.startTurn(threadID: thread.id, input: TurnInput("Run echo and tell me what it says."))

        for try await event in handle.events {
            print(event.description)
        }
    }
}
