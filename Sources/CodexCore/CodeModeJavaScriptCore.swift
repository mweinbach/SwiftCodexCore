import Foundation
import JavaScriptCore

final class JavaScriptCoreCodeModeCell: CodeModeCellSession, @unchecked Sendable {
  private struct Waiter {
    var cursor: Int
    var yieldVersion: Int
    var continuation: CheckedContinuation<CodeModeCellSnapshot, Never>
  }

  private let request: CodeModeExecutionRequest
  private let bindings: [CodeModeToolBinding]
  private let bindingsByPublicName: [String: CodeModeToolBinding]
  private let queue = DispatchQueue(label: "SwiftCodexCore.CodeModeCell")
  private let lock = NSLock()
  private let toolTaskLock = NSLock()
  private var content: [ToolContentBlock] = []
  private var emittedContentBytes = 0
  private var yieldVersion = 0
  private var finalCompletion: CodeModeCompletion?
  private var terminated = false
  private var waiters: [UUID: Waiter] = [:]
  private var completionWaiters: [CheckedContinuation<CodeModeCompletion, Never>] = []
  private var toolTasks: [String: Task<Void, Never>] = [:]
  private var jsContext: JSContext?
  private var jsBridge: JSValue?

  init(request: CodeModeExecutionRequest) {
    self.request = request
    let bindings = CodeModeToolCatalog.bindings(
      definitions: request.definitions, options: request.options)
    self.bindings = bindings
    self.bindingsByPublicName = Dictionary(
      uniqueKeysWithValues: bindings.map { ($0.publicName, $0) })
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
    let completion = CodeModeCompletion()
    finish(completion, stateTerminated: true)
  }

