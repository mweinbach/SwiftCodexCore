#if os(macOS)
  import Foundation
  import JavaScriptCore

  struct CodeModeHostStart: Codable {
    var source: String
    var bindings: [CodeModeHostBinding]
    var initialStore: [String: JSONValue]
    var maxContentBlockBytes: Int
    var maxCellOutputBytes: Int

    private enum CodingKeys: String, CodingKey {
      case source
      case bindings
      case initialStore
      case maxContentBlockBytes
      case maxCellOutputBytes
    }

    init(
      source: String,
      bindings: [CodeModeHostBinding],
      initialStore: [String: JSONValue],
      maxContentBlockBytes: Int,
      maxCellOutputBytes: Int = CodeModeOutputByteLimits.defaultCellOutputBytes
    ) {
      self.source = source
      self.bindings = bindings
      self.initialStore = initialStore
      self.maxContentBlockBytes = CodeModeOutputByteLimits.contentBlockBytes(
        maxContentBlockBytes)
      self.maxCellOutputBytes = CodeModeOutputByteLimits.cellOutputBytes(maxCellOutputBytes)
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        source: try container.decode(String.self, forKey: .source),
        bindings: try container.decode([CodeModeHostBinding].self, forKey: .bindings),
        initialStore: try container.decode([String: JSONValue].self, forKey: .initialStore),
        maxContentBlockBytes: try container.decode(Int.self, forKey: .maxContentBlockBytes),
        maxCellOutputBytes: try container.decodeIfPresent(Int.self, forKey: .maxCellOutputBytes)
          ?? CodeModeOutputByteLimits.defaultCellOutputBytes
      )
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(source, forKey: .source)
      try container.encode(bindings, forKey: .bindings)
      try container.encode(initialStore, forKey: .initialStore)
      try container.encode(maxContentBlockBytes, forKey: .maxContentBlockBytes)
      try container.encode(maxCellOutputBytes, forKey: .maxCellOutputBytes)
    }
  }

  /// Entry point used by the optional `codex-code-mode-host` executable. The
  /// host owns JavaScriptCore in a separate process so the parent can enforce a
  /// hard execution boundary with process termination.
  public enum CodeModeProcessHost {
    public static func run() async throws {
      guard let line = readLine(), let data = line.data(using: .utf8) else {
        throw CodexCoreError.invalidInput("Missing code-mode host start message")
      }
      let start = try JSONDecoder.codex.decode(CodeModeHostStart.self, from: data)
      let execution = ProcessHostExecution(start: start)
      await execution.run()
    }
  }

  private final class ProcessHostExecution: @unchecked Sendable {
    private let startMessage: CodeModeHostStart
    private let queue = DispatchQueue(label: "SwiftCodexCore.CodeModeProcessHost")
    private let writeLock = NSLock()
    private let finishLock = NSLock()
    private let outputBudgetLock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var jsContext: JSContext?
    private var jsBridge: JSValue?
    private var emittedContentBytes = 0
    private var closed = false

    init(start: CodeModeHostStart) { self.startMessage = start }

    func run() async {
      await withCheckedContinuation { continuation in
        finishLock.lock()
        self.continuation = continuation
        finishLock.unlock()
        startReader()
        startJavaScript()
      }
    }

    private func startReader() {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        while let line = readLine() { self?.receive(line) }
      }
    }

    private func startJavaScript() {
      queue.async { [self] in
        guard !isClosed else { return }
        guard let js = JSContext() else {
          sendCompletion(error: "Unable to create JavaScriptCore context.")
          return
        }
        jsContext = js
        js.exceptionHandler = { [self] _, exception in
          guard let exception else { return }
          sendCompletion(error: exception.toString())
        }
        let toolCall: @convention(block) (String, String, String) -> Void = {
          [self] identifier, name, arguments in
          guard !isClosed else { return }
          send(
            .object([
              "type": .string("tool_call"), "id": .string(identifier),
              "name": .string(name), "arguments": .string(arguments),
            ]))
        }
        let timer: @convention(block) (String, Double) -> Void = {
          [self] identifier, milliseconds in
          let milliseconds = CodeModeNumericLimits.timerMilliseconds(milliseconds)
          DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(milliseconds)
          ) {
            self.queue.async {
              guard !self.isClosed else { return }
              self.jsBridge?.objectForKeyedSubscript("fireTimer")?.call(withArguments: [
                identifier
              ])
            }
          }
        }
        let emit: @convention(block) (String, Bool) -> Void = { [self] payload, shouldYield in
          guard !isClosed else { return }
          let payloadBytes = payload.utf8.count
          guard payloadBytes <= startMessage.maxContentBlockBytes else {
            sendCompletion(error: "Code-mode content block exceeded the configured byte limit.")
            return
          }
          guard let block = parseJSON(payload) else { return }
          guard reserveContentBytes(payloadBytes) else {
            sendCompletion(
              error: "Code-mode cell output exceeded the configured cumulative byte limit.")
            return
          }
          send(
            .object([
              "type": .string("emit"), "block": block, "yield": .bool(shouldYield),
            ]))
        }
        let yield: @convention(block) () -> Void = { [self] in
          guard !isClosed else { return }
          send(.object(["type": .string("yield")]))
        }
        let completed: @convention(block) (String) -> Void = { [self] payload in
          guard !isClosed else { return }
          guard let completion = parseJSON(payload) else {
            sendCompletion(error: "Invalid JavaScript completion payload.")
            return
          }
          send(.object(["type": .string("complete"), "completion": completion]))
          finish()
        }
        js.setObject(toolCall, forKeyedSubscript: "__swiftToolCall" as NSString)
        js.setObject(timer, forKeyedSubscript: "__swiftSetTimer" as NSString)
        js.setObject(emit, forKeyedSubscript: "__swiftEmit" as NSString)
        js.setObject(yield, forKeyedSubscript: "__swiftYield" as NSString)
        js.setObject(completed, forKeyedSubscript: "__swiftComplete" as NSString)
        let bridge = js.evaluateScript(
          CodeModeJavaScriptProgram.make(
            bindings: startMessage.bindings,
            initialStore: startMessage.initialStore,
            source: startMessage.source
          ))
        if !isClosed { jsBridge = bridge }
      }
    }

    private func receive(_ line: String) {
      guard !isClosed else { return }
      guard let value = parseJSON(line), value["type"]?.stringValue == "tool_result",
        let identifier = value["id"]?.stringValue
      else { return }
      let ok = value["ok"]?.boolValue ?? false
      let payload = value["payload"].flatMap(jsonString) ?? "null"
      let error = value["error"]?.stringValue ?? "Nested tool failed"
      queue.async { [weak self] in
        guard let self, !isClosed, let jsBridge else { return }
        jsBridge.objectForKeyedSubscript("resolveTool")?.call(withArguments: [
          identifier, ok, payload, error,
        ])
      }
    }

    private func sendCompletion(error: String) {
      guard !isClosed else { return }
      send(
        .object([
          "type": .string("complete"),
          "completion": .object([
            "value": .null, "error": .string(error), "writes": .object([:]), "deletes": .array([]),
          ]),
        ]))
      finish()
    }

    private func reserveContentBytes(_ additionalBytes: Int) -> Bool {
      outputBudgetLock.withLock {
        guard
          let updatedContentBytes = CodeModeOutputByteLimits.totalAfterAdding(
            additionalBytes,
            to: emittedContentBytes,
            limit: startMessage.maxCellOutputBytes
          )
        else {
          emittedContentBytes = startMessage.maxCellOutputBytes
          return false
        }
        emittedContentBytes = updatedContentBytes
        return true
      }
    }

    private func send(_ value: JSONValue) {
      guard let line = jsonString(value)?.appending("\n"), let data = line.data(using: .utf8) else {
        return
      }
      writeLock.withLock { FileHandle.standardOutput.write(data) }
    }

    private func finish() {
      finishLock.lock()
      guard !closed else {
        finishLock.unlock()
        return
      }
      closed = true
      let continuation = self.continuation
      self.continuation = nil
      finishLock.unlock()
      queue.async { [weak self] in
        self?.jsBridge = nil
        self?.jsContext = nil
      }
      continuation?.resume()
    }

    private var isClosed: Bool {
      finishLock.withLock { closed }
    }

    private func parseJSON(_ text: String) -> JSONValue? {
      guard let data = text.data(using: .utf8) else { return nil }
      return try? JSONDecoder.codex.decode(JSONValue.self, from: data)
    }

    private func jsonString(_ value: JSONValue) -> String? {
      guard let data = try? JSONEncoder.codexCompact.encode(value) else { return nil }
      return String(data: data, encoding: .utf8)
    }
  }
#endif
