import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(Security)
  import Security
#endif

public enum AuthMode: String, Codable, Sendable, Equatable {
  case apiKey
  case chatGPT
  case bearer
}

public struct AuthSession: Codable, Sendable, Equatable {
  public var mode: AuthMode
  public var apiKey: String?
  public var accessToken: String?
  public var refreshToken: String?
  public var expiresAt: Date?
  public var accountID: String?
  public var workspaceID: String?
  public var metadata: [String: JSONValue]

  public init(
    mode: AuthMode,
    apiKey: String? = nil,
    accessToken: String? = nil,
    refreshToken: String? = nil,
    expiresAt: Date? = nil,
    accountID: String? = nil,
    workspaceID: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) {
    self.mode = mode
    self.apiKey = apiKey
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.accountID = accountID
    self.workspaceID = workspaceID
    self.metadata = metadata
  }
}

public protocol AuthorizationProvider: Sendable {
  func authorizationHeaders() async throws -> [String: String]
}

public protocol TokenRefreshingAuthorizationProvider: AuthorizationProvider {
  func refreshNow() async throws
}

public protocol AuthSessionStore: Sendable {
  func loadSession() async throws -> AuthSession?
  func saveSession(_ session: AuthSession) async throws
  func clear() async throws
}

public protocol CodexAuthCacheStore: AuthSessionStore {
  func load() async throws -> CodexAuthDotJson?
  func save(_ auth: CodexAuthDotJson) async throws
}

public struct APIKeyAuthProvider: AuthorizationProvider {
  public var apiKey: String
  public var organization: String?
  public var project: String?

  public init(apiKey: String, organization: String? = nil, project: String? = nil) {
    self.apiKey = apiKey
    self.organization = organization
    self.project = project
  }

  public func authorizationHeaders() async throws -> [String: String] {
    var headers = ["Authorization": "Bearer \(apiKey)"]
    if let organization { headers["OpenAI-Organization"] = organization }
    if let project { headers["OpenAI-Project"] = project }
    return headers
  }
}

public actor FileAuthStore: AuthSessionStore {
  public let fileURL: URL

  public init(
    fileURL: URL = CodexDefaultLocations.coreDirectory.appendingPathComponent("auth.json")
  ) {
    self.fileURL = fileURL
  }

  public func load() async throws -> AuthSession? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder.codex.decode(AuthSession.self, from: data)
  }

  public func loadSession() async throws -> AuthSession? {
    try await load()
  }

  public func save(_ session: AuthSession) async throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder.codexPretty.encode(session)
    try data.write(to: fileURL, options: [.atomic])
  }

  public func saveSession(_ session: AuthSession) async throws {
    try await save(session)
  }

  public func clear() async throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }
}

public struct CodexAuthDotJson: Codable, Sendable, Equatable {
  public var authMode: String?
  public var openaiAPIKey: String?
  public var tokens: CodexTokenData?
  public var lastRefresh: Date?
  public var agentIdentity: JSONValue?

  enum CodingKeys: String, CodingKey {
    case authMode = "auth_mode"
    case openaiAPIKey = "OPENAI_API_KEY"
    case tokens
    case lastRefresh = "last_refresh"
    case agentIdentity = "agent_identity"
  }

  enum LegacyCodingKeys: String, CodingKey {
    case openaiAPIKey = "openai_api_key"
  }

