import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public final class OpenAIResponsesClient: ModelProvider, Sendable {
  public struct Options: Sendable, Equatable {
    public var endpoint: URL
    public var extraHeaders: [String: String]
    public var requestTimeout: TimeInterval
    public var sendsMetadata: Bool
    public var supportsResponseContinuation: Bool

    public init(
      endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
      extraHeaders: [String: String] = [:],
      requestTimeout: TimeInterval = 600,
      sendsMetadata: Bool = true,
      supportsResponseContinuation: Bool = true
    ) {
      self.endpoint = endpoint
      self.extraHeaders = extraHeaders
      self.requestTimeout = requestTimeout
      self.sendsMetadata = sendsMetadata
      self.supportsResponseContinuation = supportsResponseContinuation
    }

    public static var openAIPlatform: Options {
      Options(endpoint: URL(string: "https://api.openai.com/v1/responses")!)
    }

    public static var chatGPTCodexBackend: Options {
      Options(
        endpoint: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
        sendsMetadata: false,
        supportsResponseContinuation: false
      )
    }
  }

  private let auth: any AuthorizationProvider
  private let options: Options
  private let session: URLSession
  private let modelsManager: OpenAIModelsManager?
  private let transportPolicy: ResponsesTransportPolicy
  private let diagnostics: ResponsesTransportDiagnosticsHandler
  private let sleeper: @Sendable (TimeInterval) async throws -> Void

  public convenience init(
    auth: any AuthorizationProvider,
    options: Options = Options(),
    session: URLSession = .shared,
    modelsManager: OpenAIModelsManager? = nil,
    transportPolicy: ResponsesTransportPolicy = .default,
    diagnostics: @escaping ResponsesTransportDiagnosticsHandler = { _ in }
  ) {
    self.init(
      auth: auth,
      options: options,
      session: session,
      modelsManager: modelsManager,
      transportPolicy: transportPolicy,
      diagnostics: diagnostics,
      sleeper: { delay in
        try Task.checkCancellation()
        guard delay.isFinite, delay > 0 else { return }
        let upperBound = Double(UInt64.max).nextDown
        let nanoseconds = UInt64(min(delay * 1_000_000_000, upperBound))
        try await Task.sleep(nanoseconds: nanoseconds)
      }
    )
  }

  init(
    auth: any AuthorizationProvider,
    options: Options = Options(),
    session: URLSession = .shared,
    modelsManager: OpenAIModelsManager? = nil,
    transportPolicy: ResponsesTransportPolicy = .default,
    diagnostics: @escaping ResponsesTransportDiagnosticsHandler = { _ in },
    sleeper: @escaping @Sendable (TimeInterval) async throws -> Void
  ) {
    self.auth = auth
    self.options = options
    self.session = session
    self.modelsManager = modelsManager
    self.transportPolicy = transportPolicy
    self.diagnostics = diagnostics
    self.sleeper = sleeper
  }

  public var supportsResponseContinuation: Bool {
    options.supportsResponseContinuation
  }

  /// Sends a Responses request and yields canonical model events as bytes arrive.
  public func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<
    ModelStreamEvent, Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, http) = try await send(request, allowRefresh: true)
          if let etag = http.value(forHTTPHeaderField: "X-Models-Etag") {
            await modelsManager?.refreshIfNewETag(etag)
            continuation.yield(.modelCatalogETag(etag))
          }
          let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
          if contentType.contains("text/event-stream") {
            try await Self.parseSSE(bytes: bytes, continuation: continuation)
          } else {
            let data = try await collectBody(bytes)
            try Self.parseJSONResponse(data: data, continuation: continuation)
          }
          continuation.finish()
        } catch {
          if Self.isCancellation(error) {
            continuation.finish(throwing: CancellationError())
          } else {
            continuation.finish(throwing: error)
          }
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  /// Starts a Responses API background job and returns the persisted response snapshot.
  ///
  /// The returned snapshot can be saved by the host app and refreshed later with
  /// ``retrieveResponse(id:)``. This is the primitive iOS hosts need for work that
  /// should continue on the server after the app is suspended.
  public func createBackgroundResponse(_ request: ResponsesRequest) async throws
    -> OpenAIResponseSnapshot
  {
    var backgroundRequest = request
    backgroundRequest.background = true
    backgroundRequest.stream = false
    if backgroundRequest.store == nil {
      backgroundRequest.store = true
    }
    let body = try JSONEncoder.codexCompact.encode(backgroundRequest)
    let data = try await sendData(
      method: "POST",
      url: options.endpoint,
      body: body,
      accept: "application/json",
      allowRefresh: true,
      useResponsesLite: backgroundRequest.useResponsesLite
    )
    return try Self.parseResponseSnapshot(data: data)
  }

  /// Retrieves the latest persisted response snapshot for a foreground or background response id.
  public func retrieveResponse(id: String) async throws -> OpenAIResponseSnapshot {
    let data = try await sendData(
      method: "GET",
      url: responseURL(id: id),
      body: nil,
      accept: "application/json",
      allowRefresh: true
    )
    return try Self.parseResponseSnapshot(data: data)
  }

  /// Requests cancellation for an in-progress background response.
  @discardableResult
  public func cancelResponse(id: String) async throws -> OpenAIResponseSnapshot {
    let data = try await sendData(
      method: "POST",
      url: responseURL(id: id).appendingPathComponent("cancel"),
      body: Data(),
      accept: "application/json",
      allowRefresh: true
    )
    return try Self.parseResponseSnapshot(data: data)
  }

  /// Compacts a complete stateless Responses context into the canonical input
  /// window to use for the next request.
  public func compactResponse(_ request: ResponsesCompactionRequest) async throws
    -> ResponsesCompactionResult
  {
    let data = try await sendData(
      method: "POST",
      url: options.endpoint.appendingPathComponent("compact"),
      body: JSONEncoder.codexCompact.encode(request),
      accept: "application/json",
      allowRefresh: true
    )
    return try JSONDecoder.codex.decode(ResponsesCompactionResult.self, from: data)
  }

  /// Converts a retrieved foreground/background response snapshot into the same events
  /// emitted by non-streaming Responses calls.
  public static func modelEvents(from snapshot: OpenAIResponseSnapshot) throws -> [ModelStreamEvent]
  {
    try eventsFromResponseObject(snapshot.raw)
  }

  private struct RequestIdentity {
    var requestID: String
    var idempotencyKey: String?
  }

  private func send(_ request: ResponsesRequest, allowRefresh: Bool) async throws -> (
    URLSession.AsyncBytes, HTTPURLResponse
  ) {
    let method = "POST"
    let url = options.endpoint
    let identity = makeRequestIdentity(method: method)
    var canRefresh = allowRefresh
    var completedRetryCount = 0
    var attempt = 0

    while true {
      try Task.checkCancellation()
      attempt += 1

      let urlRequest: URLRequest
      do {
        urlRequest = try await makeURLRequest(request, identity: identity)
      } catch {
        try Self.throwIfCancellation(error)
        emitFailure(error, identity: identity, method: method, url: url, attempt: attempt)
        throw error
      }

      let result: (URLSession.AsyncBytes, URLResponse)
      do {
        result = try await session.bytes(for: urlRequest)
      } catch {
        try Self.throwIfCancellation(error)
        emitFailure(error, identity: identity, method: method, url: url, attempt: attempt)
        throw error
      }
      try Task.checkCancellation()

      let (bytes, response) = result
      guard let http = response as? HTTPURLResponse else {
        let error = CodexCoreError.transportError("Responses API did not return an HTTP response")
        emitFailure(error, identity: identity, method: method, url: url, attempt: attempt)
        throw error
      }

      if http.statusCode == 401,
        canRefresh,
        let refreshing = auth as? any TokenRefreshingAuthorizationProvider
      {
        do {
          _ = try await collectBody(bytes)
          try Task.checkCancellation()
          try await refreshing.refreshNow()
        } catch {
          try Self.throwIfCancellation(error)
          emitFailure(
            error,
            http: http,
            identity: identity,
            method: method,
            url: url,
            attempt: attempt
          )
          throw error
        }
        canRefresh = false
        continue
      }

      guard !(200..<300).contains(http.statusCode) else {
        return (bytes, http)
      }

      let data: Data
      do {
        data = try await collectBody(bytes)
      } catch {
        try Self.throwIfCancellation(error)
        emitFailure(
          error,
          http: http,
          identity: identity,
          method: method,
          url: url,
          attempt: attempt
        )
        throw error
      }
      try Task.checkCancellation()
      let retryDelay = retryDelay(
        for: http,
        completedRetryCount: completedRetryCount
      )
      emitRateLimitIfNeeded(
        http,
        retryDelay: retryDelay,
        identity: identity,
        method: method,
        url: url,
        attempt: attempt
      )

      if let retryDelay {
        completedRetryCount += 1
        emitRetry(
          http,
          delay: retryDelay,
          identity: identity,
          method: method,
          url: url,
          attempt: attempt
        )
        try await sleeper(retryDelay)
        try Task.checkCancellation()
        continue
      }

      let error = Self.httpError(statusCode: http.statusCode, data: data)
      emitFailure(
        error,
        http: http,
        identity: identity,
        method: method,
        url: url,
        attempt: attempt
      )
      throw error
    }
  }

  private func makeURLRequest(_ request: ResponsesRequest, identity: RequestIdentity) async throws
    -> URLRequest
  {
    var request = request
    if !options.sendsMetadata {
      request.metadata = [:]
    }
    if !options.supportsResponseContinuation {
      request.previousResponseID = nil
    }
    var urlRequest = try await makeURLRequest(
      method: "POST",
      url: options.endpoint,
      body: JSONEncoder.codexCompact.encode(request),
      accept: "text/event-stream, application/json",
      identity: identity,
      useResponsesLite: request.useResponsesLite
    )
    if request.multiAgent?.enabled == true {
      let beta = "responses_multi_agent=v1"
      let current = urlRequest.value(forHTTPHeaderField: "OpenAI-Beta") ?? ""
      if !current.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(
        beta)
      {
        urlRequest.setValue(
          current.isEmpty ? beta : "\(current), \(beta)", forHTTPHeaderField: "OpenAI-Beta")
      }
    }
    return urlRequest
  }

  private func sendData(
    method: String,
    url: URL,
    body: Data?,
    accept: String,
    allowRefresh: Bool,
    useResponsesLite: Bool = false
  ) async throws -> Data {
    let identity = makeRequestIdentity(method: method)
    var canRefresh = allowRefresh
    var completedRetryCount = 0
    var attempt = 0

    while true {
      try Task.checkCancellation()
      attempt += 1

      let request: URLRequest
      do {
        request = try await makeURLRequest(
          method: method,
          url: url,
          body: body,
          accept: accept,
          identity: identity,
          useResponsesLite: useResponsesLite
        )
      } catch {
        try Self.throwIfCancellation(error)
        emitFailure(error, identity: identity, method: method, url: url, attempt: attempt)
        throw error
      }

      let result: (Data, URLResponse)
      do {
        result = try await session.data(for: request)
      } catch {
        try Self.throwIfCancellation(error)
        emitFailure(error, identity: identity, method: method, url: url, attempt: attempt)
        throw error
      }
      try Task.checkCancellation()

      let (data, response) = result
      guard let http = response as? HTTPURLResponse else {
        let error = CodexCoreError.transportError("Responses API did not return an HTTP response")
        emitFailure(error, identity: identity, method: method, url: url, attempt: attempt)
        throw error
      }

      if http.statusCode == 401,
        canRefresh,
        let refreshing = auth as? any TokenRefreshingAuthorizationProvider
      {
        do {
          try Task.checkCancellation()
          try await refreshing.refreshNow()
        } catch {
          try Self.throwIfCancellation(error)
          emitFailure(
            error,
            http: http,
            identity: identity,
            method: method,
            url: url,
            attempt: attempt
          )
          throw error
        }
        canRefresh = false
        continue
      }

      guard !(200..<300).contains(http.statusCode) else {
        return data
      }

      let retryDelay = retryDelay(
        for: http,
        completedRetryCount: completedRetryCount
      )
      emitRateLimitIfNeeded(
        http,
        retryDelay: retryDelay,
        identity: identity,
        method: method,
        url: url,
        attempt: attempt
      )

      if let retryDelay {
        completedRetryCount += 1
        emitRetry(
          http,
          delay: retryDelay,
          identity: identity,
          method: method,
          url: url,
          attempt: attempt
        )
        try await sleeper(retryDelay)
        try Task.checkCancellation()
        continue
      }

      let error = Self.httpError(statusCode: http.statusCode, data: data)
      emitFailure(
        error,
        http: http,
        identity: identity,
        method: method,
        url: url,
        attempt: attempt
      )
      throw error
    }
  }

  private func makeURLRequest(
    method: String,
    url: URL,
    body: Data?,
    accept: String,
    identity: RequestIdentity,
    useResponsesLite: Bool = false
  ) async throws -> URLRequest {
    var urlRequest = URLRequest(url: url, timeoutInterval: options.requestTimeout)
    urlRequest.httpMethod = method
    urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
    if let body {
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      if !body.isEmpty {
        urlRequest.httpBody = body
      }
    }
    for (key, value) in try await auth.authorizationHeaders() {
      urlRequest.setValue(value, forHTTPHeaderField: key)
    }
    urlRequest.setValue(identity.requestID, forHTTPHeaderField: "X-Client-Request-Id")
    if let idempotencyKey = identity.idempotencyKey {
      urlRequest.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
    }
    if useResponsesLite {
      urlRequest.setValue("true", forHTTPHeaderField: "x-openai-internal-codex-responses-lite")
    }
    for (key, value) in options.extraHeaders { urlRequest.setValue(value, forHTTPHeaderField: key) }
    return urlRequest
  }

  private func makeRequestIdentity(method: String) -> RequestIdentity {
    let configuredRequestID = configuredHeaderValue(named: "X-Client-Request-Id")
      .flatMap { $0.isEmpty ? nil : $0 }
    let configuredIdempotencyKey = configuredHeaderValue(named: "Idempotency-Key")
      .flatMap { $0.isEmpty ? nil : $0 }
    return RequestIdentity(
      requestID: configuredRequestID ?? UUID().uuidString,
      idempotencyKey: method.uppercased() == "POST"
        ? (configuredIdempotencyKey ?? UUID().uuidString)
        : nil
    )
  }

  private func configuredHeaderValue(named name: String) -> String? {
    options.extraHeaders.first { key, _ in
      key.caseInsensitiveCompare(name) == .orderedSame
    }?.value
  }

  private func retryDelay(
    for response: HTTPURLResponse,
    completedRetryCount: Int
  ) -> TimeInterval? {
    guard Self.isRetryableStatus(response.statusCode),
      completedRetryCount < max(0, transportPolicy.maximumRetryCount)
    else {
      return nil
    }
    return transportPolicy.delay(
      forRetry: completedRetryCount + 1,
      retryAfter: Self.retryAfterDelay(from: response)
    )
  }

  private func emitRateLimitIfNeeded(
    _ response: HTTPURLResponse,
    retryDelay: TimeInterval?,
    identity: RequestIdentity,
    method: String,
    url: URL,
    attempt: Int
  ) {
    guard response.statusCode == 429 else { return }
    diagnostics(
      ResponsesTransportDiagnostic(
        kind: .rateLimited,
        requestID: identity.requestID,
        idempotencyKey: identity.idempotencyKey,
        method: method,
        url: url,
        attempt: attempt,
        statusCode: response.statusCode,
        serverRequestID: Self.serverRequestID(from: response),
        retryDelay: retryDelay,
        message: "Responses API rate limited the request"
      ))
  }

  private func emitRetry(
    _ response: HTTPURLResponse,
    delay: TimeInterval,
    identity: RequestIdentity,
    method: String,
    url: URL,
    attempt: Int
  ) {
    diagnostics(
      ResponsesTransportDiagnostic(
        kind: .retryScheduled,
        requestID: identity.requestID,
        idempotencyKey: identity.idempotencyKey,
        method: method,
        url: url,
        attempt: attempt,
        statusCode: response.statusCode,
        serverRequestID: Self.serverRequestID(from: response),
        retryDelay: delay,
        message: "Retrying Responses API request after HTTP \(response.statusCode)"
      ))
  }

  private func emitFailure(
    _ error: Error,
    http: HTTPURLResponse? = nil,
    identity: RequestIdentity,
    method: String,
    url: URL,
    attempt: Int
  ) {
    diagnostics(
      ResponsesTransportDiagnostic(
        kind: .requestFailed,
        requestID: identity.requestID,
        idempotencyKey: identity.idempotencyKey,
        method: method,
        url: url,
        attempt: attempt,
        statusCode: http?.statusCode,
        serverRequestID: http.flatMap(Self.serverRequestID),
        retryDelay: nil,
        message: String(describing: error)
      ))
  }

  private static func isRetryableStatus(_ statusCode: Int) -> Bool {
    statusCode == 429 || (500..<600).contains(statusCode)
  }

  private static func retryAfterDelay(from response: HTTPURLResponse) -> TimeInterval? {
    if let milliseconds = response.value(forHTTPHeaderField: "Retry-After-Ms")
      .flatMap(Double.init),
      milliseconds >= 0
    {
      return milliseconds / 1_000
    }

    guard
      let value = response.value(forHTTPHeaderField: "Retry-After")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    if let seconds = Double(value), seconds >= 0 {
      return seconds
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    for format in [
      "EEE, dd MMM yyyy HH:mm:ss zzz",
      "EEEE, dd-MMM-yy HH:mm:ss zzz",
      "EEE MMM d HH:mm:ss yyyy",
    ] {
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        return max(0, date.timeIntervalSinceNow)
      }
    }
    return nil
  }

  private static func serverRequestID(from response: HTTPURLResponse) -> String? {
    response.value(forHTTPHeaderField: "X-Request-Id")
      ?? response.value(forHTTPHeaderField: "Request-Id")
  }

  private static func httpError(statusCode: Int, data: Data) -> CodexCoreError {
    CodexCoreError.transportError(
      "Responses API HTTP \(statusCode): \(String(data: data, encoding: .utf8) ?? "")"
    )
  }

  private static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError
      || (error as? URLError)?.code == .cancelled
      || Task.isCancelled
  }

  private static func throwIfCancellation(_ error: Error) throws {
    if isCancellation(error) {
      throw CancellationError()
    }
  }

  private func responseURL(id: String) -> URL {
    options.endpoint.appendingPathComponent(id)
  }

  private func collectBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
    var data = Data()
    var byteCount = 0
    for try await byte in bytes {
      data.append(byte)
      byteCount += 1
      if byteCount.isMultiple(of: 4_096) {
        try Task.checkCancellation()
      }
    }
    try Task.checkCancellation()
    return data
  }

  private struct SSEParserState {
    var eventName: String?
    var dataLines: [String] = []
    var outputItemAgents: [Int: String] = [:]
  }

  private static func parseSSE(
    bytes: URLSession.AsyncBytes,
    continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
  ) async throws {
    var line = Data()
    var state = SSEParserState()
    var byteCount = 0
    for try await byte in bytes {
      byteCount += 1
      if byteCount.isMultiple(of: 4_096) {
        try Task.checkCancellation()
      }
      if byte == 0x0A {
        if line.last == 0x0D { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else {
          throw CodexCoreError.invalidJSON("SSE response line was not UTF-8")
        }
        try processSSELine(text, continuation: continuation, state: &state)
        line.removeAll(keepingCapacity: true)
      } else {
        line.append(byte)
      }
    }
    try Task.checkCancellation()
    if !line.isEmpty {
      if line.last == 0x0D { line.removeLast() }
      guard let text = String(data: line, encoding: .utf8) else {
        throw CodexCoreError.invalidJSON("SSE response line was not UTF-8")
      }
      try processSSELine(text, continuation: continuation, state: &state)
    }
    try processSSELine("", continuation: continuation, state: &state)
  }

  private static func parseSSE(
    data: Data, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
  ) throws {
    guard let text = String(data: data, encoding: .utf8) else {
      throw CodexCoreError.invalidJSON("SSE response was not UTF-8")
    }
    var state = SSEParserState()
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      try processSSELine(String(rawLine), continuation: continuation, state: &state)
    }
    try processSSELine("", continuation: continuation, state: &state)
  }

  private static func processSSELine(
    _ rawLine: String, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation,
    state: inout SSEParserState
  ) throws {
    let line = rawLine.trimmingCharacters(in: .newlines)
    if line.isEmpty {
      guard !state.dataLines.isEmpty else { return }
      let payload = state.dataLines.joined(separator: "\n")
      state.dataLines.removeAll(keepingCapacity: true)
      defer { state.eventName = nil }
      if payload == "[DONE]" { return }
      try emitEvent(
        named: state.eventName, dataString: payload, continuation: continuation, state: &state)
    } else if line.hasPrefix(":") {
      return
    } else if line.hasPrefix("event:") {
      state.eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
    } else if line.hasPrefix("data:") {
      state.dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
    }
  }

  private static func parseJSONResponse(
    data: Data, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
  ) throws {
    if looksLikeSSE(data) {
      try parseSSE(data: data, continuation: continuation)
      return
    }
    let json = try JSONDecoder.codex.decode(JSONValue.self, from: data)
    let events = try eventsFromResponseObject(json)
    for event in events { continuation.yield(event) }
  }

  private static func looksLikeSSE(_ data: Data) -> Bool {
    guard let text = String(data: data, encoding: .utf8) else { return false }
    let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return prefix.hasPrefix("event:") || prefix.hasPrefix("data:") || prefix.hasPrefix(":")
  }

  private static func parseResponseSnapshot(data: Data) throws -> OpenAIResponseSnapshot {
    let json = try JSONDecoder.codex.decode(JSONValue.self, from: data)
    return responseSnapshot(from: json)
  }

  private static func emitEvent(
    named eventName: String?,
    dataString: String,
    continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation,
    state: inout SSEParserState
  ) throws {
    guard let data = dataString.data(using: .utf8) else { return }
    let json = try JSONDecoder.codex.decode(JSONValue.self, from: data)
    let type = json["type"]?.stringValue ?? eventName ?? ""
    for event in try eventsFromStreamObject(json, type: type, state: &state) {
      continuation.yield(event)
    }
  }

  private static func eventsFromStreamObject(
    _ json: JSONValue, type: String, state: inout SSEParserState
  ) throws -> [ModelStreamEvent] {
    switch type {
    case "response.output_item.added":
      if let outputIndex = exactNonnegativeInteger(json["output_index"]),
        let item = json["item"]
      {
        state.outputItemAgents[outputIndex] =
          agentName(from: item) ?? agentName(from: json) ?? "/root"
      }
      return [.raw(json)]
    case "response.output_text.delta":
      if json["output_index"] != nil,
        exactNonnegativeInteger(json["output_index"]) == nil
      {
        return [.raw(json)]
      }
      if let outputIndex = exactNonnegativeInteger(json["output_index"]),
        state.outputItemAgents[outputIndex] != nil,
        state.outputItemAgents[outputIndex] != "/root"
      {
        return [.raw(json)]
      }
      return [.outputTextDelta(json["delta"]?.stringValue ?? "")]
    case "response.reasoning_summary_text.delta", "response.reasoning.delta",
      "response.output_text.annotation.added":
      return [.reasoningDelta(json["delta"]?.stringValue ?? "")]
    case "response.function_call_arguments.delta", "response.custom_tool_call_input.delta":
      let callID = json["call_id"]?.stringValue ?? json["item_id"]?.stringValue ?? "unknown"
      return [
        .toolCallDelta(callID: callID, name: nil, argumentsDelta: json["delta"]?.stringValue ?? "")
      ]
    case "response.output_item.done":
      guard let item = json["item"] else { return [.raw(json)] }
      if let call = try toolCall(fromOutputItem: item) {
        return [.toolCallCompleted(call)]
      }
      if let name = serverToolName(fromOutputItem: item) {
        return [.serverToolCompleted(name: name, item: item)]
      }
      if let text = extractText(fromOutputItem: item), !text.isEmpty {
        if isRootFinalMessage(item) {
          return [.messageCompleted(text)]
        }
        return [.responseItemCompleted(item)]
      }
      if ResponseInputBuilder.replayableServerToolOutput(item) != nil || isMultiAgentItem(item) {
        return [.responseItemCompleted(item)]
      }
      return [.raw(json)]
    case "response.web_search_call.completed", "response.web_search_call.done":
      guard let item = json["item"], ResponseInputBuilder.replayableServerToolOutput(item) != nil
      else { return [] }
      return [.serverToolCompleted(name: "web_search", item: item)]
    case "response.image_generation_call.completed", "response.image_generation_call.done":
      guard let item = json["item"], ResponseInputBuilder.replayableServerToolOutput(item) != nil
      else { return [] }
      return [.serverToolCompleted(name: "image_generation", item: item)]
    case "response.completed":
      let response = json["response"]
      let responseID = response?["id"]?.stringValue
      let usage = response?["usage"].flatMap(parseUsage)
      return [.completed(responseID: responseID, usage: usage)]
    case "response.failed", "error":
      let message =
        json["error"]?["message"]?.stringValue ?? json["message"]?.stringValue ?? json.description
      return [.failed(message)]
    default:
      return [.raw(json)]
    }
  }

  private static func eventsFromResponseObject(_ json: JSONValue) throws -> [ModelStreamEvent] {
    var events: [ModelStreamEvent] = []
    if let outputs = json["output"]?.arrayValue {
      for output in outputs {
        if let call = try toolCall(fromOutputItem: output) {
          events.append(.toolCallCompleted(call))
        } else if let name = serverToolName(fromOutputItem: output) {
          events.append(.serverToolCompleted(name: name, item: output))
        } else if let text = extractText(fromOutputItem: output), !text.isEmpty {
          if isRootFinalMessage(output) {
            events.append(.messageCompleted(text))
            events.append(.outputTextDelta(text))
          } else {
            events.append(.responseItemCompleted(output))
          }
        } else if ResponseInputBuilder.replayableServerToolOutput(output) != nil
          || isMultiAgentItem(output)
        {
          events.append(.responseItemCompleted(output))
        }
      }
    } else if let text = json["output_text"]?.stringValue {
      events.append(.messageCompleted(text))
      events.append(.outputTextDelta(text))
    }
    events.append(
      .completed(responseID: json["id"]?.stringValue, usage: json["usage"].flatMap(parseUsage)))
    return events
  }

  private static func responseSnapshot(from json: JSONValue) -> OpenAIResponseSnapshot {
    OpenAIResponseSnapshot(
      id: json["id"]?.stringValue,
      status: json["status"]?.stringValue,
      background: json["background"]?.boolValue,
      outputText: extractOutputText(fromResponseObject: json),
      usage: json["usage"].flatMap(parseUsage),
      errorMessage: errorMessage(fromResponseObject: json),
      raw: json
    )
  }

  private static func toolCall(fromOutputItem item: JSONValue) throws -> ToolCall? {
    let type = item["type"]?.stringValue
    guard type == "function_call" || type == "custom_tool_call" else { return nil }
    let callID = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? UUID().uuidString
    let name = item["name"]?.stringValue ?? "unknown"
    let isCustom = type == "custom_tool_call"
    let arguments =
      isCustom ? (item["input"]?.stringValue ?? "") : (item["arguments"]?.stringValue ?? "{}")
    let rawArguments: JSONValue?
    if !isCustom, let data = arguments.data(using: .utf8),
      let decoded = try? JSONDecoder.codex.decode(JSONValue.self, from: data)
    {
      rawArguments = decoded
    } else {
      rawArguments = nil
    }
    return ToolCall(
      id: item["id"]?.stringValue ?? UUID().uuidString,
      callID: callID,
      name: name,
      arguments: arguments,
      rawArguments: rawArguments,
      caller: item["caller"],
      kind: isCustom ? .custom : .function
    )
  }

  private static func serverToolName(fromOutputItem item: JSONValue) -> String? {
    guard let type = item["type"]?.stringValue else { return nil }
    if type == "web_search_call" || type == "web_search" { return "web_search" }
    if type == "image_generation_call" || type == "image_generation" { return "image_generation" }
    if type == "mcp_call" || type == "tool_call" { return item["name"]?.stringValue ?? type }
    if type.hasSuffix("_call"), !isMultiAgentItem(item) {
      return String(type.dropLast(5))
    }
    return nil
  }

  private static func agentName(from item: JSONValue) -> String? {
    item["agent"]?["agent_name"]?.stringValue
  }

  private static func isRootFinalMessage(_ item: JSONValue) -> Bool {
    guard item["type"]?.stringValue == "message" else { return false }
    if let agent = agentName(from: item), agent != "/root" { return false }
    if let phase = item["phase"]?.stringValue, phase != "final_answer" { return false }
    return true
  }

  private static func isMultiAgentItem(_ item: JSONValue) -> Bool {
    switch item["type"]?.stringValue {
    case "multi_agent_call", "multi_agent_call_output", "agent_message":
      return true
    default:
      return false
    }
  }

  private static func extractText(fromOutputItem item: JSONValue) -> String? {
    guard let content = item["content"]?.arrayValue else { return nil }
    var parts: [String] = []
    for part in content {
      if let text = part["text"]?.stringValue ?? part["content"]?.stringValue {
        parts.append(text)
      }
    }
    return parts.joined()
  }

  private static func extractOutputText(fromResponseObject json: JSONValue) -> String {
    if let text = json["output_text"]?.stringValue {
      return text
    }
    guard let outputs = json["output"]?.arrayValue else {
      return ""
    }
    return outputs.compactMap(extractText).joined()
  }

  private static func errorMessage(fromResponseObject json: JSONValue) -> String? {
    if let message = json["error"]?["message"]?.stringValue {
      return message
    }
    if let message = json["incomplete_details"]?["reason"]?.stringValue {
      return message
    }
    return nil
  }

  private static func parseUsage(_ value: JSONValue) -> TokenUsage? {
    guard let object = value.objectValue else { return nil }
    func int(_ key: String) -> Int? {
      exactNonnegativeInteger(object[key])
    }
    func nestedInt(_ objectKey: String, _ valueKey: String) -> Int? {
      exactNonnegativeInteger(object[objectKey]?[valueKey])
    }
    return TokenUsage(
      inputTokens: int("input_tokens"),
      outputTokens: int("output_tokens"),
      totalTokens: int("total_tokens"),
      cachedInputTokens: nestedInt("input_tokens_details", "cached_tokens"),
      cacheWriteTokens: int("cache_write_tokens")
        ?? nestedInt("input_tokens_details", "cache_write_tokens"),
      reasoningOutputTokens: nestedInt("output_tokens_details", "reasoning_tokens")
    )
  }

  static func exactNonnegativeInteger(_ value: JSONValue?) -> Int? {
    guard let number = value?.doubleValue,
      number.isFinite,
      number >= 0
    else {
      return nil
    }
    return Int(exactly: number)
  }
}
