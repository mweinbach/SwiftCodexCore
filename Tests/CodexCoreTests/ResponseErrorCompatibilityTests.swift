import Foundation
import XCTest

@testable import CodexCore

final class ResponseErrorCompatibilityTests: XCTestCase {
  func testCoreErrorsPreserveMessagesThroughFoundationBridging() {
    let cases: [(CodexCoreError, String)] = [
      (.invalidJSON("missing input"), "Invalid JSON: missing input"),
      (.invalidInput("unsupported option"), "Invalid input: unsupported option"),
      (.invalidState("turn already running"), "Invalid state: turn already running"),
      (.missingThread("thread-1"), "Missing thread: thread-1"),
      (.missingTool("read_file"), "Missing tool: read_file"),
      (.modelError("Compaction is not supported in ResponsesLite"),
        "Model error: Compaction is not supported in ResponsesLite"),
      (.transportError("connection closed"), "Transport error: connection closed"),
      (.authError("sign in again"), "Auth error: sign in again"),
      (.approvalRequired("write file"), "Approval required: write file"),
      (.interrupted, "Turn interrupted"),
      (.timeout("waiting for model"), "Timeout: waiting for model"),
      (.unsupported("desktop host required"), "Unsupported: desktop host required"),
    ]

    for (coreError, expected) in cases {
      let caughtError: any Error = coreError
      XCTAssertEqual(caughtError.localizedDescription, expected)
      XCTAssertEqual((caughtError as NSError).localizedDescription, expected)
    }
  }

  func testLiteRejectsExplicitCompactionBeforeSendingRequest() {
    let request = ResponsesRequest(
      model: "gpt-5.6-sol",
      input: [ResponseInputBuilder.userMessage("hello")],
      contextManagement: [ResponseContextManagement(compactThreshold: 200_000)],
      useResponsesLite: true
    )

    XCTAssertThrowsError(try JSONEncoder().encode(request)) { error in
      guard let coreError = error as? CodexCoreError,
        case .invalidInput(let message) = coreError
      else {
        return XCTFail("Expected a clear invalid-input error, received \(error)")
      }
      XCTAssertTrue(message.contains("Responses Lite"))
      XCTAssertTrue(message.contains("context_management"))
      XCTAssertEqual(error.localizedDescription, "Invalid input: \(message)")
    }
  }

  func testStandardResponsesRetainsExplicitCompaction() throws {
    let request = ResponsesRequest(
      model: "gpt-5.6-sol",
      input: [ResponseInputBuilder.userMessage("hello")],
      contextManagement: [ResponseContextManagement(compactThreshold: 200_000)],
      useResponsesLite: false
    )
    let body = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))

    XCTAssertEqual(
      body["context_management"],
      .array([.object(["type": .string("compaction"), "compact_threshold": .number(200_000)])])
    )
  }
}
