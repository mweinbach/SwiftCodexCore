# SwiftCodexCore

A SwiftPM package that implements a Codex-style agent core in Swift:

- Responses-compatible model transport
- core turn loop: sample → tool call → tool result → resample → final answer
- tool registry plus built-in portable file/edit tools
- macOS desktop shell/patch/MCP stdio tools
- optional JustBash-backed shell/file/edit/patch tools for iOS hosts
- MCP client support for Streamable HTTP servers, plus stdio on macOS
- thread storage, thread manager, fork, rollback, archive, and resume primitives
- steering and interruption of active turns
- subagent graph and `spawn_subagent` tool
- API-key auth plus Codex-compatible ChatGPT OAuth/cache/refresh helpers
- AGENTS.md project-instruction injection and SKILL.md progressive skill injection
- built-in Responses server-tool definitions for web search, image generation, and remote MCP
- high-level `CodexRuntime` facade for app/server integrations

This is intentionally a core package, not a terminal UI. Use it under a CLI, desktop app, IDE extension, app server, or browser-side controller.

## Status

The package builds and tests with Swift 6.2. `CodexCore` supports macOS and iOS; desktop-only `Process` integrations are macOS-gated. `CodexCoreJustBash` links the sibling `../just-bash-swift` package and provides the on-device tool implementation for iOS hosts.

```bash
swift test
swift run codex-core-example
```

The implementation is production-shaped but not production-hardened. In particular, the local file/shell sandbox is policy enforcement, not an OS-level sandbox; ChatGPT OAuth mirrors the public Codex OAuth/cache/device-code shape but still depends on the live OpenAI auth service accepting the public client flow; and the Responses client streams SSE incrementally through `URLSession.bytes`.

## Quick start with API-key auth

```swift
import Foundation
import CodexCore

let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!
let auth = APIKeyAuthProvider(apiKey: apiKey)
let model = OpenAIResponsesClient(auth: auth)

var config = AgentConfiguration(
    model: "gpt-5.4",
    instructions: "You are a careful coding agent. Use tools when useful.",
    workspaceURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    approvalPolicy: .onRequest,
    sandboxPolicy: .workspaceWrite
)
config.sandboxPolicy.writableRoots = [config.workspaceURL!]

let runtime = CodexRuntime(
    configuration: config,
    modelProvider: model,
    threadStore: JSONFileThreadStore(),
    tools: defaultBuiltinTools()
)

let thread = try await runtime.createThread(title: "Build a feature")
let answer = try await runtime.sendMessage(
    threadID: thread.id,
    text: "Inspect this project and summarize the architecture."
)
print(answer)
```

## iOS tool host with JustBash

On iOS, keep `CodexCore` portable and supply tools from `CodexCoreJustBash`:

```swift
import CodexCore
import CodexCoreJustBash
import JustBash

let workspace = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
let environment = try JustBashCodexFactory.makeEnvironment(
    modelProvider: model,
    workspaceRootURL: workspace,
    configuration: AgentConfiguration(
        model: "gpt-5.4",
        instructions: "You are a careful coding agent running on iOS.",
        approvalPolicy: .onRequest,
        sandboxPolicy: .workspaceWrite
    )
)

let thread = try await environment.runtime.createThread(title: "iOS session")
```

## Streaming a turn and steering it

```swift
let thread = try await runtime.createThread(title: "Interactive")
let handle = await runtime.startTurn(
    threadID: thread.id,
    input: TurnInput("Find likely bugs in the repo.")
)

Task {
    for try await event in handle.events {
        print(event.description)
    }
}

try await runtime.steer(
    threadID: thread.id,
    expectedTurnID: handle.turnID,
    text: "Prioritize concurrency and file I/O bugs."
)

// Later, if needed:
try await runtime.interrupt(threadID: thread.id, expectedTurnID: handle.turnID)
```

## MCP: stdio server

```swift
let filesystem = StdioMCPClient(
    name: "filesystem",
    command: "/usr/bin/npx",
    arguments: [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        FileManager.default.currentDirectoryPath
    ]
)

try await runtime.connectMCP(filesystem)

// MCP tools are registered as function tools named like:
// mcp__filesystem__read_file
```

## MCP: Streamable HTTP server

```swift
let remote = StreamableHTTPMCPClient(
    name: "internal_docs",
    endpoint: URL(string: "https://example.com/mcp")!,
    bearerToken: "optional-token"
)

try await runtime.connectMCP(remote)
```

## System prompt, project instructions, skills, and hosted tools

`AgentConfiguration` lets you append to the default Codex-style system prompt or replace it entirely:

```swift
await runtime.appendSystemInstructions("Prefer minimal diffs and always cite validation commands.")
await runtime.replaceSystemPrompt("You are my custom agent. Follow this system prompt exactly.")
```

Project instruction injection follows the Codex pattern: global `CODEX_HOME`/`~/.codex` instructions first, then project `AGENTS.override.md`, `AGENTS.md`, and configured fallback names from repository root down to the working directory. Injected project docs are represented as user-role input items with an `<INSTRUCTIONS>` wrapper.

Skill injection uses progressive disclosure: the system prompt gets a capped catalog of discovered skills, while full `SKILL.md` content is injected only when a skill is explicitly mentioned, e.g. `$report-writer`, or when simple implicit matching selects it.

iOS apps can bundle skills as data and materialize them into an app-container skill root before starting a turn:

