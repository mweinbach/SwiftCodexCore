import Foundation
import JavaScriptCore

/// Codex-compatible local JavaScript execution for models advertising
/// `tool_mode: code_mode_only`. Each call gets a fresh JavaScriptCore context;
/// the runtime intentionally exposes no Node, filesystem, network, or console
/// globals. Agent tools remain behind `ToolRegistry`, so normal approval and
/// sandbox checks still apply to calls made through `tools.*`.
public actor CodeModeRuntime {
    public static let execToolName = "exec"
    public static let waitToolName = "wait"

    private let registry: ToolRegistry
    private struct RunningCell: Sendable {
        var threadID: String
        var task: Task<ToolResult, Never>
    }
    private var cells: [String: RunningCell] = [:]
    private var sessionStores: [String: [String: JSONValue]] = [:]

    public init(registry: ToolRegistry) {
        self.registry = registry
    }

    public func execute(
        source: String,
        definitions: [ToolDefinition],
        context: ToolExecutionContext
    ) async -> ToolResult {
        let options = Self.parsePragma(source)
        let cellID = UUID().uuidString.lowercased()
        let store = sessionStores[context.threadID] ?? [:]
        let task = Task.detached { [registry] in
            await CodeModeCell.run(
                source: source,
                definitions: definitions,
                registry: registry,
                context: context,
                initialStore: store,
                maxOutputTokens: options.maxOutputTokens
            )
        }
        cells[cellID] = RunningCell(threadID: context.threadID, task: task)

        if let result = await Self.firstResult(of: task, afterMilliseconds: options.yieldTimeMilliseconds) {
            cells.removeValue(forKey: cellID)
            mergeStore(from: result, threadID: context.threadID)
            return Self.withoutStoreMetadata(result)
        }
        return ToolResult(
            content: "Script running with cell ID \(cellID).",
            metadata: ["cell_id": .string(cellID), "running": .bool(true)]
        )
    }

    public func wait(arguments: JSONValue) async -> ToolResult {
        guard let cellID = arguments["cell_id"]?.stringValue, let cell = cells[cellID] else {
            return ToolResult(content: "Unknown or completed code-mode cell.", isError: true)
        }
        if arguments["terminate"]?.boolValue == true {
            cell.task.cancel()
            cells.removeValue(forKey: cellID)
            return ToolResult(content: "Terminated code-mode cell \(cellID).")
        }
        let milliseconds = Self.clampedMilliseconds(arguments["yield_time_ms"]?.doubleValue.map(Int.init) ?? 10_000)
        if let result = await Self.firstResult(of: cell.task, afterMilliseconds: milliseconds) {
            cells.removeValue(forKey: cellID)
            mergeStore(from: result, threadID: cell.threadID)
            return Self.withoutStoreMetadata(result)
        }
        return ToolResult(
            content: "Script still running with cell ID \(cellID).",
            metadata: ["cell_id": .string(cellID), "running": .bool(true)]
        )
    }

    public static func responseTools(definitions: [ToolDefinition]) -> [ResponseToolDefinition] {
        [execResponseTool(definitions: definitions), waitResponseTool]
    }

    public static func execResponseTool(definitions: [ToolDefinition]) -> ResponseToolDefinition {
        let available = definitions
            .filter { ($0.exposure ?? .direct) == .direct || $0.exposure == .deferred }
            .map { "- `tools.\($0.name)(...)`: \($0.description)" }
            .joined(separator: "\n")
        let suffix = available.isEmpty ? "" : "\n\nAvailable nested tools:\n\(available)"
        return .custom(
            name: execToolName,
            description: """
            Runs raw JavaScript in a fresh, sandboxed async module. Nested tools are available on `tools`, and `ALL_TOOLS` describes every nested tool. Use `text(value)` to emit output. Optional first-line pragma: `// @exec: {\"yield_time_ms\":10000,\"max_output_tokens\":1000}`.
            \(suffix)
            """,
            format: .object([
                "type": .string("grammar"),
                "syntax": .string("lark"),
                "definition": .string(execGrammar)
            ])
        )
    }

    public static let waitResponseTool = ResponseToolDefinition(
        name: waitToolName,
        description: "Waits on a yielded `exec` cell and returns completion or a running status.",
        parameters: ToolSchemas.object(properties: [
            "cell_id": ToolSchemas.string(description: "Identifier of the running exec cell"),
            "yield_time_ms": .object(["type": .string("number"), "description": .string("Wait before yielding; defaults to 10000 ms")]),
            "max_tokens": .object(["type": .string("number"), "description": .string("Maximum returned output token estimate")]),
            "terminate": ToolSchemas.boolean(description: "Terminate the running cell")
        ], required: ["cell_id"]),
        strict: false
    )

    public static let execGrammar = """
    start: pragma_source | plain_source
    pragma_source: PRAGMA_LINE NEWLINE SOURCE
    plain_source: SOURCE

    PRAGMA_LINE: /[ \\t]*\\/\\/ @exec:[^\\r\\n]*/
    NEWLINE: /\\r?\\n/
    SOURCE: /[\\s\\S]+/
    """

    private struct Options: Sendable {
        var yieldTimeMilliseconds = 10_000
        var maxOutputTokens = 10_000
    }

    private static func parsePragma(_ source: String) -> Options {
        guard let first = source.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              first.trimmingCharacters(in: .whitespaces).hasPrefix("// @exec:"),
              let colon = first.firstIndex(of: ":") else { return Options() }
        let raw = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder.codex.decode(JSONValue.self, from: data) else { return Options() }
        return Options(
            yieldTimeMilliseconds: clampedMilliseconds(value["yield_time_ms"]?.doubleValue.map(Int.init) ?? 10_000),
            maxOutputTokens: max(1, min(value["max_output_tokens"]?.doubleValue.map(Int.init) ?? 10_000, 100_000))
        )
    }

    private static func clampedMilliseconds(_ value: Int) -> Int { max(250, min(value, 30_000)) }

    private static func firstResult(of task: Task<ToolResult, Never>, afterMilliseconds milliseconds: Int) async -> ToolResult? {
        await withCheckedContinuation { continuation in
            let race = CodeModeRace(continuation)
            Task {
                race.resolve(await task.value)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                race.resolve(nil)
            }
        }
    }

    private func mergeStore(from result: ToolResult, threadID: String) {
        guard let fields = result.metadata["code_mode_store"]?.objectValue else { return }
        sessionStores[threadID] = fields
    }

    private static func withoutStoreMetadata(_ result: ToolResult) -> ToolResult {
        var copy = result
        copy.metadata.removeValue(forKey: "code_mode_store")
        return copy
    }
}

