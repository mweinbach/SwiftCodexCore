import Foundation

public enum SystemPromptMode: String, Codable, Sendable, Equatable {
    /// Use SwiftCodexCore's default Codex-style system prompt, then append `AgentConfiguration.instructions`.
    case append
    /// Use `AgentConfiguration.instructions` as the entire system prompt.
    case replace
}

public struct ProjectInstructionOptions: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var codexHome: URL?
    public var currentWorkingDirectory: URL?
    public var fallbackFilenames: [String]
    public var maxBytes: Int
    public var includeGlobal: Bool
    public var includeProject: Bool

    public init(
        enabled: Bool = true,
        codexHome: URL? = nil,
        currentWorkingDirectory: URL? = nil,
        fallbackFilenames: [String] = [],
        maxBytes: Int = 32 * 1024,
        includeGlobal: Bool = true,
        includeProject: Bool = true
    ) {
        self.enabled = enabled
        self.codexHome = codexHome
        self.currentWorkingDirectory = currentWorkingDirectory
        self.fallbackFilenames = fallbackFilenames
        self.maxBytes = maxBytes
        self.includeGlobal = includeGlobal
        self.includeProject = includeProject
    }
}

public struct SkillInjectionOptions: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var explicitPrefix: String
    public var maxCatalogCharacters: Int
    public var includeRepoSkills: Bool
    public var includeUserSkills: Bool
    public var includeAdminSkills: Bool
    public var includeSystemSkills: Bool
    public var additionalSkillRoots: [URL]
    public var allowImplicitInvocation: Bool
    public var loadFullInstructionsForExplicitSkills: Bool
    public var loadFullInstructionsForImplicitSkills: Bool

    public init(
        enabled: Bool = true,
        explicitPrefix: String = "$",
        maxCatalogCharacters: Int = 8_000,
        includeRepoSkills: Bool = true,
        includeUserSkills: Bool = true,
        includeAdminSkills: Bool = true,
        includeSystemSkills: Bool = false,
        additionalSkillRoots: [URL] = [],
        allowImplicitInvocation: Bool = true,
        loadFullInstructionsForExplicitSkills: Bool = true,
        loadFullInstructionsForImplicitSkills: Bool = true
    ) {
        self.enabled = enabled
        self.explicitPrefix = explicitPrefix
        self.maxCatalogCharacters = maxCatalogCharacters
        self.includeRepoSkills = includeRepoSkills
        self.includeUserSkills = includeUserSkills
        self.includeAdminSkills = includeAdminSkills
        self.includeSystemSkills = includeSystemSkills
        self.additionalSkillRoots = additionalSkillRoots
        self.allowImplicitInvocation = allowImplicitInvocation
        self.loadFullInstructionsForExplicitSkills = loadFullInstructionsForExplicitSkills
        self.loadFullInstructionsForImplicitSkills = loadFullInstructionsForImplicitSkills
    }
}

public struct LoadedProjectInstruction: Codable, Sendable, Equatable {
    public var path: URL
    public var content: String

    public init(path: URL, content: String) {
        self.path = path
        self.content = content
    }
}

public struct AgentSkill: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path.path }
    public var name: String
    public var description: String
    public var path: URL
    public var directory: URL
    public var instructions: String
    public var metadata: [String: JSONValue]
    public var allowImplicitInvocation: Bool

    public init(
        name: String,
        description: String,
        path: URL,
        directory: URL,
        instructions: String,
        metadata: [String: JSONValue] = [:],
        allowImplicitInvocation: Bool = true
    ) {
        self.name = name
        self.description = description
        self.path = path
        self.directory = directory
        self.instructions = instructions
        self.metadata = metadata
        self.allowImplicitInvocation = allowImplicitInvocation
    }
}

public struct PromptAssembly: Codable, Sendable, Equatable {
    public var instructions: String
    public var inputPrefixItems: [JSONValue]
    public var projectInstructions: [LoadedProjectInstruction]
    public var availableSkills: [AgentSkill]
    public var activatedSkills: [AgentSkill]
    public var skillCatalog: String?

    public init(
        instructions: String,
        inputPrefixItems: [JSONValue] = [],
        projectInstructions: [LoadedProjectInstruction] = [],
        availableSkills: [AgentSkill] = [],
        activatedSkills: [AgentSkill] = [],
        skillCatalog: String? = nil
    ) {
        self.instructions = instructions
        self.inputPrefixItems = inputPrefixItems
        self.projectInstructions = projectInstructions
        self.availableSkills = availableSkills
        self.activatedSkills = activatedSkills
        self.skillCatalog = skillCatalog
    }
}

public enum DefaultPrompts {
    public static let codexCore = """
You are CodexCore, an autonomous software-engineering agent. You operate in a durable thread, use tools when they materially improve correctness, and continue the tool loop until the user's request is resolved or blocked.

Core behavior:
- Prefer small, verifiable steps over large speculative changes.
- Read relevant files before editing them.
- Use available tools for file inspection, edits, shell commands, MCP resources, web search, image generation, and subagents when appropriate.
- Explain outcomes clearly, including failures and unresolved risks.
- Treat sandbox, approval, and credential boundaries as hard limits.
- Never fabricate tool results.
"""

