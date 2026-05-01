import Foundation

/// Test/demos provider that replays scripted event batches, one batch per model request.
public final class ScriptedModelProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[ModelStreamEvent]]

    public init(batches: [[ModelStreamEvent]]) {
        self.batches = batches
    }

    public func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let events = nextBatch()
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    private func nextBatch() -> [ModelStreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        if batches.isEmpty { return [.outputTextDelta("No scripted response."), .completed(responseID: nil, usage: nil)] }
        return batches.removeFirst()
    }
}
