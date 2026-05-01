import Foundation
import CodexCore
import JustBash

public struct JustBashCodexEnvironment: Sendable {
    public var runtime: CodexRuntime
    public var bash: Bash
    public var workspaceRootURL: URL

    public init(runtime: CodexRuntime, bash: Bash, workspaceRootURL: URL) {
        self.runtime = runtime
        self.bash = bash
        self.workspaceRootURL = workspaceRootURL
    }
}

public enum JustBashCodexFactory {
    public static func makeEnvironment(
        modelProvider: any ModelProvider,
        workspaceRootURL: URL,
        username: String = "coder",
        configuration: AgentConfiguration = AgentConfiguration(),
        embeddedSkills: [EmbeddedAgentSkill] = [],
        embeddedSkillsRootName: String = "bundled",
        embeddedSkillsRootURL: URL? = nil,
        threadStore: any ThreadStore = JSONFileThreadStore(),
        approvalHandler: ApprovalHandler? = nil
    ) throws -> JustBashCodexEnvironment {
        var options = try BashOptions.codingAgentWorkspace(rootURL: workspaceRootURL, username: username)
        options.enableOAIPrimaryRuntime()
        let bash = Bash(options: options)
        var config = configuration
        config.workspaceURL = workspaceRootURL
        if !embeddedSkills.isEmpty {
            let skillsRoot = embeddedSkillsRootURL ?? CodexDefaultLocations.embeddedSkillsDirectory.appendingPathComponent(embeddedSkillsRootName, isDirectory: true)
            _ = try config.installEmbeddedSkills(embeddedSkills, rootURL: skillsRoot)
        }
        let runtime = CodexRuntime(
            configuration: config,
            modelProvider: modelProvider,
            threadStore: threadStore,
            tools: justBashCodexTools(bash: bash),
            approvalHandler: approvalHandler
        )
        return JustBashCodexEnvironment(runtime: runtime, bash: bash, workspaceRootURL: workspaceRootURL)
    }
}

public func justBashCodexTools(bash: Bash, defaultCWD: String? = nil) -> [any AgentTool] {
    [
        EchoTool(),
        JustBashFileReadTool(bash: bash, defaultCWD: defaultCWD),
        JustBashFileWriteTool(bash: bash, defaultCWD: defaultCWD),
        JustBashListFilesTool(bash: bash, defaultCWD: defaultCWD),
        JustBashEditFileTool(bash: bash, defaultCWD: defaultCWD),
        JustBashApplyPatchTool(bash: bash, defaultCWD: defaultCWD),
        JustBashShellTool(bash: bash, defaultCWD: defaultCWD)
    ]
}

public struct JustBashShellTool: AgentTool {
    public let definition = ToolDefinition(
        name: "shell",
        description: "Run a command in the embedded JustBash workspace and return combined stdout/stderr.",
        parameters: ToolSchemas.object(properties: [
            "command": ToolSchemas.string(description: "Command to execute with the embedded JustBash interpreter"),
            "cwd": ToolSchemas.string(description: "Optional virtual working directory inside the JustBash workspace"),
            "stdin": ToolSchemas.string(description: "Optional standard input"),
            "timeout_seconds": .object(["type": .string("number"), "description": .string("Optional timeout hint in seconds")])
        ], required: ["command"]),
        requiresApproval: true,
        isStateChanging: true
    )

    private let bash: Bash
    private let defaultCWD: String?

    public init(bash: Bash, defaultCWD: String? = nil) {
        self.bash = bash
        self.defaultCWD = defaultCWD
    }

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowShellCommands else {
            throw CodexCoreError.approvalRequired("Shell commands are disabled by the sandbox policy")
        }
        let result = await bash.exec(
            try arguments.requiredString("command"),
            options: ExecOptions(cwd: arguments.optionalString("cwd") ?? defaultCWD, stdin: arguments.optionalString("stdin") ?? "")
        )
        return JustBashToolResult.make(result)
    }
}

public struct JustBashFileReadTool: AgentTool {
    public let definition = ToolDefinition(
        name: "read_file",
        description: "Read a UTF-8 text file from the embedded JustBash workspace.",
        parameters: ToolSchemas.object(properties: [
            "path": ToolSchemas.string(description: "Virtual path relative to the JustBash working directory")
        ], required: ["path"])
    )

    private let bash: Bash
    private let defaultCWD: String?