    public static let toolLoop = """
Tool-loop contract:
- When you need external state, call a tool instead of guessing.
- After a tool result, incorporate it into the next step.
- If a tool fails, either recover with another safe step or report the blocker.
- For code changes, prefer exact patch/edit operations and then validate with the smallest useful command.
"""

    public static let skillCatalogHeader = """
Available skills are listed below. Each skill has a name, description, and SKILL.md path. Mention a skill explicitly with `$skill-name`, or select one implicitly when the task matches its description. Load and follow full skill instructions only for activated skills.
"""
}

public enum PromptAssembler {
    public static func build(configuration: AgentConfiguration, userText: String, threadID: String? = nil, turnID: String? = nil) throws -> PromptAssembly {
        var sections: [String] = []
        switch configuration.systemPromptMode {
        case .append:
            sections.append(DefaultPrompts.codexCore)
            if !configuration.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(configuration.instructions)
            }
        case .replace:
            sections.append(configuration.instructions)
        }
        if let developer = configuration.developerInstructions, !developer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Developer instructions:\n\(developer)")
        }
        for extra in configuration.additionalSystemInstructions where !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(extra)
        }
        sections.append(DefaultPrompts.toolLoop)

        var prefixItems: [JSONValue] = []
        let projectInstructions = try ProjectInstructionLoader.load(options: configuration.projectInstructionOptions, workspaceURL: configuration.workspaceURL)
        for instruction in projectInstructions {
            prefixItems.append(ResponseInputBuilder.injectedUserInstructions(
                title: "AGENTS.md instructions for \(instruction.path.deletingLastPathComponent().path)",
                body: instruction.content,
                metadata: [
                    "source": .string(instruction.path.path),
                    "kind": .string("project_instructions")
                ]
            ))
        }

        let availableSkills = try SkillRegistry.discover(options: configuration.skillOptions, workspaceURL: configuration.workspaceURL)
        var skillCatalog: String?
        if configuration.skillOptions.enabled, !availableSkills.isEmpty {
            skillCatalog = SkillRegistry.catalog(for: availableSkills, maxCharacters: configuration.skillOptions.maxCatalogCharacters)
            if let skillCatalog, !skillCatalog.isEmpty {
                sections.append(DefaultPrompts.skillCatalogHeader + "\n\n" + skillCatalog)
            }
        }

        let activatedSkills = SkillRegistry.selectSkills(
            from: availableSkills,
            userText: userText,
            options: configuration.skillOptions
        )
        for skill in activatedSkills {
            prefixItems.append(ResponseInputBuilder.injectedUserInstructions(
                title: "Skill instructions: $\(skill.name)",
                body: skill.instructions,
                metadata: [
                    "source": .string(skill.path.path),
                    "kind": .string("skill"),
                    "skill_name": .string(skill.name)
                ]
            ))
        }

        return PromptAssembly(
            instructions: sections.joined(separator: "\n\n"),
            inputPrefixItems: prefixItems,
            projectInstructions: projectInstructions,
            availableSkills: availableSkills,
            activatedSkills: activatedSkills,
            skillCatalog: skillCatalog
        )
    }
}