  public init(
    authMode: String? = nil, openaiAPIKey: String? = nil, tokens: CodexTokenData? = nil,
    lastRefresh: Date? = nil, agentIdentity: JSONValue? = nil
  ) {
    self.authMode = authMode
    self.openaiAPIKey = openaiAPIKey
    self.tokens = tokens
    self.lastRefresh = lastRefresh
    self.agentIdentity = agentIdentity
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
    authMode = try container.decodeIfPresent(String.self, forKey: .authMode)
    openaiAPIKey =
      try container.decodeIfPresent(String.self, forKey: .openaiAPIKey)
      ?? legacyContainer.decodeIfPresent(String.self, forKey: .openaiAPIKey)
    tokens = try container.decodeIfPresent(CodexTokenData.self, forKey: .tokens)
    agentIdentity = try container.decodeIfPresent(JSONValue.self, forKey: .agentIdentity)
    if let dateString = try container.decodeIfPresent(String.self, forKey: .lastRefresh) {
      lastRefresh = CodexDate.parse(dateString)
    } else {
      lastRefresh = nil
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(authMode, forKey: .authMode)
    try container.encodeIfPresent(openaiAPIKey, forKey: .openaiAPIKey)
    try container.encodeIfPresent(tokens, forKey: .tokens)
    try container.encodeIfPresent(agentIdentity, forKey: .agentIdentity)
    if let lastRefresh { try container.encode(CodexDate.format(lastRefresh), forKey: .lastRefresh) }
  }

  public func asAuthSession() -> AuthSession? {
    let mode: AuthMode
    if authMode == "chatgpt" {
      mode = .chatGPT
    } else if authMode == "apikey" || authMode == "apiKey" {
      mode = .apiKey
    } else if tokens?.accessToken != nil {
      mode = .chatGPT
    } else if openaiAPIKey != nil {
      mode = .apiKey
    } else {
      return nil
    }

    if mode == .apiKey {
      return AuthSession(mode: .apiKey, apiKey: openaiAPIKey)
    }

    guard let tokens else { return nil }
    var metadata: [String: JSONValue] = [:]
    if let idToken = tokens.idToken { metadata["id_token_claims"] = idToken }
    if let rawIDToken = tokens.rawIDToken { metadata["raw_id_token"] = .string(rawIDToken) }
    if let lastRefresh { metadata["last_refresh"] = .string(CodexDate.format(lastRefresh)) }
    if let openaiAPIKey { metadata["openai_api_key"] = .string(openaiAPIKey) }
    let expiry = tokens.accessToken.flatMap { JWT.payload($0)?["exp"]?.doubleValue }.map {
      Date(timeIntervalSince1970: $0)
    }
    let accountID =
      tokens.accountID ?? tokens.idToken.flatMap(JWT.extractChatGPTAccountID)
      ?? tokens.accessToken.flatMap { JWT.payload($0).flatMap(JWT.extractChatGPTAccountID) }
    let workspaceID = tokens.idToken.flatMap(JWT.extractOrganizationID)
    return AuthSession(
      mode: .chatGPT,
      apiKey: openaiAPIKey,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAt: expiry,
      accountID: accountID,
      workspaceID: workspaceID,
      metadata: metadata
    )
  }
}

public struct CodexTokenData: Codable, Sendable, Equatable {
  public var idToken: JSONValue?
  public var accessToken: String?
  public var refreshToken: String?
  public var accountID: String?
  public var rawIDToken: String?

  enum CodingKeys: String, CodingKey {
    case idToken = "id_token"
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case accountID = "account_id"
    case rawIDToken = "raw_id_token"
  }

  public init(
    idToken: JSONValue? = nil, accessToken: String? = nil, refreshToken: String? = nil,
    accountID: String? = nil, rawIDToken: String? = nil
  ) {
    self.idToken = idToken
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.accountID = accountID
    self.rawIDToken = rawIDToken
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
    refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    rawIDToken = try container.decodeIfPresent(String.self, forKey: .rawIDToken)
    if let raw = try? container.decodeIfPresent(String.self, forKey: .idToken) {
      rawIDToken = rawIDToken ?? raw
      idToken = JWT.payload(raw) ?? .string(raw)
    } else {
      idToken = try container.decodeIfPresent(JSONValue.self, forKey: .idToken)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let rawIDToken {
      try container.encode(rawIDToken, forKey: .idToken)
    } else if case .string(let raw)? = idToken {
      try container.encode(raw, forKey: .idToken)
    } else {
      try container.encodeIfPresent(idToken, forKey: .idToken)
    }
    try container.encodeIfPresent(accessToken, forKey: .accessToken)
    try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
    try container.encodeIfPresent(accountID, forKey: .accountID)
  }
}

public actor CodexAuthStore: CodexAuthCacheStore {
  public let codexHome: URL
  public let authFileURL: URL

  public init(codexHome: URL = CodexAuthStore.defaultCodexHome()) {
    self.codexHome = codexHome
    self.authFileURL = codexHome.appendingPathComponent("auth.json")
  }

  public static func defaultCodexHome() -> URL {
    CodexDefaultLocations.codexHome
  }

  public func load() async throws -> CodexAuthDotJson? {
    guard FileManager.default.fileExists(atPath: authFileURL.path) else { return nil }
    let data = try Data(contentsOf: authFileURL)
    return try JSONDecoder.codex.decode(CodexAuthDotJson.self, from: data)
  }

  public func loadSession() async throws -> AuthSession? {
    try await load()?.asAuthSession()
  }

  public func save(_ auth: CodexAuthDotJson) async throws {
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    let data = try JSONEncoder.codexPretty.encode(auth)
    try data.write(to: authFileURL, options: [.atomic])
  }

  public func saveSession(_ session: AuthSession) async throws {
    guard session.mode == .chatGPT else {
      try await save(
        CodexAuthDotJson(
          authMode: session.mode == .apiKey ? "apikey" : session.mode.rawValue,
          openaiAPIKey: session.apiKey, lastRefresh: Date()))
      return
    }
    let idClaims = session.metadata["id_token_claims"]
    let rawIDToken = session.metadata["raw_id_token"]?.stringValue
    let auth = CodexAuthDotJson(
      authMode: "chatgpt",
      openaiAPIKey: session.metadata["openai_api_key"]?.stringValue ?? session.apiKey,
      tokens: CodexTokenData(
        idToken: idClaims,
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        accountID: session.accountID,
        rawIDToken: rawIDToken
      ),
      lastRefresh: Date()
    )
    try await save(auth)
  }

  public func clear() async throws {
    if FileManager.default.fileExists(atPath: authFileURL.path) {
      try FileManager.default.removeItem(at: authFileURL)
    }
  }
}

#if canImport(Security)
  public actor CodexKeychainAuthStore: CodexAuthCacheStore {
    public let service: String
    public let account: String
    public let accessGroup: String?
    public let accessible: CFString

    public init(
      service: String = "Codex Auth",
      account: String = CodexDefaultLocations.codexHome.path,
      accessGroup: String? = nil,
      accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
      self.service = service
      self.account = account
      self.accessGroup = accessGroup
      self.accessible = accessible
    }

    public func load() async throws -> CodexAuthDotJson? {
      var query = baseQuery()
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess else {
        throw CodexCoreError.authError("Keychain auth load failed with status \(status)")
      }
      guard let data = item as? Data else {
        throw CodexCoreError.authError("Keychain auth item did not contain data")
      }
      return try JSONDecoder.codex.decode(CodexAuthDotJson.self, from: data)
    }

    public func loadSession() async throws -> AuthSession? {
      try await load()?.asAuthSession()
    }

    public func save(_ auth: CodexAuthDotJson) async throws {
      let data = try JSONEncoder.codexPretty.encode(auth)
      var query = baseQuery()
      SecItemDelete(query as CFDictionary)
      query[kSecValueData as String] = data
      query[kSecAttrAccessible as String] = accessible
      let status = SecItemAdd(query as CFDictionary, nil)
      guard status == errSecSuccess else {
        throw CodexCoreError.authError("Keychain auth save failed with status \(status)")
      }
    }

    public func saveSession(_ session: AuthSession) async throws {
      guard session.mode == .chatGPT else {
        try await save(
          CodexAuthDotJson(
            authMode: session.mode == .apiKey ? "apikey" : session.mode.rawValue,
            openaiAPIKey: session.apiKey, lastRefresh: Date()))
        return
      }
      let idClaims = session.metadata["id_token_claims"]
      let rawIDToken = session.metadata["raw_id_token"]?.stringValue
      try await save(
        CodexAuthDotJson(
          authMode: "chatgpt",
          openaiAPIKey: session.metadata["openai_api_key"]?.stringValue ?? session.apiKey,
          tokens: CodexTokenData(
            idToken: idClaims,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            accountID: session.accountID,
            rawIDToken: rawIDToken
          ),
          lastRefresh: Date()
        ))
    }

    public func clear() async throws {
      let status = SecItemDelete(baseQuery() as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw CodexCoreError.authError("Keychain auth delete failed with status \(status)")
      }
    }

    private func baseQuery() -> [String: Any] {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
      if let accessGroup {
        query[kSecAttrAccessGroup as String] = accessGroup
      }
      return query
    }
  }
#endif

public struct CodexChatGPTAuthConfig: Sendable, Equatable {
  public static let codexCLIClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

