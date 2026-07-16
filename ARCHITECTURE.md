# Architecture

SwiftCodexCore mirrors the Codex harness shape at a package level.

## Runtime layers

```text
App / CLI / IDE / local server
        ↓
CodexRuntime
  - thread lifecycle
  - active turn handles
  - steering / interrupt
  - MCP registration
  - subagent tool installation
        ↓
CodexAgent
  - build model input from thread items
  - send Responses request
  - consume model stream events
  - execute tool calls
  - append tool outputs
  - resample until final answer
  - delegate exec/wait cells to CodeModeRuntime
        ↓
ModelProvider
  - OpenAIResponsesClient
  - ScriptedModelProvider for tests
  - any Responses-compatible provider
```

## Core loop

```text
turn/start
  append userMessage item
  build PromptAssembly:
    default/append/replaced system prompt
    AGENTS.md injected input items
    capped skill catalog + selected full SKILL.md items
  build ResponsesRequest:
    assembled instructions
    injected context + thread history as input items
    local/code-mode tools selected by AgentToolMode
    hosted Responses tools allowed by mode and sandbox
  send request
  stream text/reasoning/tool-call events
  if tool calls:
    append toolCall item
    execute local/MCP/subagent tool
    append toolResult item
    rebuild input
    send another request
  else:
    append assistantMessage item
    turn/completed
```

## Event model

The core emits `AgentEvent` values that are intentionally close to app-server notifications:

- `turnStarted`
- `itemStarted`
- `itemDelta`
- `itemCompleted`
- `reasoningDelta`
- `toolStarted`
- `toolCompleted`
- `approvalRequested`
- `modelCatalogChanged`
- `turnCompleted`
- `warning`
- `error`

A UI can render a live transcript from the event stream while `ThreadStore` persists the durable timeline.

## Threads and items

A thread is a durable session. A turn is one agent unit of work. A thread item is the typed persistent record of what happened.

Important item kinds:

- `userMessage`
- `assistantMessage`
- `toolCall`
- `mcpToolCall`
- `dynamicToolCall`
- `subagentToolCall`
- `webSearch`
- `imageGeneration`
- `toolResult`
- `reasoning`
- `fileChange`
- `contextCompaction`

Only model-relevant items are converted back into Responses input:

- injected AGENTS.md and selected SKILL.md instruction items
- user/developer/assistant messages
- function calls
- function call outputs
- hosted server-tool output items such as web search and image generation

`toolResult` items retain a plain display string, structured content, typed content blocks, and the exact JSON wire output. This lets resumed stateless turns replay native text/image output items without reducing them to a JSON-encoded string. Older persisted results without `wire_output` continue to replay their plain `content` value.

## Responses transport

`ModelProvider` is the abstraction. `OpenAIResponsesClient` serializes `ResponsesRequest` to `/v1/responses` or another compatible endpoint and maps raw response/SSE objects into canonical `ModelStreamEvent` values.

The loop depends on canonical events, not provider-specific JSON:

- `outputTextDelta`
- `reasoningDelta`
- `toolCallDelta`
- `toolCallCompleted`
- `serverToolCompleted`
- `messageCompleted`
- `completed`
- `failed`
- `modelCatalogETag`
- `raw`

The client applies one `ResponsesTransportPolicy` to streaming and non-streaming operations. A logical request keeps the same `X-Client-Request-Id` and, for POST, `Idempotency-Key` across HTTP retries and the separate one-time 401 credential refresh. The default policy retries 429, 5xx, and eligible connection failures twice with bounded exponential backoff, honoring capped `Retry-After-Ms` or `Retry-After`. An interrupted stream is replayable only before a semantic model event; after any text, reasoning, tool, failure, or completion event it is terminal. Cancellation is checked during backoff and body/SSE collection.

Foreground streams consult the dynamic catalog and use WebSocket transport only when the model advertises `prefer_websockets`, the provider gate is enabled, and the client has not sticky-disabled WebSockets after an earlier connection failure. The WebSocket handshake preserves auth, provider headers, Lite/Multi-agent betas, endpoint path/query, and the logical HTTP identity; the first frame is the normalized Responses body plus `type: response.create`. Text frames share the SSE event mapper. A pre-semantic failure falls back to HTTP with the same identity, while cancellation or any post-semantic failure is terminal to prevent duplicated deltas. Connections are currently per request rather than pooled or prewarmed.