private final class CodeModeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ToolResult?, Never>?

    init(_ continuation: CheckedContinuation<ToolResult?, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: ToolResult?) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(returning: value)
    }
}

private final class CodeModeCell: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SwiftCodexCore.CodeModeCell")
    private let source: String
    private let definitions: [ToolDefinition]
    private let registry: ToolRegistry
    private let context: ToolExecutionContext
    private let initialStore: [String: JSONValue]
    private let maxOutputTokens: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ToolResult, Never>?
    private var jsContext: JSContext?

    private init(
        source: String,
        definitions: [ToolDefinition],
        registry: ToolRegistry,
        context: ToolExecutionContext,
        initialStore: [String: JSONValue],
        maxOutputTokens: Int,
        continuation: CheckedContinuation<ToolResult, Never>
    ) {
        self.source = source
        self.definitions = definitions
        self.registry = registry
        self.context = context
        self.initialStore = initialStore
        self.maxOutputTokens = maxOutputTokens
        self.continuation = continuation
    }

    static func run(
        source: String,
        definitions: [ToolDefinition],
        registry: ToolRegistry,
        context: ToolExecutionContext,
        initialStore: [String: JSONValue],
        maxOutputTokens: Int
    ) async -> ToolResult {
        await withCheckedContinuation { continuation in
            let cell = CodeModeCell(
                source: source,
                definitions: definitions,
                registry: registry,
                context: context,
                initialStore: initialStore,
                maxOutputTokens: maxOutputTokens,
                continuation: continuation
            )
            cell.start()
        }
    }

    private func start() {
        queue.async { [self] in
            guard let js = JSContext() else {
                finish(ToolResult(content: "Unable to create JavaScriptCore context.", isError: true))
                return
            }
            jsContext = js
            js.exceptionHandler = { [self] _, exception in
                guard let exception else { return }
                self.finish(ToolResult(content: exception.toString(), isError: true))
            }

            let toolCall: @convention(block) (String, String, String) -> Void = { [self] identifier, name, rawArguments in
                invokeTool(identifier: identifier, name: name, rawArguments: rawArguments)
            }
            let timer: @convention(block) (String, Double) -> Void = { [self] identifier, milliseconds in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(max(0, Int(milliseconds)))) {
                    self.queue.async {
                        self.jsContext?.objectForKeyedSubscript("__fireTimer")?.call(withArguments: [identifier])
                    }
                }
            }
            let completed: @convention(block) (String) -> Void = { [self] payload in
                complete(payload: payload)
            }
            js.setObject(toolCall, forKeyedSubscript: "__swiftToolCall" as NSString)
            js.setObject(timer, forKeyedSubscript: "__swiftSetTimer" as NSString)
            js.setObject(completed, forKeyedSubscript: "__swiftComplete" as NSString)

            let bootstrap = CodeModeCell.bootstrap(
                definitions: definitions,
                initialStore: initialStore,
                source: source
            )
            _ = js.evaluateScript(bootstrap)
            if let exception = js.exception {
                finish(ToolResult(content: exception.toString(), isError: true))
            }
        }
    }

    private func invokeTool(identifier: String, name: String, rawArguments: String) {
        Task { [registry, context, self] in
            let arguments: JSONValue
            if let data = rawArguments.data(using: .utf8),
               let decoded = try? JSONDecoder.codex.decode(JSONValue.self, from: data) {
                arguments = decoded
            } else {
                arguments = .object([:])
            }
            do {
                let result = try await registry.run(name: name, arguments: arguments, context: context)
                if result.isError { throw CodexCoreError.invalidState(result.content) }
                let value = result.structuredContent ?? Self.parseJSON(result.content) ?? .string(result.content)
                deliver(identifier: identifier, value: value, error: nil)
            } catch {
                deliver(identifier: identifier, value: nil, error: String(describing: error))
            }
        }
    }

    private func deliver(identifier: String, value: JSONValue?, error: String?) {
        queue.async { [self] in
            guard let jsContext else { return }
            let encoded = value.flatMap(Self.jsonString) ?? "null"
            jsContext.objectForKeyedSubscript("__resolveTool")?.call(withArguments: [identifier, error == nil, encoded, error ?? ""])
        }
    }

    private func complete(payload: String) {
        guard let data = payload.data(using: .utf8),
              let value = try? JSONDecoder.codex.decode(JSONValue.self, from: data) else {
            finish(ToolResult(content: "Code-mode runtime returned an invalid completion payload.", isError: true))
            return
        }
        let outputs = value["outputs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let returned = value["value"]
        var content = outputs.joined(separator: "\n")
        if content.isEmpty, let returned, returned != .null {
            content = returned.stringValue ?? Self.jsonString(returned) ?? String(describing: returned)
        }
        let limit = maxOutputTokens * 4
        if content.count > limit {
            content = String(content.prefix(limit)) + "\n[output truncated]"
        }
        let error = value["error"]?.stringValue
        finish(ToolResult(
            content: error ?? content,
            isError: error != nil,
            metadata: ["code_mode_store": value["store"] ?? .object([:])]
        ))
    }

    private func finish(_ result: ToolResult) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        jsContext = nil
        current?.resume(returning: result)
    }

    private static func bootstrap(definitions: [ToolDefinition], initialStore: [String: JSONValue], source: String) -> String {
        let available = definitions.filter { ($0.exposure ?? .direct) == .direct || $0.exposure == .deferred }
        let toolValues: [JSONValue] = available.map { definition in
            .object([
                "name": .string(definition.name),
                "description": .string(definition.description),
                "parameters": definition.parameters,
                "output_schema": definition.outputSchema ?? .null
            ])
        }
        let toolsJSON = jsonString(.array(toolValues)) ?? "[]"
        let storeJSON = jsonString(.object(initialStore)) ?? "{}"
        return """
        delete globalThis.console;
        const ALL_TOOLS = \(toolsJSON);
        const tools = Object.create(null);
        const __pending = new Map();
        const __timers = new Map();
        const __outputs = [];
        const __store = \(storeJSON);
        let __nextID = 0;
        function __normalize(value) {
          if (value === undefined) return null;
          return JSON.parse(JSON.stringify(value));
        }
        function __callTool(name, args) {
          return new Promise((resolve, reject) => {
            const id = String(++__nextID);
            __pending.set(id, {resolve, reject});
            __swiftToolCall(id, name, JSON.stringify(args ?? {}));
          });
        }
        function __resolveTool(id, ok, payload, error) {
          const pending = __pending.get(id);
          if (!pending) return;
          __pending.delete(id);
          if (ok) pending.resolve(JSON.parse(payload)); else pending.reject(new Error(error));
        }
        for (const definition of ALL_TOOLS) tools[definition.name] = (args = {}) => __callTool(definition.name, args);
        function text(value) {
          const rendered = typeof value === 'string' ? value : JSON.stringify(__normalize(value));
          __outputs.push(rendered);
          return value;
        }
        function image(value) { return text(value); }
        function generatedImage(value) { return text(value); }
        function notify(value) { return text(value); }
        function store(key, value) { __store[String(key)] = __normalize(value); return value; }
        function load(key) { return __store[String(key)]; }
        function exit() { throw new Error('__CODE_MODE_EXIT__'); }
        function setTimeout(callback, milliseconds = 0) {
          const id = String(++__nextID);
          __timers.set(id, callback);
          __swiftSetTimer(id, Number(milliseconds));
          return id;
        }
        function clearTimeout(id) { __timers.delete(String(id)); }
        function __fireTimer(id) {
          const callback = __timers.get(String(id));
          if (!callback) return;
          __timers.delete(String(id));
          callback();
        }
        async function yield_control() { return undefined; }
        (async () => {
        \(source)
        })().then(
          value => __swiftComplete(JSON.stringify({value: __normalize(value), outputs: __outputs, store: __store})),
          error => {
            if (String(error && error.message) === '__CODE_MODE_EXIT__') {
              __swiftComplete(JSON.stringify({value: null, outputs: __outputs, store: __store}));
            } else {
              __swiftComplete(JSON.stringify({error: String(error), outputs: __outputs, store: __store}));
            }
          }
        );
        """
    }

    private static func parseJSON(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder.codex.decode(JSONValue.self, from: data)
    }

    private static func jsonString(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder.codexCompact.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