  public var issuer: URL
  public var clientID: String
  public var originator: String
  public var callbackPort: UInt16
  public var forcedWorkspaceID: String?
  public var scopes: String
  public var codexHome: URL
  public var staleRefreshInterval: TimeInterval

  public init(
    issuer: URL = URL(string: "https://auth.openai.com")!,
    clientID: String = CodexChatGPTAuthConfig.codexCLIClientID,
    originator: String = "codex_cli",
    callbackPort: UInt16 = 1455,
    forcedWorkspaceID: String? = nil,
    scopes: String =
      "openid profile email offline_access api.connectors.read api.connectors.invoke",
    codexHome: URL = CodexAuthStore.defaultCodexHome(),
    staleRefreshInterval: TimeInterval = 8 * 24 * 60 * 60
  ) {
    self.issuer = issuer
    self.clientID = clientID
    self.originator = originator
    self.callbackPort = callbackPort
    self.forcedWorkspaceID = forcedWorkspaceID
    self.scopes = scopes
    self.codexHome = codexHome
    self.staleRefreshInterval = staleRefreshInterval
  }

  public var trimmedIssuer: String {
    issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
  public var redirectURI: URL { URL(string: "http://localhost:\(callbackPort)/auth/callback")! }
  public var deviceRedirectURI: URL { URL(string: "\(trimmedIssuer)/deviceauth/callback")! }
}

public struct PKCECodes: Codable, Sendable, Equatable {
  public var codeVerifier: String
  public var codeChallenge: String

  public init(codeVerifier: String, codeChallenge: String) {
    self.codeVerifier = codeVerifier
    self.codeChallenge = codeChallenge
  }

  public static func generate() -> PKCECodes {
    let verifier = Base64URL.encode(RandomBytes.generate(count: 32))
    let challenge = Base64URL.encode(SHA256.hash(Data(verifier.utf8)))
    return PKCECodes(codeVerifier: verifier, codeChallenge: challenge)
  }
}

public struct CodexBrowserLoginSession: Codable, Sendable, Equatable {
  public var state: String
  public var pkce: PKCECodes
  public var redirectURI: URL
  public var authorizeURL: URL