    public init(bash: Bash, defaultCWD: String? = nil) {
        self.bash = bash
        self.defaultCWD = defaultCWD
    }

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowFileRead else {
            throw CodexCoreError.approvalRequired("File reads are disabled by the sandbox policy")
        }
        let path = try arguments.requiredString("path")
        let result = await bash.exec("cat \(shellQuote(path))", options: ExecOptions(cwd: defaultCWD))
        if result.exitCode != 0 { return JustBashToolResult.make(result) }
        return ToolResult(content: result.stdout, metadata: ["path": .string(path), "runtime": .string("justbash")])
    }
}

public struct JustBashFileWriteTool: AgentTool {
    public let definition = ToolDefinition(
        name: "write_file",
        description: "Write a UTF-8 text file inside the embedded JustBash workspace.",
        parameters: ToolSchemas.object(properties: [
            "path": ToolSchemas.string(description: "Virtual path relative to the JustBash working directory"),
            "content": ToolSchemas.string(description: "Text content to write")
        ], required: ["path", "content"]),
        requiresApproval: true,
        isStateChanging: true
    )

    private let bash: Bash
    private let defaultCWD: String?

    public init(bash: Bash, defaultCWD: String? = nil) {
        self.bash = bash
        self.defaultCWD = defaultCWD
    }

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowFileWrite else {
            throw CodexCoreError.approvalRequired("File writes are disabled by the sandbox policy")
        }
        let path = try arguments.requiredString("path")
        let content = try arguments.requiredString("content")
        try await writeVirtualFile(path: path, content: content, bash: bash, cwd: defaultCWD)
        return ToolResult(content: "Wrote \(content.utf8.count) bytes to \(path)", metadata: ["path": .string(path), "runtime": .string("justbash")])
    }
}

public struct JustBashListFilesTool: AgentTool {
    public let definition = ToolDefinition(
        name: "list_files",
        description: "List files under an embedded JustBash workspace directory.",
        parameters: ToolSchemas.object(properties: [
            "path": ToolSchemas.string(description: "Virtual directory path. Defaults to ."),
            "recursive": ToolSchemas.boolean(description: "Whether to recurse. Defaults to false")
        ])
    )

    private let bash: Bash
    private let defaultCWD: String?

    public init(bash: Bash, defaultCWD: String? = nil) {
        self.bash = bash
        self.defaultCWD = defaultCWD
    }

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowFileRead else {
            throw CodexCoreError.approvalRequired("File reads are disabled by the sandbox policy")
        }
        let path = arguments.optionalString("path") ?? "."
        let recursive = arguments.optionalBool("recursive") ?? false
        let command = recursive ? "find \(shellQuote(path))" : "ls -A \(shellQuote(path))"
        let result = await bash.exec(command, options: ExecOptions(cwd: defaultCWD))
        if result.exitCode != 0 { return JustBashToolResult.make(result) }
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        return ToolResult(content: lines.joined(separator: "\n"), structuredContent: .array(lines.map(JSONValue.string)), metadata: ["runtime": .string("justbash")])
    }
}

public struct JustBashEditFileTool: AgentTool {
    public let definition = ToolDefinition(
        name: "edit_file",
        description: "Replace an exact string in a UTF-8 file in the embedded JustBash workspace.",
        parameters: ToolSchemas.object(properties: [
            "path": ToolSchemas.string(description: "Virtual path relative to the JustBash working directory"),
            "old": ToolSchemas.string(description: "Exact old text"),
            "new": ToolSchemas.string(description: "Replacement text"),
            "replace_all": ToolSchemas.boolean(description: "Replace all occurrences instead of requiring a single match")
        ], required: ["path", "old", "new"]),
        requiresApproval: true,
        isStateChanging: true
    )

    private let bash: Bash
    private let defaultCWD: String?

