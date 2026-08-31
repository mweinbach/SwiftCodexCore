import XCTest
@testable import CodexCore

final class SubagentLifecycleTests: XCTestCase, @unchecked Sendable {
  func testInterruptClosesOwnerStreamBeforeDescendantTeardown() async throws {
    let provider = CancellationOrderProvider()
    let runtime = CodexRuntime(modelProvider: provider, tools: [])
    let manager = await runtime.installSubagentTool()
    let root = try await runtime.createThread()
    let child = try await manager.spawn(parentThreadID: root.id, prompt: "owner")
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while provider.requestCount < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(provider.requestCount, 1)
    _ = try await manager.spawn(parentThreadID: child.threadID, prompt: "descendant")
    while provider.requestCount < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(provider.requestCount, 2)
    _ = try await manager.interrupt(threadID: child.threadID)
    XCTAssertEqual(provider.cancellationOrder, [0, 1],
      "The owner must stop producing tool calls before descendants begin teardown")
    let snapshots = await manager.list()
    XCTAssertTrue(snapshots.allSatisfy { $0.state == .interrupted })
  }

  func testFailedChildReportsFailureAndReleasesItsSlot() async throws {
    let runtime = CodexRuntime(modelProvider: ScriptedModelProvider(batches: [
      [.failed("fixture model failure")],
      [.outputTextDelta("recovered"), .completed(responseID: "next", usage: nil)],
    ]), tools: [])
    let manager = await runtime.installSubagentTool(maxConcurrentAgents: 1)
    let root = try await runtime.createThread()
    let child = try await manager.spawn(parentThreadID: root.id, prompt: "fail")
    let failed = try await manager.wait(threadID: child.threadID, timeoutMilliseconds: 2_000)
    XCTAssertEqual(failed.state, .failed)
    XCTAssertTrue(failed.error?.contains("fixture model failure") == true)
    let next = try await manager.spawn(parentThreadID: root.id, prompt: "recover")
    let completed = try await manager.wait(threadID: next.threadID, timeoutMilliseconds: 2_000)
    XCTAssertEqual(completed.state, .completed)
  }
  func testConfigurationUpdatesReachNewAndExistingChildren() async throws {
    let provider = ChildConfigurationProvider()
    let initial = AgentConfiguration(model: "before", approvalPolicy: .never,
      sandboxPolicy: .dangerFullAccess, serverTools: [.webSearch()])
    let runtime = CodexRuntime(configuration: initial, modelProvider: provider, tools: [])
    let manager = await runtime.installSubagentTool()
    let root = try await runtime.createThread()
    let child = try await manager.spawn(parentThreadID: root.id, prompt: "first", model: "explicit-child-model")
    _ = try await manager.wait(threadID: child.threadID, timeoutMilliseconds: 2_000)
    XCTAssertTrue(provider.requests.first?.tools.contains(where: { $0.type == "web_search" }) == true)
    var updated = initial
    updated.model = "after"
    updated.approvalPolicy = .onRequest
    updated.sandboxPolicy = .workspaceWrite
    await runtime.updateConfiguration(updated)
    _ = try await manager.send(threadID: child.threadID, text: "follow-up")
    _ = try await manager.wait(threadID: child.threadID, timeoutMilliseconds: 2_000)
    XCTAssertEqual(provider.requests.last?.model, "explicit-child-model")
    XCTAssertFalse(provider.requests.last?.tools.contains(where: { $0.type == "web_search" }) == true)
    let next = try await manager.spawn(parentThreadID: root.id, prompt: "new child")
    _ = try await manager.wait(threadID: next.threadID, timeoutMilliseconds: 2_000)
    XCTAssertEqual(provider.requests.last?.model, "after")
    XCTAssertFalse(provider.requests.last?.tools.contains(where: { $0.type == "web_search" }) == true)
  }
  func testCompletedParentHandleCannotInterruptLaterChildWork() async throws {
    let runtime = CodexRuntime(modelProvider: ParentThenSilentProvider(), tools: [])
    let manager = await runtime.installSubagentTool()
    let root = try await runtime.createThread()
    let finished = try await runtime.startTurn(threadID: root.id, input: TurnInput("parent"))
    for try await _ in finished.events { }
    let child = try await manager.spawn(parentThreadID: root.id, prompt: "child")
    await finished.interrupt()
    let snapshot = try await manager.wait(threadID: child.threadID, timeoutMilliseconds: 0)
    XCTAssertEqual(snapshot.state, .running)
    await manager.interruptAll()
  }