  public init(state: String, pkce: PKCECodes, redirectURI: URL, authorizeURL: URL) {
    self.state = state
    self.pkce = pkce
    self.redirectURI = redirectURI
    self.authorizeURL = authorizeURL
  }
}

public struct CodexDeviceCode: Codable, Sendable, Equatable {
  public var verificationURL: URL
  public var userCode: String
  public var deviceAuthID: String
  public var interval: UInt64

  public init(verificationURL: URL, userCode: String, deviceAuthID: String, interval: UInt64) {
    self.verificationURL = verificationURL
    self.userCode = userCode
    self.deviceAuthID = deviceAuthID
    self.interval = interval
  }
}

public actor ChatGPTAuthProvider: TokenRefreshingAuthorizationProvider {
  public typealias RefreshHandler = @Sendable (AuthSession) async throws -> AuthSession

  private var session: AuthSession
  private let sessionStores: [any AuthSessionStore]
  private let refreshHandler: RefreshHandler?
  private let refreshSkew: TimeInterval
  private let config: CodexChatGPTAuthConfig
  private let httpClient: CodexChatGPTAuthClient
  private var refreshTask: Task<Void, Error>?
  private var generation = UUID()
  private var invalidated = false

  public init(
    session: AuthSession,
    store: FileAuthStore? = nil,
    codexStore: (any CodexAuthCacheStore)? = nil,
    config: CodexChatGPTAuthConfig = CodexChatGPTAuthConfig(),
    refreshSkew: TimeInterval = 300,
    refreshHandler: RefreshHandler? = nil,
    urlSession: URLSession = .shared
  ) {
    self.session = session
    self.sessionStores = [store as (any AuthSessionStore)?, codexStore as (any AuthSessionStore)?]
      .compactMap { $0 }
    self.config = config
    self.refreshHandler = refreshHandler
    self.refreshSkew = refreshSkew
    self.httpClient = CodexChatGPTAuthClient(
      config: config, store: codexStore ?? CodexAuthStore(codexHome: config.codexHome),
      session: urlSession)
  }

  public static func fromCodexAuthFile(
    config: CodexChatGPTAuthConfig = CodexChatGPTAuthConfig(),
    refreshSkew: TimeInterval = 300,
    refreshHandler: RefreshHandler? = nil,
    urlSession: URLSession = .shared
  ) async throws -> ChatGPTAuthProvider {
    let store = CodexAuthStore(codexHome: config.codexHome)
    guard let session = try await store.loadSession() else {
      throw CodexCoreError.authError(
        "No Codex auth cache found at \(config.codexHome.appendingPathComponent("auth.json").path)")
    }
    return ChatGPTAuthProvider(
      session: session, codexStore: store, config: config, refreshSkew: refreshSkew,
      refreshHandler: refreshHandler, urlSession: urlSession)
  }

  public static func fromCodexAuthStore(
    _ store: any CodexAuthCacheStore,
    config: CodexChatGPTAuthConfig = CodexChatGPTAuthConfig(),
    refreshSkew: TimeInterval = 300,
    refreshHandler: RefreshHandler? = nil,
    urlSession: URLSession = .shared
  ) async throws -> ChatGPTAuthProvider {
    guard let session = try await store.loadSession() else {
      throw CodexCoreError.authError("No Codex auth cache found")
    }
    return ChatGPTAuthProvider(
      session: session, codexStore: store, config: config, refreshSkew: refreshSkew,
      refreshHandler: refreshHandler, urlSession: urlSession)
  }

  public static func accessToken(
    _ token: String, accountID: String? = nil, workspaceID: String? = nil
  ) -> ChatGPTAuthProvider {
    ChatGPTAuthProvider(
      session: AuthSession(
        mode: .chatGPT, accessToken: token, accountID: accountID, workspaceID: workspaceID))
  }

  public func currentSession() -> AuthSession { session }

  public func updateSession(_ newSession: AuthSession) async throws {
    invalidated = true
    let previous = refreshTask
    generation = UUID()
    let currentGeneration = generation
    refreshTask = nil
    previous?.cancel()
    _ = await previous?.result
    guard generation == currentGeneration else { throw CancellationError() }
    invalidated = false
    session = newSession
    for store in sessionStores {
      try await store.saveSession(newSession)
    }
  }

  /// Revokes this provider immediately, waits for pending writes, then removes
  /// its saved credentials. A late refresh cannot sign the account back in.
  public func invalidate(clearStores: Bool = true) async throws {
    invalidated = true
    generation = UUID()
    let currentGeneration = generation
    session = AuthSession(mode: .chatGPT)
    let previous = refreshTask
    refreshTask = nil
    previous?.cancel()
    _ = await previous?.result
    guard generation == currentGeneration else { return }
    if clearStores {
      for store in sessionStores { try await store.clear() }
    }
  }

  public func authorizationHeaders() async throws -> [String: String] {
    try Task.checkCancellation()
    guard !invalidated else { throw CodexCoreError.authError("ChatGPT session was signed out") }
    if needsRefresh() {
      try await refreshNow()
    }
    try Task.checkCancellation()
    guard !invalidated, let token = session.accessToken, !token.isEmpty else {
      throw CodexCoreError.authError("Missing ChatGPT access token")
    }
    var headers = ["Authorization": "Bearer \(token)"]
    if let accountID = session.accountID, !accountID.isEmpty {
      headers["ChatGPT-Account-Id"] = accountID
    }
    return headers
  }

  public func refreshNow() async throws {
    guard !invalidated else { throw CodexCoreError.authError("ChatGPT session was signed out") }
    if let refreshTask {
      try await refreshTask.value
      return
    }
    let currentGeneration = generation
    let task = Task { try await self.performRefresh(generation: currentGeneration) }
    refreshTask = task
    defer { if generation == currentGeneration { refreshTask = nil } }
    try await task.value
  }

  private func performRefresh(generation expectedGeneration: UUID) async throws {
    let refreshed: AuthSession
    if let refreshHandler {
      refreshed = try await refreshHandler(session)
    } else {
      refreshed = try await httpClient.refresh(session: session, persist: false)
    }
    try Task.checkCancellation()
    guard !invalidated, generation == expectedGeneration else { throw CancellationError() }
    session = refreshed
    for store in sessionStores {
      try Task.checkCancellation()
      guard !invalidated, generation == expectedGeneration else { throw CancellationError() }
      try await store.saveSession(refreshed)
    }
  }

  private func needsRefresh() -> Bool {
    if let expiresAt = session.expiresAt, expiresAt.timeIntervalSinceNow < refreshSkew {
      return true
    }
    guard let lastRefreshString = session.metadata["last_refresh"]?.stringValue,
      let lastRefresh = CodexDate.parse(lastRefreshString)
    else { return false }
    return Date().timeIntervalSince(lastRefresh) > config.staleRefreshInterval
  }
}

public final class CodexChatGPTAuthClient: Sendable {
  public let config: CodexChatGPTAuthConfig
  public let store: any CodexAuthCacheStore
  private let session: URLSession

