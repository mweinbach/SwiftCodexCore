import XCTest
import CodexCore
@testable import CodexCoreJustBash
import JustBash

final class CodexCoreJustBashTests: XCTestCase {
    func testShellNetworkPolicyOverridesHostAllowlistEvenWithoutApprovals() async throws {
        let inspect = AnyBashCommand(name: "inspect-network") { _, context in
            ExecResult(stdout: context.allowedURLPrefixes.joined(separator: ","), stderr: "", exitCode: 0)
        }
        let bash = Bash(options: BashOptions(customCommands: [inspect], allowedURLPrefixes: ["https://"]))
        let tool = JustBashShellTool(bash: bash)
        let denied = try await tool.run(arguments: .object(["command": .string("sh -c inspect-network")]),
            context: ToolExecutionContext(threadID: "test", turnID: "test", approvalPolicy: .never, sandboxPolicy: .workspaceWrite))
        XCTAssertEqual(denied.structuredContent?["stdout"]?.stringValue, "")
        let allowed = try await tool.run(arguments: .object(["command": .string("inspect-network")]),
            context: ToolExecutionContext(threadID: "test", turnID: "test", approvalPolicy: .never, sandboxPolicy: .dangerFullAccess))
        XCTAssertEqual(allowed.structuredContent?["stdout"]?.stringValue, "https://")
    }
    func testShellRejectsUnsupportedTimeoutInsteadOfIgnoringIt() async throws {
        let tool = JustBashShellTool(bash: Bash())
        XCTAssertNil(tool.definition.parameters["properties"]?["timeout_seconds"])
        do {
            _ = try await tool.run(arguments: .object(["command": .string("echo unexpected"), "timeout_seconds": .number(1)]),
                context: ToolExecutionContext(threadID: "test", turnID: "test", approvalPolicy: .never, sandboxPolicy: .workspaceWrite))
            XCTFail("Unsupported deadlines must not silently execute")
        } catch CodexCoreError.unsupported { }
    }
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

    func testJustBashToolsUseDefaultCWD() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreJustBash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bash = Bash(options: try .codingAgentWorkspace(rootURL: root))
        _ = await bash.exec("mkdir -p /Users/coder/project")
        let registry = ToolRegistry(tools: justBashCodexTools(bash: bash, defaultCWD: "/Users/coder/project"))
        let context = ToolExecutionContext(threadID: "t", turnID: "u", approvalPolicy: .never, sandboxPolicy: .workspaceWrite)

        _ = try await registry.run(
            name: "write_file",
            arguments: .object(["path": .string("scoped.txt"), "content": .string("project")]),
            context: context
        )

        let read = try await registry.run(
            name: "shell",
            arguments: .object(["command": .string("pwd && cat scoped.txt")]),
            context: context
        )
        XCTAssertTrue(read.content.contains("/Users/coder/project"))
        XCTAssertTrue(read.content.contains("project"))
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

    func testJustBashApplyPatchPreservesMissingFinalNewline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreJustBash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bash = Bash(options: try .codingAgentWorkspace(rootURL: root))
        let registry = ToolRegistry(tools: justBashCodexTools(bash: bash))
        let context = ToolExecutionContext(threadID: "t", turnID: "u", approvalPolicy: .never, sandboxPolicy: .workspaceWrite)

        _ = try await registry.run(
            name: "write_file",
            arguments: .object(["path": .string("hello.txt"), "content": .string("hello")]),
            context: context
        )

        let patch = """
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1 +1 @@
        -hello
        +hello codex
        """

        _ = try await registry.run(
            name: "apply_patch",
            arguments: .object(["patch": .string(patch)]),
            context: context
        )

        let read = try await registry.run(
            name: "read_file",
            arguments: .object(["path": .string("hello.txt")]),
            context: context
        )
        XCTAssertEqual(read.content, "hello codex")
    }

    func testFactoryEnablesOAIPrimaryRuntimeCommands() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreJustBash-\(UUID().uuidString)")
        let skillsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreJustBashSkills-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: skillsRoot)
        }

        let environment = try JustBashCodexFactory.makeEnvironment(
            modelProvider: ScriptedModelProvider(batches: []),
            workspaceRootURL: workspace,
            defaultCWD: "/Users/coder/project",
            embeddedSkills: [
                EmbeddedAgentSkill(
                    name: "artifact-writer",
                    description: "Create document, presentation, and spreadsheet artifacts.",
                    instructions: "Use primary-runtime-skills-check before artifact work.",
                    allowImplicitInvocation: false
                )
            ],
            embeddedSkillsRootURL: skillsRoot
        )

        XCTAssertEqual(environment.defaultCWD, "/Users/coder/project")
        let result = await environment.bash.exec("primary-runtime-skills-check")
        XCTAssertNotEqual(result.exitCode, 127)
        XCTAssertTrue(result.stdout.contains(#""platform": "ios""#))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillsRoot.appendingPathComponent("artifact-writer/SKILL.md").path))
        XCTAssertFalse(skillsRoot.path.hasPrefix(workspace.path))
    }
}
