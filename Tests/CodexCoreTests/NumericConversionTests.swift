import XCTest

@testable import CodexCore

final class NumericConversionTests: XCTestCase {
  func testRPCIDFormattingDoesNotNarrowHostileNumbers() {
    XCTAssertEqual(rpcIDString(.number(42)), "42")
    XCTAssertEqual(rpcIDString(.number(1.5)), "1.5")

    for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
      let formatted = rpcIDString(.number(value))
      XCTAssertFalse(formatted.isEmpty)
      XCTAssertEqual(formatted, String(value))
    }
  }

  func testResponsesIntegerParserRejectsNonFiniteOutOfRangeAndFractionalValues() {
    XCTAssertEqual(OpenAIResponsesClient.exactNonnegativeInteger(.number(0)), 0)
    XCTAssertEqual(OpenAIResponsesClient.exactNonnegativeInteger(.number(42)), 42)

    for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 1.5] {
      XCTAssertNil(OpenAIResponsesClient.exactNonnegativeInteger(.number(value)))
    }
    XCTAssertNil(OpenAIResponsesClient.exactNonnegativeInteger(.string("42")))
    XCTAssertNil(OpenAIResponsesClient.exactNonnegativeInteger(nil))
  }

  func testResponsesUsageIgnoresHostileNumericFields() throws {
    for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 1.5] {
      let snapshot = OpenAIResponseSnapshot(
        raw: .object([
          "id": .string("response"),
          "usage": .object([
            "input_tokens": .number(value),
            "output_tokens": .number(7),
            "total_tokens": .number(value),
            "input_tokens_details": .object([
              "cached_tokens": .number(value),
              "cache_write_tokens": .number(3),
            ]),
            "output_tokens_details": .object([
              "reasoning_tokens": .number(value)
            ]),
          ]),
        ]))

      let events = try OpenAIResponsesClient.modelEvents(from: snapshot)
      guard case .completed(_, let usage) = events.last else {
        return XCTFail("Expected completion event")
      }
      XCTAssertNil(usage?.inputTokens)
      XCTAssertEqual(usage?.outputTokens, 7)
      XCTAssertNil(usage?.totalTokens)
      XCTAssertNil(usage?.cachedInputTokens)
      XCTAssertEqual(usage?.cacheWriteTokens, 3)
      XCTAssertNil(usage?.reasoningOutputTokens)
    }
  }

  #if os(macOS)
    func testApplyPatchRejectsHostileStripCountsBeforeLaunchingPatch() async throws {
      let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftCodexCoreNumericTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: workspace) }

      let tool = ApplyPatchTool()
      let context = ToolExecutionContext(
        threadID: "thread",
        turnID: "turn",
        workspaceURL: workspace,
        approvalPolicy: .never,
        sandboxPolicy: .workspaceWrite
      )

      for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 1.5] {
        do {
          _ = try await tool.run(
            arguments: .object([
              "patch": .string("not reached"),
              "strip": .number(value),
            ]),
            context: context
          )
          XCTFail("Expected strip count \(value) to be rejected")
        } catch CodexCoreError.invalidInput(let message) {
          XCTAssertTrue(message.contains("strip count"))
        }
      }
    }

    func testProcessRunnerRejectsUnrepresentableTimeoutsBeforeLaunching() async {
      for timeout in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
        do {
          _ = try await ProcessRunner.run(
            "/usr/bin/true",
            arguments: [],
            currentDirectory: nil,
            stdin: nil,
            timeout: timeout
          )
          XCTFail("Expected timeout \(timeout) to be rejected")
        } catch CodexCoreError.invalidInput {
          // Expected.
        } catch {
          XCTFail("Unexpected error: \(error)")
        }
      }
    }
  #endif
}
