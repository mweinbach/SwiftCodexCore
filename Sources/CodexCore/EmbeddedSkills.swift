import Foundation

public struct EmbeddedSkillFile: Codable, Sendable, Equatable {
    public var relativePath: String
    public var contents: String

    public init(relativePath: String, contents: String) {
        self.relativePath = relativePath
        self.contents = contents
    }
}

public struct EmbeddedAgentSkill: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var instructions: String
    public var files: [EmbeddedSkillFile]
    public var allowImplicitInvocation: Bool
    public var directoryName: String?

    public init(
        name: String,
        description: String,
        instructions: String,
        files: [EmbeddedSkillFile] = [],
        allowImplicitInvocation: Bool = true,
        directoryName: String? = nil
    ) {
        self.name = name
        self.description = description
        self.instructions = instructions
        self.files = files
        self.allowImplicitInvocation = allowImplicitInvocation
        self.directoryName = directoryName
    }

    public func invocation(prefix: String = "$") -> String {
        "\(prefix)\(name)"
    }
}

public struct InstalledEmbeddedSkill: Codable, Sendable, Equatable, Identifiable {
    public var id: String { skill.name }
    public var skill: EmbeddedAgentSkill
    public var directoryURL: URL
    public var manifestURL: URL

    public init(skill: EmbeddedAgentSkill, directoryURL: URL, manifestURL: URL) {
        self.skill = skill
        self.directoryURL = directoryURL
        self.manifestURL = manifestURL
    }
}

public enum EmbeddedSkillInstaller {
    public static func install(
        _ skills: [EmbeddedAgentSkill],
        into rootURL: URL,
        overwrite: Bool = true
    ) throws -> [InstalledEmbeddedSkill] {
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var installed: [InstalledEmbeddedSkill] = []
        var usedDirectories = Set<String>()

        for skill in skills {
            let directoryName = skill.directoryName ?? sanitizedDirectoryName(for: skill.name)
            guard isSafeDirectoryName(directoryName) else {
                throw CodexCoreError.invalidInput("Embedded skill \(skill.name) has an invalid directory name: \(directoryName)")
            }
            guard usedDirectories.insert(directoryName).inserted else {
                throw CodexCoreError.invalidInput("Duplicate embedded skill directory: \(directoryName)")
            }

            let directoryURL = rootURL.appendingPathComponent(directoryName, isDirectory: true)
            if overwrite, fm.fileExists(atPath: directoryURL.path) {
                try fm.removeItem(at: directoryURL)
            }
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let manifestURL = directoryURL.appendingPathComponent("SKILL.md")
            try skill.manifestText.write(to: manifestURL, atomically: true, encoding: .utf8)

            if !skill.allowImplicitInvocation {
                let configURL = directoryURL.appendingPathComponent("agents/openai.yaml")
                try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "allow_implicit_invocation: false\n".write(to: configURL, atomically: true, encoding: .utf8)
            }

            for file in skill.files {
                let destination = try destinationURL(for: file.relativePath, under: directoryURL)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.contents.write(to: destination, atomically: true, encoding: .utf8)
            }

            installed.append(InstalledEmbeddedSkill(skill: skill, directoryURL: directoryURL, manifestURL: manifestURL))
        }

        return installed
    }

    public static func sanitizedDirectoryName(for skillName: String) -> String {
        let scalars = skillName.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar.value == 45 || scalar.value == 95 {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "skill" : collapsed
    }

    private static func isSafeDirectoryName(_ directoryName: String) -> Bool {
        !directoryName.isEmpty
            && directoryName != "."
            && directoryName != ".."
            && !directoryName.contains("/")
            && !directoryName.contains("\\")
    }

    private static func destinationURL(for relativePath: String, under rootURL: URL) throws -> URL {
        let normalizedPath = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !normalizedPath.isEmpty, !normalizedPath.hasPrefix("/") else {
            throw CodexCoreError.invalidInput("Embedded skill file path must be relative: \(relativePath)")
        }
        let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains(".") else {
            throw CodexCoreError.invalidInput("Embedded skill file path cannot traverse directories: \(relativePath)")
        }
        guard normalizedPath != "SKILL.md", !normalizedPath.hasPrefix("agents/openai.yaml") else {
            throw CodexCoreError.invalidInput("Embedded skill file path is reserved: \(relativePath)")
        }

        let root = rootURL.standardizedFileURL
        let destination = root.appendingPathComponent(normalizedPath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw CodexCoreError.invalidInput("Embedded skill file path escapes the skill directory: \(relativePath)")
        }
        return destination
    }
}

public extension AgentConfiguration {
    mutating func installEmbeddedSkills(
        _ skills: [EmbeddedAgentSkill],
        rootURL: URL,
        overwrite: Bool = true
    ) throws -> [InstalledEmbeddedSkill] {
        let installed = try EmbeddedSkillInstaller.install(skills, into: rootURL, overwrite: overwrite)
        if !skillOptions.additionalSkillRoots.contains(rootURL) {
            skillOptions.additionalSkillRoots.append(rootURL)
        }
        return installed
    }

    func withEmbeddedSkills(
        _ skills: [EmbeddedAgentSkill],
        rootURL: URL,
        overwrite: Bool = true
    ) throws -> (configuration: AgentConfiguration, installedSkills: [InstalledEmbeddedSkill]) {
        var copy = self
        let installed = try copy.installEmbeddedSkills(skills, rootURL: rootURL, overwrite: overwrite)
        return (copy, installed)
    }
}

private extension EmbeddedAgentSkill {
    var manifestText: String {
        """
        ---
        name: \(Self.yamlString(name))
        description: \(Self.yamlString(description))
        ---

        \(instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    static func yamlString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
