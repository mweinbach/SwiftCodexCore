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
  public var priority: Int? { Self.integer(fields["priority"]) }
  public var visibility: String? { fields["visibility"]?.stringValue }
  public var supportedInAPI: Bool? { fields["supported_in_api"]?.boolValue }
  public var defaultReasoningEffort: ReasoningEffort? {
    defaultReasoningEffortName.flatMap(ReasoningEffort.init(rawValue:))
  }
  public var defaultReasoningEffortName: String? { fields["default_reasoning_level"]?.stringValue }
  public var supportedReasoningEffortNames: [String] {
    fields["supported_reasoning_levels"]?.arrayValue?.compactMap {
      $0.stringValue ?? $0["effort"]?.stringValue
    } ?? []
  }
  public var supportedReasoningEfforts: [ReasoningEffort] {
    supportedReasoningEffortNames.compactMap(ReasoningEffort.init(rawValue:))
  }
  public var contextWindow: Int? { Self.integer(fields["context_window"], minimum: 1) }
  public var maximumContextWindow: Int? { Self.integer(fields["max_context_window"], minimum: 1) }
  public var supportsOriginalImageDetail: Bool {
    fields["supports_image_detail_original"]?.boolValue ?? false
  }
  public var supportsParallelToolCalls: Bool? { fields["supports_parallel_tool_calls"]?.boolValue }
  public var supportsVerbosity: Bool? { fields["support_verbosity"]?.boolValue }
  public var defaultVerbosity: ResponseVerbosity? {
    fields["default_verbosity"]?.stringValue.flatMap(ResponseVerbosity.init(rawValue:))
  }
  public var supportsSearchTool: Bool { fields["supports_search_tool"]?.boolValue ?? false }
  public var usesResponsesLite: Bool { fields["use_responses_lite"]?.boolValue ?? false }
  public var prefersWebSockets: Bool { fields["prefer_websockets"]?.boolValue ?? false }
  public var toolMode: String? { fields["tool_mode"]?.stringValue }
  public var shellType: String? { fields["shell_type"]?.stringValue }
  public var applyPatchToolType: String? { fields["apply_patch_tool_type"]?.stringValue }
  public var webSearchToolType: String? { fields["web_search_tool_type"]?.stringValue }
  public var reasoningSummaryFormat: String? { fields["reasoning_summary_format"]?.stringValue }
  public var defaultReasoningSummary: ReasoningSummary? {
    fields["default_reasoning_summary"]?.stringValue.flatMap(ReasoningSummary.init(rawValue:))
  }
  public var minimalClientVersion: String? { fields["minimal_client_version"]?.stringValue }
  public var includeSkillsUsageInstructions: Bool? {
    fields["include_skills_usage_instructions"]?.boolValue
  }
  public var truncationMode: String? { fields["truncation_policy"]?["mode"]?.stringValue }
  public var truncationLimit: Int? {
    Self.integer(fields["truncation_policy"]?["limit"], minimum: 1)
  }
  public var instructionsTemplate: String? {
    fields["model_messages"]?["instructions_template"]?.stringValue
  }
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
    let configured = Self.integer(fields["auto_compact_token_limit"], minimum: 1)
    let derived = (contextWindow ?? maximumContextWindow).map {
      ($0 / 10) * 9 + (($0 % 10) * 9) / 10
    }
    switch (configured, derived) {
    case (let configured?, let derived?): return min(configured, derived)
    case (let configured?, nil): return configured
    case (nil, let derived?): return derived
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

  private static func integer(_ value: JSONValue?, minimum: Int? = nil) -> Int? {
    guard let number = value?.doubleValue,
      number.isFinite,
      number.rounded(.towardZero) == number,
      let integer = Int(exactly: number),
      minimum.map({ integer >= $0 }) ?? true
    else {
      return nil
    }
    return integer
  }

  fileprivate func mergingRemoteFields(_ remote: OpenAIModelInfo) -> OpenAIModelInfo {
    OpenAIModelInfo(fields: fields.merging(remote.fields) { _, remote in remote })
  }
}