```swift
var config = AgentConfiguration(workspaceURL: workspaceURL)
try config.installEmbeddedSkills([
    EmbeddedAgentSkill(
        name: "artifact-writer",
        description: "Create document, presentation, and spreadsheet artifacts.",
        instructions: "Use the host-provided artifact runtime before inventing a renderer."
    )
], rootURL: appSupport.appendingPathComponent("EmbeddedSkills", isDirectory: true))
// The skill is now callable as $artifact-writer through the normal registry.
```

Hosted Responses tools can be added alongside local Swift function tools:

```swift
await runtime.enableWebSearch(searchContextSize: "medium", externalWebAccess: true)
await runtime.enableImageGeneration(model: "gpt-image-2", size: "1024x1024", outputFormat: "png")
await runtime.addServerTool(.remoteMCP(
    serverLabel: "docs",
    serverURL: URL(string: "https://example.com/mcp")!,
    requireApproval: "never"
))
```

## ChatGPT / Codex auth

For programmatic workflows, API-key auth remains the cleanest path. When you need ChatGPT-managed Codex auth, the package now includes Codex-compatible cache and OAuth helpers:

```swift
// Load ~/.codex/auth.json, refresh when stale or near expiry, and retry once on 401.
let auth = try await ChatGPTAuthProvider.fromCodexAuthFile()
let model = OpenAIResponsesClient(
    auth: auth,
    options: .chatGPTCodexBackend
)
```

Browser login helper:

```swift
let client = CodexChatGPTAuthClient()
let login = client.makeBrowserLoginSession()
print(login.authorizeURL) // open this in the browser

// After the localhost callback, pass the callback URL back in:
let session = try await client.finishBrowserLogin(login, callbackURL: callbackURL)
```

Device-code helper:

```swift
let client = CodexChatGPTAuthClient()
let code = try await client.requestDeviceCode()
print("Open \(code.verificationURL) and enter \(code.userCode)")
let session = try await client.completeDeviceCodeLogin(code)
```

`CodexAuthStore` reads and writes `CODEX_HOME/auth.json` or `~/.codex/auth.json`, using the Codex-shaped `auth_mode`, `tokens`, and `last_refresh` fields. `ChatGPTAuthProvider` refreshes proactively when the token is near expiry or when `last_refresh` is stale, and `OpenAIResponsesClient` triggers one refresh-and-retry on HTTP 401.

## Subagents

```swift
await runtime.installSubagentTool()

let answer = try await runtime.sendMessage(
    threadID: thread.id,
    text: "Use a subagent to review the tests, then summarize the highest-risk issue."
)
```

The subagent tool creates a child thread, links it in `AgentGraphStore`, runs a child turn, closes the child edge, and returns the child thread id plus final text.

## Thread storage

Use `InMemoryThreadStore` for tests and ephemeral sessions. Use `JSONFileThreadStore` for durable local sessions:

```swift
let store = JSONFileThreadStore(
    directoryURL: URL(fileURLWithPath: "/tmp/swift-codex-threads")
)
let runtime = CodexRuntime(modelProvider: model, threadStore: store)
```

`ThreadManager` supports:

- `createThread`
- `listThreads`
- `getThread`
- `appendItem` / `appendItems`
- `forkThread`
- `rollbackThread`
- `archiveThread` / `unarchiveThread`
- `deleteThread`

## Built-in tools

`defaultBuiltinTools()` includes:

- `echo`
- `read_file`
- `write_file`
- `list_files`
- `edit_file`
- `apply_patch` on macOS
- `shell` on macOS when `includeShell` is true

For iOS hosts, use `justBashCodexTools(bash:)` from `CodexCoreJustBash`; it provides the same shell/file/edit/patch surface through the embedded JustBash runtime instead of system processes.

The tools are ordinary Swift types conforming to `AgentTool`, so app-specific tools can be added without changing the agent loop.

```swift
public struct MyTool: AgentTool {
    public let definition = ToolDefinition(
        name: "my_tool",
        description: "Does app-specific work.",
        parameters: ToolSchemas.object(properties: [
            "input": ToolSchemas.string(description: "Input text")
        ], required: ["input"])
    )

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        ToolResult(content: "Got \(try arguments.requiredString("input"))")
    }
}

await runtime.registerTool(MyTool())
```

## Package layout

```text
Sources/CodexCore
  AgentLoop.swift              Core sample/tool/resample loop
  CodexRuntime.swift           High-level app/server facade
  CodexDefaultLocations.swift  Platform-safe default storage locations
  ResponsesModels.swift        Responses request + canonical stream events
  OpenAIResponsesClient.swift  HTTP Responses-compatible transport
  Prompting.swift              Default prompt, AGENTS.md loader, skill discovery/injection
  Tools.swift                  Tool protocol, registry, schemas
  BuiltinTools.swift           Portable file tools plus macOS shell/patch tools
  MCP.swift                    JSON-RPC, Streamable HTTP MCP, macOS stdio MCP
  Auth.swift                   API-key, Codex ChatGPT OAuth/cache/refresh, OAuth helper
  ThreadStorage.swift          In-memory and JSON file thread stores
  Subagents.swift              Agent graph, manager, spawn_subagent tool
  CoreModels.swift             Threads, items, turns, config
  AgentEvent.swift             UI/app-server-friendly event stream
  JSONValue.swift              Arbitrary JSON bridge

Sources/CodexCoreJustBash
  JustBashCodexTools.swift     JustBash-backed CodexRuntime factory and tools
```

## Design rule

Responses is treated as the model transport. The agent is the Swift harness around it: thread state, instructions, tool schemas, tool execution, MCP integration, approvals, steering, persistence, and subagent graph.
