import Foundation

public enum CodeModeCellState: String, Codable, Sendable, Equatable {
  case running
  case yielded
  case completed
  case terminated
}

public struct CodeModeDiagnostic: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case cellStarted
    case cellYielded
    case cellCompleted
    case cellTerminated
    case outputTruncated
    case cellEvicted
  }

  public var kind: Kind
  public var cellID: String
  public var threadID: String
  public var state: CodeModeCellState
  public var message: String?

  public init(
    kind: Kind, cellID: String, threadID: String, state: CodeModeCellState, message: String? = nil
  ) {
    self.kind = kind
    self.cellID = cellID
    self.threadID = threadID
    self.state = state
    self.message = message
  }
}

public typealias CodeModeDiagnosticsHandler = @Sendable (CodeModeDiagnostic) -> Void

/// A progress message emitted by `notify()` while a code-mode cell continues
/// running. Notifications are independent custom-tool outputs; they are never
/// included in the cell's incremental `text()`/`image()` output.
public struct CodeModeNotification: Sendable, Equatable {
  public var cellID: String
  public var threadID: String
  public var turnID: String
  public var callID: String
  public var text: String

  public init(cellID: String, threadID: String, turnID: String, callID: String, text: String) {
    self.cellID = cellID
    self.threadID = threadID
    self.turnID = turnID
    self.callID = callID
    self.text = text
  }
}

public typealias CodeModeNotificationHandler = @Sendable (CodeModeNotification) -> Void

/// Token accounting used for code-mode output limits. Hosts can inject their
/// model tokenizer; the bundled implementation is a dependency-free UTF-8
/// estimate suitable for conservative defaults.
public protocol CodeModeTokenCounting: Sendable {
  func countTokens(in text: String) -> Int
}

public struct EstimatedCodeModeTokenCounter: CodeModeTokenCounting {
  public init() {}
  public func countTokens(in text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return max(1, (text.utf8.count + 3) / 4)
  }
}

enum CodeModeTokenBudget {
  static func truncate(
    _ text: String,
    maxTokens: Int,
    counter: any CodeModeTokenCounting,
    marker: String
  ) -> (text: String, truncated: Bool) {
    let maximum = max(1, maxTokens)
    guard counter.countTokens(in: text) > maximum else { return (text, false) }
    let indices = Array(text.indices)
    var lower = 0
    var upper = indices.count
    while lower < upper {
      let midpoint = (lower + upper + 1) / 2
      let end = midpoint == indices.count ? text.endIndex : indices[midpoint]
      let candidate = String(text[..<end])
      if counter.countTokens(in: candidate) <= maximum {
        lower = midpoint
      } else {
        upper = midpoint - 1
      }
    }
    let end = lower == indices.count ? text.endIndex : indices[lower]
    return (String(text[..<end]) + marker, true)
  }
}

enum CodeModeNumericLimits {
  static func timerMilliseconds(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    if value <= 0 { return 0 }
    if value >= 300_000 { return 300_000 }
    return Int(value.rounded(.towardZero))
  }
}

enum CodeModeOutputByteLimits {
  static let minimumBytes = 1_024
  static let maximumContentBlockBytes = 64 * 1_024 * 1_024
  static let defaultCellOutputBytes = 32 * 1_024 * 1_024
  static let maximumCellOutputBytes = 256 * 1_024 * 1_024

  static func contentBlockBytes(_ value: Int) -> Int {
    max(minimumBytes, min(value, maximumContentBlockBytes))
  }

  static func cellOutputBytes(_ value: Int) -> Int {
    max(minimumBytes, min(value, maximumCellOutputBytes))
  }

  static func totalAfterAdding(_ additionalBytes: Int, to consumedBytes: Int, limit: Int) -> Int? {
    let limit = cellOutputBytes(limit)
    guard additionalBytes >= 0,
      consumedBytes >= 0,
      consumedBytes <= limit,
      additionalBytes <= limit - consumedBytes
    else {
      return nil
    }
    return consumedBytes + additionalBytes
  }

  static func encodedContentBlockBytes(_ fields: [String: JSONValue]) -> Int? {
    try? JSONEncoder.codexCompact.encode(JSONValue.object(fields)).count
  }
}

public struct CodeModeCompletion: Sendable, Equatable {
  public var returnedValue: JSONValue?
  public var error: String?
  public var storeWrites: [String: JSONValue]
  public var storeDeletes: Set<String>

  public init(
    returnedValue: JSONValue? = nil,
    error: String? = nil,
    storeWrites: [String: JSONValue] = [:],
    storeDeletes: Set<String> = []
  ) {
    self.returnedValue = returnedValue
    self.error = error
    self.storeWrites = storeWrites
    self.storeDeletes = storeDeletes
  }
}