  public init(
    config: CodexChatGPTAuthConfig = CodexChatGPTAuthConfig(),
    store: (any CodexAuthCacheStore)? = nil, session: URLSession = .shared
  ) {
    self.config = config
    self.store = store ?? CodexAuthStore(codexHome: config.codexHome)
    self.session = session
  }

  public func makeBrowserLoginSession() -> CodexBrowserLoginSession {
    let pkce = PKCECodes.generate()
    let state = Base64URL.encode(RandomBytes.generate(count: 32))
    let url = buildAuthorizeURL(pkce: pkce, state: state, redirectURI: config.redirectURI)
    return CodexBrowserLoginSession(
      state: state, pkce: pkce, redirectURI: config.redirectURI, authorizeURL: url)
  }

  public func finishBrowserLogin(_ login: CodexBrowserLoginSession, callbackURL: URL, persist: Bool = true) async throws
    -> AuthSession
  {
    guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
      throw CodexCoreError.authError("Invalid callback URL")
    }
    let params = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      })
    guard params["state"] == login.state else {
      throw CodexCoreError.authError("OAuth callback state mismatch")
    }
    guard let code = params["code"], !code.isEmpty else {
      throw CodexCoreError.authError(
        params["error"] ?? "OAuth callback did not contain an authorization code")
    }
    let token = try await exchangeCodeForTokens(
      code: code, pkce: login.pkce, redirectURI: login.redirectURI)
    try Task.checkCancellation()
    let authSession = try await self.persist(tokenResponse: token, rawIDToken: token.idToken, writeToStore: persist)
    return authSession
  }

  public func requestDeviceCode() async throws -> CodexDeviceCode {
    let base = config.trimmedIssuer
    let url = URL(string: "\(base)/api/accounts/deviceauth/usercode")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder.codexCompact.encode(
      UserCodeRequest(clientID: config.clientID))
    let (data, response) = try await session.data(for: request)
    try Self.validateHTTP(response, data: data)
    let result = try JSONDecoder.codex.decode(UserCodeResponse.self, from: data)
    return CodexDeviceCode(
      verificationURL: URL(string: "\(base)/codex/device")!,
      userCode: result.userCode,
      deviceAuthID: result.deviceAuthID,
      interval: result.interval ?? 5
    )
  }

