import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
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

public actor FileAuthStore {
    public let fileURL: URL

    public init(fileURL: URL = CodexDefaultLocations.coreDirectory.appendingPathComponent("auth.json")) {
        self.fileURL = fileURL
    }

    public func load() throws -> AuthSession? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.codex.decode(AuthSession.self, from: data)
    }

    public func save(_ session: AuthSession) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.codexPretty.encode(session)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func clear() throws {
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
        case openaiAPIKey = "openai_api_key"
        case tokens
        case lastRefresh = "last_refresh"
        case agentIdentity = "agent_identity"
    }

    public init(authMode: String? = nil, openaiAPIKey: String? = nil, tokens: CodexTokenData? = nil, lastRefresh: Date? = nil, agentIdentity: JSONValue? = nil) {
        self.authMode = authMode
        self.openaiAPIKey = openaiAPIKey
        self.tokens = tokens
        self.lastRefresh = lastRefresh
        self.agentIdentity = agentIdentity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authMode = try container.decodeIfPresent(String.self, forKey: .authMode)
        openaiAPIKey = try container.decodeIfPresent(String.self, forKey: .openaiAPIKey)
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
        if authMode == "chatgpt" { mode = .chatGPT }
        else if authMode == "apikey" || authMode == "apiKey" { mode = .apiKey }
        else if tokens?.accessToken != nil { mode = .chatGPT }
        else if openaiAPIKey != nil { mode = .apiKey }
        else { return nil }

        if mode == .apiKey {
            return AuthSession(mode: .apiKey, apiKey: openaiAPIKey)
        }

        guard let tokens else { return nil }
        var metadata: [String: JSONValue] = [:]
        if let idToken = tokens.idToken { metadata["id_token_claims"] = idToken }
        if let rawIDToken = tokens.rawIDToken { metadata["raw_id_token"] = .string(rawIDToken) }
        if let lastRefresh { metadata["last_refresh"] = .string(CodexDate.format(lastRefresh)) }
        if let openaiAPIKey { metadata["openai_api_key"] = .string(openaiAPIKey) }
        let expiry = tokens.accessToken.flatMap { JWT.payload($0)?["exp"]?.doubleValue }.map { Date(timeIntervalSince1970: $0) }
        let accountID = tokens.accountID ?? tokens.idToken.flatMap(JWT.extractChatGPTAccountID) ?? tokens.accessToken.flatMap { JWT.payload($0).flatMap(JWT.extractChatGPTAccountID) }
        return AuthSession(
            mode: .chatGPT,
            apiKey: openaiAPIKey,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: expiry,
            accountID: accountID,
            workspaceID: tokens.idToken.flatMap(JWT.extractOrganizationID),
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

    public init(idToken: JSONValue? = nil, accessToken: String? = nil, refreshToken: String? = nil, accountID: String? = nil, rawIDToken: String? = nil) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.rawIDToken = rawIDToken
    }
}

