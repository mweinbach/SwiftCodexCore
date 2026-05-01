import Foundation

public struct FileReadTool: AgentTool {
    public let definition = ToolDefinition(
        name: "read_file",
        description: "Read a UTF-8 text file from the workspace.",
        parameters: ToolSchemas.object(properties: [
            "path": ToolSchemas.string(description: "File path relative to the workspace, or absolute path if permitted")
        ], required: ["path"])
    )

    public init() {}

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowFileRead else { throw CodexCoreError.approvalRequired("File reads are disabled by the sandbox policy") }
        let url = try resolvePath(try arguments.requiredString("path"), context: context, forWrite: false)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexCoreError.invalidState("File is not UTF-8: \(url.path)")
        }
        return ToolResult(content: text, metadata: ["path": .string(url.path)])
    }
}

public struct FileWriteTool: AgentTool {
    public let definition = ToolDefinition(
        name: "write_file",
        description: "Write a UTF-8 text file inside the workspace. Creates parent directories when needed.",
        parameters: ToolSchemas.object(properties: [
            "path": ToolSchemas.string(description: "File path relative to the workspace"),
            "content": ToolSchemas.string(description: "Text content to write")
        ], required: ["path", "content"]),
        requiresApproval: true,
        isStateChanging: true
    )

    public init() {}

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowFileWrite else { throw CodexCoreError.approvalRequired("File writes are disabled by the sandbox policy") }
        let url = try resolvePath(try arguments.requiredString("path"), context: context, forWrite: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = try arguments.requiredString("content")
        try content.data(using: .utf8)?.write(to: url, options: [.atomic])
        return ToolResult(content: "Wrote \(content.utf8.count) bytes to \(url.path)", metadata: ["path": .string(url.path)])
    }
}

public struct ListFilesTool: AgentTool {
    public let definition = ToolDefinition(
        name: "list_files",
        description: "List files under a workspace directory.",
        parameters: ToolSchemas.object(properties: [
            "path": ToolSchemas.string(description: "Directory path relative to the workspace. Defaults to ."),
            "recursive": ToolSchemas.boolean(description: "Whether to recurse. Defaults to false")
        ])
    )

    public init() {}

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowFileRead else { throw CodexCoreError.approvalRequired("File reads are disabled by the sandbox policy") }
        let path = arguments.optionalString("path") ?? "."
        let recursive = arguments.optionalBool("recursive") ?? false
        let url = try resolvePath(path, context: context, forWrite: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexCoreError.invalidState("Not a directory: \(url.path)")
        }
        let urls: [URL]
        if recursive {
            urls = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])?.compactMap { $0 as? URL } ?? [])
        } else {
            urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        }
        let base = context.workspaceURL ?? url
        let lines = urls.sorted { $0.path < $1.path }.map { child in
            relativePath(child, base: base)
        }
        return ToolResult(content: lines.joined(separator: "\n"), structuredContent: .array(lines.map(JSONValue.string)))
    }
}

public struct EditFileTool: AgentTool {
    public let definition = ToolDefinition(
        name: "edit_file",
        description: "Replace an exact string in a UTF-8 file. Fails if the old text is missing or appears more than once unless replace_all is true.",
        parameters: ToolSchemas.object(properties: [
            "path": ToolSchemas.string(description: "File path relative to the workspace"),
            "old": ToolSchemas.string(description: "Exact old text"),
            "new": ToolSchemas.string(description: "Replacement text"),
            "replace_all": ToolSchemas.boolean(description: "Replace all occurrences instead of requiring a single match")
        ], required: ["path", "old", "new"]),
        requiresApproval: true,
        isStateChanging: true
    )

    public init() {}

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowFileWrite else { throw CodexCoreError.approvalRequired("File writes are disabled by the sandbox policy") }
        let url = try resolvePath(try arguments.requiredString("path"), context: context, forWrite: true)
        let old = try arguments.requiredString("old")
        let new = try arguments.requiredString("new")
        let replaceAll = arguments.optionalBool("replace_all") ?? false
        guard var text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw CodexCoreError.invalidState("File is not UTF-8: \(url.path)")
        }
        let occurrences = text.components(separatedBy: old).count - 1
        guard occurrences > 0 else { throw CodexCoreError.invalidState("Old text not found in \(url.path)") }
        if !replaceAll && occurrences != 1 {
            throw CodexCoreError.invalidState("Old text occurs \(occurrences) times. Set replace_all=true or use more context.")
        }
        text = text.replacingOccurrences(of: old, with: new)
        try text.data(using: .utf8)?.write(to: url, options: [.atomic])
        return ToolResult(content: "Edited \(url.path): replaced \(replaceAll ? occurrences : 1) occurrence(s)")
    }
}

