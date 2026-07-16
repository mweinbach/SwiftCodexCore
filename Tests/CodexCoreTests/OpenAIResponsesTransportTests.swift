import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import CodexCore

final class OpenAIResponsesTransportTests: XCTestCase {
    override func tearDown() {
        TransportStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testStreamingRateLimitHonorsRetryAfterAndKeepsRequestIdentity() async throws {
        let attempts = TransportLocked(0)
        let requests = TransportLocked<[TransportCapturedRequest]>([])
        let diagnostics = TransportLocked<[ResponsesTransportDiagnostic]>([])
        let delays = TransportLocked<[TimeInterval]>([])

        TransportStubURLProtocol.handler = { request in
            requests.withValue { $0.append(TransportCapturedRequest(request)) }
            let attempt = attempts.withValue { value in
                value += 1
                return value
            }
            if attempt == 1 {
                return TransportStubURLProtocol.response(
                    for: request,
                    statusCode: 429,
                    headers: ["Retry-After": "3", "X-Request-Id": "server-rate-limit"],
                    body: #"{"error":{"message":"slow down"}}"#
                )
            }
            return TransportStubURLProtocol.response(
                for: request,
                body: #"{"id":"resp_retry","output_text":"recovered"}"#
            )
        }

        let client = OpenAIResponsesClient(
            auth: TransportStaticAuthProvider(),
            options: .init(endpoint: URL(string: "https://example.test/v1/responses")!),
            session: transportTestSession(),
            transportPolicy: .init(
                maximumRetryCount: 1,
                initialBackoff: 0.01,
                maximumBackoff: 5
            ),
            diagnostics: { diagnostic in
                diagnostics.withValue { $0.append(diagnostic) }
            },
            sleeper: { delay in
                delays.withValue { $0.append(delay) }
            }
        )

        var events: [ModelStreamEvent] = []
        for try await event in client.streamResponse(ResponsesRequest(
            model: "gpt-5.6-sol",
            input: [ResponseInputBuilder.userMessage("hello")]
        )) {
            events.append(event)
        }

        XCTAssertTrue(events.contains(.outputTextDelta("recovered")))
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(delays.value, [3])

        let captured = requests.value
        XCTAssertEqual(captured.count, 2)
        XCTAssertNotNil(captured[0].requestID)
        XCTAssertEqual(captured[0].requestID, captured[1].requestID)
        XCTAssertNotNil(captured[0].idempotencyKey)
        XCTAssertEqual(captured[0].idempotencyKey, captured[1].idempotencyKey)

        let emitted = diagnostics.value
        XCTAssertEqual(emitted.map(\.kind), [.rateLimited, .retryScheduled])
        XCTAssertEqual(emitted[0].retryDelay, 3)
        XCTAssertEqual(emitted[0].serverRequestID, "server-rate-limit")
        XCTAssertEqual(emitted[1].retryDelay, 3)
        XCTAssertEqual(emitted[1].requestID, captured[0].requestID)
        XCTAssertEqual(emitted[1].idempotencyKey, captured[0].idempotencyKey)
    }

    func testDataRequestUsesBoundedExponentialBackoffAndEmitsTerminalFailure() async throws {
        let attempts = TransportLocked(0)
        let requests = TransportLocked<[TransportCapturedRequest]>([])
        let diagnostics = TransportLocked<[ResponsesTransportDiagnostic]>([])
        let delays = TransportLocked<[TimeInterval]>([])

        TransportStubURLProtocol.handler = { request in
            requests.withValue { $0.append(TransportCapturedRequest(request)) }
            let attempt = attempts.withValue { value in
                value += 1
                return value
            }
            return TransportStubURLProtocol.response(
                for: request,
                statusCode: 503,
                headers: ["X-Request-Id": "server-\(attempt)"],
                body: #"{"error":{"message":"busy"}}"#
            )
        }

        let client = OpenAIResponsesClient(
            auth: TransportStaticAuthProvider(),
            options: .init(endpoint: URL(string: "https://example.test/v1/responses")!),
            session: transportTestSession(),
            transportPolicy: .init(
                maximumRetryCount: 2,
                initialBackoff: 0.25,
                maximumBackoff: 1,
                backoffMultiplier: 2
            ),
            diagnostics: { diagnostic in
                diagnostics.withValue { $0.append(diagnostic) }
            },
            sleeper: { delay in
                delays.withValue { $0.append(delay) }
            }
        )

        do {
            _ = try await client.createBackgroundResponse(ResponsesRequest(
                model: "gpt-5.6-sol",
                input: [ResponseInputBuilder.userMessage("background work")]
            ))
            XCTFail("Expected retry exhaustion to fail")
        } catch CodexCoreError.transportError(let message) {
            XCTAssertTrue(message.contains("HTTP 503"))
            XCTAssertTrue(message.contains("busy"))
        }

        XCTAssertEqual(attempts.value, 3)
        XCTAssertEqual(delays.value, [0.25, 0.5])

        let captured = requests.value
        XCTAssertEqual(Set(captured.compactMap(\.requestID)).count, 1)
        XCTAssertEqual(Set(captured.compactMap(\.idempotencyKey)).count, 1)

        let emitted = diagnostics.value
        XCTAssertEqual(emitted.map(\.kind), [.retryScheduled, .retryScheduled, .requestFailed])
        XCTAssertEqual(emitted.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(emitted.last?.statusCode, 503)
        XCTAssertEqual(emitted.last?.serverRequestID, "server-3")
        XCTAssertNil(emitted.last?.retryDelay)
    }

    func testAuthenticationRefreshRetainsIdentityWithoutConsumingRetryBudget() async throws {
        let attempts = TransportLocked(0)
        let requests = TransportLocked<[TransportCapturedRequest]>([])
        let diagnostics = TransportLocked<[ResponsesTransportDiagnostic]>([])
        let auth = TransportRefreshingAuthProvider()

        TransportStubURLProtocol.handler = { request in
            requests.withValue { $0.append(TransportCapturedRequest(request)) }
            let attempt = attempts.withValue { value in
                value += 1
                return value
            }
            if attempt == 1 {
                return TransportStubURLProtocol.response(
                    for: request,
                    statusCode: 401,
                    body: #"{"error":{"message":"expired"}}"#
                )
            }
            return TransportStubURLProtocol.response(
                for: request,
                body: #"{"id":"resp_auth","status":"queued","background":true}"#
            )
        }

        let client = OpenAIResponsesClient(
            auth: auth,
            options: .init(endpoint: URL(string: "https://example.test/v1/responses")!),
            session: transportTestSession(),
            transportPolicy: .init(maximumRetryCount: 0),
            diagnostics: { diagnostic in
                diagnostics.withValue { $0.append(diagnostic) }
            },
            sleeper: { _ in }
        )

        let snapshot = try await client.createBackgroundResponse(ResponsesRequest(
            model: "gpt-5.6-sol",
            input: [ResponseInputBuilder.userMessage("refresh auth")]
        ))

        XCTAssertEqual(snapshot.id, "resp_auth")
        let refreshCount = await auth.refreshCount
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(diagnostics.value, [])

        let captured = requests.value
        XCTAssertEqual(captured.map(\.authorization), ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(captured[0].requestID, captured[1].requestID)
        XCTAssertEqual(captured[0].idempotencyKey, captured[1].idempotencyKey)
    }

    func testCancellationDuringBackoffPropagatesWithoutAnotherAttempt() async throws {
        let attempts = TransportLocked(0)
        let diagnostics = TransportLocked<[ResponsesTransportDiagnostic]>([])
        let (retrySignals, retrySignalContinuation) = AsyncStream<Void>.makeStream()

        TransportStubURLProtocol.handler = { request in
            attempts.withValue { $0 += 1 }
            return TransportStubURLProtocol.response(
                for: request,
                statusCode: 503,
                body: #"{"error":{"message":"busy"}}"#
            )
        }

        let client = OpenAIResponsesClient(
            auth: TransportStaticAuthProvider(),
            options: .init(endpoint: URL(string: "https://example.test/v1/responses")!),
            session: transportTestSession(),
            transportPolicy: .init(maximumRetryCount: 1, initialBackoff: 30, maximumBackoff: 30),
            diagnostics: { diagnostic in
                diagnostics.withValue { $0.append(diagnostic) }
                if diagnostic.kind == .retryScheduled {
                    retrySignalContinuation.yield()
                }
            },
            sleeper: { _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )

        let task = Task {
            try await client.createBackgroundResponse(ResponsesRequest(
                model: "gpt-5.6-sol",
                input: [ResponseInputBuilder.userMessage("cancel me")]
            ))
        }

        var signalIterator = retrySignals.makeAsyncIterator()
        _ = await signalIterator.next()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation is not wrapped in a transport error.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        retrySignalContinuation.finish()
        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(diagnostics.value.map(\.kind), [.retryScheduled])
    }
}

private func transportTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TransportStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private struct TransportStaticAuthProvider: AuthorizationProvider {
    func authorizationHeaders() async throws -> [String: String] {
        ["Authorization": "Bearer test-token"]
    }
}

private actor TransportRefreshingAuthProvider: TokenRefreshingAuthorizationProvider {
    private var token = "old-token"
    private(set) var refreshCount = 0

    func authorizationHeaders() async throws -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }

    func refreshNow() async throws {
        refreshCount += 1
        token = "new-token"
    }
}

private struct TransportCapturedRequest: Sendable {
    var requestID: String?
    var idempotencyKey: String?
    var authorization: String?

    init(_ request: URLRequest) {
        requestID = request.value(forHTTPHeaderField: "X-Client-Request-Id")
        idempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key")
        authorization = request.value(forHTTPHeaderField: "Authorization")
    }
}

private final class TransportLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

private final class TransportStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: String
    ) -> (HTTPURLResponse, Data) {
        var headers = headers
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }
}
