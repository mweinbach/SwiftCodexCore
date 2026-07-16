import Foundation

/// Bounded retry behavior for Responses API transport requests.
public struct ResponsesTransportPolicy: Sendable, Equatable {
    /// The number of retries after the initial request.
    public var maximumRetryCount: Int

    /// The exponential backoff used for the first retry when the server does not
    /// provide a `Retry-After` value.
    public var initialBackoff: TimeInterval

    /// The upper bound applied to both exponential backoff and server-provided
    /// `Retry-After` values.
    public var maximumBackoff: TimeInterval

    /// The multiplier applied for each subsequent retry.
    public var backoffMultiplier: Double

    public init(
        maximumRetryCount: Int = 2,
        initialBackoff: TimeInterval = 0.5,
        maximumBackoff: TimeInterval = 30,
        backoffMultiplier: Double = 2
    ) {
        self.maximumRetryCount = max(0, maximumRetryCount)
        self.initialBackoff = max(0, initialBackoff)
        self.maximumBackoff = max(0, maximumBackoff)
        self.backoffMultiplier = max(1, backoffMultiplier)
    }

    public static let `default` = ResponsesTransportPolicy()

    func delay(forRetry retryNumber: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let upperBound = maximumBackoff.isFinite ? max(0, maximumBackoff) : 0
        if let retryAfter, retryAfter.isFinite {
            return min(max(0, retryAfter), upperBound)
        }

        let initial = initialBackoff.isFinite ? max(0, initialBackoff) : 0
        let multiplier = backoffMultiplier.isFinite ? max(1, backoffMultiplier) : 1
        let calculated = initial * pow(multiplier, Double(max(0, retryNumber - 1)))
        return calculated.isFinite ? min(calculated, upperBound) : upperBound
    }
}

/// A structured transport signal emitted by ``OpenAIResponsesClient``.
public struct ResponsesTransportDiagnostic: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The service returned HTTP 429.
        case rateLimited

        /// A retryable response will be attempted after `retryDelay`.
        case retryScheduled

        /// A request ended with a non-retryable or retry-exhausted failure.
        case requestFailed
    }

    public let kind: Kind
    public let requestID: String
    public let idempotencyKey: String?
    public let method: String
    public let url: URL
    /// The one-based network attempt number, including an authentication refresh retry.
    public let attempt: Int
    public let statusCode: Int?
    public let serverRequestID: String?
    public let retryDelay: TimeInterval?
    public let message: String?

    public init(
        kind: Kind,
        requestID: String,
        idempotencyKey: String?,
        method: String,
        url: URL,
        attempt: Int,
        statusCode: Int?,
        serverRequestID: String?,
        retryDelay: TimeInterval?,
        message: String?
    ) {
        self.kind = kind
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.method = method
        self.url = url
        self.attempt = attempt
        self.statusCode = statusCode
        self.serverRequestID = serverRequestID
        self.retryDelay = retryDelay
        self.message = message
    }
}

public typealias ResponsesTransportDiagnosticsHandler = @Sendable (ResponsesTransportDiagnostic) -> Void