  public func completeDeviceCodeLogin(
    _ deviceCode: CodexDeviceCode, timeout: TimeInterval = 15 * 60
  ) async throws -> AuthSession {
    guard timeout.isFinite, timeout >= 0 else {
      throw CodexCoreError.invalidInput(
        "Device auth timeout must be a finite, non-negative number of seconds")
    }
    let base = config.trimmedIssuer
    let url = URL(string: "\(base)/api/accounts/deviceauth/token")!
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder.codexCompact.encode(
        TokenPollRequest(deviceAuthID: deviceCode.deviceAuthID, userCode: deviceCode.userCode))
      let (data, response) = try await session.data(for: request)
      if let http = response as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 404 {
        let pollSeconds = min(max(deviceCode.interval, 1), 300)
        try await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
        continue
      }
      try Self.validateHTTP(response, data: data)
      let success = try JSONDecoder.codex.decode(DeviceCodeSuccessResponse.self, from: data)
      let pkce = PKCECodes(codeVerifier: success.codeVerifier, codeChallenge: success.codeChallenge)
      let token = try await exchangeCodeForTokens(
        code: success.authorizationCode, pkce: pkce, redirectURI: config.deviceRedirectURI)
      return try await persist(tokenResponse: token, rawIDToken: token.idToken)
    }
    throw CodexCoreError.timeout("Device auth timed out after \(timeout) seconds")
  }

  public func refresh(session authSession: AuthSession, persist: Bool = true) async throws -> AuthSession {
    guard let refreshToken = authSession.refreshToken, !refreshToken.isEmpty else {
      throw CodexCoreError.authError("Missing ChatGPT refresh token")
    }
    var form = URLComponents()
    form.queryItems = [
      URLQueryItem(name: "grant_type", value: "refresh_token"),
      URLQueryItem(name: "refresh_token", value: refreshToken),
      URLQueryItem(name: "client_id", value: config.clientID),
    ]
    let token = try await postTokenForm(form)
    return try await self.persist(tokenResponse: token, rawIDToken: token.idToken, writeToStore: persist)
  }

  public func exchangeCodeForTokens(code: String, pkce: PKCECodes, redirectURI: URL) async throws
    -> TokenResponse
  {
    var form = URLComponents()
    form.queryItems = [
      URLQueryItem(name: "grant_type", value: "authorization_code"),
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "client_id", value: config.clientID),
      URLQueryItem(name: "code_verifier", value: pkce.codeVerifier),
    ]
    return try await postTokenForm(form)
  }

  private func postTokenForm(_ form: URLComponents) async throws -> TokenResponse {
    let url = URL(string: "\(config.trimmedIssuer)/oauth/token")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = form.query?.data(using: .utf8)
    let (data, response) = try await session.data(for: request)
    try Self.validateHTTP(response, data: data)
    return try JSONDecoder.codex.decode(TokenResponse.self, from: data)
  }

  private func persist(tokenResponse token: TokenResponse, rawIDToken: String?, writeToStore: Bool = true) async throws
    -> AuthSession
  {
    let idClaims = token.idToken.flatMap(JWT.payload) ?? .object([:])
    let accessClaims = JWT.payload(token.accessToken)
    let accountID =
      JWT.extractChatGPTAccountID(idClaims) ?? accessClaims.flatMap(JWT.extractChatGPTAccountID)
    let expiresAt = accessClaims?["exp"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
    let authSession = AuthSession(
      mode: .chatGPT,
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAt: expiresAt,
      accountID: accountID,
      workspaceID: JWT.extractOrganizationID(idClaims),
      metadata: [
        "id_token_claims": idClaims,
        "raw_id_token": rawIDToken.map(JSONValue.string) ?? .null,
        "last_refresh": .string(CodexDate.format(Date())),
      ]
    )
    if writeToStore { try await store.save(
      CodexAuthDotJson(
        authMode: "chatgpt",
        openaiAPIKey: nil,
        tokens: CodexTokenData(
          idToken: idClaims,
          accessToken: token.accessToken,
          refreshToken: token.refreshToken,
          accountID: accountID,
          rawIDToken: rawIDToken
        ),
        lastRefresh: Date()
      )) }
    return authSession
  }

  private func buildAuthorizeURL(pkce: PKCECodes, state: String, redirectURI: URL) -> URL {
    var components = URLComponents(string: "\(config.trimmedIssuer)/oauth/authorize")!
    var items = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: config.clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "scope", value: config.scopes),
      URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "id_token_add_organizations", value: "true"),
      URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "originator", value: config.originator),
    ]
    if let forcedWorkspaceID = config.forcedWorkspaceID {
      items.append(URLQueryItem(name: "allowed_workspace_id", value: forcedWorkspaceID))
    }
    components.queryItems = items
    return components.url!
  }

  private static func validateHTTP(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw CodexCoreError.authError("HTTP \(http.statusCode): \(body)")
    }
  }

  public struct TokenResponse: Codable, Sendable, Equatable {
    public var idToken: String?
    public var accessToken: String
    public var refreshToken: String
    public var expiresIn: Int?
    public var tokenType: String?

    enum CodingKeys: String, CodingKey {
      case idToken = "id_token"
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
      case tokenType = "token_type"
    }
  }

  private struct UserCodeRequest: Codable {
    var clientID: String
    enum CodingKeys: String, CodingKey { case clientID = "client_id" }
  }

  private struct UserCodeResponse: Codable {
    var deviceAuthID: String
    var userCode: String
    var interval: UInt64?
    enum CodingKeys: String, CodingKey {
      case deviceAuthID = "device_auth_id"
      case userCode = "user_code"
      case interval
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      deviceAuthID = try container.decode(String.self, forKey: .deviceAuthID)
      userCode = try container.decodeIfPresent(String.self, forKey: .userCode) ?? ""
      if let intervalString = try? container.decodeIfPresent(String.self, forKey: .interval) {
        interval = UInt64(intervalString)
      } else {
        interval = try container.decodeIfPresent(UInt64.self, forKey: .interval)
      }
    }
  }

  private struct TokenPollRequest: Codable {
    var deviceAuthID: String
    var userCode: String
    enum CodingKeys: String, CodingKey {
      case deviceAuthID = "device_auth_id"
      case userCode = "user_code"
    }
  }

  private struct DeviceCodeSuccessResponse: Codable {
    var authorizationCode: String
    var codeChallenge: String
    var codeVerifier: String
    enum CodingKeys: String, CodingKey {
      case authorizationCode = "authorization_code"
      case codeChallenge = "code_challenge"
      case codeVerifier = "code_verifier"
    }
  }
}