public struct CodeModeCellSnapshot: Sendable, Equatable {
  public var state: CodeModeCellState
  public var content: [ToolContentBlock]
  public var nextCursor: Int
  public var yieldVersion: Int
  public var completion: CodeModeCompletion?

  public init(
    state: CodeModeCellState,
    content: [ToolContentBlock],
    nextCursor: Int,
    yieldVersion: Int,
    completion: CodeModeCompletion? = nil
  ) {
    self.state = state
    self.content = content
    self.nextCursor = nextCursor
    self.yieldVersion = yieldVersion
    self.completion = completion
  }
}

public struct CodeModeExecutionRequest: Sendable {
  public var source: String
  public var definitions: [ToolDefinition]
  public var registry: ToolRegistry
  public var context: ToolExecutionContext
  public var initialStore: [String: JSONValue]
  public var options: CodeModeOptions
  public var maxOutputTokens: Int
  public var tokenCounter: any CodeModeTokenCounting
  var notificationHandler: @Sendable (String) -> Void

  public init(
    source: String,
    definitions: [ToolDefinition],
    registry: ToolRegistry,
    context: ToolExecutionContext,
    initialStore: [String: JSONValue],
    options: CodeModeOptions,
    maxOutputTokens: Int,
    tokenCounter: any CodeModeTokenCounting = EstimatedCodeModeTokenCounter()
  ) {
    self.source = source
    self.definitions = definitions
    self.registry = registry
    self.context = context
    self.initialStore = initialStore
    self.options = options
    self.maxOutputTokens = maxOutputTokens
    self.tokenCounter = tokenCounter
    self.notificationHandler = { _ in }
  }
}

public protocol CodeModeCellSession: Sendable {
  func wait(cursor: Int, yieldVersion: Int, timeoutMilliseconds: Int) async -> CodeModeCellSnapshot
  func completion() async -> CodeModeCompletion
  func terminate()
}

public protocol CodeModeEngine: Sendable {
  func start(request: CodeModeExecutionRequest) -> any CodeModeCellSession
}

public struct JavaScriptCoreCodeModeEngine: CodeModeEngine {
  public init() {}

  public func start(request: CodeModeExecutionRequest) -> any CodeModeCellSession {
    JavaScriptCoreCodeModeCell(request: request)
  }
}

/// Uses the packaged process host when it is available on macOS and the
/// WebKit/Worker host on iOS. Unbundled macOS command-line hosts retain the
/// JavaScriptCore fallback for compatibility with non-GUI environments.
public struct AutomaticCodeModeEngine: CodeModeEngine {
  #if os(iOS)
    private let webKitEngine: WebKitCodeModeEngine

    public init() {
      self.webKitEngine = WebKitCodeModeEngine()
    }
  #else
    public init() {}
  #endif

  public func start(request: CodeModeExecutionRequest) -> any CodeModeCellSession {
    #if os(iOS)
      return webKitEngine.start(request: request)
    #elseif os(macOS)
      let processEngine = ProcessCodeModeEngine()
      if processEngine.isAvailable { return processEngine.start(request: request) }
      return JavaScriptCoreCodeModeEngine().start(request: request)
    #else
      return JavaScriptCoreCodeModeEngine().start(request: request)
    #endif
  }
}

public struct CodeModeToolBinding: Sendable, Equatable {
  public var publicName: String
  public var toolName: String
  public var namespace: String?
  public var nestedPath: [String]
  public var definition: ToolDefinition

  public init(
    publicName: String,
    toolName: String,
    namespace: String?,
    nestedPath: [String],
    definition: ToolDefinition
  ) {
    self.publicName = publicName
    self.toolName = toolName
    self.namespace = namespace
    self.nestedPath = nestedPath
    self.definition = definition
  }
}

struct CodeModeHostBinding: Codable, Sendable, Equatable {
  var publicName: String
  var description: String
  var parameters: JSONValue
  var outputSchema: JSONValue?
  var deferred: Bool
  var path: [String]

  init(_ binding: CodeModeToolBinding) {
    publicName = binding.publicName
    description = binding.definition.description
    parameters = binding.definition.parameters
    outputSchema = binding.definition.outputSchema
    deferred = binding.definition.exposure == .deferred
    path = binding.nestedPath
  }
}

