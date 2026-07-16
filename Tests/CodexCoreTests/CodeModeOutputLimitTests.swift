import XCTest

@testable import CodexCore

final class CodeModeOutputLimitTests: XCTestCase {
  func testCodeModeOptionsDecodeLegacyPayloadWithDefaultCellOutputLimit() throws {
    let options = try JSONDecoder.codex.decode(
      CodeModeOptions.self,
      from: Data("{}".utf8)
    )
    XCTAssertEqual(options.maxCellOutputBytes, 32 * 1024 * 1024)

    let encoded = try JSONDecoder.codex.decode(
      JSONValue.self,
      from: JSONEncoder.codexCompact.encode(options)
    )
    XCTAssertEqual(encoded["maxCellOutputBytes"]?.doubleValue, Double(32 * 1024 * 1024))
    XCTAssertEqual(CodeModeOptions(maxCellOutputBytes: 1).maxCellOutputBytes, 1_024)
    XCTAssertEqual(
      CodeModeOptions(maxCellOutputBytes: .max).maxCellOutputBytes,
      256 * 1024 * 1024
    )
  }

  func testJavaScriptCoreRejectsMultipleBlocksThatCrossCellOutputLimit() async throws {
    let options = CodeModeOptions(
      maxContentBlockBytes: 1_024,
      maxCellOutputBytes: 1_024
    )
    let request = CodeModeExecutionRequest(
      source: "text('a'.repeat(700)); text('b'.repeat(700));",
      definitions: [],
      registry: ToolRegistry(),
      context: ToolExecutionContext(
        threadID: "jsc-output-limit",
        turnID: "turn",
        approvalPolicy: .never,
        sandboxPolicy: .workspaceWrite
      ),
      initialStore: [:],
      options: options,
      maxOutputTokens: 10_000
    )
    let session = JavaScriptCoreCodeModeEngine().start(request: request)
    let completion = await session.completion()
    let snapshot = await session.wait(
      cursor: 0,
      yieldVersion: 0,
      timeoutMilliseconds: 1_000
    )

    XCTAssertEqual(
      completion.error,
      "Code-mode cell output exceeded the configured cumulative byte limit."
    )
    XCTAssertEqual(snapshot.state, .completed)
    XCTAssertEqual(snapshot.content.count, 1)
    XCTAssertEqual(snapshot.content.first?.textValue, String(repeating: "a", count: 700))
    XCTAssertLessThan(
      try XCTUnwrap(
        CodeModeOutputByteLimits.encodedContentBlockBytes(
          try XCTUnwrap(snapshot.content.first).fields
        )),
      options.maxContentBlockBytes
    )
  }

  #if os(macOS)
    func testProcessHostStartDecodesLegacyMessageWithDefaultCellLimit() throws {
      let legacyMessage = Data(
        """
        {
          "source": "text('ok')",
          "bindings": [],
          "initialStore": {},
          "maxContentBlockBytes": 4096
        }
        """.utf8)

      let start = try JSONDecoder.codex.decode(CodeModeHostStart.self, from: legacyMessage)
      XCTAssertEqual(start.maxContentBlockBytes, 4_096)
      XCTAssertEqual(start.maxCellOutputBytes, 32 * 1024 * 1024)
    }
  #endif
}