public enum OpenAIModelCatalogSource: String, Codable, Sendable, Equatable {
  case codex
  case openAI
  case fallback
}

/// Describes whether bundled model metadata contributed to a resolved catalog.
public enum OpenAIModelCatalogFallbackUsage: String, Codable, Sendable, Equatable {
  case none
  case merged
  case exclusive
}

/// Identifies how the manager resolved its most recently observed catalog.
public enum OpenAIModelCatalogResolutionSource: String, Codable, Sendable, Equatable {
  case memoryCache
  case diskCache
  case network
  case notModified
  case etagValidated
  case staleWhileRevalidate
  case bundledFallback
  case refreshFailure
}

/// Structured, host-visible state for catalog cache and fallback decisions.
public struct OpenAIModelCatalogDiagnostics: Codable, Sendable, Equatable {
  public var resolutionSource: OpenAIModelCatalogResolutionSource
  public var catalogSource: OpenAIModelCatalogSource?
  public var fallbackUsage: OpenAIModelCatalogFallbackUsage
  public var endpoint: URL
  public var clientVersion: String
  public var etag: String?
  public var isStale: Bool
  public var isRefreshInFlight: Bool
  public var errorDescription: String?
  public var recordedAt: Date

  public var usesBundledFallback: Bool { fallbackUsage != .none }

  public init(
    resolutionSource: OpenAIModelCatalogResolutionSource,
    catalogSource: OpenAIModelCatalogSource?,
    fallbackUsage: OpenAIModelCatalogFallbackUsage,
    endpoint: URL,
    clientVersion: String,
    etag: String?,
    isStale: Bool,
    isRefreshInFlight: Bool,
    errorDescription: String? = nil,
    recordedAt: Date = Date()
  ) {
    self.resolutionSource = resolutionSource
    self.catalogSource = catalogSource
    self.fallbackUsage = fallbackUsage
    self.endpoint = endpoint
    self.clientVersion = clientVersion
    self.etag = etag
    self.isStale = isStale
    self.isRefreshInFlight = isRefreshInFlight
    self.errorDescription = errorDescription
    self.recordedAt = recordedAt
  }
}

public struct OpenAIModelCatalogSnapshot: Codable, Sendable, Equatable {
  public var models: [OpenAIModelInfo]
  public var etag: String?
  public var fetchedAt: Date
  public var clientVersion: String
  public var source: OpenAIModelCatalogSource
  /// Canonical endpoint identity used to prevent a shared cache file from
  /// being consumed by a different provider.
  public var endpointIdentity: String?
  /// Manager-produced snapshots set this explicitly; older decoded snapshots
  /// infer it from their provider source.
  public var fallbackUsage: OpenAIModelCatalogFallbackUsage

  private enum CodingKeys: String, CodingKey {
    case models
    case etag
    case fetchedAt
    case clientVersion
    case source
    case endpointIdentity
    case fallbackUsage
  }

