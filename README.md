# SwiftCodexCore

A SwiftPM package that implements a Codex-style agent core in Swift:

- Responses-compatible model transport with bounded retries, stable request identity, and diagnostics
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
- dynamic Codex-style `/models` discovery with ETag refresh, scoped caching, diagnostics, and offline fallback
- GPT-5.6 reasoning, caching, multimodal, compaction, Multi-agent, programmatic-tool, and model-advertised runtime controls
- Codex-compatible `code_mode` and `code_mode_only` execution with `exec`, `wait`, typed content, and pluggable JavaScript engines
- a packaged macOS code-mode helper for process-isolated JavaScript execution, with a terminable WebKit worker host on iOS
- built-in Responses server-tool definitions for web/file search, image generation, hosted shell, code interpreter, apply patch, skills, computer use, tool search, and remote MCP
- high-level `CodexRuntime` facade for app/server integrations

This is intentionally a core package, not a terminal UI. Use it under a CLI, desktop app, IDE extension, app server, or browser-side controller.

## Status

The package uses Swift tools 6.0. `CodexCore` supports macOS 15 and iOS 18; desktop-only `Process` integrations are macOS-gated. `CodexCoreJustBash` depends on `just-bash-swift` and provides the on-device tool implementation for iOS hosts.

```bash
swift test
swift run codex-core-example
```

When developing coordinated changes with the sibling JustBash checkout, use `swift package edit just-bash-swift --path ../just-bash-swift` before building this package. The editable override is local and keeps the tracked remote pin unchanged. The unreleased per-invocation network-policy adapter requires the matching sibling changes until that JustBash revision is published and pinned. Cowork's development workspace already supplies its sibling package override.

The implementation is production-shaped but not production-hardened. In particular, the local file/shell sandbox is policy enforcement, not an OS-level sandbox; code-mode process isolation covers JavaScript execution but not the Swift tool implementations it invokes; ChatGPT OAuth mirrors the public Codex OAuth/cache/device-code shape but still depends on the live OpenAI auth service accepting the public client flow; and the Responses client uses one WebSocket per preferred request rather than upstream's connection pooling and prewarming optimizations.

## Validation and upstream parity

CI validates the pinned OpenAI Codex contracts, builds the process-isolated code-mode helper, runs the Swift tests, performs a release build, and builds `CodexCore` for a generic iPhoneOS device. The equivalent local checks are:

```bash
swift build --product codex-code-mode-host
SWIFT_CODEX_CODE_MODE_HOST_TEST_EXECUTABLE="$(swift build --show-bin-path)/codex-code-mode-host" swift test
swift build --configuration release
python3 Scripts/check_upstream_parity.py
```

`UpstreamParity/codex.json` pins the upstream commit, source hashes, GPT-5.6 catalog facts, tool-mode schema/dispatch contracts, raw-response cache-write usage, and MCP encrypted-content output semantics. A daily workflow also runs `python3 Scripts/check_upstream_parity.py --check-upstream-head` to signal that upstream `main` moved. This is a focused drift detector, not a claim of complete behavioral parity, and it never updates the pin automatically.

## GPT-5.6 and current Codex alignment

