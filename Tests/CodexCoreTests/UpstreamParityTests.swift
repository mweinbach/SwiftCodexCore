import Foundation
import XCTest

@testable import CodexCore

final class UpstreamParityTests: XCTestCase {
  func testParityManifestUsesImmutableOpenAICodexPin() throws {
    let manifest = try loadManifest()

    XCTAssertEqual(manifest.schemaVersion, 1)
    XCTAssertEqual(manifest.upstream.repository, "https://github.com/openai/codex.git")
    XCTAssertEqual(manifest.upstream.branch, "main")
    XCTAssertNotNil(
      manifest.upstream.commit.range(
        of: #"^[0-9a-f]{40}$"#,
        options: .regularExpression
      )
    )
  }

  func testPinnedToolModeWireSchemaMatchesCodexCore() throws {
    let expected = try loadManifest().contracts.toolMode.wireValues

    XCTAssertEqual(AgentToolMode.allCases.map(\.rawValue), expected)
  }

  func testPinnedGPT56CatalogIsRepresentableByDynamicModelMetadata() throws {
    let expectedModels = try loadManifest().contracts.modelCatalog.models
    let swiftModelIDs = Set(OpenAIModel.allCases.map(\.rawValue))

    XCTAssertTrue(Set(expectedModels.map(\.slug)).isSubset(of: swiftModelIDs))

    for expected in expectedModels {
      let info = expected.modelInfo
      XCTAssertEqual(info.slug, expected.slug)
      XCTAssertEqual(info.displayName, expected.string("display_name"))
      XCTAssertEqual(info.contextWindow, expected.integer("context_window"))
      XCTAssertEqual(info.maximumContextWindow, expected.integer("max_context_window"))
      XCTAssertEqual(info.toolMode, expected.string("tool_mode"))
      XCTAssertEqual(
        info.supportsParallelToolCalls, expected.boolean("supports_parallel_tool_calls"))
      XCTAssertEqual(
        info.supportsOriginalImageDetail, expected.boolean("supports_image_detail_original"))
      XCTAssertEqual(info.supportsSearchTool, expected.boolean("supports_search_tool"))
      XCTAssertEqual(info.usesResponsesLite, expected.boolean("use_responses_lite"))
      XCTAssertEqual(info.prefersWebSockets, expected.boolean("prefer_websockets"))
      XCTAssertEqual(info.supportsVerbosity, expected.boolean("support_verbosity"))
      XCTAssertEqual(info.defaultVerbosity?.rawValue, expected.string("default_verbosity"))
      XCTAssertEqual(info.applyPatchToolType, expected.string("apply_patch_tool_type"))
      XCTAssertEqual(info.webSearchToolType, expected.string("web_search_tool_type"))
      XCTAssertEqual(info.shellType, expected.string("shell_type"))
      XCTAssertEqual(info.truncationMode, "tokens")
      XCTAssertEqual(info.truncationLimit, 10_000)
      XCTAssertEqual(info.reasoningSummaryFormat, expected.string("reasoning_summary_format"))
      XCTAssertEqual(info.minimalClientVersion, expected.string("minimal_client_version"))
      XCTAssertEqual(info.inputModalities, expected.strings("input_modalities"))
      XCTAssertEqual(info.visibility, expected.string("visibility"))
      XCTAssertEqual(info.supportedInAPI, expected.boolean("supported_in_api"))
      XCTAssertEqual(info.defaultReasoningEffortName, expected.string("default_reasoning_level"))
      XCTAssertEqual(info.supportedReasoningEffortNames, expected.reasoningEfforts)
      XCTAssertEqual(info.multiAgentVersion, expected.string("multi_agent_version"))
      XCTAssertEqual(
        info["apply_patch_tool_type"]?.stringValue, expected.string("apply_patch_tool_type"))
      XCTAssertEqual(info["shell_type"]?.stringValue, expected.string("shell_type"))

      var configuration = AgentConfiguration(
        reasoningEffort: nil,
        parallelToolCalls: nil,
        toolMode: nil
      )
      configuration.applyModelDefaults(info)
      XCTAssertEqual(configuration.model, expected.slug)
      XCTAssertEqual(
        configuration.reasoningEffort?.rawValue, expected.string("default_reasoning_level"))
      XCTAssertEqual(
        configuration.parallelToolCalls, expected.boolean("supports_parallel_tool_calls"))
      XCTAssertEqual(configuration.toolMode?.rawValue, expected.string("tool_mode"))
      XCTAssertEqual(
        configuration.textOptions?.verbosity?.rawValue, expected.string("default_verbosity"))
      XCTAssertEqual(configuration.useResponsesLite, expected.boolean("use_responses_lite"))
      XCTAssertEqual(
        configuration.skillOptions.includeUsageInstructions,
        expected.boolean("include_skills_usage_instructions")
      )
      XCTAssertEqual(configuration.codeModeOptions?.defaultMaxOutputTokens, 10_000)
      XCTAssertEqual(configuration.codeModeOptions?.allowOriginalImageDetail, true)
    }
  }