  public init(
    models: [OpenAIModelInfo],
    etag: String? = nil,
    fetchedAt: Date = Date(),
    clientVersion: String,
    source: OpenAIModelCatalogSource,
    endpointIdentity: String? = nil,
    fallbackUsage: OpenAIModelCatalogFallbackUsage = .none
  ) {
    self.models = models
    self.etag = etag
    self.fetchedAt = fetchedAt
    self.clientVersion = clientVersion
    self.source = source
    self.endpointIdentity = endpointIdentity
    self.fallbackUsage = fallbackUsage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    models = try container.decode([OpenAIModelInfo].self, forKey: .models)
    etag = try container.decodeIfPresent(String.self, forKey: .etag)
    fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
    clientVersion = try container.decode(String.self, forKey: .clientVersion)
    source = try container.decode(OpenAIModelCatalogSource.self, forKey: .source)
    endpointIdentity = try container.decodeIfPresent(String.self, forKey: .endpointIdentity)
    fallbackUsage =
      try container.decodeIfPresent(OpenAIModelCatalogFallbackUsage.self, forKey: .fallbackUsage)
      ?? Self.inferredFallbackUsage(for: source)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(models, forKey: .models)
    try container.encodeIfPresent(etag, forKey: .etag)
    try container.encode(fetchedAt, forKey: .fetchedAt)
    try container.encode(clientVersion, forKey: .clientVersion)
    try container.encode(source, forKey: .source)
    try container.encodeIfPresent(endpointIdentity, forKey: .endpointIdentity)
    try container.encode(fallbackUsage, forKey: .fallbackUsage)
  }

  private static func inferredFallbackUsage(
    for source: OpenAIModelCatalogSource
  ) -> OpenAIModelCatalogFallbackUsage {
    switch source {
    case .codex: return .none
    case .openAI: return .merged
    case .fallback: return .exclusive
    }
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
  /// Always waits for the single-flight network refresh, using a cached ETag
  /// for conditional validation when available.
  case online
  /// Never accesses the network and may return a stale matching cache.
  case offline
  /// Returns a fresh cache, or returns stale data immediately while one
  /// single-flight refresh proceeds in the background.
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
      cacheURL: URL? = CodexDefaultLocations.coreDirectory.appendingPathComponent(
        "models_cache.json"),
      cacheTTL: TimeInterval = 300
    ) {
      self.endpoint = endpoint
      self.extraHeaders = extraHeaders
      self.requestTimeout = requestTimeout
      self.clientVersion = clientVersion
      self.cacheURL = cacheURL
      self.cacheTTL = cacheTTL
    }

