import Foundation

/// Current OpenAI model identifiers that are useful to Codex-style hosts.
public enum OpenAIModel: String, Codable, Sendable, Equatable, CaseIterable {
    /// Alias that routes to GPT-5.6 Sol.
    case gpt56 = "gpt-5.6"
    case gpt56Sol = "gpt-5.6-sol"
    case gpt56Terra = "gpt-5.6-terra"
    case gpt56Luna = "gpt-5.6-luna"
}

public struct OpenAIModelCapabilities: Codable, Sendable, Equatable {
    public var model: OpenAIModel
    public var contextWindow: Int
    public var maxOutputTokens: Int
    public var supportedReasoningEfforts: [ReasoningEffort]
    public var supportsImageInput: Bool

    public init(
        model: OpenAIModel,
        contextWindow: Int,
        maxOutputTokens: Int,
        supportedReasoningEfforts: [ReasoningEffort],
        supportsImageInput: Bool
    ) {
        self.model = model
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsImageInput = supportsImageInput
    }

    public static let gpt56Family: [OpenAIModel: OpenAIModelCapabilities] = {
        let efforts: [ReasoningEffort] = [.none, .low, .medium, .high, .xhigh, .max]
        return Dictionary(uniqueKeysWithValues: OpenAIModel.allCases.map { model in
            (model, OpenAIModelCapabilities(
                model: model,
                contextWindow: 1_050_000,
                maxOutputTokens: 128_000,
                supportedReasoningEfforts: efforts,
                supportsImageInput: true
            ))
        })
    }()
}

public enum PromptCacheMode: String, Codable, Sendable, Equatable, CaseIterable {
    case implicit
    case explicit
}

public struct PromptCacheOptions: Codable, Sendable, Equatable {
    public var mode: PromptCacheMode
    public var ttl: String

    public init(mode: PromptCacheMode = .implicit, ttl: String = "30m") {
        self.mode = mode
        self.ttl = ttl
    }
}

public struct MultiAgentConfiguration: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var maxConcurrentSubagents: Int?

    enum CodingKeys: String, CodingKey {
        case enabled
        case maxConcurrentSubagents = "max_concurrent_subagents"
    }

    public init(enabled: Bool = true, maxConcurrentSubagents: Int? = 3) {
        self.enabled = enabled
        self.maxConcurrentSubagents = maxConcurrentSubagents
    }
}
