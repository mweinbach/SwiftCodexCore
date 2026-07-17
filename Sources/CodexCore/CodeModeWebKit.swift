#if os(iOS)
  import Foundation
  import WebKit

  /// Runs code-mode cells outside the app process in dedicated Web Workers
  /// hosted by a private, nonpersistent WebKit page.
  ///
  /// WebKit may pool its content processes, so this is not a one-process-per-cell
  /// sandbox. Each cell does receive its own Worker boundary, which lets the
  /// host stop synchronous non-yielding JavaScript with `Worker.terminate()`.
  public final class WebKitCodeModeEngine: CodeModeEngine, @unchecked Sendable {
    private let host: WebKitCodeModeHostCoordinator
    public let startupTimeoutMilliseconds: Int

    public init(startupTimeoutMilliseconds: Int = 10_000) {
      self.startupTimeoutMilliseconds = max(250, min(startupTimeoutMilliseconds, 60_000))
      self.host = WebKitCodeModeHostCoordinator()
    }

    public func start(request: CodeModeExecutionRequest) -> any CodeModeCellSession {
      WebKitCodeModeCell(
        request: request,
        host: host,
        startupTimeoutMilliseconds: startupTimeoutMilliseconds
      )
    }
  }

  private final class WebKitCodeModeHostCoordinator: @unchecked Sendable {
    private struct Registration {
      var cell: WebKitCodeModeCell
      var generation: UUID?
    }

    private let lock = NSLock()
    private let eventQueue = DispatchQueue(
      label: "SwiftCodexCore.WebKitCodeModeHost.events",
      qos: .userInitiated
    )
    private var cells: [String: Registration] = [:]
    @MainActor private var pageHost: WebKitCodeModePageHost?

    func start(cell: WebKitCodeModeCell, token: String, program: String, maxEventBytes: Int) {
      lock.withLock { cells[cell.hostCellID] = Registration(cell: cell, generation: nil) }
      Task { @MainActor [weak self] in
        guard let self, self.registration(id: cell.hostCellID) != nil else { return }
        let pageHost: WebKitCodeModePageHost
        if let existing = self.pageHost {
          pageHost = existing
        } else {
          let created = WebKitCodeModePageHost(coordinator: self)
          self.pageHost = created
          pageHost = created
        }
        guard self.assign(cellID: cell.hostCellID, to: pageHost.generation) else { return }
        pageHost.start(
          cellID: cell.hostCellID,
          token: token,
          program: program,
          maxEventBytes: maxEventBytes
        )
      }
    }

    func finish(cellID: String) {
      let removed = lock.withLock { cells.removeValue(forKey: cellID) != nil }
      guard removed else { return }
      Task { @MainActor [weak self] in self?.pageHost?.terminate(cellID: cellID) }
    }

    func receive(rawEvent: String, generation: UUID, reply: WebKitCodeModeReply) {
      eventQueue.async { [weak self] in
        guard let separator = rawEvent.firstIndex(of: "\n") else {
          reply.reject("Code-mode host received an invalid message envelope.")
          return
        }
        let cellID = String(rawEvent[..<separator])
        guard let registration = self?.registration(id: cellID),
          registration.generation == generation
        else {
          reply.reject("Unknown or completed code-mode host cell.")
          return
        }
        let eventText = String(rawEvent[rawEvent.index(after: separator)...])
        guard
          eventText.utf8.count <= CodeModeOutputByteLimits.maximumContentBlockBytes + 65_536,
          let data = eventText.data(using: .utf8),
          let event = try? JSONDecoder.codex.decode(JSONValue.self, from: data),
          event["cell_id"]?.stringValue == cellID
        else {
          let message = "Code-mode host received an invalid or oversized message."
          registration.cell.hostFailed(message)
          reply.reject(message)
          return
        }
        registration.cell.receive(event: event, reply: reply)
      }
    }

    @MainActor
    func fail(cellID: String, generation: UUID, message: String) {
      guard let registration = registration(id: cellID), registration.generation == generation
      else { return }
      registration.cell.hostFailed(message)
    }

    @MainActor
    func pageHostFailed(_ failedHost: WebKitCodeModePageHost, message: String) {
      guard pageHost === failedHost else { return }
      pageHost = nil
      let activeCells = lock.withLock {
        let failedIDs = cells.compactMap { id, registration in
          registration.generation == failedHost.generation ? id : nil
        }
        return failedIDs.compactMap { cells.removeValue(forKey: $0)?.cell }
      }
      for cell in activeCells { cell.hostFailed(message, unregister: false) }
    }

    private func registration(id: String) -> Registration? {
      lock.withLock { cells[id] }
    }

    private func assign(cellID: String, to generation: UUID) -> Bool {
      lock.withLock {
        guard var registration = cells[cellID] else { return false }
        registration.generation = generation
        cells[cellID] = registration
        return true
      }
    }
  }

  private final class WebKitCodeModeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable (Any?, String?) -> Void)?

    init(_ handler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
      self.handler = handler
    }

    func resolve(_ value: String? = nil) {
      complete(value: value, error: nil)
    }

    func reject(_ message: String) {
      complete(value: nil, error: message)
    }

    private func complete(value: String?, error: String?) {
      guard
        let handler = lock.withLock({ () -> (@MainActor @Sendable (Any?, String?) -> Void)? in
          defer { self.handler = nil }
          return self.handler
        })
      else { return }
      Task { @MainActor in handler(value, error) }
    }
  }

  @MainActor
  private final class WebKitCodeModeMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: WebKitCodeModePageHost?

    init(owner: WebKitCodeModePageHost) {
      self.owner = owner
    }

    func userContentController(
      _: WKUserContentController,
      didReceive message: WKScriptMessage,
      replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
      guard let owner else {
        replyHandler(nil, "Code-mode WebKit host is no longer available.")
        return
      }
      owner.receive(message: message, reply: WebKitCodeModeReply(replyHandler))
    }
  }

  @MainActor
  private final class WebKitCodeModePageHost: NSObject, WKNavigationDelegate {
    private enum State: Equatable {
      case loading
      case installingRelay
      case ready
      case failed
    }

    weak var coordinator: WebKitCodeModeHostCoordinator?
    let generation = UUID()
    let contentWorld: WKContentWorld
    private let handlerName: String
    private let relayName: String
    private var state: State = .loading
    private var webView: WKWebView?
    private var messageProxy: WebKitCodeModeMessageProxy?
    private var pendingStarts: [String: (token: String, program: String, maxEventBytes: Int)] = [:]
    private var activeCellIDs: Set<String> = []

    init(coordinator: WebKitCodeModeHostCoordinator) {
      self.coordinator = coordinator
      let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      self.handlerName = "codexCodeMode_\(suffix)"
      self.relayName = "__codexCodeModeRelay_\(suffix)"
      self.contentWorld = WKContentWorld.world(name: "SwiftCodexCore.CodeMode.\(suffix)")
      super.init()
      createPage()
    }

    func start(cellID: String, token: String, program: String, maxEventBytes: Int) {
      guard state != .failed else {
        coordinator?.fail(
          cellID: cellID,
          generation: generation,
          message: "The WebKit code-mode host is unavailable."
        )
        return
      }
      pendingStarts[cellID] = (token, program, maxEventBytes)
      guard state == .ready else { return }
      launchPendingCell(cellID)
    }

    func terminate(cellID: String) {
      pendingStarts.removeValue(forKey: cellID)
      guard activeCellIDs.remove(cellID) != nil, let webView, state == .ready else { return }
      Task { @MainActor [weak self, weak webView] in
        guard let self, let webView else { return }
        _ = try? await webView.callAsyncJavaScript(
          "globalThis[relayName]?.terminate(cellID);",
          arguments: ["relayName": self.relayName, "cellID": cellID],
          in: nil,
          contentWorld: self.contentWorld
        )
      }
    }

    func receive(message: WKScriptMessage, reply: WebKitCodeModeReply) {
      guard message.webView === webView else {
        reply.reject("Code-mode host rejected a message from the wrong web view.")
        return
      }
      guard message.frameInfo.isMainFrame else {
        reply.reject("Code-mode host rejected a message from a non-main frame.")
        return
      }
      guard message.world === contentWorld else {
        reply.reject("Code-mode host rejected a message from the wrong content world.")
        return
      }
      guard let rawEvent = message.body as? String else {
        reply.reject("Code-mode host received a non-string message.")
        return
      }
      guard let coordinator else {
        reply.reject("Code-mode WebKit host is no longer available.")
        return
      }
      coordinator.receive(rawEvent: rawEvent, generation: generation, reply: reply)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
      guard state == .loading else { return }
      state = .installingRelay
      installRelay()
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
      fail("Unable to load the WebKit code-mode host: \(error)")
    }

    func webView(
      _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error
    ) {
      fail("Unable to load the WebKit code-mode host: \(error)")
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
      fail("The WebKit code-mode content process terminated before completion.")
    }

    func webView(
      _: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      let scheme = navigationAction.request.url?.scheme?.lowercased()
      let isInitialDocument = state == .loading && (scheme == nil || scheme == "about")
      decisionHandler(isInitialDocument ? .allow : .cancel)
    }

    private func createPage() {
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.defaultWebpagePreferences.allowsContentJavaScript = false
      configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
      configuration.mediaTypesRequiringUserActionForPlayback = .all

      let controller = WKUserContentController()
      let proxy = WebKitCodeModeMessageProxy(owner: self)
      controller.addScriptMessageHandler(proxy, contentWorld: contentWorld, name: handlerName)
      configuration.userContentController = controller

      let webView = WKWebView(frame: .zero, configuration: configuration)
      webView.navigationDelegate = self
      webView.isInspectable = false
      self.messageProxy = proxy
      self.webView = webView
      webView.loadHTMLString(CodeModeWebKitProgram.documentHTML, baseURL: nil)
    }

    private func installRelay() {
      guard let webView else {
        fail("The WebKit code-mode page disappeared during startup.")
        return
      }
      let program = CodeModeWebKitProgram.makeRelay(
        handlerName: handlerName,
        relayName: relayName
      )
      Task { @MainActor [weak self, weak webView] in
        guard let self, let webView, self.state == .installingRelay else { return }
        do {
          _ = try await webView.callAsyncJavaScript(
            program,
            arguments: [:],
            in: nil,
            contentWorld: self.contentWorld
          )
          guard self.state == .installingRelay else { return }
          self.state = .ready
          for cellID in Array(self.pendingStarts.keys) { self.launchPendingCell(cellID) }
        } catch {
          self.fail("Unable to install the WebKit code-mode relay: \(error)")
        }
      }
    }

    private func launchPendingCell(_ cellID: String) {
      guard state == .ready, let webView, let pending = pendingStarts.removeValue(forKey: cellID)
      else { return }
      activeCellIDs.insert(cellID)
      Task { @MainActor [weak self, weak webView] in
        guard let self, let webView, self.activeCellIDs.contains(cellID), self.state == .ready
        else { return }
        do {
          _ = try await webView.callAsyncJavaScript(
            "return globalThis[relayName].start({cell_id: cellID, token: token, program: program, max_event_bytes: maxEventBytes});",
            arguments: [
              "relayName": self.relayName,
              "cellID": cellID,
              "token": pending.token,
              "program": pending.program,
              "maxEventBytes": pending.maxEventBytes,
            ],
            in: nil,
            contentWorld: self.contentWorld
          )
        } catch {
          self.activeCellIDs.remove(cellID)
          self.coordinator?.fail(
            cellID: cellID,
            generation: self.generation,
            message: "Unable to start the WebKit code-mode worker: \(error)"
          )
        }
      }
    }

    private func fail(_ message: String) {
      guard state != .failed else { return }
      state = .failed
      let webView = self.webView
      self.webView = nil
      activeCellIDs.removeAll()
      pendingStarts.removeAll()
      if let webView {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
          forName: handlerName,
          contentWorld: contentWorld
        )
      }
      messageProxy = nil
      coordinator?.pageHostFailed(self, message: message)
    }
  }

  private final class WebKitCodeModeCell: CodeModeCellSession, @unchecked Sendable {
    private struct Waiter {
      var cursor: Int
      var yieldVersion: Int
      var continuation: CheckedContinuation<CodeModeCellSnapshot, Never>
    }

    private struct ToolInvocation {
      var task: Task<Void, Never>
      var reply: WebKitCodeModeReply
    }

    let hostCellID = UUID().uuidString.lowercased()
    private let request: CodeModeExecutionRequest
    private let bindings: [CodeModeToolBinding]
    private let bindingsByPublicName: [String: CodeModeToolBinding]
    private let host: WebKitCodeModeHostCoordinator
    private let lock = NSLock()
    private let toolTaskLock = NSLock()
    private var content: [ToolContentBlock] = []
    private var emittedContentBytes = 0
    private var yieldVersion = 0
    private var finalCompletion: CodeModeCompletion?
    private var terminated = false
    private var hostReady = false
    private var waiters: [UUID: Waiter] = [:]
    private var completionWaiters: [CheckedContinuation<CodeModeCompletion, Never>] = []
    private var toolInvocations: [String: ToolInvocation] = [:]
    private var startupTask: Task<Void, Never>?

    init(
      request: CodeModeExecutionRequest,
      host: WebKitCodeModeHostCoordinator,
      startupTimeoutMilliseconds: Int
    ) {
      self.request = request
      let bindings = CodeModeToolCatalog.bindings(
        definitions: request.definitions,
        options: request.options
      )
      self.bindings = bindings
      self.bindingsByPublicName = Dictionary(
        uniqueKeysWithValues: bindings.map { ($0.publicName, $0) }
      )
      self.host = host
      let token = UUID().uuidString.lowercased()
      let program = CodeModeWebKitProgram.makeWorker(
        bindings: bindings.map(CodeModeHostBinding.init),
        initialStore: request.initialStore,
        source: request.source,
        token: token
      )
      startupTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(startupTimeoutMilliseconds))
        guard !Task.isCancelled else { return }
        self?.startupTimedOut()
      }
      host.start(
        cell: self,
        token: token,
        program: program,
        maxEventBytes: CodeModeOutputByteLimits.contentBlockBytes(
          request.options.maxContentBlockBytes)
      )
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
          cursor: cursor,
          yieldVersion: observedYieldVersion,
          continuation: continuation
        )
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
    }

    func receive(event: JSONValue, reply: WebKitCodeModeReply) {
      guard !isClosed else {
        reply.reject("Code-mode cell was terminated.")
        return
      }
      guard let type = event["type"]?.stringValue else {
        reply.reject("Code-mode host emitted an event without a type.")
        failProtocol("Code-mode host emitted an invalid event.")
        return
      }
      switch type {
      case "host_ready":
        markHostReady()
        reply.resolve()
      case "tool_call":
        guard let identifier = event["id"]?.stringValue,
          let publicName = event["name"]?.stringValue
        else {
          reply.reject("Code-mode host emitted an invalid tool call.")
          failProtocol("Code-mode host emitted an invalid tool call.")
          return
        }
        invokeTool(
          identifier: identifier,
          publicName: publicName,
          rawArguments: event["arguments"]?.stringValue ?? "{}",
          reply: reply
        )
      case "emit":
        guard let payload = event["payload"]?.stringValue else {
          reply.reject("Code-mode host emitted an invalid content block.")
          failProtocol("Code-mode host emitted an invalid content block.")
          return
        }
        reply.resolve()
        emit(payload: payload, shouldYield: event["yield"]?.boolValue ?? false)
      case "notify":
        guard let text = event["text"]?.stringValue else {
          reply.reject("Code-mode host emitted an invalid notification.")
          failProtocol("Code-mode host emitted an invalid notification.")
          return
        }
        reply.resolve()
        notify(text: text)
      case "yield":
        reply.resolve()
        signalYield()
      case "complete":
        guard let payload = event["payload"]?.stringValue else {
          reply.reject("Code-mode host emitted an invalid completion.")
          failProtocol("Code-mode host emitted an invalid completion.")
          return
        }
        reply.resolve()
        complete(payload: payload)
      case "host_error", "worker_error":
        let message =
          event["error"]?.stringValue ?? event["message"]?.stringValue
          ?? "The WebKit worker failed."
        reply.resolve()
        failProtocol("WebKit code-mode worker failed: \(message)")
      default:
        // Unknown event types are ignored to keep the bridge forwards-compatible.
        reply.resolve()
      }
    }

    func hostFailed(_ message: String, unregister: Bool = true) {
      finish(CodeModeCompletion(error: message), unregister: unregister)
    }

    private func markHostReady() {
      let startupTask = lock.withLock {
        hostReady = true
        let task = self.startupTask
        self.startupTask = nil
        return task
      }
      startupTask?.cancel()
    }

    private func startupTimedOut() {
      let ready = lock.withLock { hostReady || finalCompletion != nil || terminated }
      guard !ready else { return }
      finish(CodeModeCompletion(error: "The WebKit code-mode host timed out during startup."))
    }

    private func invokeTool(
      identifier: String,
      publicName: String,
      rawArguments: String,
      reply: WebKitCodeModeReply
    ) {
      guard let binding = bindingsByPublicName[publicName] else {
        reply.reject("Unknown nested tool: \(publicName)")
        return
      }
      let task = Task.detached { [request, self] in
        defer { removeToolInvocation(identifier: identifier) }
        guard !isClosed else {
          reply.reject("Code-mode cell was terminated.")
          return
        }
        let arguments = Self.parseJSON(rawArguments) ?? .object([:])
        do {
          let result = try await request.registry.run(
            name: binding.toolName,
            arguments: arguments,
            context: request.context
          )
          guard !isClosed else {
            reply.reject("Code-mode cell was terminated.")
            return
          }
          guard !result.isError else {
            reply.reject(result.content)
            return
          }
          let value = CodeModeToolResultEncoder.value(
            result,
            maxOutputTokens: max(1, request.options.maxNestedToolOutputTokens),
            tokenCounter: request.tokenCounter
          )
          guard let payload = Self.jsonString(value) else {
            reply.reject("Nested tool returned an unencodable result.")
            return
          }
          reply.resolve(payload)
        } catch {
          reply.reject(String(describing: error))
        }
      }
      toolTaskLock.withLock {
        toolInvocations[identifier] = ToolInvocation(task: task, reply: reply)
      }
      if isClosed { cancelToolInvocations() }
    }

    private func emit(payload: String, shouldYield: Bool) {
      let payloadBytes = payload.utf8.count
      guard
        payloadBytes
          <= CodeModeOutputByteLimits.contentBlockBytes(
            request.options.maxContentBlockBytes)
      else {
        failProtocol("Code-mode content block exceeded the configured byte limit.")
        return
      }
      guard let value = Self.parseJSON(payload), case .object(let fields) = value else {
        failProtocol("Code-mode host emitted an invalid content block.")
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
        failProtocol("Code-mode cell output exceeded the configured cumulative byte limit.")
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
          <= CodeModeOutputByteLimits.contentBlockBytes(
            request.options.maxContentBlockBytes)
      else {
        failProtocol("Code-mode notification exceeded the configured byte limit.")
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
          <= CodeModeOutputByteLimits.contentBlockBytes(
            request.options.maxContentBlockBytes)
      else {
        failProtocol("Code-mode completion exceeded the configured byte limit.")
        return
      }
      guard let value = Self.parseJSON(payload) else {
        failProtocol("Code-mode runtime returned an invalid completion payload.")
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
        )
      )
    }

    private func failProtocol(_ message: String) {
      finish(CodeModeCompletion(error: message))
    }

    private func finish(
      _ completion: CodeModeCompletion,
      stateTerminated: Bool = false,
      unregister: Bool = true
    ) {
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
      let startupTask = self.startupTask
      self.startupTask = nil
      lock.unlock()
      startupTask?.cancel()
      cancelToolInvocations()
      if unregister { host.finish(cellID: hostCellID) }
      resume(pending)
      for waiter in completionWaiters { waiter.resume(returning: completion) }
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
      for (continuation, snapshot) in pending { continuation.resume(returning: snapshot) }
    }

    private func removeToolInvocation(identifier: String) {
      _ = toolTaskLock.withLock { toolInvocations.removeValue(forKey: identifier) }
    }

    private func cancelToolInvocations() {
      let invocations = toolTaskLock.withLock {
        let invocations = Array(toolInvocations.values)
        toolInvocations.removeAll()
        return invocations
      }
      for invocation in invocations {
        invocation.task.cancel()
        invocation.reply.reject("Code-mode cell was terminated.")
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
#endif