    public static func derivedFromResponsesEndpoint(
      _ endpoint: URL, clientVersion: String = "0.1.0"
    ) -> Options {
      Options(
        endpoint: endpoint.deletingLastPathComponent().appendingPathComponent("models"),
        clientVersion: clientVersion)
    }
  }

  private let auth: any AuthorizationProvider
  private let options: Options
  private let session: URLSession
  private let fallbackModels: [OpenAIModelInfo]
  private var current: OpenAIModelCatalogSnapshot?
  private var refreshTask: Task<OpenAIModelCatalogSnapshot, Error>?
  public private(set) var lastRefreshError: String?
  public private(set) var lastDiagnostics: OpenAIModelCatalogDiagnostics?

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

  public func catalog(_ strategy: OpenAIModelCatalogRefreshStrategy = .onlineIfUncached) async
    -> OpenAIModelCatalogSnapshot
  {
    switch strategy {
    case .offline:
      if let current, isValidResolvedSnapshot(current) {
        recordDiagnostics(
          resolutionSource: current.source == .fallback ? .bundledFallback : .memoryCache,
          snapshot: current,
          isStale: !isFresh(current)
        )
        return current
      }
      if let cached = loadCache() {
        current = cached
        recordDiagnostics(resolutionSource: .diskCache, snapshot: cached, isStale: !isFresh(cached))
        return cached
      }
      return resolvedFallbackSnapshot()

    case .onlineIfUncached:
      if let current, current.source != .fallback, isFresh(current) {
        recordDiagnostics(resolutionSource: .memoryCache, snapshot: current, isStale: false)
        return current
      }
      if let cached = loadFreshCache() {
        current = cached
        recordDiagnostics(resolutionSource: .diskCache, snapshot: cached, isStale: false)
        return cached
      }
      if let stale = staleSnapshot() {
        current = stale
        recordDiagnostics(
          resolutionSource: .staleWhileRevalidate,
          snapshot: stale,
          isStale: true,
          isRefreshInFlight: true
        )
        scheduleBackgroundRefresh()
        return stale
      }

    case .online:
      break
    }

    do {
      return try await refresh()
    } catch {
      if let current, isValidResolvedSnapshot(current), current.source != .fallback {
        recordDiagnostics(
          resolutionSource: .memoryCache,
          snapshot: current,
          isStale: !isFresh(current),
          error: error
        )
        return current
      }
      if let cached = loadCache() {
        current = cached
        recordDiagnostics(
          resolutionSource: .diskCache,
          snapshot: cached,
          isStale: !isFresh(cached),
          error: error
        )
        return cached
      }
      return resolvedFallbackSnapshot(error: error)
    }
  }

  @discardableResult
  public func refresh() async throws -> OpenAIModelCatalogSnapshot {
    if let refreshTask {
      return try await refreshTask.value
    }

    let task = Task { try await self.performRefresh() }
    refreshTask = task
    do {
      let snapshot = try await task.value
      refreshTask = nil
      return snapshot
    } catch {
      refreshTask = nil
      lastRefreshError = String(describing: error)
      let existing = current ?? loadCache()
      recordDiagnostics(
        resolutionSource: .refreshFailure,
        snapshot: existing,
        isStale: existing.map { !isFresh($0) } ?? false,
        error: error
      )
      throw error
    }
  }

  public func refreshIfNewETag(_ etag: String) async {
    if var snapshot = conditionalSnapshot(), snapshot.etag == etag {
      snapshot.fetchedAt = Date()
      current = snapshot
      lastRefreshError = nil
      try? persist(snapshot)
      recordDiagnostics(resolutionSource: .etagValidated, snapshot: snapshot, isStale: false)
      return
    }
    _ = await catalog(.online)
  }

  private enum FetchResult {
    case modified(OpenAIModelCatalogSnapshot)
    case notModified(etag: String?)
  }

  private func performRefresh() async throws -> OpenAIModelCatalogSnapshot {
    let conditional = conditionalSnapshot()
    let result = try await fetch(allowRefresh: true, ifNoneMatch: conditional?.etag)
    let snapshot: OpenAIModelCatalogSnapshot
    let resolutionSource: OpenAIModelCatalogResolutionSource

    switch result {
    case .modified(let remote):
      snapshot = merge(remote)
      resolutionSource = .network

    case .notModified(let etag):
      guard var conditional else {
        throw CodexCoreError.transportError(
          "Models API returned 304 without a matching cached catalog")
      }
      conditional.etag = etag ?? conditional.etag
      conditional.fetchedAt = Date()
      snapshot = conditional
      resolutionSource = .notModified
    }

    current = snapshot
    lastRefreshError = nil
    try persist(snapshot)
    recordDiagnostics(resolutionSource: resolutionSource, snapshot: snapshot, isStale: false)
    return snapshot
  }

  private func fetch(allowRefresh: Bool, ifNoneMatch: String?) async throws -> FetchResult {
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
    if let ifNoneMatch, !ifNoneMatch.isEmpty {
      request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
    }
    for (key, value) in try await auth.authorizationHeaders() {
      request.setValue(value, forHTTPHeaderField: key)
    }
    for (key, value) in options.extraHeaders { request.setValue(value, forHTTPHeaderField: key) }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CodexCoreError.transportError("Models API did not return an HTTP response")
    }
    if http.statusCode == 401, allowRefresh,
      let refreshing = auth as? any TokenRefreshingAuthorizationProvider
    {
      try await refreshing.refreshNow()
      return try await fetch(allowRefresh: false, ifNoneMatch: ifNoneMatch)
    }
    if http.statusCode == 304 {
      return .notModified(etag: http.value(forHTTPHeaderField: "ETag"))
    }
    guard (200..<300).contains(http.statusCode) else {
      throw CodexCoreError.transportError(
        "Models API HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
    }

    let root = try JSONDecoder.codex.decode(JSONValue.self, from: data)
    let codexModels = root["models"]?.arrayValue
    let platformModels = root["data"]?.arrayValue
    guard codexModels != nil || platformModels != nil else {
      throw CodexCoreError.invalidJSON("Models response did not contain `models` or `data`")
    }
    let source: OpenAIModelCatalogSource = codexModels != nil ? .codex : .openAI
    let values = codexModels ?? platformModels ?? []
    let models = try validatedModels(values)
    return .modified(
      OpenAIModelCatalogSnapshot(
        models: models,
        etag: http.value(forHTTPHeaderField: "ETag"),
        clientVersion: options.clientVersion,
        source: source,
        endpointIdentity: endpointIdentity,
        fallbackUsage: .none
      ))
  }

  private func merge(_ remote: OpenAIModelCatalogSnapshot) -> OpenAIModelCatalogSnapshot {
    if remote.source == .codex,
      remote.models.contains(where: { $0.visibility == nil || $0.visibility == "list" })
    {
      var authoritative = remote
      authoritative.fallbackUsage = .none
      return authoritative
    }
    var byID: [String: OpenAIModelInfo] = [:]
    var usedFallback = false
    for model in fallbackModels where Self.isValidModel(model) {
      byID[model.slug] = model
      usedFallback = true
    }
    for model in remote.models {
      byID[model.slug] = byID[model.slug]?.mergingRemoteFields(model) ?? model
    }
    var merged = remote
    merged.models = Array(byID.values).sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
    merged.fallbackUsage = usedFallback ? .merged : .none
    return merged
  }

  private func fallbackSnapshot() -> OpenAIModelCatalogSnapshot {
    var seen = Set<String>()
    let validFallbacks = fallbackModels.filter { model in
      Self.isValidModel(model) && seen.insert(model.slug).inserted
    }
    return OpenAIModelCatalogSnapshot(
      models: validFallbacks,
      clientVersion: options.clientVersion,
      source: .fallback,
      endpointIdentity: endpointIdentity,
      fallbackUsage: .exclusive
    )
  }

  private func isFresh(_ snapshot: OpenAIModelCatalogSnapshot) -> Bool {
    guard isValidResolvedSnapshot(snapshot) else { return false }
    let age = Date().timeIntervalSince(snapshot.fetchedAt)
    return age >= -60 && age <= options.cacheTTL
  }

  private func loadFreshCache() -> OpenAIModelCatalogSnapshot? {
    loadCache().flatMap { isFresh($0) ? $0 : nil }
  }

  private func loadCache() -> OpenAIModelCatalogSnapshot? {
    guard let url = options.cacheURL,
      let data = try? Data(contentsOf: url),
      let snapshot = try? JSONDecoder.codex.decode(OpenAIModelCatalogSnapshot.self, from: data),
      snapshot.source != .fallback,
      isValidResolvedSnapshot(snapshot)
    else { return nil }
    return snapshot
  }

  private func persist(_ snapshot: OpenAIModelCatalogSnapshot) throws {
    guard let url = options.cacheURL else { return }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder.codexPretty.encode(snapshot).write(to: url, options: .atomic)
  }

  private var endpointIdentity: String {
    guard var components = URLComponents(url: options.endpoint, resolvingAgainstBaseURL: false)
    else {
      return options.endpoint.absoluteString
    }
    components.fragment = nil
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    if (components.scheme == "https" && components.port == 443)
      || (components.scheme == "http" && components.port == 80)
    {
      components.port = nil
    }
    let query = (components.queryItems ?? [])
      .filter { $0.name != "client_version" }
      .sorted {
        if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
        return $0.name < $1.name
      }
    components.queryItems = query.isEmpty ? nil : query
    return components.url?.absoluteString ?? options.endpoint.absoluteString
  }

  private func conditionalSnapshot() -> OpenAIModelCatalogSnapshot? {
    if let current, current.source != .fallback, isValidResolvedSnapshot(current) {
      return current
    }
    return loadCache()
  }

  private func staleSnapshot() -> OpenAIModelCatalogSnapshot? {
    if let current, current.source != .fallback, isValidResolvedSnapshot(current) {
      return current
    }
    return loadCache()
  }

  private func isValidResolvedSnapshot(_ snapshot: OpenAIModelCatalogSnapshot) -> Bool {
    guard snapshot.clientVersion == options.clientVersion,
      snapshot.endpointIdentity == endpointIdentity,
      !snapshot.models.isEmpty
    else { return false }
    var identifiers = Set<String>()
    return snapshot.models.allSatisfy { model in
      Self.isValidModel(model) && identifiers.insert(model.slug).inserted
    }
  }

  private static func isValidModel(_ model: OpenAIModelInfo) -> Bool {
    let identifier = model.slug
    return identifier != "unknown"
      && identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      && !identifier.isEmpty
      && identifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
      && identifier.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private func validatedModels(_ values: [JSONValue]) throws -> [OpenAIModelInfo] {
    guard !values.isEmpty else {
      throw CodexCoreError.invalidJSON("Models response contained an empty catalog")
    }
    var identifiers = Set<String>()
    return try values.enumerated().map { index, value in
      guard case .object(let fields) = value else {
        throw CodexCoreError.invalidJSON("Models response entry \(index) was not an object")
      }
      let model = OpenAIModelInfo(fields: fields)
      guard Self.isValidModel(model) else {
        throw CodexCoreError.invalidJSON(
          "Models response entry \(index) did not contain a valid model identifier")
      }
      guard identifiers.insert(model.slug).inserted else {
        throw CodexCoreError.invalidJSON(
          "Models response contained duplicate model identifier `\(model.slug)`")
      }
      return model
    }
  }

  private func scheduleBackgroundRefresh() {
    Task { [weak self] in
      guard let self else { return }
      _ = try? await self.refresh()
    }
  }

  private func resolvedFallbackSnapshot(error: Error? = nil) -> OpenAIModelCatalogSnapshot {
    let snapshot = fallbackSnapshot()
    current = snapshot
    recordDiagnostics(
      resolutionSource: .bundledFallback,
      snapshot: snapshot,
      isStale: false,
      error: error
    )
    return snapshot
  }

  private func recordDiagnostics(
    resolutionSource: OpenAIModelCatalogResolutionSource,
    snapshot: OpenAIModelCatalogSnapshot?,
    isStale: Bool,
    isRefreshInFlight: Bool = false,
    error: Error? = nil
  ) {
    lastDiagnostics = OpenAIModelCatalogDiagnostics(
      resolutionSource: resolutionSource,
      catalogSource: snapshot?.source,
      fallbackUsage: fallbackUsage(for: snapshot),
      endpoint: options.endpoint,
      clientVersion: options.clientVersion,
      etag: snapshot?.etag,
      isStale: isStale,
      isRefreshInFlight: isRefreshInFlight,
      errorDescription: error.map { String(describing: $0) }
    )
  }

  private func fallbackUsage(for snapshot: OpenAIModelCatalogSnapshot?)
    -> OpenAIModelCatalogFallbackUsage
  {
    snapshot?.fallbackUsage ?? .none
  }
}

