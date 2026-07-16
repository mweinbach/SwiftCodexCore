import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Current OpenAI model identifiers that are useful to Codex-style hosts.
public enum OpenAIModel: String, Codable, Sendable, Equatable, CaseIterable {
    /// Alias that routes to GPT-5.6 Sol.
    case gpt56 = "gpt-5.6"
    case gpt56Sol = "gpt-5.6-sol"
    case gpt56Terra = "gpt-5.6-terra"
    case gpt56Luna = "gpt-5.6-luna"
}

/// Future-compatible model metadata returned by the provider `/models`
/// endpoint. Unknown fields are preserved so hosts can adopt newly advertised
/// capabilities without waiting for a package release.
public struct OpenAIModelInfo: Codable, Sendable, Equatable, Identifiable {
    public var fields: [String: JSONValue]

    public var id: String { slug }
    public var slug: String { fields["slug"]?.stringValue ?? fields["id"]?.stringValue ?? "unknown" }
    public var displayName: String { fields["display_name"]?.stringValue ?? slug }
    public var description: String? { fields["description"]?.stringValue }
    public var priority: Int? { fields["priority"]?.doubleValue.map(Int.init) }
    public var visibility: String? { fields["visibility"]?.stringValue }
    public var supportedInAPI: Bool? { fields["supported_in_api"]?.boolValue }
    public var defaultReasoningEffort: ReasoningEffort? {
        defaultReasoningEffortName.flatMap(ReasoningEffort.init(rawValue:))
    }
    public var defaultReasoningEffortName: String? { fields["default_reasoning_level"]?.stringValue }
    public var supportedReasoningEffortNames: [String] {
        fields["supported_reasoning_levels"]?.arrayValue?.compactMap { $0.stringValue ?? $0["effort"]?.stringValue } ?? []
    }
    public var supportedReasoningEfforts: [ReasoningEffort] {
        supportedReasoningEffortNames.compactMap(ReasoningEffort.init(rawValue:))
    }
    public var contextWindow: Int? { fields["context_window"]?.doubleValue.map(Int.init) }
    public var maximumContextWindow: Int? { fields["max_context_window"]?.doubleValue.map(Int.init) }
    public var supportsOriginalImageDetail: Bool { fields["supports_image_detail_original"]?.boolValue ?? false }
    public var supportsParallelToolCalls: Bool? { fields["supports_parallel_tool_calls"]?.boolValue }
    public var supportsVerbosity: Bool? { fields["support_verbosity"]?.boolValue }
    public var supportsSearchTool: Bool { fields["supports_search_tool"]?.boolValue ?? false }
    public var usesResponsesLite: Bool { fields["use_responses_lite"]?.boolValue ?? false }
    public var toolMode: String? { fields["tool_mode"]?.stringValue }
    public var multiAgentVersion: String? { fields["multi_agent_version"]?.stringValue }
    public var defaultServiceTier: String? { fields["default_service_tier"]?.stringValue }
    public var serviceTiers: [JSONValue] { fields["service_tiers"]?.arrayValue ?? [] }
    public var additionalSpeedTiers: [String] {
        fields["additional_speed_tiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
    public var inputModalities: [String] {
        fields["input_modalities"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
    public var experimentalSupportedTools: [String] {
        fields["experimental_supported_tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
    public var automaticCompactionTokenLimit: Int? {
        let configured = fields["auto_compact_token_limit"]?.doubleValue.map(Int.init)
        let derived = (contextWindow ?? maximumContextWindow).map { $0 * 9 / 10 }
        switch (configured, derived) {
        case let (configured?, derived?): return min(configured, derived)
        case let (configured?, nil): return configured
        case let (nil, derived?): return derived
        case (nil, nil): return nil
        }
    }

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        fields = try container.decode([String: JSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }

    public subscript(field: String) -> JSONValue? { fields[field] }

    fileprivate func mergingRemoteFields(_ remote: OpenAIModelInfo) -> OpenAIModelInfo {
        OpenAIModelInfo(fields: fields.merging(remote.fields) { _, remote in remote })
    }
}

public enum OpenAIModelCatalogSource: String, Codable, Sendable, Equatable {
    case codex
    case openAI
    case fallback
}

public struct OpenAIModelCatalogSnapshot: Codable, Sendable, Equatable {
    public var models: [OpenAIModelInfo]
    public var etag: String?
    public var fetchedAt: Date
    public var clientVersion: String
    public var source: OpenAIModelCatalogSource

    public init(
        models: [OpenAIModelInfo],
        etag: String? = nil,
        fetchedAt: Date = Date(),
        clientVersion: String,
        source: OpenAIModelCatalogSource
    ) {
        self.models = models
        self.etag = etag
        self.fetchedAt = fetchedAt
        self.clientVersion = clientVersion
        self.source = source
    }

    public func model(id: String) -> OpenAIModelInfo? {
        models.first { $0.slug == id }
    }

    public var defaultModel: OpenAIModelInfo? {
        models
            .filter { $0.visibility == nil || $0.visibility == "list" }
            .sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
            .first
    }
}

public enum OpenAIModelCatalogRefreshStrategy: Sendable, Equatable {
    case online
    case offline
    case onlineIfUncached
}

/// Codex-style dynamic model catalog backed by `/models`, a five-minute disk
/// cache, ETag refresh signals, and a small bundled fallback.
public actor OpenAIModelsManager {
    public struct Options: Sendable, Equatable {
        public var endpoint: URL
        public var extraHeaders: [String: String]
        public var requestTimeout: TimeInterval
        public var clientVersion: String
        public var cacheURL: URL?
        public var cacheTTL: TimeInterval

        public init(
            endpoint: URL,
            extraHeaders: [String: String] = [:],
            requestTimeout: TimeInterval = 5,
            clientVersion: String = "0.1.0",
            cacheURL: URL? = CodexDefaultLocations.coreDirectory.appendingPathComponent("models_cache.json"),
            cacheTTL: TimeInterval = 300
        ) {
            self.endpoint = endpoint
            self.extraHeaders = extraHeaders
            self.requestTimeout = requestTimeout
            self.clientVersion = clientVersion
            self.cacheURL = cacheURL
            self.cacheTTL = cacheTTL
        }

        public static func derivedFromResponsesEndpoint(_ endpoint: URL, clientVersion: String = "0.1.0") -> Options {
            Options(endpoint: endpoint.deletingLastPathComponent().appendingPathComponent("models"), clientVersion: clientVersion)
        }
    }

    private let auth: any AuthorizationProvider
    private let options: Options
    private let session: URLSession
    private let fallbackModels: [OpenAIModelInfo]
    private var current: OpenAIModelCatalogSnapshot?
    public private(set) var lastRefreshError: String?

    public init(
        auth: any AuthorizationProvider,
        options: Options,
        session: URLSession = .shared,
        fallbackModels: [OpenAIModelInfo] = OpenAIModelInfo.gpt56FallbackCatalog
    ) {
        self.auth = auth
        self.options = options
        self.session = session
        self.fallbackModels = fallbackModels
    }

    public func catalog(_ strategy: OpenAIModelCatalogRefreshStrategy = .onlineIfUncached) async -> OpenAIModelCatalogSnapshot {
        if strategy != .online, let current, isFresh(current) {
            return current
        }
        if strategy != .online, let cached = loadFreshCache() {
            current = cached
            return cached
        }
        guard strategy != .offline else { return fallbackSnapshot() }
        do {
            return try await refresh()
        } catch {
            lastRefreshError = String(describing: error)
            if let current { return current }
            if let cached = loadCache() { return cached }
            return fallbackSnapshot()
        }
    }

    @discardableResult
    public func refresh() async throws -> OpenAIModelCatalogSnapshot {
        let remote = try await fetch(allowRefresh: true)
        let merged = merge(remote)
        current = merged
        lastRefreshError = nil
        try persist(merged)
        return merged
    }

    public func refreshIfNewETag(_ etag: String) async {
        if current?.etag == etag {
            if var current {
                current.fetchedAt = Date()
                self.current = current
                try? persist(current)
            }
            return
        }
        _ = await catalog(.online)
    }

    private func fetch(allowRefresh: Bool) async throws -> OpenAIModelCatalogSnapshot {
        var components = URLComponents(url: options.endpoint, resolvingAgainstBaseURL: false)
        var query = components?.queryItems ?? []
        query.removeAll { $0.name == "client_version" }
        query.append(URLQueryItem(name: "client_version", value: options.clientVersion))
        components?.queryItems = query
        guard let url = components?.url else {
            throw CodexCoreError.transportError("Invalid models endpoint")
        }
        var request = URLRequest(url: url, timeoutInterval: options.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in try await auth.authorizationHeaders() { request.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in options.extraHeaders { request.setValue(value, forHTTPHeaderField: key) }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexCoreError.transportError("Models API did not return an HTTP response")
        }
        if http.statusCode == 401, allowRefresh, let refreshing = auth as? any TokenRefreshingAuthorizationProvider {
            try await refreshing.refreshNow()
            return try await fetch(allowRefresh: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexCoreError.transportError("Models API HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }

        let root = try JSONDecoder.codex.decode(JSONValue.self, from: data)
        let codexModels = root["models"]?.arrayValue
        let platformModels = root["data"]?.arrayValue
        guard codexModels != nil || platformModels != nil else {
            throw CodexCoreError.invalidJSON("Models response did not contain `models` or `data`")
        }
        let source: OpenAIModelCatalogSource = codexModels != nil ? .codex : .openAI
        let values = codexModels ?? platformModels ?? []
        let models = values.compactMap { value -> OpenAIModelInfo? in
            guard case .object(let fields) = value else { return nil }
            return OpenAIModelInfo(fields: fields)
        }
        return OpenAIModelCatalogSnapshot(
            models: models,
            etag: http.value(forHTTPHeaderField: "ETag"),
            clientVersion: options.clientVersion,
            source: source
        )
    }

    private func merge(_ remote: OpenAIModelCatalogSnapshot) -> OpenAIModelCatalogSnapshot {
        if remote.source == .codex,
           remote.models.contains(where: { $0.visibility == nil || $0.visibility == "list" }) {
            return remote
        }
        var byID = Dictionary(uniqueKeysWithValues: fallbackModels.map { ($0.slug, $0) })
        for model in remote.models {
            byID[model.slug] = byID[model.slug]?.mergingRemoteFields(model) ?? model
        }
        var merged = remote
        merged.models = Array(byID.values).sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
        return merged
    }

    private func fallbackSnapshot() -> OpenAIModelCatalogSnapshot {
        OpenAIModelCatalogSnapshot(models: fallbackModels, clientVersion: options.clientVersion, source: .fallback)
    }

    private func isFresh(_ snapshot: OpenAIModelCatalogSnapshot) -> Bool {
        snapshot.clientVersion == options.clientVersion && Date().timeIntervalSince(snapshot.fetchedAt) <= options.cacheTTL
    }

    private func loadFreshCache() -> OpenAIModelCatalogSnapshot? {
        loadCache().flatMap { isFresh($0) ? $0 : nil }
    }

    private func loadCache() -> OpenAIModelCatalogSnapshot? {
        guard let url = options.cacheURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder.codex.decode(OpenAIModelCatalogSnapshot.self, from: data),
              snapshot.clientVersion == options.clientVersion else { return nil }
        return snapshot
    }

    private func persist(_ snapshot: OpenAIModelCatalogSnapshot) throws {
        guard let url = options.cacheURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.codexPretty.encode(snapshot).write(to: url, options: .atomic)
    }
}

public extension AgentConfiguration {
    /// Applies defaults advertised by the dynamic catalog while preserving
    /// values the host already selected explicitly.
    mutating func applyModelDefaults(_ info: OpenAIModelInfo, configureCompaction: Bool = true) {
        model = info.slug
        if reasoningEffort == nil {
            reasoningEffort = info.defaultReasoningEffort
        }
        if parallelToolCalls == nil {
            parallelToolCalls = info.supportsParallelToolCalls
        }
        if serviceTier == nil {
            serviceTier = info.defaultServiceTier
        }
        if configureCompaction, contextManagement == nil, let threshold = info.automaticCompactionTokenLimit {
            contextManagement = [ResponseContextManagement(compactThreshold: threshold)]
        }
    }

    func applyingModelDefaults(_ info: OpenAIModelInfo, configureCompaction: Bool = true) -> AgentConfiguration {
        var copy = self
        copy.applyModelDefaults(info, configureCompaction: configureCompaction)
        return copy
    }
}

public extension OpenAIModelInfo {
    /// Bundled only for first launch and offline recovery; a detailed remote
    /// Codex catalog is authoritative when available.
    static let gpt56FallbackCatalog: [OpenAIModelInfo] = [
        fallback(.gpt56Sol, displayName: "GPT-5.6-Sol", priority: 1, defaultEffort: .low, efforts: [.low, .medium, .high, .xhigh, .max, .ultra], multiAgentVersion: "v2"),
        fallback(.gpt56Terra, displayName: "GPT-5.6-Terra", priority: 2, defaultEffort: .medium, efforts: [.low, .medium, .high, .xhigh, .max, .ultra], multiAgentVersion: "v2"),
        fallback(.gpt56Luna, displayName: "GPT-5.6-Luna", priority: 3, defaultEffort: .medium, efforts: [.low, .medium, .high, .xhigh, .max], multiAgentVersion: "v1")
    ]

    private static func fallback(
        _ model: OpenAIModel,
        displayName: String,
        priority: Int,
        defaultEffort: ReasoningEffort,
        efforts: [ReasoningEffort],
        multiAgentVersion: String
    ) -> OpenAIModelInfo {
        OpenAIModelInfo(fields: [
            "slug": .string(model.rawValue),
            "display_name": .string(displayName),
            "default_reasoning_level": .string(defaultEffort.rawValue),
            "supported_reasoning_levels": .array(efforts.map { .object(["effort": .string($0.rawValue)]) }),
            "context_window": .number(372_000),
            "max_context_window": .number(372_000),
            "supports_image_detail_original": .bool(true),
            "input_modalities": .array([.string("text"), .string("image")]),
            "supports_search_tool": .bool(true),
            "use_responses_lite": .bool(true),
            "tool_mode": .string("code_mode_only"),
            "multi_agent_version": .string(multiAgentVersion),
            "priority": .number(Double(priority)),
            "visibility": .string("list"),
            "supported_in_api": .bool(true)
        ])
    }
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