#if os(macOS)
public struct ShellTool: AgentTool {
    public let definition = ToolDefinition(
        name: "shell",
        description: "Run a shell command in the workspace and return combined stdout/stderr. Use only when needed.",
        parameters: ToolSchemas.object(properties: [
            "command": ToolSchemas.string(description: "Command to execute with /bin/sh -lc"),
            "cwd": ToolSchemas.string(description: "Optional working directory relative to the workspace"),
            "timeout_seconds": .object(["type": .string("number"), "description": .string("Optional timeout in seconds")])
        ], required: ["command"]),
        requiresApproval: true,
        isStateChanging: true
    )

    public init() {}

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowShellCommands else { throw CodexCoreError.approvalRequired("Shell commands are disabled by the sandbox policy") }
        let command = try arguments.requiredString("command")
        let cwd = try resolvePath(arguments.optionalString("cwd") ?? ".", context: context, forWrite: false)
        let timeout = TimeInterval(arguments["timeout_seconds"]?.doubleValue ?? 120)
        let result = try await ProcessRunner.run("/bin/sh", arguments: ["-lc", command], currentDirectory: cwd, stdin: nil, timeout: timeout)
        let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return ToolResult(
            content: output.isEmpty ? "Command exited with status \(result.exitCode)" : output,
            structuredContent: .object([
                "exit_code": .number(Double(result.exitCode)),
                "stdout": .string(result.stdout),
                "stderr": .string(result.stderr)
            ]),
            isError: result.exitCode != 0
        )
    }
}

public struct ApplyPatchTool: AgentTool {
    public let definition = ToolDefinition(
        name: "apply_patch",
        description: "Apply a unified diff patch in the workspace using the system patch utility.",
        parameters: ToolSchemas.object(properties: [
            "patch": ToolSchemas.string(description: "Unified diff patch text"),
            "strip": .object(["type": .string("number"), "description": .string("patch -p strip count, defaults to 0")])
        ], required: ["patch"]),
        requiresApproval: true,
        isStateChanging: true
    )

    public init() {}

    public func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        guard context.sandboxPolicy.allowFileWrite else { throw CodexCoreError.approvalRequired("Patch application is disabled by the sandbox policy") }
        let workspace = context.workspaceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let patch = try arguments.requiredString("patch")
        let strip = Int(arguments["strip"]?.doubleValue ?? 0)
        let result = try await ProcessRunner.run("/usr/bin/patch", arguments: ["--batch", "--forward", "-p\(strip)"], currentDirectory: workspace, stdin: patch, timeout: 120)
        let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return ToolResult(content: output.isEmpty ? "patch exited with status \(result.exitCode)" : output, isError: result.exitCode != 0)
    }
}
#endif

public func defaultBuiltinTools(includeShell: Bool = true) -> [any AgentTool] {
    var tools: [any AgentTool] = [
        EchoTool(),
        FileReadTool(),
        FileWriteTool(),
        ListFilesTool(),
        EditFileTool()
    ]
    #if os(macOS)
    tools.append(ApplyPatchTool())
    if includeShell { tools.append(ShellTool()) }
    #endif
    return tools
}

func resolvePath(_ path: String, context: ToolExecutionContext, forWrite: Bool) throws -> URL {
    let base = context.workspaceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let raw = URL(fileURLWithPath: path, relativeTo: path.hasPrefix("/") ? nil : base).standardizedFileURL
    let allowedRoots = forWrite
        ? (context.sandboxPolicy.writableRoots.isEmpty ? [base] : context.sandboxPolicy.writableRoots)
        : [base]
    guard allowedRoots.contains(where: { raw.isContained(in: $0) }) else {
        let operation = forWrite ? "writable" : "readable"
        throw CodexCoreError.approvalRequired("Path is outside \(operation) roots: \(raw.path)")
    }
    return raw
}

private extension URL {
    func isContained(in root: URL) -> Bool {
        let path = standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

func relativePath(_ child: URL, base: URL) -> String {
    let childPath = child.standardizedFileURL.path
    let basePath = base.standardizedFileURL.path
    if childPath == basePath { return "." }
    if childPath.hasPrefix(basePath + "/") { return String(childPath.dropFirst(basePath.count + 1)) }
    return childPath
}

#if os(macOS)
public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessRunner {
    public static func run(_ executable: String, arguments: [String], currentDirectory: URL?, stdin: String?, timeout: TimeInterval) async throws -> ProcessResult {
        try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                if let stdin {
                    let input = Pipe()
                    process.standardInput = input
                    try process.run()
                    input.fileHandleForWriting.write(Data(stdin.utf8))
                    try? input.fileHandleForWriting.close()
                } else {
                    try process.run()
                }
                process.waitUntilExit()
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                return ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                throw CodexCoreError.timeout("Process timed out after \(timeout) seconds")
            }
            guard let result = try await group.next() else {
                throw CodexCoreError.invalidState("Process task produced no result")
            }
            group.cancelAll()
            return result
        }
    }
}
#endif