extension AgentConfiguration {
  /// Applies defaults advertised by the dynamic catalog while preserving
  /// values the host already selected explicitly.
  public mutating func applyModelDefaults(_ info: OpenAIModelInfo, configureCompaction: Bool = true)
  {
    model = info.slug
    if reasoningEffort == nil, reasoningEffortName == nil {
      if let effort = info.defaultReasoningEffort {
        reasoningEffort = effort
      } else {
        reasoningEffortName = info.defaultReasoningEffortName
      }
    }
    if parallelToolCalls == nil {
      parallelToolCalls = info.supportsParallelToolCalls
    }
    if serviceTier == nil {
      serviceTier = info.defaultServiceTier
    }
    if toolMode == nil, let advertisedToolMode = info.toolMode,
      let mode = AgentToolMode(rawValue: advertisedToolMode)
    {
      toolMode = mode
    }
    if reasoningSummary == nil {
      reasoningSummary = info.defaultReasoningSummary
    }
    if textOptions?.verbosity == nil, info.supportsVerbosity == true,
      let verbosity = info.defaultVerbosity
    {
      if textOptions == nil { textOptions = ResponseTextOptions() }
      textOptions?.verbosity = verbosity
    }
    if useResponsesLite == nil {
      useResponsesLite = info.usesResponsesLite
    }
    if skillOptions.includeUsageInstructions == nil {
      skillOptions.includeUsageInstructions = info.includeSkillsUsageInstructions
    }
    if codeModeOptions == nil {
      let limit = max(1, info.truncationLimit ?? 10_000)
      codeModeOptions = CodeModeOptions(
        maxNestedToolOutputTokens: limit,
        defaultMaxOutputTokens: limit,
        allowOriginalImageDetail: info.supportsOriginalImageDetail
      )
    }
    if configureCompaction, contextManagement == nil,
      let threshold = info.automaticCompactionTokenLimit
    {
      contextManagement = [ResponseContextManagement(compactThreshold: threshold)]
    }
  }