  private func start() {
    queue.async { [self] in
      guard !isClosed else { return }
      guard let js = JSContext() else {
        finish(CodeModeCompletion(error: "Unable to create JavaScriptCore context."))
        return
      }
      jsContext = js
      js.exceptionHandler = { [self] _, exception in
        guard let exception else { return }
        finish(CodeModeCompletion(error: exception.toString()))
      }

      let toolCall: @convention(block) (String, String, String) -> Void = {
        [self] identifier, name, rawArguments in
        invokeTool(identifier: identifier, publicName: name, rawArguments: rawArguments)
      }
      let timer: @convention(block) (String, Double) -> Void = { [self] identifier, milliseconds in
        let milliseconds = CodeModeNumericLimits.timerMilliseconds(milliseconds)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
          self.queue.async {
            guard !self.isClosed else { return }
            self.jsBridge?.objectForKeyedSubscript("fireTimer")?.call(withArguments: [identifier])
          }
        }
      }
      let emit: @convention(block) (String, Bool) -> Void = { [self] payload, shouldYield in
        emit(payload: payload, shouldYield: shouldYield)
      }
      let notify: @convention(block) (String) -> Void = { [self] text in
        notify(text: text)
      }
      let yield: @convention(block) () -> Void = { [self] in signalYield() }
      let completed: @convention(block) (String) -> Void = { [self] payload in
        complete(payload: payload)
      }
      js.setObject(toolCall, forKeyedSubscript: "__swiftToolCall" as NSString)
      js.setObject(timer, forKeyedSubscript: "__swiftSetTimer" as NSString)
      js.setObject(emit, forKeyedSubscript: "__swiftEmit" as NSString)
      js.setObject(notify, forKeyedSubscript: "__swiftNotify" as NSString)
      js.setObject(yield, forKeyedSubscript: "__swiftYield" as NSString)
      js.setObject(completed, forKeyedSubscript: "__swiftComplete" as NSString)

      jsBridge = js.evaluateScript(
        CodeModeJavaScriptProgram.make(
          bindings: bindings.map(CodeModeHostBinding.init),
          initialStore: request.initialStore,
          source: request.source
        ))
      if let exception = js.exception {
        finish(CodeModeCompletion(error: exception.toString()))
      }
    }
  }

  private func invokeTool(identifier: String, publicName: String, rawArguments: String) {
    guard !isClosed else { return }
    guard let binding = bindingsByPublicName[publicName] else {
      deliver(identifier: identifier, value: nil, error: "Unknown nested tool: \(publicName)")
      return
    }
    let task = Task { [request, self] in
      defer { removeToolTask(identifier: identifier) }
      guard !isClosed else {
        deliver(identifier: identifier, value: nil, error: "Code-mode cell was terminated.")
        return
      }
      let arguments = Self.parseJSON(rawArguments) ?? .object([:])
      do {
        let result = try await request.runNestedTool(
          identifier: identifier, name: binding.toolName, arguments: arguments)
        guard !isClosed else {
          deliver(identifier: identifier, value: nil, error: "Code-mode cell was terminated.")
          return
        }
        guard !result.isError else {
          deliver(identifier: identifier, value: nil, error: result.content)
          return
        }
        deliver(
          identifier: identifier,
          value: CodeModeToolResultEncoder.value(
            result,
            maxOutputTokens: max(1, request.options.maxNestedToolOutputTokens),
            tokenCounter: request.tokenCounter
          ),
          error: nil
        )
      } catch {
        deliver(identifier: identifier, value: nil, error: String(describing: error))
      }
    }
    toolTaskLock.withLock { toolTasks[identifier] = task }
    if isClosed { cancelToolTasks() }
  }

  private func deliver(identifier: String, value: JSONValue?, error: String?) {
    queue.async { [weak self] in
      guard let self, !isClosed, let jsBridge else { return }
      let encoded = value.flatMap(Self.jsonString) ?? "null"
      jsBridge.objectForKeyedSubscript("resolveTool")?.call(withArguments: [
        identifier, error == nil, encoded, error ?? "",
      ])
    }
  }

  private func emit(payload: String, shouldYield: Bool) {
    let payloadBytes = payload.utf8.count
    guard
      payloadBytes
        <= CodeModeOutputByteLimits.contentBlockBytes(request.options.maxContentBlockBytes)
    else {
      finish(
        CodeModeCompletion(error: "Code-mode content block exceeded the configured byte limit."))
      return
    }
    guard let value = Self.parseJSON(payload), case .object(let fields) = value else {
      finish(CodeModeCompletion(error: "Code-mode helper emitted an invalid content block."))
      return
    }
    lock.lock()
    guard !terminated, finalCompletion == nil else {
      lock.unlock()
      return
    }
    guard
      let updatedContentBytes = CodeModeOutputByteLimits.totalAfterAdding(
        payloadBytes,
        to: emittedContentBytes,
        limit: request.options.maxCellOutputBytes
      )
    else {
      emittedContentBytes = CodeModeOutputByteLimits.cellOutputBytes(
        request.options.maxCellOutputBytes)
      lock.unlock()
      finish(
        CodeModeCompletion(
          error: "Code-mode cell output exceeded the configured cumulative byte limit."))
      return
    }
    emittedContentBytes = updatedContentBytes
    content.append(ToolContentBlock(fields: fields))
    if shouldYield { yieldVersion += 1 }
    let pending = shouldYield ? drainReadyWaitersLocked() : []
    lock.unlock()
    resume(pending)
  }

  private func notify(text: String) {
    guard !isClosed else { return }
    guard
      text.utf8.count
        <= CodeModeOutputByteLimits.contentBlockBytes(request.options.maxContentBlockBytes)
    else {
      finish(
        CodeModeCompletion(error: "Code-mode notification exceeded the configured byte limit."))
      return
    }
    request.notificationHandler(text)
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

  private func complete(payload: String) {
    guard
      payload.utf8.count
        <= CodeModeOutputByteLimits.contentBlockBytes(request.options.maxContentBlockBytes)
    else {
      finish(CodeModeCompletion(error: "Code-mode completion exceeded the configured byte limit."))
      return
    }
    guard let value = Self.parseJSON(payload) else {
      finish(CodeModeCompletion(error: "Code-mode runtime returned an invalid completion payload."))
      return
    }
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
    queue.async { [weak self] in
      self?.jsBridge = nil
      self?.jsContext = nil
    }
    resume(pending)
    for waiter in completionWaiters {
      waiter.resume(returning: completion)
    }
  }

  private var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return terminated || finalCompletion != nil
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
    let snapshot = snapshotLocked(cursor: waiter.cursor, observedYieldVersion: waiter.yieldVersion)
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
    for task in tasks {
      task.cancel()
    }
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
