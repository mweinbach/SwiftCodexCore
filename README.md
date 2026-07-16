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
- dynamic Codex-style `/models` discovery with ETag refresh and an offline cache
- GPT-5.6 reasoning, caching, multimodal, compaction, Multi-agent, and programmatic-tool controls
- built-in Responses server-tool definitions for web/file search, image generation, hosted shell, code interpreter, apply patch, skills, computer use, tool search, and remote MCP
- high-level `CodexRuntime` facade for app/server integrations

This is intentionally a core package, not a terminal UI. Use it under a CLI, desktop app, IDE extension, app server, or browser-side controller.

## Status

The package builds and tests with Swift 6.2. `CodexCore` supports macOS and iOS; desktop-only `Process` integrations are macOS-gated. `CodexCoreJustBash` links the sibling `../just-bash-swift` package and provides the on-device tool implementation for iOS hosts.

```bash
swift test
swift run codex-core-example
```

The implementation is production-shaped but not production-hardened. In particular, the local file/shell sandbox is policy enforcement, not an OS-level sandbox; ChatGPT OAuth mirrors the public Codex OAuth/cache/device-code shape but still depends on the live OpenAI auth service accepting the public client flow; and the Responses client streams SSE incrementally through `URLSession.bytes`.

## GPT-5.6 and current Codex alignment

The package was compared against OpenAI Codex at commit [`800715d`](https://github.com/openai/codex/commit/800715d201651a2a07c2706dca10400109dae3d3). Model capabilities are not treated as a permanent Swift table: `OpenAIModelsManager` queries the provider's `/models?client_version=...` endpoint, preserves unknown fields, caches the result for five minutes, and refreshes when a Responses stream returns `X-Models-Etag`. A small Sol/Terra/Luna catalog is retained only for first launch and offline recovery.

The [public GPT-5.6 API documentation](https://developers.openai.com/api/docs/models/gpt-5.6-sol) advertises a 1,050,000-token context window and 128,000 maximum output tokens. The [pinned Codex catalog](https://github.com/openai/codex/blob/800715d201651a2a07c2706dca10400109dae3d3/codex-rs/models-manager/models.json) currently advertises a 372,000-token effective context for Sol, Terra, and Luna. Use the dynamic catalog for runtime behavior; do not assume those two limits are interchangeable.

```swift
let auth = try await ChatGPTAuthProvider.fromCodexAuthFile()
let responseOptions = OpenAIResponsesClient.Options.chatGPTCodexBackend
let models = OpenAIModelsManager(
    auth: auth,
    options: .derivedFromResponsesEndpoint(
        responseOptions.endpoint,
        clientVersion: "1.0.0" // your host app version
    )
)

let catalog = await models.catalog()
var config = AgentConfiguration()
if let selected = catalog.defaultModel {
    config.applyModelDefaults(selected)
}

let model = OpenAIResponsesClient(
    auth: auth,
    options: responseOptions,
    modelsManager: models
)
```

Detailed Codex catalogs are authoritative. The standard OpenAI `/v1/models` shape is also accepted; its IDs are merged with fallback metadata because that endpoint does not currently return the full Codex capability record.

## Quick start with API-key auth

```swift
import Foundation
import CodexCore

let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!
let auth = APIKeyAuthProvider(apiKey: apiKey)
let model = OpenAIResponsesClient(auth: auth)

var config = AgentConfiguration(
    model: OpenAIModel.gpt56Sol.rawValue,
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
        model: OpenAIModel.gpt56Luna.rawValue,
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
let handle = try await runtime.startTurn(
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

## GPT-5.6 Responses controls

GPT-5.6 request controls are available at both the low-level `ResponsesRequest` layer and the high-level agent loop:

```swift
var config = AgentConfiguration(
    model: OpenAIModel.gpt56Terra.rawValue,
    reasoningEffort: .max,
    reasoningMode: .pro,
    reasoningContext: .allTurns,
    serviceTier: "priority",
    promptCacheOptions: PromptCacheOptions(mode: .explicit),
    safetyIdentifier: "<stable-user-hash>",
    maxOutputTokens: 128_000,
    multiAgent: MultiAgentConfiguration(maxConcurrentSubagents: 3),
    textOptions: ResponseTextOptions(verbosity: .low)
)
config.serverTools = [
    .programmaticToolCalling(),
    .hostedShell(allowedCallers: [.direct, .programmatic]),
    .applyPatch(allowedCallers: [.programmatic]),
    .toolSearch()
]
```

The client automatically sends the Multi-agent beta header, suppresses unsupported reasoning summaries during Multi-agent runs, exposes only the root `final_answer` as the user-facing completion, and preserves agent/program/reasoning items for the next stateless request. Programmatic function calls retain their `caller` linkage through local execution and `function_call_output`.

Multimodal high-level turns accept the same content blocks as the Responses API:

```swift
let input = TurnInput(content: [
    ResponseInputBuilder.inputText("Inspect this screenshot"),
    ResponseInputBuilder.inputImage(
        urlString: "<data:image/png;base64,...>",
        detail: .original
    )
])
let handle = try await runtime.startTurn(threadID: thread.id, input: input)
```

Server-side compaction can be selected manually with `contextManagement`, or populated from the dynamic model metadata by `applyModelDefaults`. Compaction output is stored and replayed while obsolete pre-compaction conversation items are pruned. For explicit stateless control, call `OpenAIResponsesClient.compactResponse(_:)` and pass its complete `output` into the next Responses request.

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
  OpenAIModels.swift           Dynamic model catalog, cache, ETag refresh, fallbacks
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
