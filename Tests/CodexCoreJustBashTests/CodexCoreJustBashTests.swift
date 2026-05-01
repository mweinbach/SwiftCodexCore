import XCTest
import CodexCore
@testable import CodexCoreJustBash
import JustBash

final class CodexCoreJustBashTests: XCTestCase {
    func testJustBashShellAndFileToolsShareWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreJustBash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bash = Bash(options: try .codingAgentWorkspace(rootURL: root))
        let registry = ToolRegistry(tools: justBashCodexTools(bash: bash))
        let context = ToolExecutionContext(threadID: "t", turnID: "u", approvalPolicy: .never, sandboxPolicy: .workspaceWrite)

        let write = try await registry.run(
            name: "write_file",
            arguments: .object(["path": .string("hello.txt"), "content": .string("hello")]),
            context: context
        )
        XCTAssertFalse(write.isError)

        let shell = try await registry.run(
            name: "shell",
            arguments: .object(["command": .string("cat hello.txt && echo ' world'")]),
            context: context
        )
        XCTAssertFalse(shell.isError)
        XCTAssertTrue(shell.content.contains("hello"))
        XCTAssertTrue(shell.content.contains("world"))

        let read = try await registry.run(
            name: "read_file",
            arguments: .object(["path": .string("hello.txt")]),
            context: context
        )
        XCTAssertEqual(read.content, "hello")
    }

    func testJustBashApplyPatchEditsVirtualFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreJustBash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bash = Bash(options: try .codingAgentWorkspace(rootURL: root))
        let registry = ToolRegistry(tools: justBashCodexTools(bash: bash))
        let context = ToolExecutionContext(threadID: "t", turnID: "u", approvalPolicy: .never, sandboxPolicy: .workspaceWrite)

        _ = try await registry.run(
            name: "write_file",
            arguments: .object(["path": .string("hello.txt"), "content": .string("hello\n")]),
            context: context
        )

        let patch = """
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1 +1 @@
        -hello
        +hello codex
        """

        let result = try await registry.run(
            name: "apply_patch",
            arguments: .object(["patch": .string(patch)]),
            context: context
        )
        XCTAssertFalse(result.isError)

        let read = try await registry.run(
            name: "read_file",
            arguments: .object(["path": .string("hello.txt")]),
            context: context
        )
        XCTAssertEqual(read.content, "hello codex\n")
    }
}