The package pins focused compatibility contracts from OpenAI Codex commit [`d58d0e5`](https://github.com/openai/codex/commit/d58d0e5841e0de08e251673db2d5af8cf3a1ad51). Model capabilities are not treated as a permanent Swift table: `OpenAIModelsManager` queries the provider's `/models?client_version=...` endpoint, preserves unknown fields, caches the result for five minutes by default, and reacts to `X-Models-Etag` signals from Responses streams. The bundled Sol/Terra/Luna records provide first-launch and offline recovery and enrich the sparse standard OpenAI `/v1/models` shape; a detailed Codex catalog is authoritative.

The [public GPT-5.6 API documentation](https://developers.openai.com/api/docs/models/gpt-5.6-sol) advertises a 1,050,000-token context window and 128,000 maximum output tokens. The [pinned Codex catalog](https://github.com/openai/codex/blob/d58d0e5841e0de08e251673db2d5af8cf3a1ad51/codex-rs/models-manager/models.json) currently advertises a 272,000-token base context and an 872,000-token maximum configurable context for Sol, Terra, and Luna. Use the dynamic catalog for runtime behavior; do not assume those two limits are interchangeable.

```swift
let auth = try await ChatGPTAuthProvider.fromCodexAuthFile()
let responseOptions = OpenAIResponsesClient.Options.chatGPTCodexBackend
let models = OpenAIModelsManager(
    auth: auth,
    options: .derivedFromResponsesEndpoint(responseOptions.endpoint)
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

`catalog()` defaults to `.onlineIfUncached`: it returns a fresh memory/disk cache, or returns a valid stale cache immediately while one single-flight refresh runs in the background. Use `.online` to await conditional ETag validation and `.offline` to prohibit network access. Cached snapshots are accepted only for the same canonical endpoint and client version, and malformed, empty, or duplicate model records are rejected. `lastDiagnostics` reports the resolution source, staleness, in-flight refresh state, ETag, fallback usage, and last error.

`Options.defaultClientVersion` is `0.144.0`, the Codex wire compatibility baseline recorded by the pinned bundled catalog, independent of an app's marketing version. Overrides always become a whole numeric version: `1.0` becomes `1.0.0`, prerelease/build suffixes are stripped, and malformed input uses the compatibility baseline. Normalization also applies when mutating options, so request and cache identities agree.

`OpenAIModelInfo` exposes known capabilities such as exact reasoning levels, context and truncation limits, default verbosity and reasoning summary, Responses-lite preference, tool mode and tool types, image detail, search, parallel calls, WebSocket preference, Multi-agent version, and minimum client version while retaining future fields in `fields`. `applyModelDefaults` copies supported defaults into unset host configuration, including unknown reasoning-effort wire values through `reasoningEffortName`, code-mode limits, original-image policy, and automatic compaction for standard Responses. Responses Lite does not support server-side automatic compaction, so its defaults omit `context_management`. Explicit host choices remain intact for request validation. When the client has the same models manager, `prefer_websockets` also selects WebSocket streaming unless `OpenAIResponsesClient.Options.supportsWebSockets` is disabled.

When metadata enables `use_responses_lite`, the agent uses the upstream Lite envelope: supported tools become one canonical leading `additional_tools` developer item, assembled instructions become a developer message, top-level tools/instructions are omitted, parallel tool calls are disabled, reasoning context is forced to `all_turns`, and image input is normalized for Lite constraints. Function/custom tools, web search, tool search, and explicit namespaces are retained; unverified hosted tool types are excluded. Network policy still controls whether hosted search is offered. The low-level request encoder applies the same idempotent shaping, and standalone compaction uses the same body and internal Responses Lite header contract.

## Code mode and tool exposure

When model metadata advertises `tool_mode`, `applyModelDefaults` selects the matching `AgentToolMode`. Every nested call still passes through the Swift `ToolRegistry`, approval handler, and sandbox policy.

| Mode | Direct local tools shown to the model | Code tools | Hosted server tools |
| --- | --- | --- | --- |
| `.direct` | `.direct` and `.directModelOnly` | None | All configured types |
| `.codeMode` | `.direct` and `.directModelOnly` | `exec` and `wait` | All configured types |
| `.codeModeOnly` | `.directModelOnly` plus tools in `directOnlyToolNamespaces` | `exec` and `wait` | Types in `directServerToolTypes`; web search types by default |

Inside `exec`, `.direct` and `.deferred` tools are available through `tools.*` and `ALL_TOOLS` unless their namespace is excluded or direct-only. `.hidden` and `.directModelOnly` tools are never nested. MCP adapters use `mcp__<server>` namespaces and expose normalized paths such as `tools.server.tool(...)`.

Tools and hosts can configure the exposure boundary directly:

```swift
let definition = ToolDefinition(
    name: "lookup_symbol",
    description: "Looks up a symbol.",
    parameters: ToolSchemas.object(properties: [:]),
    exposure: .deferred, // available in ALL_TOOLS and tools.*, not directly
    namespace: "market_data"
)

// Other choices: .direct, .directModelOnly, and .hidden.
var config = AgentConfiguration(
    toolMode: .codeModeOnly,
    codeModeOptions: CodeModeOptions(
        excludedToolNamespaces: ["internal"],
        directOnlyToolNamespaces: ["host_ui"],
        directServerToolTypes: ["web_search"]
    )
)
```

Each `exec` call gets a fresh restricted JavaScript cell without Node, filesystem, network, or console globals. It supports parallel async nested tools, typed `text`/`image`/`generatedImage` output, independent progress through `notify`, thread-scoped `store`/`load`, timers, `exit`, `yield_control`, the upstream Lark grammar, first-line execution pragmas, and incremental `wait` polling. In `code_mode_only`, the `exec` description includes every eager nested tool's exact input/output schemas. `notify` produces a typed agent event and a separate custom-tool output without entering `exec`/`wait` content or forcing a yield. Output budgets use an injectable token counter; `CodeModeOptions` also bounds concurrent cells, nested results, individual content blocks, cumulative cell output, default yield time, and original-image detail.

`CodexRuntime` uses `AutomaticCodeModeEngine` by default. On macOS it selects the packaged `codex-code-mode-host` only when `SWIFT_CODEX_CODE_MODE_HOST` names it or it is found beside the app bundle executable or `argv[0]`; it never scans the current working directory or `PATH`. A host can bypass discovery by passing `ProcessCodeModeEngine(executableURL:)` to `CodexRuntime`. Unbundled macOS command-line processes retain the in-process `JavaScriptCoreCodeModeEngine` fallback for non-GUI compatibility.

On iOS, the automatic engine is `WebKitCodeModeEngine`. It keeps a hidden, nonpersistent `WKWebView` as a trusted relay in a private content world and starts a dedicated Blob Web Worker for each cell. Page JavaScript is disabled, a restrictive content-security policy blocks network egress, browser/bridge globals are removed from both normal lookup and their native prototype descriptors, and native tool calls cross a token-authenticated reply channel. The relay enforces configured event limits before native decoding. `Worker.terminate()` lets `wait(... terminate: true)` stop synchronous non-yielding code without blocking the app. `JavaScriptCoreCodeModeEngine` remains available as an explicit lightweight fallback, and `JustBashCodexFactory.makeEnvironment` accepts a custom `codeModeEngine` when an app wants to supply one.

The macOS process engine starts one helper per cell and can terminate synchronous non-yielding JavaScript with `SIGTERM` followed by `SIGKILL` after a grace period. The helper receives only the environment explicitly supplied to `ProcessCodeModeEngine` (empty by default), and nested tool execution remains in the parent process. This is a hard lifecycle boundary for JavaScript, not an OS sandbox for Swift tools, credentials, filesystem access, or network access. WebKit protects the iOS app process and gives each cell a terminable Worker, but iOS may pool multiple workers into one WebContent process; it is not a guaranteed OS process per cell. Foreground/background WebKit scheduling remains subject to iOS lifecycle policy. The explicit in-process engine cannot preempt synchronous non-yielding JavaScript.

## Responses transport reliability

`OpenAIResponsesClient` applies `ResponsesTransportPolicy.default` to streaming, background, retrieval, cancellation, and compaction requests. The default retries HTTP 429 and 5xx responses and eligible connection failures twice after the initial attempt, starting at 0.5 seconds with exponential backoff capped at 30 seconds. `Retry-After-Ms` and numeric or HTTP-date `Retry-After` values take precedence but remain capped. An interrupted response stream is replayed only when no semantic model event has been emitted; after any text, tool, reasoning, failure, or completion event, the error is terminal so deltas cannot be duplicated.

```swift
let model = OpenAIResponsesClient(
    auth: auth,
    transportPolicy: ResponsesTransportPolicy(
        maximumRetryCount: 2,
        initialBackoff: 0.5,
        maximumBackoff: 30
    ),
    diagnostics: { event in
        print("Responses transport: \(event.kind) attempt \(event.attempt)")
    }
)
```

Each request gets a stable `X-Client-Request-Id`; POST requests also get a stable `Idempotency-Key`. Both survive retries and the separate one-time 401 token-refresh attempt. Diagnostics distinguish `rateLimited`, `retryScheduled`, and terminal `requestFailed` events and include client/server request IDs, attempt, status, delay, URL, and message. Cancellation interrupts backoff and body/SSE collection and propagates as `CancellationError`.

For foreground streaming requests, the client consults its dynamic model catalog. When the selected model advertises `prefer_websockets` and the provider gate is enabled, it connects to the matching `ws`/`wss` endpoint, sends a `response.create` text frame, and decodes each response event through the same canonical event mapper used by SSE. Authentication, extra headers, Lite and Multi-agent headers, request identity, endpoint path, and query are preserved. A 401 can refresh credentials once; any failure before semantic output disables WebSockets for that client instance and falls back to HTTP with the same identity. Cancellation and failures after semantic output never replay over HTTP. This initial implementation intentionally uses one connection per request rather than pooling or prewarming.

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

Interruption cancels the actual turn task, stops dispatching remaining tool calls, and waits for cooperative tools and code cells to finish cleanup. A cancelled tool receives a persisted error output so the next turn can replay a complete call/result pair. `handle.waitForCompletion()` waits without consuming its event stream; a completed handle cannot interrupt later work on the same thread. Swift tool implementations must cooperate with task cancellation. The embedded JustBash adapter does not advertise a per-command wall-clock timeout because its pinned shell API cannot enforce one.

For local child agents, install the bounded lifecycle tools once per chat runtime:

```swift
let agents = await runtime.installSubagentTool(maxDepth: 3, maxConcurrentAgents: 3)
let child = try await agents.spawn(parentThreadID: thread.id, prompt: "Inspect the tests.")
let snapshot = try await agents.wait(threadID: child.threadID, timeoutMilliseconds: 10_000)
// snapshot.state is running, completed, interrupted, or failed.
_ = try await agents.send(threadID: child.threadID, text: "Also inspect cancellation coverage.")
await agents.interruptAll()
await runtime.shutdown()
```

The model receives `spawn_agent`, `send_input`, `wait_agent`, `interrupt_agent`, and `list_agents`, plus the blocking `spawn_subagent` compatibility tool. Child threads share the configured workspace, tools, approvals, and code-mode engine. Their depth follows persisted ancestry; active and starting runs share the concurrency limit. A model can control only its descendants. Normal parent completion allows children to finish; Stop cancels chat-owned child work. `shutdown()` closes the runtime to further turns and disconnects its MCP servers. Keep one runtime per chat to retain this lifecycle across sends. `updateConfiguration` propagates new defaults and policies to future child turns while preserving explicit child model overrides; running turns retain their starting configuration.

Reuse one `ChatGPTAuthProvider` for an account's model catalog and Responses clients. Concurrent expired-session requests share one refresh. After stopping account-owned runtimes, `try await auth.invalidate()` revokes the provider and clears its configured stores; a late refresh cannot restore credentials. Pass `clearStores: false` when replacing only an in-memory provider.

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

Streamable HTTP supports negotiated protocol/session headers, paginated tool/resource catalogs, and matching JSON or SSE responses. Tool refresh and `runtime.disconnectMCP(serverName:)` remove stale adapters; disconnect attempts server-session deletion. A supplied `authorizationProvider:` can implement host-owned OAuth and token refresh, including one retry after HTTP 401. The package does not launch an OAuth browser flow or import desktop credentials automatically. An expired MCP session surfaces a reconnection error instead of silently replaying tool calls. MCP mutation tools request approval unless the server explicitly advertises `readOnlyHint` or the host's approval policy is `.never`.

For virtual filesystems, set `SkillInjectionOptions.pathMappings` to `[PromptPathMapping(physicalRoot: workspaceRoot, virtualRoot: "/")]`. Skill catalogs, activated skill directories, and instruction source labels then use virtual paths while discovery and reads continue using their actual URLs.

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

`ToolResult.content` remains the plain-text compatibility value. Tools can also return `structuredContent`, a native `codeModeResult`, and future-compatible `ToolContentBlock` values:

```swift
ToolResult(
    content: "Generated a preview.",
    structuredContent: .object(["width": .number(1_024)]),
    contentBlocks: [
        .text("Generated a preview."),
        .image(imageURL: "data:image/png;base64,...", detail: .original)
    ],
    codeModeResult: .object(["status": .string("ready")])
)
```

Text and image blocks map to native Responses output items when possible; MCP text marked with `_meta["codex/encryptedContent"] = true` maps to an `encrypted_content` item and takes precedence over `structuredContent`, matching current Codex behavior. Audio, resource, unknown, or otherwise unmappable blocks survive in a JSON compatibility envelope. The agent persists both the display text and exact wire output so resumed stateless turns preserve typed content. Code-mode callers receive `codeModeResult`, then `structuredContent`, then typed/plain content in that priority order. MCP adapters retain the server's typed blocks, structured content, metadata, error state, and full programmatic result.

## Package layout

```text
Sources/CodexCore
  AgentLoop.swift              Core sample/tool/resample loop
  CodexRuntime.swift           High-level app/server facade
  CodexDefaultLocations.swift  Platform-safe default storage locations
  ResponsesModels.swift        Responses request + canonical stream events
  OpenAIModels.swift           Dynamic model metadata, scoped cache, ETag refresh, fallbacks
  OpenAIResponsesClient.swift  HTTP/SSE Responses transport, retry and WS selection
  OpenAIResponsesWebSocket.swift URLSession WebSocket adapter and sticky fallback state
  TransportPolicy.swift        Retry policy and structured transport diagnostics
  CodeMode.swift               Cell lifecycle, exec/wait tools, state, and output budgets
  CodeModeTypes.swift          Engine/session protocols, tool routing, typed result encoding
  CodeModeJavaScriptProgram.swift Restricted JavaScript surface shared by both engines
  CodeModeJavaScriptCore.swift In-process JavaScriptCore engine
  CodeModeProcessEngine.swift  macOS helper-process client and hard termination
  CodeModeProcessHost.swift    macOS helper-process protocol server
  Prompting.swift              Default prompt, AGENTS.md loader, skill discovery/injection
  Tools.swift                  Tool protocol, registry, schemas, and typed content
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

Sources/CodexCodeModeHost
  main.swift                   Packaged codex-code-mode-host executable

UpstreamParity/codex.json      Pinned upstream sources and focused contracts
Scripts/check_upstream_parity.py
.github/workflows              Push/PR validation and scheduled upstream drift check
```

## Design rule

Responses is treated as the model transport. The agent is the Swift harness around it: thread state, instructions, tool schemas, tool execution, MCP integration, approvals, steering, persistence, and subagent graph.
