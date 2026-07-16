import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum ResponsesWebSocketMessage: Sendable, Equatable {
  case text(String)
  case data(Data)
}

protocol ResponsesWebSocketTasking: Sendable {
  var response: URLResponse? { get }
  func resume()
  func send(_ message: ResponsesWebSocketMessage) async throws
  func receive() async throws -> ResponsesWebSocketMessage
  func cancel()
}

protocol ResponsesWebSocketTaskFactory: Sendable {
  func makeTask(with request: URLRequest, maximumMessageSize: Int) -> any ResponsesWebSocketTasking
}

struct URLSessionResponsesWebSocketTaskFactory: ResponsesWebSocketTaskFactory {
  let session: URLSession

  func makeTask(with request: URLRequest, maximumMessageSize: Int) -> any ResponsesWebSocketTasking
  {
    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = maximumMessageSize
    return URLSessionResponsesWebSocketTask(task: task)
  }
}

private final class URLSessionResponsesWebSocketTask: ResponsesWebSocketTasking,
  @unchecked Sendable
{
  private let task: URLSessionWebSocketTask

  init(task: URLSessionWebSocketTask) {
    self.task = task
  }

  var response: URLResponse? { task.response }

  func resume() {
    task.resume()
  }

  func send(_ message: ResponsesWebSocketMessage) async throws {
    switch message {
    case .text(let text):
      try await task.send(.string(text))
    case .data(let data):
      try await task.send(.data(data))
    }
  }

  func receive() async throws -> ResponsesWebSocketMessage {
    switch try await task.receive() {
    case .string(let text): return .text(text)
    case .data(let data): return .data(data)
    @unknown default:
      throw ResponsesWebSocketError.unsupportedMessage
    }
  }

  func cancel() {
    task.cancel(with: .goingAway, reason: nil)
  }
}

final class ResponsesWebSocketFallbackState: @unchecked Sendable {
  private let lock = NSLock()
  private var disabled = false

  var isDisabled: Bool {
    lock.withLock { disabled }
  }

  func disable() {
    lock.withLock { disabled = true }
  }
}

enum ResponsesWebSocketError: Error, CustomStringConvertible {
  case invalidEndpoint(URL)
  case unsupportedMessage
  case endedBeforeCompletion
  case attemptFailed(underlying: Error, statusCode: Int?)

  var description: String {
    switch self {
    case .invalidEndpoint(let url):
      return "Cannot derive a WebSocket endpoint from \(url.absoluteString)"
    case .unsupportedMessage:
      return "Responses WebSocket returned a binary or unsupported message"
    case .endedBeforeCompletion:
      return "Responses WebSocket ended before a terminal response event"
    case .attemptFailed(let error, let statusCode):
      let status = statusCode.map { " (HTTP \($0))" } ?? ""
      return "Responses WebSocket failed\(status): \(error)"
    }
  }

  var statusCode: Int? {
    guard case .attemptFailed(_, let statusCode) = self else { return nil }
    return statusCode
  }
}