enum CodeModeToolResultEncoder {
  static func value(
    _ result: ToolResult,
    maxOutputTokens: Int,
    tokenCounter: any CodeModeTokenCounting
  ) -> JSONValue {
    if let codeModeResult = result.codeModeResult {
      return bounded(codeModeResult, maxOutputTokens: maxOutputTokens, tokenCounter: tokenCounter)
    }
    if let structuredContent = result.structuredContent {
      return bounded(
        structuredContent, maxOutputTokens: maxOutputTokens, tokenCounter: tokenCounter)
    }
    if let blocks = result.contentBlocks {
      return bounded(
        .object([
          "content": .array(blocks.map { .object($0.fields) }),
          "structuredContent": .null,
          "isError": .bool(result.isError),
          "metadata": .object(result.metadata),
        ]), maxOutputTokens: maxOutputTokens, tokenCounter: tokenCounter)
    }
    return .string(
      CodeModeTokenBudget.truncate(
        result.content,
        maxTokens: maxOutputTokens,
        counter: tokenCounter,
        marker: "\n[tool output truncated by code-mode nested limit]"
      ).text)
  }

  private static func bounded(
    _ value: JSONValue,
    maxOutputTokens: Int,
    tokenCounter: any CodeModeTokenCounting
  ) -> JSONValue {
    guard let data = try? JSONEncoder.codexCompact.encode(value),
      let encoded = String(data: data, encoding: .utf8)
    else { return value }
    let limited = CodeModeTokenBudget.truncate(
      encoded,
      maxTokens: maxOutputTokens,
      counter: tokenCounter,
      marker: "\n[tool output truncated by code-mode nested limit]"
    )
    return limited.truncated ? .string(limited.text) : value
  }
}

public enum CodeModeToolCatalog {
  public static func namespace(for definition: ToolDefinition) -> String? {
    if let namespace = definition.namespace, !namespace.isEmpty { return namespace }
    let pieces = definition.name.split(separator: "__", omittingEmptySubsequences: true).map(
      String.init)
    if definition.name.hasPrefix("mcp__"), pieces.count >= 3 { return "mcp__\(pieces[1])" }
    return pieces.count >= 2 ? pieces[0] : nil
  }

  public static func normalizedIdentifier(_ raw: String) -> String {
    var result = raw.unicodeScalars.map { scalar -> Character in
      let allowed = CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
      return allowed ? Character(String(scalar)) : "_"
    }
    if result.isEmpty { result = ["_"] }
    if let first = result.first, first.isNumber { result.insert("_", at: 0) }
    return String(result)
  }

  public static func bindings(
    definitions: [ToolDefinition],
    options: CodeModeOptions
  ) -> [CodeModeToolBinding] {
    let excluded = Set(options.excludedToolNamespaces)
    let directOnly = Set(options.directOnlyToolNamespaces)
    let eligible = definitions.filter { definition in
      guard definition.name != CodeModeRuntime.execToolName,
        definition.name != CodeModeRuntime.waitToolName
      else { return false }
      let exposure = definition.exposure ?? .direct
      guard exposure == .direct || exposure == .deferred else { return false }
      guard let namespace = namespace(for: definition) else { return true }
      return !excluded.contains(namespace) && !directOnly.contains(namespace)
    }
    var occurrences: [String: Int] = [:]
    return eligible.sorted { $0.name < $1.name }.map { definition in
      let base = normalizedIdentifier(definition.name)
      let occurrence = occurrences[base, default: 0]
      occurrences[base] = occurrence + 1
      let publicName = occurrence == 0 ? base : "\(base)_\(occurrence + 1)"
      let namespace = namespace(for: definition)
      let nestedPath: [String]
      if definition.name.hasPrefix("mcp__") {
        let pieces = definition.name.split(separator: "__", omittingEmptySubsequences: true)
          .dropFirst()
        nestedPath = pieces.map { normalizedIdentifier(String($0)) }
      } else if let namespace {
        nestedPath = [normalizedIdentifier(namespace), normalizedIdentifier(definition.name)]
      } else {
        nestedPath = [publicName]
      }
      return CodeModeToolBinding(
        publicName: publicName,
        toolName: definition.name,
        namespace: namespace,
        nestedPath: nestedPath,
        definition: definition
      )
    }
  }

  public static func directModelDefinitions(
    definitions: [ToolDefinition],
    options: CodeModeOptions
  ) -> [ToolDefinition] {
    let directOnly = Set(options.directOnlyToolNamespaces)
    return definitions.filter { definition in
      guard definition.name != CodeModeRuntime.execToolName,
        definition.name != CodeModeRuntime.waitToolName
      else { return false }
      guard definition.exposure != .hidden else { return false }
      if definition.exposure == .directModelOnly { return true }
      guard let namespace = namespace(for: definition) else { return false }
      return directOnly.contains(namespace)
    }
  }
}

extension ToolContentBlock {
  public var textValue: String? { fields["text"]?.stringValue }
}
