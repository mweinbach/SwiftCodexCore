import Foundation

/// Codex-compatible code-mode coordinator. Execution is delegated to a
/// pluggable engine while this actor owns cell lifecycle, incremental cursors,
/// thread-scoped state, and output budgets.
public actor CodeModeRuntime {
  public static let execToolName = "exec"
  public static let waitToolName = "wait"

  private struct RunningCell: Sendable {
    var threadID: String
    var session: any CodeModeCellSession
    var cursor: Int
    var yieldVersion: Int
    var createdAt: Date
    var storeMerged: Bool
    var waitInFlight: Bool
    var allowOriginalImageDetail: Bool
    var maxContentBlockBytes: Int
  }

  private let registry: ToolRegistry
  private let engine: any CodeModeEngine
  private let tokenCounter: any CodeModeTokenCounting
  private let diagnostics: CodeModeDiagnosticsHandler
  private var cells: [String: RunningCell] = [:]
  private var sessionStores: [String: [String: JSONValue]] = [:]

  public init(
    registry: ToolRegistry,
    engine: any CodeModeEngine = AutomaticCodeModeEngine(),
    tokenCounter: any CodeModeTokenCounting = EstimatedCodeModeTokenCounter(),
    diagnostics: @escaping CodeModeDiagnosticsHandler = { _ in }
  ) {
    self.registry = registry
    self.engine = engine
    self.tokenCounter = tokenCounter
    self.diagnostics = diagnostics
  }

  public func execute(
    source: String,
    definitions: [ToolDefinition],
    context: ToolExecutionContext,
    options: CodeModeOptions = CodeModeOptions()
  ) async -> ToolResult {
    let executionOptions: ExecutionOptions
    do {
      executionOptions = try Self.parseExecSource(source, defaults: options)
    } catch {
      return ToolResult(content: String(describing: error), isError: true)
    }
    enforceCellLimit(options.maxConcurrentCells)
    let cellID = UUID().uuidString.lowercased()
    let session = engine.start(
      request: CodeModeExecutionRequest(
        source: executionOptions.source,
        definitions: definitions,
        registry: registry,
        context: context,
        initialStore: sessionStores[context.threadID] ?? [:],
        options: options,
        maxOutputTokens: executionOptions.maxOutputTokens,
        tokenCounter: tokenCounter
      ))
    let runningCell = RunningCell(
      threadID: context.threadID,
      session: session,
      cursor: 0,
      yieldVersion: 0,
      createdAt: Date(),
      storeMerged: false,
      waitInFlight: false,
      allowOriginalImageDetail: options.allowOriginalImageDetail,
      maxContentBlockBytes: max(1_024, min(options.maxContentBlockBytes, 64 * 1024 * 1024))
    )
    cells[cellID] = runningCell
    diagnostics(
      CodeModeDiagnostic(
        kind: .cellStarted,
        cellID: cellID,
        threadID: context.threadID,
        state: .running
      ))
    Task { [weak self] in
      let completion = await session.completion()
      await self?.recordCompletion(cellID: cellID, completion: completion)
    }
    let snapshot = await session.wait(
      cursor: 0,
      yieldVersion: 0,
      timeoutMilliseconds: executionOptions.yieldTimeMilliseconds
    )
    return consume(
      cellID: cellID,
      snapshot: snapshot,
      maxTokens: executionOptions.maxOutputTokens,
      runningPrefix: "Script running with cell ID \(cellID).",
      knownCell: runningCell
    )
  }

  public func wait(arguments: JSONValue) async -> ToolResult {
    guard let cellID = arguments["cell_id"]?.stringValue, let cell = cells[cellID] else {
      return ToolResult(content: "Unknown or completed code-mode cell.", isError: true)
    }
    let maxTokens = Self.clampedInteger(
      arguments["max_tokens"]?.doubleValue,
      default: 10_000,
      minimum: 1,
      maximum: 100_000
    )
    if arguments["terminate"]?.boolValue == true {
      cell.session.terminate()
      let snapshot = await cell.session.wait(
        cursor: cell.cursor,
        yieldVersion: cell.yieldVersion,
        timeoutMilliseconds: 0
      )
      return consume(
        cellID: cellID,
        snapshot: snapshot,
        maxTokens: maxTokens,
        runningPrefix: "Script still running with cell ID \(cellID).",
        knownCell: cell
      )
    }
    guard !cell.waitInFlight else {
      return ToolResult(
        content: "A wait is already in progress for code-mode cell \(cellID).", isError: true)
    }
    var waitingCell = cell
    waitingCell.waitInFlight = true
    cells[cellID] = waitingCell
    let milliseconds = Self.clampedInteger(
      arguments["yield_time_ms"]?.doubleValue,
      default: 10_000,
      minimum: 250,
      maximum: 300_000
    )
    let snapshot = await cell.session.wait(
      cursor: cell.cursor,
      yieldVersion: cell.yieldVersion,
      timeoutMilliseconds: milliseconds
    )
    return consume(
      cellID: cellID,
      snapshot: snapshot,
      maxTokens: maxTokens,
      runningPrefix: "Script still running with cell ID \(cellID).",
      knownCell: cell
    )
  }

  public func terminateCells(threadID: String, clearStore: Bool = false) {
    let matchingCells = cells.filter { $0.value.threadID == threadID }
    for (cellID, cell) in matchingCells {
      cell.session.terminate()
      cells.removeValue(forKey: cellID)
    }
    if clearStore {
      sessionStores.removeValue(forKey: threadID)
    }
  }

  public static func responseTools(
    definitions: [ToolDefinition],
    options: CodeModeOptions = CodeModeOptions()
  ) -> [ResponseToolDefinition] {
    [execResponseTool(definitions: definitions, options: options), waitResponseTool]
  }

  public static func execResponseTool(
    definitions: [ToolDefinition],
    options: CodeModeOptions = CodeModeOptions()
  ) -> ResponseToolDefinition {
    let bindings = CodeModeToolCatalog.bindings(definitions: definitions, options: options)
    let eager = bindings.filter { $0.definition.exposure != .deferred }
    let deferredCount = bindings.count - eager.count
    let available =
      eager
      .map { "- `tools.\($0.publicName)(...)`: \($0.definition.description)" }
      .joined(separator: "\n")
    let suffix = available.isEmpty ? "" : "\n\nAvailable nested tools:\n\(available)"
    let deferred =
      deferredCount == 0
      ? ""
      : "\n\nAdditional deferred tools are listed in `ALL_TOOLS`; filter it by `name` and `description`, then call `tools[name](args)`."
    return .custom(
      name: execToolName,
      description: """
        Runs raw JavaScript in a fresh, restricted async module. Pass JavaScript source directly, not JSON, a quoted string, or a Markdown code fence. Node.js, filesystem, network, and console APIs are not exposed.

        Call nested tools through `tools`, for example `await tools.some_tool({ key: "value" })`. Namespaced tools support both their normalized flat name and nested path. Tool failures reject the returned promise. `ALL_TOOLS` contains metadata for every enabled tool, including deferred tools.

        Emit model-visible output with `text(value)`, `image(value, detail?)`, or `generatedImage(result)`. Remote image URLs are rejected; use a base64 `data:` URL or forward an MCP image content block. `notify(value)` emits and immediately yields. `store(key, value)` and `load(key)` persist JSON values for later cells in the same thread. `setTimeout`, `clearTimeout`, `exit`, and `yield_control()` are also available.

        If the script is still running after the yield window, the result includes a cell ID. Continue it with `wait`, which returns only output not previously consumed. An optional strict first-line pragma can override the initial limits: `// @exec: {\"yield_time_ms\":10000,\"max_output_tokens\":1000}`.
        \(suffix)\(deferred)
        """,
      format: .object([
        "type": .string("grammar"),
        "syntax": .string("lark"),
        "definition": .string(execGrammar),
      ])
    )
  }

  public static let waitResponseTool = ResponseToolDefinition(
    name: waitToolName,
    description:
      "Waits on a cell ID returned by `exec`. Each call returns only newly emitted output plus completion or running state. Use `max_tokens` to bound the returned text, `yield_time_ms` to control this wait, or `terminate` to stop the cell.",
    parameters: ToolSchemas.object(
      properties: [
        "cell_id": ToolSchemas.string(description: "Identifier of the running exec cell"),
        "yield_time_ms": .object([
          "type": .string("number"),
          "description": .string("Wait before yielding; defaults to 10000 ms"),
        ]),
        "max_tokens": .object([
          "type": .string("number"),
          "description": .string("Maximum returned output token estimate"),
        ]),
        "terminate": ToolSchemas.boolean(description: "Terminate the running cell"),
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

  private struct ExecutionOptions: Sendable {
    var source: String
    var yieldTimeMilliseconds: Int
    var maxOutputTokens: Int
  }

  private struct SourceError: Error, CustomStringConvertible {
    var description: String
  }

  private static func parseExecSource(_ source: String, defaults: CodeModeOptions) throws
    -> ExecutionOptions
  {
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SourceError(description: "exec expects raw JavaScript source text (non-empty).")
    }
    var result = ExecutionOptions(
      source: source,
      yieldTimeMilliseconds: clampedMilliseconds(defaults.defaultYieldTimeMilliseconds),
      maxOutputTokens: max(1, min(defaults.defaultMaxOutputTokens, 100_000))
    )
    guard
      let first = source.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .first,
      first.trimmingCharacters(in: .whitespaces).hasPrefix("// @exec:"),
      let colon = first.firstIndex(of: ":")
    else { return result }
    let parts = source.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SourceError(
        description: "exec pragma must be followed by JavaScript source on subsequent lines")
    }
    let raw = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty, let data = raw.data(using: .utf8),
      let value = try? JSONDecoder.codex.decode(JSONValue.self, from: data),
      case .object(let fields) = value
    else {
      throw SourceError(
        description:
          "exec pragma must be a valid JSON object with supported fields `yield_time_ms` and `max_output_tokens`"
      )
    }
    let unknown = fields.keys.filter { $0 != "yield_time_ms" && $0 != "max_output_tokens" }
    guard unknown.isEmpty else {
      throw SourceError(
        description:
          "exec pragma only supports `yield_time_ms` and `max_output_tokens`; got `\(unknown.sorted()[0])`"
      )
    }
    if let value = try safeInteger(fields["yield_time_ms"], field: "yield_time_ms") {
      result.yieldTimeMilliseconds = clampedMilliseconds(value)
    }
    if let value = try safeInteger(fields["max_output_tokens"], field: "max_output_tokens") {
      result.maxOutputTokens = max(1, min(value, 100_000))
    }
    result.source = String(parts[1])
    return result
  }

  private static func safeInteger(_ value: JSONValue?, field: String) throws -> Int? {
    guard let value else { return nil }
    guard let number = value.doubleValue, number.isFinite, number >= 0,
      number.rounded(.towardZero) == number,
      number <= 9_007_199_254_740_991,
      number <= Double(Int.max)
    else {
      throw SourceError(
        description: "exec pragma field `\(field)` must be a non-negative safe integer")
    }
    return Int(number)
  }

  private static func clampedMilliseconds(_ value: Int) -> Int { max(250, min(value, 300_000)) }

  private static func clampedInteger(
    _ value: Double?,
    default defaultValue: Int,
    minimum: Int,
    maximum: Int
  ) -> Int {
    guard let value, !value.isNaN else { return defaultValue }
    if value <= Double(minimum) { return minimum }
    if !value.isFinite || value >= Double(maximum) { return maximum }
    return Int(value.rounded(.towardZero))
  }

  private func consume(
    cellID: String,
    snapshot: CodeModeCellSnapshot,
    maxTokens: Int,
    runningPrefix: String,
    knownCell: RunningCell? = nil
  ) -> ToolResult {
    let trackedCell = cells[cellID]
    let isTerminal = snapshot.state == .completed || snapshot.state == .terminated
    guard var cell = trackedCell ?? (isTerminal ? knownCell : nil) else {
      return ToolResult(content: "Unknown or completed code-mode cell.", isError: true)
    }
    let isTracked = trackedCell != nil
    if isTracked {
      cell.cursor = snapshot.nextCursor
      cell.yieldVersion = snapshot.yieldVersion
      cell.waitInFlight = false
      cells[cellID] = cell
      if let completion = snapshot.completion {
        mergeStoreIfNeeded(cellID: cellID, completion: completion)
      }
    }

    var blocks = snapshot.content
    blocks = blocks.map { block in
      guard let data = try? JSONEncoder.codexCompact.encode(block),
        data.count > cell.maxContentBlockBytes
      else { return block }
      return .text("[code-mode content block omitted: exceeded byte limit]")
    }
    if !cell.allowOriginalImageDetail {
      blocks = blocks.map { block in
        guard block.type == "image", block.fields["detail"]?.stringValue == "original" else {
          return block
        }
        var fields = block.fields
        fields["detail"] = .string("high")
        return ToolContentBlock(fields: fields)
      }
    }
    var rendered = blocks.compactMap(\.textValue).joined(separator: "\n")
    if snapshot.state == .completed, let returned = snapshot.completion?.returnedValue,
      returned != .null, blocks.isEmpty
    {
      let value = returned.stringValue ?? Self.jsonString(returned) ?? String(describing: returned)
      blocks.append(.text(value))
      rendered = value
    }
    if let error = snapshot.completion?.error {
      rendered = [rendered, error].filter { !$0.isEmpty }.joined(separator: "\n")
      blocks.append(.text(error))
    }
    if snapshot.state == .running || snapshot.state == .yielded {
      rendered = [rendered, runningPrefix].filter { !$0.isEmpty }.joined(separator: "\n")
    } else if snapshot.state == .terminated, rendered.isEmpty {
      rendered = "Script terminated."
    }
    let limited = CodeModeTokenBudget.truncate(
      rendered,
      maxTokens: maxTokens,
      counter: tokenCounter,
      marker: "\n[output truncated]"
    )
    rendered = limited.text
    let wasTruncated = limited.truncated
    if wasTruncated {
      let nonTextBlocks = blocks.filter { $0.type != "text" }
      blocks = nonTextBlocks + (rendered.isEmpty ? [] : [.text(rendered)])
      if isTracked {
        diagnostics(
          CodeModeDiagnostic(
            kind: .outputTruncated,
            cellID: cellID,
            threadID: cell.threadID,
            state: snapshot.state,
            message: "Code-mode output exceeded the configured budget."
          ))
      }
    }
    if isTerminal, isTracked { cells.removeValue(forKey: cellID) }
    let diagnosticKind: CodeModeDiagnostic.Kind? =
      switch snapshot.state {
      case .yielded: .cellYielded
      case .completed: .cellCompleted
      case .terminated: .cellTerminated
      case .running: nil
      }
    if let diagnosticKind, isTracked {
      diagnostics(
        CodeModeDiagnostic(
          kind: diagnosticKind,
          cellID: cellID,
          threadID: cell.threadID,
          state: snapshot.state,
          message: snapshot.completion?.error
        ))
    }
    return ToolResult(
      content: rendered,
      structuredContent: .object([
        "cell_id": .string(cellID),
        "state": .string(snapshot.state.rawValue),
        "cursor": .number(Double(snapshot.nextCursor)),
      ]),
      isError: snapshot.completion?.error != nil,
      metadata: [
        "cell_id": .string(cellID),
        "running": .bool(!isTerminal),
        "state": .string(snapshot.state.rawValue),
      ],
      contentBlocks: blocks.isEmpty ? nil : blocks
    )
  }

  private func recordCompletion(cellID: String, completion: CodeModeCompletion) {
    mergeStoreIfNeeded(cellID: cellID, completion: completion)
  }

  private func mergeStoreIfNeeded(cellID: String, completion: CodeModeCompletion) {
    guard var cell = cells[cellID], !cell.storeMerged else { return }
    var store = sessionStores[cell.threadID] ?? [:]
    for key in completion.storeDeletes { store.removeValue(forKey: key) }
    for (key, value) in completion.storeWrites { store[key] = value }
    sessionStores[cell.threadID] = store
    cell.storeMerged = true
    cells[cellID] = cell
  }

  private func enforceCellLimit(_ maximum: Int) {
    let maximum = max(1, maximum)
    guard cells.count >= maximum,
      let oldest = cells.min(by: { $0.value.createdAt < $1.value.createdAt })
    else { return }
    oldest.value.session.terminate()
    cells.removeValue(forKey: oldest.key)
    diagnostics(
      CodeModeDiagnostic(
        kind: .cellEvicted,
        cellID: oldest.key,
        threadID: oldest.value.threadID,
        state: .terminated,
        message: "Maximum concurrent code-mode cell count reached."
      ))
  }

  private static func jsonString(_ value: JSONValue) -> String? {
    guard let data = try? JSONEncoder.codexCompact.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