public struct OAuthDeviceCode: Codable, Sendable, Equatable {
  public var deviceCode: String
  public var userCode: String
  public var verificationURI: URL
  public var expiresIn: Int
  public var interval: Int

  public init(
    deviceCode: String, userCode: String, verificationURI: URL, expiresIn: Int, interval: Int = 5
  ) {
    self.deviceCode = deviceCode
    self.userCode = userCode
    self.verificationURI = verificationURI
    self.expiresIn = expiresIn
    self.interval = interval
  }
}

public struct OAuthDeviceFlowConfig: Sendable, Equatable {
  public var deviceAuthorizationEndpoint: URL
  public var tokenEndpoint: URL
  public var clientID: String
  public var scope: String?
  public var extraParameters: [String: String]

  public init(
    deviceAuthorizationEndpoint: URL, tokenEndpoint: URL, clientID: String, scope: String? = nil,
    extraParameters: [String: String] = [:]
  ) {
    self.deviceAuthorizationEndpoint = deviceAuthorizationEndpoint
    self.tokenEndpoint = tokenEndpoint
    self.clientID = clientID
    self.scope = scope
    self.extraParameters = extraParameters
  }
}

public final class OAuthDeviceFlowClient: Sendable {
  private let config: OAuthDeviceFlowConfig
  private let session: URLSession

  public init(config: OAuthDeviceFlowConfig, session: URLSession = .shared) {
    self.config = config
    self.session = session
  }

  public func begin() async throws -> OAuthDeviceCode {
    var components = URLComponents()
    components.queryItems = [URLQueryItem(name: "client_id", value: config.clientID)]
    if let scope = config.scope {
      components.queryItems?.append(URLQueryItem(name: "scope", value: scope))
    }
    for (key, value) in config.extraParameters {
      components.queryItems?.append(URLQueryItem(name: key, value: value))
    }
    var request = URLRequest(url: config.deviceAuthorizationEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = components.query?.data(using: .utf8)
    let (data, response) = try await session.data(for: request)
    try Self.validateHTTP(response, data: data)
    let json = try JSONDecoder.codex.decode(DeviceCodeResponse.self, from: data)
    guard let uri = URL(string: json.verificationURI ?? json.verificationURIComplete ?? "") else {
      throw CodexCoreError.authError("OAuth device response did not include a verification URI")
    }
    return OAuthDeviceCode(
      deviceCode: json.deviceCode,
      userCode: json.userCode,
      verificationURI: uri,
      expiresIn: json.expiresIn,
      interval: json.interval ?? 5
    )
  }

  public func poll(deviceCode: OAuthDeviceCode) async throws -> AuthSession {
    let deadline = Date().addingTimeInterval(TimeInterval(deviceCode.expiresIn))
    while Date() < deadline {
      var components = URLComponents()
      components.queryItems = [
        URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:device_code"),
        URLQueryItem(name: "device_code", value: deviceCode.deviceCode),
        URLQueryItem(name: "client_id", value: config.clientID),
      ]
      var request = URLRequest(url: config.tokenEndpoint)
      request.httpMethod = "POST"
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = components.query?.data(using: .utf8)
      let (data, response) = try await session.data(for: request)
      if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
        if let value = try? JSONDecoder.codex.decode(OAuthErrorResponse.self, from: data),
          value.error == "authorization_pending"
        {
          let pollSeconds = UInt64(min(max(deviceCode.interval, 1), 300))
          try await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
          continue
        }
        try Self.validateHTTP(response, data: data)
      }
      let token = try JSONDecoder.codex.decode(TokenResponse.self, from: data)
      return AuthSession(
        mode: .bearer,
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
        expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
      )
    }
    throw CodexCoreError.timeout("OAuth device code expired")
  }

  private static func validateHTTP(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw CodexCoreError.authError("HTTP \(http.statusCode): \(body)")
    }
  }

  private struct DeviceCodeResponse: Codable {
    var deviceCode: String
    var userCode: String
    var verificationURI: String?
    var verificationURIComplete: String?
    var expiresIn: Int
    var interval: Int?
    enum CodingKeys: String, CodingKey {
      case deviceCode = "device_code"
      case userCode = "user_code"
      case verificationURI = "verification_uri"
      case verificationURIComplete = "verification_uri_complete"
      case expiresIn = "expires_in"
      case interval
    }
  }

  private struct OAuthErrorResponse: Codable { var error: String }

  private struct TokenResponse: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int?
    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
    }
  }
}

