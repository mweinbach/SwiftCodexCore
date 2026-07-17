import Foundation
import XCTest

@testable import CodexCore

final class CodeModeWebKitProgramTests: XCTestCase {
  func testWorkerEmbedsRuntimeWithJSONEncodingAndLocksDownHostGlobals() throws {
    let source = "text(\"quote: \\\"; newline:\\n; slash: \\\\\")"
    let token = "token\";\\npostMessage('escaped')//"
    let runtime = CodeModeJavaScriptProgram.make(
      bindings: [],
      initialStore: ["quoted\"key": .string("line one\nline two")],
      source: source
    )
    let worker = CodeModeWebKitProgram.makeWorker(
      bindings: [],
      initialStore: ["quoted\"key": .string("line one\nline two")],
      source: source,
      token: token
    )

    XCTAssertTrue(worker.contains("const __token = \(try jsonString(token));"))
    XCTAssertTrue(worker.contains("const __runtime = \(try jsonString(runtime));"))
    XCTAssertTrue(worker.contains("__bridge = __nativeEval(__runtime);"))
    XCTAssertTrue(worker.contains("bridge.resolveTool(identifier"))
    XCTAssertTrue(worker.contains("target = __getPrototypeOf(target);"))
    XCTAssertTrue(worker.contains("if (__hasOwn(target, name)) __replaceProperty(target, name);"))

    for name in [
      "postMessage", "close", "fetch", "XMLHttpRequest", "WebSocket", "EventSource",
      "importScripts", "Worker", "SharedWorker", "indexedDB", "caches", "BroadcastChannel",
      "addEventListener", "removeEventListener", "eval", "setInterval", "clearInterval",
    ] {
      XCTAssertTrue(worker.contains("'\(name)'"), "Missing lockdown for \(name)")
    }

    for event in ["host_ready", "tool_call", "emit", "notify", "yield", "complete"] {
      XCTAssertTrue(worker.contains("'\(event)'"), "Missing worker event \(event)")
    }
  }

  func testRelayEscapesNamesAndEnforcesCellAndTokenRouting() throws {
    let handlerName = "handler\"; delete globalThis.webkit; //"
    let relayName = "relay\nwith\\escapes"
    let relay = CodeModeWebKitProgram.makeRelay(
      handlerName: handlerName,
      relayName: relayName
    )

    XCTAssertTrue(relay.contains("const __handlerName = \(try jsonString(handlerName));"))
    XCTAssertTrue(relay.contains("const __relayName = \(try jsonString(relayName));"))
    XCTAssertTrue(relay.contains("const __workers = new Map();"))
    XCTAssertTrue(relay.contains("message.token !== record.token"))
    XCTAssertTrue(relay.contains("cell_id: record.cellID"))
    XCTAssertTrue(relay.contains("type: 'tool_result'"))
    XCTAssertTrue(relay.contains("type: 'host_error'"))
    XCTAssertTrue(relay.contains("const maxEventBytes = request.max_event_bytes;"))
    XCTAssertTrue(relay.contains("__fits(message.payload, record.maxEventBytes)"))
    XCTAssertTrue(relay.contains("return __postToNative(`${record.cellID}\n${encoded}`);"))
    XCTAssertTrue(relay.contains("Object.freeze({start, terminate, terminateAll})"))
    XCTAssertTrue(relay.contains("return true;"))
  }

  func testDocumentUsesRestrictiveWorkerCSP() {
    let html = CodeModeWebKitProgram.documentHTML

    for directive in [
      "default-src 'none'", "script-src 'unsafe-eval'", "worker-src blob:", "img-src data:",
      "connect-src 'none'", "media-src 'none'", "frame-src 'none'", "object-src 'none'",
      "base-uri 'none'", "form-action 'none'",
    ] {
      XCTAssertTrue(html.contains(directive), "Missing CSP directive: \(directive)")
    }
    XCTAssertFalse(html.contains("'unsafe-inline'"))
  }

  private func jsonString(_ value: String) throws -> String {
    String(decoding: try JSONEncoder.codexCompact.encode(value), as: UTF8.self)
  }
}
