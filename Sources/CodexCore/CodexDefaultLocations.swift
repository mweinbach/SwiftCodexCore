import Foundation

public enum CodexDefaultLocations {
    public static var coreDirectory: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swift-codex-core", isDirectory: true)
        #else
        return applicationSupportDirectory.appendingPathComponent("SwiftCodexCore", isDirectory: true)
        #endif
    }

    public static var codexHome: URL {
        if let value = ProcessInfo.processInfo.environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        #else
        return applicationSupportDirectory.appendingPathComponent("Codex", isDirectory: true)
        #endif
    }

    public static var userSkillsDirectory: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills", isDirectory: true)
        #else
        return applicationSupportDirectory.appendingPathComponent("Agents/skills", isDirectory: true)
        #endif
    }

    private static var applicationSupportDirectory: URL {
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }
}