`ResponsesTransportDiagnostic` separates rate-limit signals, scheduled retries, and terminal failures. It carries the logical request identity, network attempt, status, server request ID, delay, URL, and message without coupling the transport to a logging framework.

## Dynamic model catalog

`OpenAIModelsManager` accepts either the detailed Codex `models` shape or the standard OpenAI `data` shape. `OpenAIModelInfo` stores arbitrary fields and provides typed accessors for known reasoning, context, truncation, verbosity, Responses-lite, tool-mode/tool-type, image, search, parallel-call, WebSocket, Multi-agent, and minimum-client capabilities.

Catalog resolution has three explicit strategies:

- `.online` awaits a single-flight network refresh and conditionally validates a cached ETag.
- `.offline` performs no network access and may use a stale matching cache.
- `.onlineIfUncached` returns a fresh cache or serves a valid stale cache while one refresh runs in the background.

Disk snapshots are scoped to the canonical provider endpoint and client version. The manager rejects invalid or duplicate identifiers, handles 304 responses, and records structured resolution diagnostics. A detailed visible Codex catalog is authoritative. Sparse standard OpenAI results are merged with the bundled GPT-5.6 records; fallback usage is explicit on the snapshot and diagnostics.

`AgentConfiguration.applyModelDefaults` copies only values the host has not chosen. It can select the exact reasoning effort, including future raw values, service tier, parallel calls, tool mode, reasoning summary, verbosity, Responses-lite shaping, code-mode output/image policy, and compaction threshold.

When `useResponsesLite` is enabled, request assembly canonicalizes function/custom tools into one leading `additional_tools` developer item, moves assembled instructions into a developer message, omits top-level `tools` and `instructions`, forces `parallel_tool_calls` off, and forces reasoning context to `all_turns`. Image detail is removed, remote image URLs are replaced with an omission marker, and the transport adds the internal Responses Lite header. The low-level request and compaction encoders apply the same idempotent rules. This flag is an internal shaping signal and is not serialized as a JSON field itself.

## Prompting, AGENTS.md, and skills

`PromptAssembler` owns per-turn prompt construction. With `systemPromptMode = .append`, it starts from the built-in Codex-style system prompt and appends user/system additions. With `.replace`, the configured `instructions` string becomes the entire system prompt.

`ProjectInstructionLoader` discovers global and project instructions in this order: Codex home `AGENTS.override.md` or `AGENTS.md`, then one instruction file per directory from repository root to current working directory. It respects configured fallback names and a byte cap.

`SkillRegistry` discovers local `SKILL.md` manifests under repo, user, admin, system, and additional roots. The initial prompt gets a capped catalog containing skill names and descriptions, not local file paths. Full skill instructions are added as injected input items only for explicit `$skill` mentions or implicit description matches.

## Hosted Responses tools

`ResponseToolDefinition` is intentionally flexible: it can encode local function tools, `web_search`, `image_generation`, remote hosted MCP tools, and arbitrary future Responses tool objects. Hosted tool completion events are persisted as typed thread items and replayed as model input.

## Tools

Tools conform to `AgentTool`:

```swift
var definition: ToolDefinition { get }
func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult
```

`ToolRegistry` owns dispatch. It enforces approval policy before executing risky or state-changing tools.

`ToolResult.content` is the plain-text compatibility representation. `structuredContent` and `codeModeResult` preserve programmatic values, while future-compatible `ToolContentBlock` records retain text, image, audio, resource, and unknown fields. Text and image blocks become native Responses output items when representable; MCP text marked with `_meta["codex/encryptedContent"] = true` becomes `encrypted_content` and forces the typed content payload to win over `structuredContent`. Other combinations use a JSON compatibility envelope. Code-mode nested calls prefer `codeModeResult`, then `structuredContent`, then typed/plain output, with an independently bounded token budget.

`ToolDefinition.exposure` and its optional namespace determine direct and code-mode visibility:

- `.direct` is direct in normal/hybrid mode and eligible inside code.
- `.deferred` is available only inside code through `ALL_TOOLS` and `tools.*`.
- `.directModelOnly` is direct but never nested.
- `.hidden` is never model-visible.

## Code mode

`AgentToolMode` has three distinct dispatch shapes:

| Mode | Direct local tools | `exec` / `wait` | Hosted server tools |
| --- | --- | --- | --- |
| `.direct` | direct and direct-model-only | No | All configured |
| `.codeMode` | direct and direct-model-only | Yes | All configured |
| `.codeModeOnly` | direct-model-only and direct-only namespaces | Yes | `directServerToolTypes` only |

`CodeModeOptions` additionally excludes namespaces from nested code, reserves namespaces for direct exposure, bounds concurrent cells and nested output, selects default yield/output budgets, limits both individual content blocks and cumulative cell output bytes, and controls original image detail. MCP tools receive `mcp__<server>` namespaces; JavaScript identifiers and nested paths are normalized without changing the registry's underlying tool name.

`CodeModeRuntime` owns cell IDs, incremental cursors, yield versions, thread-scoped store deltas, eviction, output accounting, and diagnostics. The pluggable `CodeModeEngine` owns execution. `yield_control` wakes a waiter, and each subsequent `wait` returns only unseen content. `notify` bypasses cell content and emits a typed `CodeModeNotification` plus a distinct custom-tool output for the next model request. Archiving a thread terminates its cells; hosts can explicitly clear the thread-scoped code-mode store with `terminateCells(threadID:clearStore:)`.

`AutomaticCodeModeEngine` is the default. On macOS it uses `ProcessCodeModeEngine` only for an executable selected by `SWIFT_CODEX_CODE_MODE_HOST`, bundle adjacency, or `argv[0]` adjacency. A host may instead inject an explicit executable URL. Discovery never searches the current working directory or `PATH`. If no trusted helper is available, and on iOS, it uses `JavaScriptCoreCodeModeEngine` in process.

The process engine starts one packaged `codex-code-mode-host` per cell and exchanges newline-delimited JSON over pipes. JavaScript has no Node, filesystem, network, or console globals; nested tool calls cross back to the parent `ToolRegistry`, where approvals and sandbox checks still run. Termination closes the protocol, sends `SIGTERM`, and escalates to `SIGKILL` after the configured grace period, so synchronous non-yielding JavaScript can be stopped. The helper gets only the explicitly supplied environment, empty by default. The in-process engine has the same JavaScript surface but cannot hard-interrupt synchronous execution.

## MCP

`MCPClient` abstracts MCP servers:

- `StdioMCPClient`
- `StreamableHTTPMCPClient`

`MCPRegistry` lists server tools and registers them into `ToolRegistry` as `mcp__server__tool` function tools.

## Steering

`TurnHandle` owns a `TurnControl` actor. Steering adds pending input to the active turn. The loop drains that pending input between model/tool iterations and appends it as another user message in the same turn. Interrupt marks the active turn as interrupted.

## Subagents

`SubagentManager` creates child threads and records parent/child edges in `AgentGraphStore`. `SpawnSubagentTool` exposes this to the model as a tool. The child agent uses the same model/tool/thread infrastructure unless you pass a model override.

## Auth

- `APIKeyAuthProvider` adds platform API-key bearer headers.
- `CodexAuthStore` reads and writes Codex-shaped `CODEX_HOME/auth.json` / `~/.codex/auth.json`.
- `CodexChatGPTAuthClient` implements the public Codex browser-login helper shape, device-code user-code/token polling, OAuth token exchange, JWT claim extraction, and persistence.
- `ChatGPTAuthProvider` loads cached Codex sessions, refreshes near expiry or after stale `last_refresh`, and exposes bearer headers with `ChatGPT-Account-Id` when available.
- `OpenAIResponsesClient` retries once after HTTP 401 by invoking `TokenRefreshingAuthorizationProvider.refreshNow()`.
- `OAuthDeviceFlowClient` remains available for generic host-owned OAuth clients.

## Security boundaries

`SandboxPolicy` controls whether tools may read files, write files, execute shell commands, and access network-enabled tools. This is policy enforcement, not an OS jail. The macOS helper adds a killable process boundary around JavaScript only; nested Swift/MCP tools execute in the parent process and retain whatever capabilities their implementations and policy allow. The iOS and helper-unavailable paths execute JavaScript in process. Apps should still add platform sandboxing, command allow-lists, credential isolation, network controls, and human approvals before exposing state-changing tools to untrusted prompts.