    public init(bash: Bash, defaultCWD: String? = nil) {
        self.bash = bash
        self.defaultCWD = defaultCWD
    }

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowFileWrite else {
            throw CodexCoreError.approvalRequired("File writes are disabled by the sandbox policy")
        }
        let path = try arguments.requiredString("path")
        let old = try arguments.requiredString("old")
        let new = try arguments.requiredString("new")
        let replaceAll = arguments.optionalBool("replace_all") ?? false
        let read = await bash.exec("cat \(shellQuote(path))", options: ExecOptions(cwd: defaultCWD))
        if read.exitCode != 0 { return JustBashToolResult.make(read) }
        let occurrences = read.stdout.components(separatedBy: old).count - 1
        guard occurrences > 0 else { throw CodexCoreError.invalidState("Old text not found in \(path)") }
        guard replaceAll || occurrences == 1 else {
            throw CodexCoreError.invalidState("Old text occurs \(occurrences) times. Set replace_all=true or use more context.")
        }
        let edited = read.stdout.replacingOccurrences(of: old, with: new)
        try await writeVirtualFile(path: path, content: edited, bash: bash, cwd: defaultCWD)
        return ToolResult(content: "Edited \(path): replaced \(replaceAll ? occurrences : 1) occurrence(s)", metadata: ["runtime": .string("justbash")])
    }
}

public struct JustBashApplyPatchTool: AgentTool {
    public let definition = ToolDefinition(
        name: "apply_patch",
        description: "Apply a unified diff patch inside the embedded JustBash workspace.",
        parameters: ToolSchemas.object(properties: [
            "patch": ToolSchemas.string(description: "Unified diff patch text"),
            "strip": .object(["type": .string("number"), "description": .string("Additional leading path components to strip after a/ and b/ prefixes are removed")])
        ], required: ["patch"]),
        requiresApproval: true,
        isStateChanging: true
    )

    private let bash: Bash
    private let defaultCWD: String?

    public init(bash: Bash, defaultCWD: String? = nil) {
        self.bash = bash
        self.defaultCWD = defaultCWD
    }

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowFileWrite else {
            throw CodexCoreError.approvalRequired("Patch application is disabled by the sandbox policy")
        }
        let patch = try arguments.requiredString("patch")
        let strip = Int(arguments["strip"]?.doubleValue ?? 0)
        let changed = try await UnifiedDiffApplier.apply(patch: patch, strip: strip, bash: bash, cwd: defaultCWD)
        return ToolResult(content: "Applied patch to \(changed.joined(separator: ", "))", structuredContent: .array(changed.map(JSONValue.string)), metadata: ["runtime": .string("justbash")])
    }
}

private enum JustBashToolResult {
    static func make(_ result: ExecResult) -> ToolResult {
        let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return ToolResult(
            content: output.isEmpty ? "Command exited with status \(result.exitCode)" : output,
            structuredContent: .object([
                "exit_code": .number(Double(result.exitCode)),
                "stdout": .string(result.stdout),
                "stderr": .string(result.stderr)
            ]),
            isError: result.exitCode != 0,
            metadata: ["runtime": .string("justbash")]
        )
    }
}

private func writeVirtualFile(path: String, content: String, bash: Bash, cwd: String?) async throws {
    if let parent = virtualParent(of: path), parent != "." {
        let mkdir = await bash.exec("mkdir -p \(shellQuote(parent))", options: ExecOptions(cwd: cwd))
        if mkdir.exitCode != 0 { throw CodexCoreError.invalidState(mkdir.stderr.isEmpty ? mkdir.stdout : mkdir.stderr) }
    }
    let result = await bash.exec("cat > \(shellQuote(path))", options: ExecOptions(cwd: cwd, stdin: content))
    if result.exitCode != 0 { throw CodexCoreError.invalidState(result.stderr.isEmpty ? result.stdout : result.stderr) }
}

private func readVirtualFile(path: String, bash: Bash, cwd: String?) async throws -> String {
    let result = await bash.exec("cat \(shellQuote(path))", options: ExecOptions(cwd: cwd))
    if result.exitCode != 0 { throw CodexCoreError.invalidState(result.stderr.isEmpty ? result.stdout : result.stderr) }
    return result.stdout
}

private func deleteVirtualFile(path: String, bash: Bash, cwd: String?) async throws {
    let result = await bash.exec("rm -f \(shellQuote(path))", options: ExecOptions(cwd: cwd))
    if result.exitCode != 0 { throw CodexCoreError.invalidState(result.stderr.isEmpty ? result.stdout : result.stderr) }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func virtualParent(of path: String) -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let url = URL(fileURLWithPath: trimmed)
    let parent = url.deletingLastPathComponent().path
    if trimmed.hasPrefix("/") { return parent.isEmpty ? "/" : parent }
    guard let slash = trimmed.lastIndex(of: "/") else { return nil }
    let relative = String(trimmed[..<slash])
    return relative.isEmpty ? "." : relative
}