  public func applyingModelDefaults(_ info: OpenAIModelInfo, configureCompaction: Bool = true)
    -> AgentConfiguration
  {
    var copy = self
    copy.applyModelDefaults(info, configureCompaction: configureCompaction)
    return copy
  }
}

extension OpenAIModelInfo {
  /// Bundled baseline used to enrich sparse `/v1/models` results and to keep
  /// first-launch or offline model selection functional. Detailed remote
  /// fields remain authoritative when available.
  public static let gpt56FallbackCatalog: [OpenAIModelInfo] = [
    fallback(
      .gpt56Sol, displayName: "GPT-5.6-Sol", priority: 1, defaultEffort: .low,
      efforts: [.low, .medium, .high, .xhigh, .max, .ultra], multiAgentVersion: "v2"),
    fallback(
      .gpt56Terra, displayName: "GPT-5.6-Terra", priority: 2, defaultEffort: .medium,
      efforts: [.low, .medium, .high, .xhigh, .max, .ultra], multiAgentVersion: "v2"),
    fallback(
      .gpt56Luna, displayName: "GPT-5.6-Luna", priority: 3, defaultEffort: .medium,
      efforts: [.low, .medium, .high, .xhigh, .max], multiAgentVersion: "v1"),
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
      "supported_reasoning_levels": .array(
        efforts.map { .object(["effort": .string($0.rawValue)]) }),
      "context_window": .number(372_000),
      "max_context_window": .number(372_000),
      "supports_image_detail_original": .bool(true),
      "prefer_websockets": .bool(true),
      "support_verbosity": .bool(true),
      "default_verbosity": .string("low"),
      "apply_patch_tool_type": .string("freeform"),
      "web_search_tool_type": .string("text_and_image"),
      "truncation_policy": .object(["mode": .string("tokens"), "limit": .number(10_000)]),
      "supports_parallel_tool_calls": .bool(true),
      "input_modalities": .array([.string("text"), .string("image")]),
      "supports_search_tool": .bool(true),
      "use_responses_lite": .bool(true),
      "include_skills_usage_instructions": .bool(false),
      "reasoning_summary_format": .string("experimental"),
      "default_reasoning_summary": .string("none"),
      "shell_type": .string("shell_command"),
      "minimal_client_version": .string("0.144.0"),
      "tool_mode": .string("code_mode_only"),
      "multi_agent_version": .string(multiAgentVersion),
      "priority": .number(Double(priority)),
      "visibility": .string("list"),
      "supported_in_api": .bool(true),
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