public enum JWT {
  public static func payload(_ jwt: String) -> JSONValue? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    guard let data = Base64URL.decode(String(parts[1])) else { return nil }
    return try? JSONDecoder.codex.decode(JSONValue.self, from: data)
  }

  public static func extractChatGPTAccountID(_ value: JSONValue) -> String? {
    if let direct = value["chatgpt_account_id"]?.stringValue { return direct }
    if let nested = value["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue {
      return nested
    }
    if let firstOrg = value["organizations"]?.arrayValue?.first?["id"]?.stringValue {
      return firstOrg
    }
    return nil
  }

  public static func extractOrganizationID(_ value: JSONValue) -> String? {
    if let direct = value["organization_id"]?.stringValue { return direct }
    if let nested = value["https://api.openai.com/auth"]?["organization_id"]?.stringValue {
      return nested
    }
    if let firstOrg = value["organizations"]?.arrayValue?.first?["id"]?.stringValue {
      return firstOrg
    }
    return nil
  }
}

public enum Base64URL {
  public static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func decode(_ string: String) -> Data? {
    var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    base64 += String(repeating: "=", count: padding)
    return Data(base64Encoded: base64)
  }
}

public enum RandomBytes {
  public static func generate(count: Int) -> Data {
    if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom")) {
      defer { try? handle.close() }
      let data = handle.readData(ofLength: count)
      if data.count == count { return data }
    }
    return Data((0..<count).map { _ in UInt8.random(in: 0...255) })
  }
}

public enum CodexDate {
  public static func parse(_ string: String) -> Date? {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: string) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    if let d = f2.date(from: string) { return d }
    return nil
  }

  public static func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

public enum SHA256 {
  private static let k: [UInt32] = [
    0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4,
    0xab1c_5ed5,
    0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7,
    0xc19b_f174,
    0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc,
    0x76f9_88da,
    0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351,
    0x1429_2967,
    0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e,
    0x9272_2c85,
    0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585,
    0x106a_a070,
    0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f,
    0x682e_6ff3,
    0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7,
    0xc671_78f2,
  ]

  public static func hash(_ data: Data) -> Data {
    var message = [UInt8](data)
    let bitLength = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
      message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
    }

    var h0: UInt32 = 0x6a09_e667
    var h1: UInt32 = 0xbb67_ae85
    var h2: UInt32 = 0x3c6e_f372
    var h3: UInt32 = 0xa54f_f53a
    var h4: UInt32 = 0x510e_527f
    var h5: UInt32 = 0x9b05_688c
    var h6: UInt32 = 0x1f83_d9ab
    var h7: UInt32 = 0x5be0_cd19

    for chunkStart in stride(from: 0, to: message.count, by: 64) {
      var w = Array(repeating: UInt32(0), count: 64)
      for i in 0..<16 {
        let j = chunkStart + i * 4
        w[i] =
          (UInt32(message[j]) << 24) | (UInt32(message[j + 1]) << 16)
          | (UInt32(message[j + 2]) << 8) | UInt32(message[j + 3])
      }
      for i in 16..<64 {
        let s0 = rotateRight(w[i - 15], by: 7) ^ rotateRight(w[i - 15], by: 18) ^ (w[i - 15] >> 3)
        let s1 = rotateRight(w[i - 2], by: 17) ^ rotateRight(w[i - 2], by: 19) ^ (w[i - 2] >> 10)
        w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
      }

      var a = h0
      var b = h1
      var c = h2
      var d = h3
      var e = h4
      var f = h5
      var g = h6
      var hh = h7
      for i in 0..<64 {
        let bigSigma1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
        let ch = (e & f) ^ ((~e) & g)
        let temp1 = hh &+ bigSigma1 &+ ch &+ k[i] &+ w[i]
        let bigSigma0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
        let maj = (a & b) ^ (a & c) ^ (b & c)
        let temp2 = bigSigma0 &+ maj
        hh = g
        g = f
        f = e
        e = d &+ temp1
        d = c
        c = b
        b = a
        a = temp1 &+ temp2
      }
      h0 = h0 &+ a
      h1 = h1 &+ b
      h2 = h2 &+ c
      h3 = h3 &+ d
      h4 = h4 &+ e
      h5 = h5 &+ f
      h6 = h6 &+ g
      h7 = h7 &+ hh
    }

    var digest = Data()
    for h in [h0, h1, h2, h3, h4, h5, h6, h7] {
      digest.append(UInt8((h >> 24) & 0xff))
      digest.append(UInt8((h >> 16) & 0xff))
      digest.append(UInt8((h >> 8) & 0xff))
      digest.append(UInt8(h & 0xff))
    }
    return digest
  }

  private static func rotateRight(_ value: UInt32, by: UInt32) -> UInt32 {
    (value >> by) | (value << (32 - by))
  }
}