public enum ProjectInstructionLoader {
    public static func load(options: ProjectInstructionOptions, workspaceURL: URL?) throws -> [LoadedProjectInstruction] {
        guard options.enabled else { return [] }
        let fm = FileManager.default
        let codexHome = options.codexHome ?? CodexDefaultLocations.codexHome
        let cwd = options.currentWorkingDirectory ?? workspaceURL ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        var files: [URL] = []

        if options.includeGlobal {
            if let global = firstInstructionFile(in: codexHome, fallbackFilenames: options.fallbackFilenames) {
                files.append(global)
            }
        }

        if options.includeProject {
            let root = findRepositoryRoot(from: cwd) ?? cwd
            let chain = directoryChain(from: root, to: cwd)
            for directory in chain {
                if let file = firstInstructionFile(in: directory, fallbackFilenames: options.fallbackFilenames) {
                    files.append(file)
                }
            }
        }

        var remaining = max(options.maxBytes, 0)
        var result: [LoadedProjectInstruction] = []
        for file in files {
            guard remaining > 0 else { break }
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
            let slice = data.prefix(remaining)
            guard let text = String(data: slice, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            result.append(LoadedProjectInstruction(path: file, content: text))
            remaining -= slice.count
        }
        return result
    }

    private static func firstInstructionFile(in directory: URL, fallbackFilenames: [String]) -> URL? {
        let names = ["AGENTS.override.md", "AGENTS.md"] + fallbackFilenames
        for name in names {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func findRepositoryRoot(from start: URL) -> URL? {
        let fm = FileManager.default
        var current = start.standardizedFileURL
        while true {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    static func directoryChain(from root: URL, to leaf: URL) -> [URL] {
        let rootPath = root.standardizedFileURL.path
        let leafPath = leaf.standardizedFileURL.path
        guard leafPath.hasPrefix(rootPath) else { return [leaf] }
        var chain: [URL] = []
        var current = leaf.standardizedFileURL
        while true {
            chain.append(current)
            if current.path == root.standardizedFileURL.path { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return chain.reversed()
    }
}

public enum SkillRegistry {
    public static func discover(options: SkillInjectionOptions, workspaceURL: URL?) throws -> [AgentSkill] {
        guard options.enabled else { return [] }
        let fm = FileManager.default
        let cwd = workspaceURL ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        var roots: [URL] = []

        if options.includeRepoSkills {
            let root = ProjectInstructionLoader.findRepositoryRoot(from: cwd) ?? cwd
            for directory in ProjectInstructionLoader.directoryChain(from: root, to: cwd) {
                roots.append(directory.appendingPathComponent(".agents/skills"))
            }
        }
        if options.includeUserSkills {
            roots.append(CodexDefaultLocations.userSkillsDirectory)
        }
        if options.includeAdminSkills {
            roots.append(URL(fileURLWithPath: "/etc/codex/skills"))
        }
        if options.includeSystemSkills {
            roots.append(URL(fileURLWithPath: "/usr/share/codex/skills"))
        }
        roots.append(contentsOf: options.additionalSkillRoots)

        var skills: [AgentSkill] = []
        var seenPaths = Set<String>()
        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                let manifest = entry.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: manifest.path), !seenPaths.contains(manifest.path) else { continue }
                if let skill = try parseSkill(at: manifest) {
                    skills.append(skill)
                    seenPaths.insert(manifest.path)
                }
            }
        }
        return skills.sorted { lhs, rhs in lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
    }

    public static func parseSkill(at manifest: URL) throws -> AgentSkill? {
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let parsed = parseFrontMatter(text)
        guard let name = parsed.metadata["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let description = parsed.metadata["description"]?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty else {
            return nil
        }
        let directory = manifest.deletingLastPathComponent()
        let openAIConfig = directory.appendingPathComponent("agents/openai.yaml")
        var allowImplicit = true
        var metadata = parsed.metadata.mapValues(JSONValue.string)
        if let config = try? String(contentsOf: openAIConfig, encoding: .utf8) {
            metadata["openai_config_path"] = .string(openAIConfig.path)
            if config.lowercased().contains("allow_implicit_invocation: false") {
                allowImplicit = false
            }
        }
        return AgentSkill(
            name: name,
            description: description,
            path: manifest,
            directory: directory,
            instructions: parsed.body.trimmingCharacters(in: .whitespacesAndNewlines),
            metadata: metadata,
            allowImplicitInvocation: allowImplicit
        )
    }

    public static func catalog(for skills: [AgentSkill], maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        var lines: [String] = []
        var used = 0
        for skill in skills {
            var line = "- $\(skill.name): \(skill.description) (\(skill.path.path))"
            let remaining = maxCharacters - used
            guard remaining > 0 else { break }
            if line.count > remaining {
                let keep = max(0, remaining - 1)
                line = String(line.prefix(keep)) + "…"
            }
            lines.append(line)
            used += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    public static func selectSkills(from skills: [AgentSkill], userText: String, options: SkillInjectionOptions) -> [AgentSkill] {
        guard options.enabled else { return [] }
        let lower = userText.lowercased()
        var selected: [AgentSkill] = []
        for skill in skills {
            let explicit = lower.contains("\(options.explicitPrefix)\(skill.name.lowercased())")
            let implicit = options.allowImplicitInvocation && skill.allowImplicitInvocation && matchesImplicitly(skill: skill, lowerUserText: lower)
            if (explicit && options.loadFullInstructionsForExplicitSkills) || (implicit && options.loadFullInstructionsForImplicitSkills) {
                selected.append(skill)
            }
        }
        return selected
    }

    private static func matchesImplicitly(skill: AgentSkill, lowerUserText: String) -> Bool {
        if lowerUserText.contains(skill.name.lowercased()) { return true }
        let keywords = skill.description
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 5 }
        guard !keywords.isEmpty else { return false }
        let hits = keywords.filter { lowerUserText.contains($0) }.count
        return hits >= min(2, keywords.count)
    }

    private static func parseFrontMatter(_ text: String) -> (metadata: [String: String], body: String) {
        var metadata: [String: String] = [:]
        guard text.hasPrefix("---") else { return (metadata, text) }
        let lines = text.components(separatedBy: .newlines)
        var bodyStart = 0
        for index in 1..<lines.count {
            if lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                bodyStart = index + 1
                break
            }
            let line = lines[index]
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty { metadata[key] = value }
        }
        guard bodyStart > 0 else { return (metadata, text) }
        return (metadata, lines.dropFirst(bodyStart).joined(separator: "\n"))
    }
}
