#if os(macOS)
  import Darwin
  import Foundation

  /// Runs each code-mode cell in the `codex-code-mode-host` helper process.
  /// Unlike an in-process JavaScriptCore context, a stuck synchronous script can
  /// be stopped at the operating-system process boundary.
  public struct ProcessCodeModeEngine: CodeModeEngine {
    public let executableURL: URL?
    public let terminationGracePeriodMilliseconds: Int
    public let environment: [String: String]

    public init(
      executableURL: URL? = nil,
      terminationGracePeriodMilliseconds: Int = 250,
      environment: [String: String] = [:]
    ) {
      self.executableURL = executableURL ?? Self.discoverExecutableURL()
      self.terminationGracePeriodMilliseconds = max(0, terminationGracePeriodMilliseconds)
      self.environment = environment
    }

    public var isAvailable: Bool {
      guard let executableURL else { return false }
      return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    public func start(request: CodeModeExecutionRequest) -> any CodeModeCellSession {
      ProcessCodeModeCell(
        request: request,
        executableURL: executableURL,
        terminationGracePeriodMilliseconds: terminationGracePeriodMilliseconds,
        environment: environment
      )
    }

    /// Finds an explicitly configured or adjacent SwiftPM-built helper.
    /// Production apps should normally pass the helper's bundled URL directly.
    public static func discoverExecutableURL() -> URL? {
      let fileManager = FileManager.default
      var candidates: [URL] = []
      if let configured = ProcessInfo.processInfo.environment["SWIFT_CODEX_CODE_MODE_HOST"],
        !configured.isEmpty
      {
        candidates.append(URL(fileURLWithPath: configured))
      }
      if let executable = Bundle.main.executableURL {
        candidates.append(
          executable.deletingLastPathComponent().appendingPathComponent("codex-code-mode-host"))
      }
      if let argument = CommandLine.arguments.first, !argument.isEmpty {
        candidates.append(
          URL(fileURLWithPath: argument).standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("codex-code-mode-host")
        )
      }

      return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
  }

  private final class ProcessCodeModeCell: CodeModeCellSession, @unchecked Sendable {
    private struct Waiter {
      var cursor: Int
      var yieldVersion: Int
      var continuation: CheckedContinuation<CodeModeCellSnapshot, Never>
    }

    private let request: CodeModeExecutionRequest
    private let bindings: [CodeModeToolBinding]
    private let bindingsByPublicName: [String: CodeModeToolBinding]
    private let executableURL: URL?
    private let terminationGracePeriodMilliseconds: Int
    private let environment: [String: String]
    private let lock = NSLock()
    private let inputLock = NSLock()
    private let errorLock = NSLock()
    private let toolTaskLock = NSLock()
    private let outputQueue = DispatchQueue(label: "SwiftCodexCore.CodeModeProcess.output")
    private let errorQueue = DispatchQueue(label: "SwiftCodexCore.CodeModeProcess.error")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var standardError = Data()
    private var content: [ToolContentBlock] = []
    private var emittedContentBytes = 0
    private var yieldVersion = 0
    private var finalCompletion: CodeModeCompletion?
    private var terminated = false
    private var waiters: [UUID: Waiter] = [:]
    private var completionWaiters: [CheckedContinuation<CodeModeCompletion, Never>] = []
    private var toolTasks: [String: Task<Void, Never>] = [:]

    init(
      request: CodeModeExecutionRequest,
      executableURL: URL?,
      terminationGracePeriodMilliseconds: Int,
      environment: [String: String]
    ) {
      self.request = request
      let bindings = CodeModeToolCatalog.bindings(
        definitions: request.definitions, options: request.options)
      self.bindings = bindings
      self.bindingsByPublicName = Dictionary(
        uniqueKeysWithValues: bindings.map { ($0.publicName, $0) })
      self.executableURL = executableURL
      self.terminationGracePeriodMilliseconds = terminationGracePeriodMilliseconds
      self.environment = environment
      start()
    }

    func wait(cursor: Int, yieldVersion observedYieldVersion: Int, timeoutMilliseconds: Int) async
      -> CodeModeCellSnapshot
    {
      await withCheckedContinuation { continuation in
        lock.lock()
        if shouldResolveWait(observedYieldVersion: observedYieldVersion) {
          let snapshot = snapshotLocked(cursor: cursor, observedYieldVersion: observedYieldVersion)
          lock.unlock()
          continuation.resume(returning: snapshot)
          return
        }
        let id = UUID()
        waiters[id] = Waiter(
          cursor: cursor, yieldVersion: observedYieldVersion, continuation: continuation)
        lock.unlock()
        DispatchQueue.global().asyncAfter(
          deadline: .now() + .milliseconds(max(0, timeoutMilliseconds))
        ) { [weak self] in
          self?.resolveWaiter(id: id)
        }
      }
    }

    func completion() async -> CodeModeCompletion {
      await withCheckedContinuation { continuation in
        lock.lock()
        if let finalCompletion {
          lock.unlock()
          continuation.resume(returning: finalCompletion)
        } else {
          completionWaiters.append(continuation)
          lock.unlock()
        }
      }
    }

    func terminate() {
      finish(CodeModeCompletion(), stateTerminated: true)
      inputLock.withLock {
        try? inputHandle?.close()
        inputHandle = nil
      }
      guard let process else { return }
      let processIdentifier = process.processIdentifier
      if process.isRunning { process.terminate() }
      DispatchQueue.global().asyncAfter(
        deadline: .now() + .milliseconds(terminationGracePeriodMilliseconds)
      ) {
        guard process.processIdentifier == processIdentifier, process.isRunning else { return }
        _ = Darwin.kill(processIdentifier, SIGKILL)
      }
    }

    private func start() {
      guard let executableURL else {
        finish(CodeModeCompletion(error: "The codex-code-mode-host executable could not be found."))
        return
      }
      guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        finish(
          CodeModeCompletion(
            error: "The code-mode host is not executable at \(executableURL.path)."))
        return
      }

      let process = Process()
      let inputPipe = Pipe()
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.executableURL = executableURL
      process.standardInput = inputPipe
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      process.environment = environment
      self.process = process
      inputHandle = inputPipe.fileHandleForWriting

      outputQueue.async { [weak self] in
        self?.readOutput(outputPipe.fileHandleForReading)
      }
      errorQueue.async { [weak self] in
        self?.readError(errorPipe.fileHandleForReading)
      }
      process.terminationHandler = { [weak self] process in
        // The output queue drains the protocol pipe before observing exit,
        // so a final completion line wins over the termination callback.
        self?.outputQueue.async { [weak self] in
          self?.processExited(status: process.terminationStatus)
        }
      }

      do {
        try process.run()
        let startMessage = CodeModeHostStart(
          source: request.source,
          bindings: bindings.map(CodeModeHostBinding.init),
          initialStore: request.initialStore,
          maxContentBlockBytes: CodeModeOutputByteLimits.contentBlockBytes(
            request.options.maxContentBlockBytes),
          maxCellOutputBytes: CodeModeOutputByteLimits.cellOutputBytes(
            request.options.maxCellOutputBytes)
        )
        try sendStart(startMessage)
      } catch {
        process.terminate()
        finish(CodeModeCompletion(error: "Unable to launch code-mode host: \(error)"))
      }
    }

    private func sendStart(_ startMessage: CodeModeHostStart) throws {
      var data = try JSONEncoder.codexCompact.encode(startMessage)
      data.append(0x0A)
      try inputLock.withLock {
        guard let inputHandle else {
          throw CodexCoreError.invalidState("Code-mode host input is closed")
        }
        try inputHandle.write(contentsOf: data)
      }
    }

    private func readOutput(_ handle: FileHandle) {
      var buffer = Data()
      let maximumLineBytes = CodeModeOutputByteLimits.contentBlockBytes(
        request.options.maxContentBlockBytes)
      while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        if buffer.count > maximumLineBytes, buffer.firstIndex(of: 0x0A) == nil {
          failProtocol("Code-mode host protocol line exceeded the configured byte limit.")
          return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
          let lineData = buffer[..<newline]
          buffer.removeSubrange(...newline)
          guard lineData.count <= maximumLineBytes else {
            failProtocol("Code-mode host protocol line exceeded the configured byte limit.")
            return
          }
          if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
            receive(line: line)
          }
        }
      }
      if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
        receive(line: line)
      }
    }

    private func readError(_ handle: FileHandle) {
      let data = handle.readDataToEndOfFile()
      errorLock.withLock {
        standardError.append(data.prefix(65_536))
      }
    }

    private func receive(line: String) {
      guard !isClosed else { return }
      guard let event = Self.parseJSON(line), let type = event["type"]?.stringValue else {
        failProtocol("Code-mode host emitted invalid JSON.")
        return
      }
      switch type {
      case "tool_call":
        guard let identifier = event["id"]?.stringValue,
          let publicName = event["name"]?.stringValue
        else {
          failProtocol("Code-mode host emitted an invalid tool call.")
          return
        }
        let rawArguments = event["arguments"]?.stringValue ?? "{}"
        invokeTool(identifier: identifier, publicName: publicName, rawArguments: rawArguments)
      case "emit":
        guard let fields = event["block"]?.objectValue else {
          failProtocol("Code-mode host emitted an invalid content block.")
          return
        }
        emit(ToolContentBlock(fields: fields), shouldYield: event["yield"]?.boolValue ?? false)
      case "notify":
        guard let text = event["text"]?.stringValue else {
          failProtocol("Code-mode host emitted an invalid notification.")
          return
        }
        request.notificationHandler(text)
      case "yield":
        signalYield()
      case "complete":
        guard let completionValue = event["completion"] else {
          failProtocol("Code-mode host emitted an invalid completion.")
          return
        }
        complete(completionValue)
      default:
        // Unknown event types are ignored to keep the protocol forwards-compatible.
        break
      }
    }

    private func invokeTool(identifier: String, publicName: String, rawArguments: String) {
      guard !isClosed else { return }
      guard let binding = bindingsByPublicName[publicName] else {
        sendToolResult(
          identifier: identifier, value: nil, error: "Unknown nested tool: \(publicName)")
        return
      }
      let task = Task { [request, self] in
        defer { removeToolTask(identifier: identifier) }
        guard !isClosed else {
          sendToolResult(
            identifier: identifier, value: nil, error: "Code-mode cell was terminated.")
          return
        }
        let arguments = Self.parseJSON(rawArguments) ?? .object([:])
        do {
          let result = try await request.registry.run(
            name: binding.toolName,
            arguments: arguments,
            context: request.context
          )
          guard !isClosed else { return }
          guard !result.isError else {
            sendToolResult(identifier: identifier, value: nil, error: result.content)
            return
          }
          sendToolResult(
            identifier: identifier,
            value: CodeModeToolResultEncoder.value(
              result,
              maxOutputTokens: max(1, min(request.options.maxNestedToolOutputTokens, 100_000)),
              tokenCounter: request.tokenCounter
            ),
            error: nil
          )
        } catch {
          guard !isClosed else { return }
          sendToolResult(identifier: identifier, value: nil, error: String(describing: error))
        }
      }
      toolTaskLock.withLock { toolTasks[identifier] = task }
      if isClosed { cancelToolTasks() }
    }

    private func sendToolResult(identifier: String, value: JSONValue?, error: String?) {
      var fields: [String: JSONValue] = [
        "type": .string("tool_result"),
        "id": .string(identifier),
        "ok": .bool(error == nil),
      ]
      if let value { fields["payload"] = value }
      if let error { fields["error"] = .string(error) }
      send(.object(fields))
    }

    private func send(_ value: JSONValue) {
      guard !isClosed else { return }
      guard var data = try? JSONEncoder.codexCompact.encode(value) else { return }
      data.append(0x0A)
      inputLock.withLock {
        guard let inputHandle else { return }
        do {
          try inputHandle.write(contentsOf: data)
        } catch {
          failProtocol("Unable to communicate with code-mode host: \(error)")
        }
      }
    }

    private func emit(_ block: ToolContentBlock, shouldYield: Bool) {
      guard let blockBytes = CodeModeOutputByteLimits.encodedContentBlockBytes(block.fields) else {
        failProtocol("Code-mode host emitted an unencodable content block.")
        return
      }
      guard
        blockBytes
          <= CodeModeOutputByteLimits.contentBlockBytes(
            request.options.maxContentBlockBytes)
      else {
        failProtocol("Code-mode host content block exceeded the configured byte limit.")
        return
      }
      lock.lock()
      guard !terminated, finalCompletion == nil else {
        lock.unlock()
        return
      }
      guard
        let updatedContentBytes = CodeModeOutputByteLimits.totalAfterAdding(
          blockBytes,
          to: emittedContentBytes,
          limit: request.options.maxCellOutputBytes
        )
      else {
        emittedContentBytes = CodeModeOutputByteLimits.cellOutputBytes(
          request.options.maxCellOutputBytes)
        lock.unlock()
        failProtocol("Code-mode host exceeded the configured cumulative output byte limit.")
        return
      }
      emittedContentBytes = updatedContentBytes
      content.append(block)
      if shouldYield { yieldVersion += 1 }
      let pending = shouldYield ? drainReadyWaitersLocked() : []
      lock.unlock()
      resume(pending)
    }

    private func signalYield() {
      lock.lock()
      guard !terminated, finalCompletion == nil else {
        lock.unlock()
        return
      }
      yieldVersion += 1
      let pending = drainReadyWaitersLocked()
      lock.unlock()
      resume(pending)
    }

    private func complete(_ value: JSONValue) {
      let writes = value["writes"]?.objectValue ?? [:]
      let deletes = Set(value["deletes"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      finish(
        CodeModeCompletion(
          returnedValue: value["value"],
          error: value["error"]?.stringValue,
          storeWrites: writes,
          storeDeletes: deletes
        ))
    }

    private func failProtocol(_ message: String) {
      finish(CodeModeCompletion(error: message))
      guard let process, process.isRunning else { return }
      process.terminate()
    }

    private func processExited(status: Int32) {
      lock.lock()
      let alreadyFinished = finalCompletion != nil
      lock.unlock()
      guard !alreadyFinished else { return }
      let stderr = errorLock.withLock { String(data: standardError, encoding: .utf8) ?? "" }
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let detail = stderr.isEmpty ? "exit status \(status)" : stderr
      finish(CodeModeCompletion(error: "Code-mode host exited before completion: \(detail)"))
    }

    private func finish(_ completion: CodeModeCompletion, stateTerminated: Bool = false) {
      lock.lock()
      guard finalCompletion == nil else {
        lock.unlock()
        return
      }
      terminated = stateTerminated
      finalCompletion = completion
      let pending = drainReadyWaitersLocked()
      let completionWaiters = self.completionWaiters
      self.completionWaiters.removeAll()
      lock.unlock()
      cancelToolTasks()
      resume(pending)
      for waiter in completionWaiters {
        waiter.resume(returning: completion)
      }
    }

    private var isClosed: Bool {
      lock.withLock { terminated || finalCompletion != nil }
    }

    private func shouldResolveWait(observedYieldVersion: Int) -> Bool {
      finalCompletion != nil || terminated || yieldVersion > observedYieldVersion
    }

    private func resolveWaiter(id: UUID) {
      lock.lock()
      guard let waiter = waiters.removeValue(forKey: id) else {
        lock.unlock()
        return
      }
      let snapshot = snapshotLocked(
        cursor: waiter.cursor, observedYieldVersion: waiter.yieldVersion)
      lock.unlock()
      waiter.continuation.resume(returning: snapshot)
    }

    private func drainReadyWaitersLocked() -> [(
      CheckedContinuation<CodeModeCellSnapshot, Never>, CodeModeCellSnapshot
    )] {
      var ready: [(CheckedContinuation<CodeModeCellSnapshot, Never>, CodeModeCellSnapshot)] = []
      let readyIDs = waiters.compactMap { id, waiter in
        shouldResolveWait(observedYieldVersion: waiter.yieldVersion) ? id : nil
      }
      for id in readyIDs {
        guard let waiter = waiters.removeValue(forKey: id) else { continue }
        ready.append(
          (
            waiter.continuation,
            snapshotLocked(cursor: waiter.cursor, observedYieldVersion: waiter.yieldVersion)
          ))
      }
      return ready
    }

    private func snapshotLocked(cursor: Int, observedYieldVersion: Int) -> CodeModeCellSnapshot {
      let safeCursor = max(0, min(cursor, content.count))
      let state: CodeModeCellState
      if terminated {
        state = .terminated
      } else if finalCompletion != nil {
        state = .completed
      } else if yieldVersion > observedYieldVersion {
        state = .yielded
      } else {
        state = .running
      }
      return CodeModeCellSnapshot(
        state: state,
        content: Array(content[safeCursor...]),
        nextCursor: content.count,
        yieldVersion: yieldVersion,
        completion: finalCompletion
      )
    }

    private func resume(
      _ pending: [(CheckedContinuation<CodeModeCellSnapshot, Never>, CodeModeCellSnapshot)]
    ) {
      for (continuation, snapshot) in pending {
        continuation.resume(returning: snapshot)
      }
    }

    private func removeToolTask(identifier: String) {
      _ = toolTaskLock.withLock { toolTasks.removeValue(forKey: identifier) }
    }

    private func cancelToolTasks() {
      let tasks = toolTaskLock.withLock {
        let tasks = Array(toolTasks.values)
        toolTasks.removeAll()
        return tasks
      }
      for task in tasks { task.cancel() }
    }

    private static func parseJSON(_ text: String) -> JSONValue? {
      guard let data = text.data(using: .utf8) else { return nil }
      return try? JSONDecoder.codex.decode(JSONValue.self, from: data)
    }
  }
#endif
