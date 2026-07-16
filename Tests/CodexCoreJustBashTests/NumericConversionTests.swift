import CodexCore
import JustBash
import XCTest

@testable import CodexCoreJustBash

final class JustBashNumericConversionTests: XCTestCase {
  func testApplyPatchRejectsHostileStripCounts() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SwiftCodexCoreJustBashNumericTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let bash = Bash(options: try .codingAgentWorkspace(rootURL: root))
    let tool = JustBashApplyPatchTool(bash: bash)
    let context = ToolExecutionContext(
      threadID: "thread",
      turnID: "turn",
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
}