public actor CodexAuthStore {
    public let codexHome: URL
    public let authFileURL: URL

    public init(codexHome: URL = CodexAuthStore.defaultCodexHome()) {
        self.codexHome = codexHome
        self.authFileURL = codexHome.appendingPathComponent("auth.json")
    }

    public static func defaultCodexHome() -> URL {
        CodexDefaultLocations.codexHome
    }

    public func load() throws -> CodexAuthDotJson? {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else { return nil }
        let data = try Data(contentsOf: authFileURL)
        return try JSONDecoder.codex.decode(CodexAuthDotJson.self, from: data)
    }

    public func loadSession() throws -> AuthSession? {
        try load()?.asAuthSession()
    }

    public func save(_ auth: CodexAuthDotJson) throws {
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let data = try JSONEncoder.codexPretty.encode(auth)
        try data.write(to: authFileURL, options: [.atomic])
    }

    public func saveSession(_ session: AuthSession) throws {
        guard session.mode == .chatGPT else {
            try save(CodexAuthDotJson(authMode: session.mode == .apiKey ? "apikey" : session.mode.rawValue, openaiAPIKey: session.apiKey, lastRefresh: Date()))
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
        try save(auth)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: authFileURL.path) {
            try FileManager.default.removeItem(at: authFileURL)
        }
    }
}

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
        scopes: String = "openid profile email offline_access api.connectors.read api.connectors.invoke",
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

    public var trimmedIssuer: String { issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
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
    private let legacyStore: FileAuthStore?
    private let codexStore: CodexAuthStore?
    private let refreshHandler: RefreshHandler?
    private let refreshSkew: TimeInterval
    private let config: CodexChatGPTAuthConfig
    private let httpClient: CodexChatGPTAuthClient

    public init(
        session: AuthSession,
        store: FileAuthStore? = nil,
        codexStore: CodexAuthStore? = nil,
        config: CodexChatGPTAuthConfig = CodexChatGPTAuthConfig(),
        refreshSkew: TimeInterval = 300,
        refreshHandler: RefreshHandler? = nil,
        urlSession: URLSession = .shared
    ) {
        self.session = session
        self.legacyStore = store
        self.codexStore = codexStore
        self.config = config
        self.refreshHandler = refreshHandler
        self.refreshSkew = refreshSkew
        self.httpClient = CodexChatGPTAuthClient(config: config, store: codexStore ?? CodexAuthStore(codexHome: config.codexHome), session: urlSession)
    }

    public static func fromCodexAuthFile(
        config: CodexChatGPTAuthConfig = CodexChatGPTAuthConfig(),
        refreshSkew: TimeInterval = 300,
        refreshHandler: RefreshHandler? = nil,
        urlSession: URLSession = .shared
    ) async throws -> ChatGPTAuthProvider {
        let store = CodexAuthStore(codexHome: config.codexHome)
        guard let session = try await store.loadSession() else {
            throw CodexCoreError.authError("No Codex auth cache found at \(config.codexHome.appendingPathComponent("auth.json").path)")
        }
        return ChatGPTAuthProvider(session: session, codexStore: store, config: config, refreshSkew: refreshSkew, refreshHandler: refreshHandler, urlSession: urlSession)
    }

    public static func accessToken(_ token: String, accountID: String? = nil, workspaceID: String? = nil) -> ChatGPTAuthProvider {
        ChatGPTAuthProvider(session: AuthSession(mode: .chatGPT, accessToken: token, accountID: accountID, workspaceID: workspaceID))
    }

    public func currentSession() -> AuthSession { session }

    public func updateSession(_ newSession: AuthSession) async throws {
        session = newSession
        try await legacyStore?.save(newSession)
        try await codexStore?.saveSession(newSession)
    }

    public func authorizationHeaders() async throws -> [String: String] {
        if needsRefresh() {
            try await refreshNow()
        }
        guard let token = session.accessToken, !token.isEmpty else {
            throw CodexCoreError.authError("Missing ChatGPT access token")
        }
        var headers = ["Authorization": "Bearer \(token)"]
        if let accountID = session.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return headers
    }

    public func refreshNow() async throws {
        if let refreshHandler {
            session = try await refreshHandler(session)
        } else {
            session = try await httpClient.refresh(session: session)
        }
        try await legacyStore?.save(session)
        try await codexStore?.saveSession(session)
    }

    private func needsRefresh() -> Bool {
        if let expiresAt = session.expiresAt, expiresAt.timeIntervalSinceNow < refreshSkew { return true }
        guard let lastRefreshString = session.metadata["last_refresh"]?.stringValue,
              let lastRefresh = CodexDate.parse(lastRefreshString) else { return false }
        return Date().timeIntervalSince(lastRefresh) > config.staleRefreshInterval
    }
}

public final class CodexChatGPTAuthClient: Sendable {
    public let config: CodexChatGPTAuthConfig
    public let store: CodexAuthStore
    private let session: URLSession

    public init(config: CodexChatGPTAuthConfig = CodexChatGPTAuthConfig(), store: CodexAuthStore? = nil, session: URLSession = .shared) {
        self.config = config
        self.store = store ?? CodexAuthStore(codexHome: config.codexHome)
        self.session = session
    }

    public func makeBrowserLoginSession() -> CodexBrowserLoginSession {
        let pkce = PKCECodes.generate()
        let state = Base64URL.encode(RandomBytes.generate(count: 32))
        let url = buildAuthorizeURL(pkce: pkce, state: state, redirectURI: config.redirectURI)
        return CodexBrowserLoginSession(state: state, pkce: pkce, redirectURI: config.redirectURI, authorizeURL: url)
    }

