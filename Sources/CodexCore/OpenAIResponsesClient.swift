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

        public static var openAIPlatform: Options { Options(endpoint: URL(string: "https://api.openai.com/v1/responses")!) }

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

    public init(auth: any AuthorizationProvider, options: Options = Options(), session: URLSession = .shared) {
        self.auth = auth
        self.options = options
        self.session = session
    }

    public var supportsResponseContinuation: Bool {
        options.supportsResponseContinuation
    }

    /// Sends a Responses request and yields canonical model events as bytes arrive.
    public func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, http) = try await send(request, allowRefresh: true)
                    let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                    if contentType.contains("text/event-stream") {
                        try await Self.parseSSE(bytes: bytes, continuation: continuation)
                    } else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        try Self.parseJSONResponse(data: data, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
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
    public func createBackgroundResponse(_ request: ResponsesRequest) async throws -> OpenAIResponseSnapshot {
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
            allowRefresh: true
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

    /// Converts a retrieved foreground/background response snapshot into the same events
    /// emitted by non-streaming Responses calls.
    public static func modelEvents(from snapshot: OpenAIResponseSnapshot) throws -> [ModelStreamEvent] {
        try eventsFromResponseObject(snapshot.raw)
    }

    private func send(_ request: ResponsesRequest, allowRefresh: Bool) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: try makeURLRequest(request))
        guard let http = response as? HTTPURLResponse else {
            throw CodexCoreError.transportError("Responses API did not return an HTTP response")
        }
        if http.statusCode == 401, allowRefresh, let refreshing = auth as? any TokenRefreshingAuthorizationProvider {
            _ = try await collectBody(bytes)
            try await refreshing.refreshNow()
            return try await send(request, allowRefresh: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            let data = try await collectBody(bytes)
            throw CodexCoreError.transportError("Responses API HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return (bytes, http)
    }

    private func makeURLRequest(_ request: ResponsesRequest) async throws -> URLRequest {
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
            accept: "text/event-stream, application/json"
        )
        if request.multiAgent?.enabled == true {
            let beta = "responses_multi_agent=v1"
            let current = urlRequest.value(forHTTPHeaderField: "OpenAI-Beta") ?? ""
            if !current.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(beta) {
                urlRequest.setValue(current.isEmpty ? beta : "\(current), \(beta)", forHTTPHeaderField: "OpenAI-Beta")
            }
        }
        return urlRequest
    }

    private func sendData(method: String, url: URL, body: Data?, accept: String, allowRefresh: Bool) async throws -> Data {
        let request = try await makeURLRequest(method: method, url: url, body: body, accept: accept)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexCoreError.transportError("Responses API did not return an HTTP response")
        }
        if http.statusCode == 401, allowRefresh, let refreshing = auth as? any TokenRefreshingAuthorizationProvider {
            try await refreshing.refreshNow()
            return try await sendData(method: method, url: url, body: body, accept: accept, allowRefresh: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexCoreError.transportError("Responses API HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return data
    }

    private func makeURLRequest(method: String, url: URL, body: Data?, accept: String) async throws -> URLRequest {
        var urlRequest = URLRequest(url: url, timeoutInterval: options.requestTimeout)
        urlRequest.httpMethod = method
        urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !body.isEmpty {
                urlRequest.httpBody = body
            }
        }
        for (key, value) in try await auth.authorizationHeaders() { urlRequest.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in options.extraHeaders { urlRequest.setValue(value, forHTTPHeaderField: key) }
        return urlRequest
    }

    private func responseURL(id: String) -> URL {
        options.endpoint.appendingPathComponent(id)
    }

    private func collectBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    private struct SSEParserState {
        var eventName: String?
        var dataLines: [String] = []
    }

    private static func parseSSE(bytes: URLSession.AsyncBytes, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation) async throws {
        var line = Data()
        var state = SSEParserState()
        for try await byte in bytes {
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
        if !line.isEmpty {
            if line.last == 0x0D { line.removeLast() }
            guard let text = String(data: line, encoding: .utf8) else {
                throw CodexCoreError.invalidJSON("SSE response line was not UTF-8")
            }
            try processSSELine(text, continuation: continuation, state: &state)
        }
        try processSSELine("", continuation: continuation, state: &state)
    }

    private static func parseSSE(data: Data, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw CodexCoreError.invalidJSON("SSE response was not UTF-8") }
        var state = SSEParserState()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            try processSSELine(String(rawLine), continuation: continuation, state: &state)
        }
        try processSSELine("", continuation: continuation, state: &state)
    }

    private static func processSSELine(_ rawLine: String, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation, state: inout SSEParserState) throws {
        let line = rawLine.trimmingCharacters(in: .newlines)
        if line.isEmpty {
            guard !state.dataLines.isEmpty else { return }
            let payload = state.dataLines.joined(separator: "\n")
            state.dataLines.removeAll(keepingCapacity: true)
            defer { state.eventName = nil }
            if payload == "[DONE]" { return }
            try emitEvent(named: state.eventName, dataString: payload, continuation: continuation)
        } else if line.hasPrefix(":") {
            return
        } else if line.hasPrefix("event:") {
            state.eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            state.dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
    }

    private static func parseJSONResponse(data: Data, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation) throws {
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

    private static func emitEvent(named eventName: String?, dataString: String, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation) throws {
        guard let data = dataString.data(using: .utf8) else { return }
        let json = try JSONDecoder.codex.decode(JSONValue.self, from: data)
        let type = json["type"]?.stringValue ?? eventName ?? ""
        for event in try eventsFromStreamObject(json, type: type) {
            continuation.yield(event)
        }
    }

    private static func eventsFromStreamObject(_ json: JSONValue, type: String) throws -> [ModelStreamEvent] {
        switch type {
        case "response.output_text.delta":
            return [.outputTextDelta(json["delta"]?.stringValue ?? "")]
        case "response.reasoning_summary_text.delta", "response.reasoning.delta", "response.output_text.annotation.added":
            return [.reasoningDelta(json["delta"]?.stringValue ?? "")]
        case "response.function_call_arguments.delta":
            let callID = json["call_id"]?.stringValue ?? json["item_id"]?.stringValue ?? "unknown"
            return [.toolCallDelta(callID: callID, name: nil, argumentsDelta: json["delta"]?.stringValue ?? "")]
        case "response.output_item.done":
            guard let item = json["item"] else { return [.raw(json)] }
            if let call = try toolCall(fromOutputItem: item) {
                return [.toolCallCompleted(call)]
            }
            if let name = serverToolName(fromOutputItem: item) {
                return [.serverToolCompleted(name: name, item: item)]
            }
            if let text = extractText(fromOutputItem: item), !text.isEmpty {
                return [.messageCompleted(text)]
            }
            return [.raw(json)]
        case "response.web_search_call.completed", "response.web_search_call.done":
            guard let item = json["item"], ResponseInputBuilder.replayableServerToolOutput(item) != nil else { return [] }
            return [.serverToolCompleted(name: "web_search", item: item)]
        case "response.image_generation_call.completed", "response.image_generation_call.done":
            guard let item = json["item"], ResponseInputBuilder.replayableServerToolOutput(item) != nil else { return [] }
            return [.serverToolCompleted(name: "image_generation", item: item)]
        case "response.completed":
            let response = json["response"]
            let responseID = response?["id"]?.stringValue
            let usage = response?["usage"].flatMap(parseUsage)
            return [.completed(responseID: responseID, usage: usage)]
        case "response.failed", "error":
            let message = json["error"]?["message"]?.stringValue ?? json["message"]?.stringValue ?? json.description
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
                    events.append(.messageCompleted(text))
                    events.append(.outputTextDelta(text))
                }
            }
        } else if let text = json["output_text"]?.stringValue {
            events.append(.messageCompleted(text))
            events.append(.outputTextDelta(text))
        }
        events.append(.completed(responseID: json["id"]?.stringValue, usage: json["usage"].flatMap(parseUsage)))
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
        guard item["type"]?.stringValue == "function_call" else { return nil }
        let callID = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? UUID().uuidString
        let name = item["name"]?.stringValue ?? "unknown"
        let arguments = item["arguments"]?.stringValue ?? "{}"
        let rawArguments: JSONValue?
        if let data = arguments.data(using: .utf8), let decoded = try? JSONDecoder.codex.decode(JSONValue.self, from: data) {
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
            caller: item["caller"]
        )
    }

    private static func serverToolName(fromOutputItem item: JSONValue) -> String? {
        guard let type = item["type"]?.stringValue else { return nil }
        if type == "web_search_call" || type == "web_search" { return "web_search" }
        if type == "image_generation_call" || type == "image_generation" { return "image_generation" }
        if type == "mcp_call" || type == "tool_call" { return item["name"]?.stringValue ?? type }
        return nil
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
            guard let double = object[key]?.doubleValue else { return nil }
            return Int(double)
        }
        func nestedInt(_ objectKey: String, _ valueKey: String) -> Int? {
            guard let double = object[objectKey]?[valueKey]?.doubleValue else { return nil }
            return Int(double)
        }
        return TokenUsage(
            inputTokens: int("input_tokens"),
            outputTokens: int("output_tokens"),
            totalTokens: int("total_tokens"),
            cachedInputTokens: nestedInt("input_tokens_details", "cached_tokens"),
            cacheWriteTokens: int("cache_write_tokens") ?? nestedInt("input_tokens_details", "cache_write_tokens"),
            reasoningOutputTokens: nestedInt("output_tokens_details", "reasoning_tokens")
        )
    }
}