private enum UnifiedDiffApplier {
    struct FilePatch {
        var oldPath: String
        var newPath: String
        var hunks: [Hunk] = []
    }

    struct Hunk {
        var oldStart: Int
        var lines: [PatchLine] = []
    }

    enum PatchLine {
        case context(String)
        case addition(String)
        case removal(String)
    }

    static func apply(patch: String, strip: Int, bash: Bash, cwd: String?) async throws -> [String] {
        let files = try parse(patch)
        var changed: [String] = []
        for file in files {
            let path = normalizePatchPath(file.newPath == "/dev/null" ? file.oldPath : file.newPath, strip: strip)
            if file.newPath == "/dev/null" {
                try await deleteVirtualFile(path: path, bash: bash, cwd: cwd)
                changed.append(path)
                continue
            }
            let original = try? await readVirtualFile(path: path, bash: bash, cwd: cwd)
            let edited = try apply(file: file, to: original ?? "")
            try await writeVirtualFile(path: path, content: edited, bash: bash, cwd: cwd)
            changed.append(path)
        }
        return changed
    }

    private static func parse(_ patch: String) throws -> [FilePatch] {
        let lines = patch.components(separatedBy: "\n")
        var index = 0
        var files: [FilePatch] = []
        while index < lines.count {
            guard lines[index].hasPrefix("--- ") else {
                index += 1
                continue
            }
            let oldPath = String(lines[index].dropFirst(4)).split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
            index += 1
            guard index < lines.count, lines[index].hasPrefix("+++ ") else {
                throw CodexCoreError.invalidJSON("Unified diff missing +++ header")
            }
            let newPath = String(lines[index].dropFirst(4)).split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
            index += 1
            var file = FilePatch(oldPath: oldPath, newPath: newPath)
            while index < lines.count, !lines[index].hasPrefix("--- ") {
                guard lines[index].hasPrefix("@@") else {
                    index += 1
                    continue
                }
                var hunk = Hunk(oldStart: try parseOldStart(lines[index]))
                index += 1
                while index < lines.count, !lines[index].hasPrefix("@@"), !lines[index].hasPrefix("--- ") {
                    let line = lines[index]
                    if line.hasPrefix(" ") {
                        hunk.lines.append(.context(String(line.dropFirst())))
                    } else if line.hasPrefix("+") {
                        hunk.lines.append(.addition(String(line.dropFirst())))
                    } else if line.hasPrefix("-") {
                        hunk.lines.append(.removal(String(line.dropFirst())))
                    }
                    index += 1
                }
                file.hunks.append(hunk)
            }
            files.append(file)
        }
        guard !files.isEmpty else { throw CodexCoreError.invalidJSON("No file patches found") }
        return files
    }

    private static func parseOldStart(_ header: String) throws -> Int {
        guard let range = header.range(of: #"@@ -(\d+)"#, options: .regularExpression) else {
            throw CodexCoreError.invalidJSON("Invalid unified diff hunk header: \(header)")
        }
        let match = String(header[range]).dropFirst(4)
        return Int(match) ?? 1
    }

    private static func apply(file: FilePatch, to text: String) throws -> String {
        var lines = splitLines(text)
        let hadFinalNewline = text.hasSuffix("\n")
        var offset = 0
        for hunk in file.hunks {
            var cursor = max(hunk.oldStart - 1 + offset, 0)
            for line in hunk.lines {
                switch line {
                case .context(let expected):
                    guard cursor < lines.count, lines[cursor] == expected else {
                        throw CodexCoreError.invalidState("Patch context did not match \(file.newPath)")
                    }
                    cursor += 1
                case .removal(let expected):
                    guard cursor < lines.count, lines[cursor] == expected else {
                        throw CodexCoreError.invalidState("Patch removal did not match \(file.newPath)")
                    }
                    lines.remove(at: cursor)
                    offset -= 1
                case .addition(let value):
                    lines.insert(value, at: min(cursor, lines.count))
                    cursor += 1
                    offset += 1
                }
            }
        }
        let patched = lines.joined(separator: "\n")
        return hadFinalNewline ? patched + "\n" : patched
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func normalizePatchPath(_ path: String, strip: Int) -> String {
        var components = path.split(separator: "/").map(String.init)
        if components.first == "a" || components.first == "b" {
            components.removeFirst()
        }
        if strip > 0 {
            components.removeFirst(min(strip, components.count))
        }
        return components.joined(separator: "/")
    }
}