    public func finishBrowserLogin(_ login: CodexBrowserLoginSession, callbackURL: URL) async throws -> AuthSession {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw CodexCoreError.authError("Invalid callback URL")
        }
        let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        guard params["state"] == login.state else { throw CodexCoreError.authError("OAuth callback state mismatch") }
        guard let code = params["code"], !code.isEmpty else {
            throw CodexCoreError.authError(params["error"] ?? "OAuth callback did not contain an authorization code")
        }
        let token = try await exchangeCodeForTokens(code: code, pkce: login.pkce, redirectURI: login.redirectURI)
        let authSession = try await persist(tokenResponse: token, rawIDToken: token.idToken)
        return authSession
    }

    public func requestDeviceCode() async throws -> CodexDeviceCode {
        let base = config.trimmedIssuer
        let url = URL(string: "\(base)/api/accounts/deviceauth/usercode")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.codexCompact.encode(UserCodeRequest(clientID: config.clientID))
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

    public func completeDeviceCodeLogin(_ deviceCode: CodexDeviceCode, timeout: TimeInterval = 15 * 60) async throws -> AuthSession {
        let base = config.trimmedIssuer
        let url = URL(string: "\(base)/api/accounts/deviceauth/token")!
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.codexCompact.encode(TokenPollRequest(deviceAuthID: deviceCode.deviceAuthID, userCode: deviceCode.userCode))
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 404 {
                try await Task.sleep(nanoseconds: deviceCode.interval * 1_000_000_000)
                continue
            }
            try Self.validateHTTP(response, data: data)
            let success = try JSONDecoder.codex.decode(DeviceCodeSuccessResponse.self, from: data)
            let pkce = PKCECodes(codeVerifier: success.codeVerifier, codeChallenge: success.codeChallenge)
            let token = try await exchangeCodeForTokens(code: success.authorizationCode, pkce: pkce, redirectURI: config.deviceRedirectURI)
            return try await persist(tokenResponse: token, rawIDToken: token.idToken)
        }
        throw CodexCoreError.timeout("Device auth timed out after \(Int(timeout)) seconds")
    }

    public func refresh(session authSession: AuthSession) async throws -> AuthSession {
        guard let refreshToken = authSession.refreshToken, !refreshToken.isEmpty else {
            throw CodexCoreError.authError("Missing ChatGPT refresh token")
        }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: config.clientID)
        ]
        let token = try await postTokenForm(form)
        return try await persist(tokenResponse: token, rawIDToken: token.idToken)
    }

    public func exchangeCodeForTokens(code: String, pkce: PKCECodes, redirectURI: URL) async throws -> TokenResponse {
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "code_verifier", value: pkce.codeVerifier)
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

    private func persist(tokenResponse token: TokenResponse, rawIDToken: String?) async throws -> AuthSession {
        let idClaims = token.idToken.flatMap(JWT.payload) ?? .object([:])
        let accessClaims = JWT.payload(token.accessToken)
        let accountID = JWT.extractChatGPTAccountID(idClaims) ?? accessClaims.flatMap(JWT.extractChatGPTAccountID)
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
                "last_refresh": .string(CodexDate.format(Date()))
            ]
        )
        try await store.save(CodexAuthDotJson(
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
        ))
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
            URLQueryItem(name: "originator", value: config.originator)
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

    public init(deviceCode: String, userCode: String, verificationURI: URL, expiresIn: Int, interval: Int = 5) {
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

    public init(deviceAuthorizationEndpoint: URL, tokenEndpoint: URL, clientID: String, scope: String? = nil, extraParameters: [String: String] = [:]) {
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
        if let scope = config.scope { components.queryItems?.append(URLQueryItem(name: "scope", value: scope)) }
        for (key, value) in config.extraParameters { components.queryItems?.append(URLQueryItem(name: key, value: value)) }
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
                URLQueryItem(name: "client_id", value: config.clientID)
            ]
            var request = URLRequest(url: config.tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = components.query?.data(using: .utf8)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                if let value = try? JSONDecoder.codex.decode(OAuthErrorResponse.self, from: data), value.error == "authorization_pending" {
                    try await Task.sleep(nanoseconds: UInt64(max(deviceCode.interval, 1)) * 1_000_000_000)
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
        if let nested = value["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue { return nested }
        if let firstOrg = value["organizations"]?.arrayValue?.first?["id"]?.stringValue { return firstOrg }
        return nil
    }

    public static func extractOrganizationID(_ value: JSONValue) -> String? {
        if let direct = value["organization_id"]?.stringValue { return direct }
        if let nested = value["https://api.openai.com/auth"]?["organization_id"]?.stringValue { return nested }
        if let firstOrg = value["organizations"]?.arrayValue?.first?["id"]?.stringValue { return firstOrg }
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
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
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
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]

    public static func hash(_ data: Data) -> Data {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var w = Array(repeating: UInt32(0), count: 64)
            for i in 0..<16 {
                let j = chunkStart + i * 4
                w[i] = (UInt32(message[j]) << 24) | (UInt32(message[j+1]) << 16) | (UInt32(message[j+2]) << 8) | UInt32(message[j+3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(w[i-15], by: 7) ^ rotateRight(w[i-15], by: 18) ^ (w[i-15] >> 3)
                let s1 = rotateRight(w[i-2], by: 17) ^ rotateRight(w[i-2], by: 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, hh = h7
            for i in 0..<64 {
                let S1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = S0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d
            h4 = h4 &+ e; h5 = h5 &+ f; h6 = h6 &+ g; h7 = h7 &+ hh
        }

        var digest = Data()
        for h in [h0,h1,h2,h3,h4,h5,h6,h7] {
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