  func testBundledFallbackRetainsPinnedOfflineCatalogFacts() throws {
    let expectedModels = try loadManifest().contracts.modelCatalog.models
    let fallbacks = Dictionary(
      uniqueKeysWithValues: OpenAIModelInfo.gpt56FallbackCatalog.map { ($0.slug, $0) }
    )

    XCTAssertEqual(Set(fallbacks.keys), Set(expectedModels.map(\.slug)))
    for expected in expectedModels {
      let fallback = try XCTUnwrap(fallbacks[expected.slug])
      XCTAssertEqual(fallback.displayName, expected.string("display_name"))
      XCTAssertEqual(fallback.contextWindow, expected.integer("context_window"))
      XCTAssertEqual(fallback.maximumContextWindow, expected.integer("max_context_window"))
      XCTAssertEqual(fallback.toolMode, expected.string("tool_mode"))
      XCTAssertEqual(
        fallback.supportsOriginalImageDetail, expected.boolean("supports_image_detail_original"))
      XCTAssertEqual(fallback.supportsSearchTool, expected.boolean("supports_search_tool"))
      XCTAssertEqual(fallback.usesResponsesLite, expected.boolean("use_responses_lite"))
      XCTAssertEqual(fallback.prefersWebSockets, expected.boolean("prefer_websockets"))
      XCTAssertEqual(fallback.defaultVerbosity?.rawValue, expected.string("default_verbosity"))
      XCTAssertEqual(fallback.truncationLimit, 10_000)
      XCTAssertEqual(fallback.inputModalities, expected.strings("input_modalities"))
      XCTAssertEqual(fallback.visibility, expected.string("visibility"))
      XCTAssertEqual(fallback.supportedInAPI, expected.boolean("supported_in_api"))
      XCTAssertEqual(
        fallback.defaultReasoningEffortName, expected.string("default_reasoning_level"))
      XCTAssertEqual(fallback.supportedReasoningEffortNames, expected.reasoningEfforts)
      XCTAssertEqual(fallback.multiAgentVersion, expected.string("multi_agent_version"))
    }
  }

  func testDynamicModelMetadataRejectsUnsafeIntegers() {
    let info = OpenAIModelInfo(fields: [
      "slug": .string("future-model"),
      "priority": .number(.infinity),
      "context_window": .number(1e300),
      "max_context_window": .number(-1),
      "auto_compact_token_limit": .number(2.5),
      "truncation_policy": .object([
        "mode": .string("tokens"),
        "limit": .number(1e300),
      ]),
    ])

    XCTAssertNil(info.priority)
    XCTAssertNil(info.contextWindow)
    XCTAssertNil(info.maximumContextWindow)
    XCTAssertNil(info.automaticCompactionTokenLimit)
    XCTAssertNil(info.truncationLimit)

    var configuration = AgentConfiguration()
    configuration.applyModelDefaults(info)
    XCTAssertEqual(configuration.model, "future-model")
  }

  private func loadManifest() throws -> ParityManifest {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let manifestURL = packageRoot.appendingPathComponent("UpstreamParity/codex.json")
    return try JSONDecoder().decode(
      ParityManifest.self,
      from: Data(contentsOf: manifestURL)
    )
  }
}

private struct ParityManifest: Decodable {
  let schemaVersion: Int
  let upstream: Upstream
  let contracts: Contracts

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case upstream
    case contracts
  }

  struct Upstream: Decodable {
    let repository: String
    let branch: String
    let commit: String
  }

  struct Contracts: Decodable {
    let modelCatalog: ModelCatalog
    let toolMode: ToolMode

    enum CodingKeys: String, CodingKey {
      case modelCatalog = "model_catalog"
      case toolMode = "tool_mode"
    }
  }

  struct ModelCatalog: Decodable {
    let models: [ExpectedModel]
  }

  struct ToolMode: Decodable {
    let wireValues: [String]

    enum CodingKeys: String, CodingKey {
      case wireValues = "wire_values"
    }
  }
}

private struct ExpectedModel: Decodable {
  let slug: String
  let fields: [String: JSONValue]
  let reasoningEfforts: [String]

  enum CodingKeys: String, CodingKey {
    case slug
    case fields
    case reasoningEfforts = "reasoning_efforts"
  }

  var modelInfo: OpenAIModelInfo {
    var modelFields = fields
    modelFields["slug"] = .string(slug)
    modelFields["supported_reasoning_levels"] = .array(
      reasoningEfforts.map { .object(["effort": .string($0)]) }
    )
    return OpenAIModelInfo(fields: modelFields)
  }

  func string(_ field: String) -> String? {
    fields[field]?.stringValue
  }

  func strings(_ field: String) -> [String] {
    fields[field]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  func integer(_ field: String) -> Int? {
    fields[field]?.doubleValue.flatMap { Int(exactly: $0) }
  }

  func boolean(_ field: String) -> Bool? {
    fields[field]?.boolValue
  }
}
