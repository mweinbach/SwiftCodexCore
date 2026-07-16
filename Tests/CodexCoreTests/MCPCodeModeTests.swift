import XCTest

@testable import CodexCore

final class MCPCodeModeTests: XCTestCase {
  func testMCPResultPreservesTypedBlocksAndNativeCodeModeEnvelope() throws {
    let raw: JSONValue = .object([
      "content": .array([
        .object(["type": .string("text"), "text": .string("hello")]),
        .object([
          "type": .string("image"),
          "data": .string("AAAA"),
          "mimeType": .string("image/png"),
        ]),
      ]),
      "structuredContent": .object(["answer": .number(42)]),
      "isError": .bool(false),
      "_meta": .object(["source": .string("fixture")]),
    ])

    let result = parseMCPToolResult(raw)
    XCTAssertEqual(result.contentBlocks?.map(\.type), ["text", "image"])
    XCTAssertEqual(result.structuredContent?["answer"]?.doubleValue, 42)
    XCTAssertEqual(result.codeModeResult, raw)
    XCTAssertEqual(result.metadata["source"]?.stringValue, "fixture")
  }

  func testMCPAdapterDeclaresUpstreamCompatibleNamespace() {
    let adapter = MCPToolAdapter(
      serverName: "history",
      tool: MCPTool(name: "lookup"),
      client: FixtureMCPClient()
    )
    XCTAssertEqual(adapter.definition.name, "mcp__history__lookup")
    XCTAssertEqual(adapter.definition.namespace, "mcp__history")
  }

  func testEncryptedMCPTextOverridesStructuredContentOnResponsesWire() throws {
    let raw: JSONValue = .object([
      "content": .array([
        .object(["type": .string("text"), "text": .string("Lookup completed")]),
        .object([
          "type": .string("text"),
          "text": .string("gAAAA-test"),
          "_meta": .object(["codex/encryptedContent": .bool(true)]),
        ]),
      ]),
      "structuredContent": .object(["answer": .number(42)]),
    ])

    let result = parseMCPToolResult(raw)
    let output = try XCTUnwrap(result.responseOutputValue.arrayValue)

    XCTAssertEqual(output.count, 2)
    XCTAssertEqual(output[0]["type"]?.stringValue, "input_text")
    XCTAssertEqual(output[0]["text"]?.stringValue, "Lookup completed")
    XCTAssertEqual(output[1]["type"]?.stringValue, "encrypted_content")
    XCTAssertEqual(output[1]["encrypted_content"]?.stringValue, "gAAAA-test")
    XCTAssertTrue(try XCTUnwrap(result.contentBlocks?.last).isEncryptedContent)
  }
}

private struct FixtureMCPClient: MCPClient {
  let name = "history"
  func connect() async throws {}
  func initialize() async throws -> MCPServerInfo? { nil }
  func listTools() async throws -> [MCPTool] { [] }
  func callTool(name: String, arguments: JSONValue) async throws -> ToolResult {
    ToolResult(content: "unused")
  }
  func close() async {}
}
