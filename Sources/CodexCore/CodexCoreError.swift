import Foundation

public enum CodexCoreError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    case invalidJSON(String)
    case invalidInput(String)
    case invalidState(String)
    case missingThread(String)
    case missingTool(String)
    case modelError(String)
    case transportError(String)
    case authError(String)
    case approvalRequired(String)
    case interrupted
    case timeout(String)
    case unsupported(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidJSON(let message): return "Invalid JSON: \(message)"
        case .invalidInput(let message): return "Invalid input: \(message)"
        case .invalidState(let message): return "Invalid state: \(message)"
        case .missingThread(let id): return "Missing thread: \(id)"
        case .missingTool(let name): return "Missing tool: \(name)"
        case .modelError(let message): return "Model error: \(message)"
        case .transportError(let message): return "Transport error: \(message)"
        case .authError(let message): return "Auth error: \(message)"
        case .approvalRequired(let message): return "Approval required: \(message)"
        case .interrupted: return "Turn interrupted"
        case .timeout(let message): return "Timeout: \(message)"
        case .unsupported(let message): return "Unsupported: \(message)"
        }
    }
}