  func testConcurrentStartsCannotOversubscribeReservedSlots() async throws {
    let runtime = CodexRuntime(modelProvider: SubagentSilentProvider(), tools: [])
    let manager = await runtime.installSubagentTool(maxConcurrentAgents: 1)
    let root = try await runtime.createThread()
    let accepted = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<8 {
        group.addTask {
          do { _ = try await manager.spawn(parentThreadID: root.id, prompt: "hold"); return true }
          catch { return false }
        }
      }
      var total = 0
      for await success in group { if success { total += 1 } }
      return total
    }
    XCTAssertEqual(accepted, 1)
    await manager.interruptAll()
  }
  func testZeroDepthRejectsSpawnBeforeCreatingThread() async throws {
    let runtime = CodexRuntime(modelProvider: ScriptedModelProvider(batches: []), tools: [])
    let manager = await runtime.installSubagentTool(maxDepth: 0)
    let parent = try await runtime.createThread()
    do {
      _ = try await manager.spawn(parentThreadID: parent.id, prompt: "go")
      XCTFail("Depth zero must disable child creation")
    } catch CodexCoreError.invalidState { }
    let threads = try await runtime.listThreads()
    XCTAssertEqual(threads.count, 1)
  }

  func testConcurrencyAndDepthBudgetsReleaseOnInterrupt() async throws {
    let runtime = CodexRuntime(modelProvider: SubagentSilentProvider(), tools: [])
    let manager = await runtime.installSubagentTool(maxDepth: 1, maxConcurrentAgents: 1)
    let parent = try await runtime.createThread()
    let first = try await manager.spawn(parentThreadID: parent.id, prompt: "hold")
    do {
      _ = try await manager.spawn(parentThreadID: parent.id, prompt: "too many")
      XCTFail("Concurrent runs must be bounded")
    } catch CodexCoreError.invalidState { }
    let stopped = try await manager.interrupt(threadID: first.threadID)
    XCTAssertEqual(stopped.state, .interrupted)
    do {
      _ = try await manager.spawn(parentThreadID: first.threadID, prompt: "too deep")
      XCTFail("Durable ancestry must enforce the depth limit")
    } catch CodexCoreError.invalidState { }
    let next = try await manager.spawn(parentThreadID: parent.id, prompt: "slot released")
    XCTAssertEqual(next.state, .running)
    await manager.interruptAll()
    let snapshots = await manager.list()
    XCTAssertTrue(snapshots.allSatisfy { $0.state == .interrupted })
  }

  func testCompletedChildAcceptsFollowUpAndCannotBeControlledByAnotherRoot() async throws {
    let provider = ScriptedModelProvider(batches: [
      [.outputTextDelta("first"), .completed(responseID: "one", usage: nil)],
      [.outputTextDelta("follow-up"), .completed(responseID: "two", usage: nil)],
    ])
    let runtime = CodexRuntime(modelProvider: provider, tools: [])
    let manager = await runtime.installSubagentTool()
    let parent = try await runtime.createThread()
    let other = try await runtime.createThread()
    let child = try await manager.spawn(parentThreadID: parent.id, prompt: "one")
    let first = try await manager.wait(threadID: child.threadID, timeoutMilliseconds: 2_000)
    XCTAssertEqual(first.finalText, "first")
    XCTAssertEqual(first.state, .completed)
    _ = try await manager.send(threadID: child.threadID, text: "two")
    let second = try await manager.wait(threadID: child.threadID, timeoutMilliseconds: 2_000)
    XCTAssertEqual(second.finalText, "follow-up")
    XCTAssertNotEqual(first.turnID, second.turnID)
    let context = ToolExecutionContext(threadID: other.id, turnID: "foreign", approvalPolicy: .never, sandboxPolicy: .workspaceWrite)
    do {
      _ = try await SubagentControlTool(manager: manager, action: .send).run(
        arguments: .object(["thread_id": .string(child.threadID), "text": .string("unrelated")]), context: context)
      XCTFail("Other root threads cannot control this child")
    } catch CodexCoreError.invalidInput { }
    let names = await runtime.toolRegistry.listDefinitions().map(\.name)
    XCTAssertTrue(Set(["spawn_agent", "send_input", "wait_agent", "interrupt_agent", "list_agents"]).isSubset(of: Set(names)))
  }

  func testRuntimeShutdownStopsChildrenAndRejectsNewTurns() async throws {
    let runtime = CodexRuntime(modelProvider: SubagentSilentProvider(), tools: [])
    let manager = await runtime.installSubagentTool()
    let root = try await runtime.createThread()
    _ = try await manager.spawn(parentThreadID: root.id, prompt: "hold")
    await runtime.shutdown()
    let snapshots = await manager.list()
    XCTAssertTrue(snapshots.allSatisfy { $0.state == .interrupted })
    do {
      _ = try await runtime.startTurn(threadID: root.id, input: TurnInput("late"))
      XCTFail("Closed runtime must reject late startup")
    } catch CodexCoreError.invalidState { }
    do {
      _ = try await manager.spawn(parentThreadID: root.id, prompt: "late")
      XCTFail("Closed manager must reject late children")
    } catch CodexCoreError.invalidState { }
  }
}

private struct SubagentSilentProvider: ModelProvider {
  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    AsyncThrowingStream { _ in }
  }
}

private final class CancellationOrderProvider: ModelProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var started = 0
  private var cancelled: [Int] = []
  var requestCount: Int { lock.withLock { started } }
  var cancellationOrder: [Int] { lock.withLock { cancelled } }

  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let index = lock.withLock { started }
    return AsyncThrowingStream { continuation in
      continuation.onTermination = { [self] termination in
        if case .cancelled = termination { lock.withLock { cancelled.append(index) } }
      }
      lock.withLock { started += 1 }
    }
  }
}

private final class ParentThenSilentProvider: ModelProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var isFirst = true
  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let first = lock.withLock { let value = isFirst; isFirst = false; return value }
    return AsyncThrowingStream { continuation in
      if first {
        continuation.yield(.outputTextDelta("parent complete"))
        continuation.yield(.completed(responseID: "parent", usage: nil))
        continuation.finish()
      }
    }
  }
}

private final class ChildConfigurationProvider: ModelProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [ResponsesRequest] = []
  var requests: [ResponsesRequest] { lock.withLock { recorded } }
  func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    lock.withLock { recorded.append(request) }
    return AsyncThrowingStream { continuation in
      continuation.yield(.outputTextDelta("done"))
      continuation.yield(.completed(responseID: "fixture", usage: nil))
      continuation.finish()
    }
  }
}
