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
    local function tools + hosted Responses tools
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
- `raw`


## Prompting, AGENTS.md, and skills

`PromptAssembler` owns per-turn prompt construction. With `systemPromptMode = .append`, it starts from the built-in Codex-style system prompt and appends user/system additions. With `.replace`, the configured `instructions` string becomes the entire system prompt.

`ProjectInstructionLoader` discovers global and project instructions in this order: Codex home `AGENTS.override.md` or `AGENTS.md`, then one instruction file per directory from repository root to current working directory. It respects configured fallback names and a byte cap.

`SkillRegistry` discovers local `SKILL.md` manifests under repo, user, admin, system, and additional roots. The initial prompt gets a capped skill catalog with name, description, and path. Full skill instructions are added as injected input items only for explicit `$skill` mentions or implicit description matches.

## Hosted Responses tools

`ResponseToolDefinition` is intentionally flexible: it can encode local function tools, `web_search`, `image_generation`, remote hosted MCP tools, and arbitrary future Responses tool objects. Hosted tool completion events are persisted as typed thread items and replayed as model input.

## Tools

Tools conform to `AgentTool`:

```swift
var definition: ToolDefinition { get }
func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult
```

`ToolRegistry` owns dispatch. It enforces approval policy before executing risky or state-changing tools.

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

`SandboxPolicy` controls whether tools may read files, write files, execute shell commands, and access network-enabled tools. This is not an OS jail. Apps embedding this package should add platform-specific sandboxing, process isolation, command allow-lists, and human approvals before exposing shell/file-write tools to untrusted prompts.
