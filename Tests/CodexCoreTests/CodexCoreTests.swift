import XCTest
@testable import CodexCore

final class CodexCoreTests: XCTestCase {
    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object([
            "name": .string("codex"),
            "count": .number(3),
            "enabled": .bool(true),
            "items": .array([.string("a"), .null])
        ])
        let data = try JSONEncoder.codexCompact.encode(value)
        let decoded = try JSONDecoder.codex.decode(JSONValue.self, from: data)
        XCTAssertEqual(value, decoded)
    }

    func testToolRegistryEcho() async throws {
        let registry = ToolRegistry(tools: [EchoTool()])
        let result = try await registry.run(
            name: "echo",
            arguments: .object(["text": .string("hello")]),
            context: ToolExecutionContext(threadID: "t", turnID: "u", approvalPolicy: .never, sandboxPolicy: .readOnly)
        )
        XCTAssertEqual(result.content, "hello")
    }

    func testFileReadCannotEscapeWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreTests-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        let outside = root.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ToolRegistry(tools: [FileReadTool()])
        let context = ToolExecutionContext(
            threadID: "t",
            turnID: "u",
            workspaceURL: workspace,
            approvalPolicy: .never,
            sandboxPolicy: .workspaceWrite
        )
        do {
            _ = try await registry.run(
                name: "read_file",
                arguments: .object(["path": .string("../outside.txt")]),
                context: context
            )
            XCTFail("Expected read outside workspace to fail")
        } catch CodexCoreError.approvalRequired(let message) {
            XCTAssertTrue(message.contains("outside readable roots"))
        }
    }

    func testAgentLoopRunsToolThenFinalAnswer() async throws {
        let provider = ScriptedModelProvider(batches: [
            [
                .toolCallCompleted(ToolCall(callID: "call_echo", name: "echo", arguments: "{\"text\":\"pong\"}")),
                .completed(responseID: "r1", usage: nil)
            ],
            [
                .outputTextDelta("pong"),
                .completed(responseID: "r2", usage: nil)
            ]
        ])
        let registry = ToolRegistry(tools: [EchoTool()])
        let manager = ThreadManager(store: InMemoryThreadStore())
        let agent = CodexAgent(modelProvider: provider, toolRegistry: registry, threadManager: manager)
        let thread = try await agent.createThread()
        let handle = agent.startTurn(threadID: thread.id, input: TurnInput("ping"))
        var sawTool = false
        var sawFinal = false
        for try await event in handle.events {
            if case .toolCompleted(let call, let result) = event {
                sawTool = call.name == "echo" && result.content == "pong"
            }
            if case .itemCompleted(let item) = event, item.kind == .assistantMessage, item.payload["content"]?.stringValue == "pong" {
                sawFinal = true
            }
        }
        XCTAssertTrue(sawTool)
        XCTAssertTrue(sawFinal)
    }

    func testRuntimeClearsActiveTurnWhenStreamingHandleCompletes() async throws {
        let provider = ScriptedModelProvider(batches: [
            [
                .outputTextDelta("done"),
                .completed(responseID: "r1", usage: nil)
            ]
        ])
        let runtime = CodexRuntime(modelProvider: provider, tools: [])
        let thread = try await runtime.createThread()
        let handle = try await runtime.startTurn(threadID: thread.id, input: TurnInput("go"))

        for try await _ in handle.events {}

        let active = await runtime.activeTurn(threadID: thread.id)
        XCTAssertNil(active)
    }

    func testRuntimeRejectsOverlappingTurnsOnSameThread() async throws {
        let provider = DelayedModelProvider(delayNanoseconds: 500_000_000)
        let runtime = CodexRuntime(modelProvider: provider, tools: [])
        let thread = try await runtime.createThread()
        let handle = try await runtime.startTurn(threadID: thread.id, input: TurnInput("first"))

        do {
            _ = try await runtime.startTurn(threadID: thread.id, input: TurnInput("second"))
            XCTFail("Expected overlapping turn to fail")
        } catch CodexCoreError.invalidState(let message) {
            XCTAssertTrue(message.contains("already has active turn"))
        }

        await handle.interrupt()
        for try await _ in handle.events {}
    }

    func testAgentLoopAddsReasoningAndDisablesForegroundStore() async throws {
        let provider = RecordingModelProvider(batches: [
            [
                .outputTextDelta("done"),
                .completed(responseID: "r1", usage: nil)
            ]
        ])
        let config = AgentConfiguration(
            model: "gpt-5.4",
            reasoningEffort: .high,
            reasoningSummary: .auto,
            backgroundAccessEnabled: true
        )
        let runtime = CodexRuntime(configuration: config, modelProvider: provider, tools: [])
        let thread = try await runtime.createThread()
        let handle = try await runtime.startTurn(threadID: thread.id, input: TurnInput("go"))

        for try await _ in handle.events {}

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.reasoning?.effort, "high")
        XCTAssertEqual(request.reasoning?.summary, "auto")
        XCTAssertEqual(request.store, false)
    }

    func testNetworkServerToolsAreFilteredWhenSandboxDisallowsNetwork() async throws {
        let provider = RecordingModelProvider(batches: [
            [.outputTextDelta("done"), .completed(responseID: "r1", usage: nil)]
        ])
        let config = AgentConfiguration(
            sandboxPolicy: .workspaceWrite,
            serverTools: [
                .webSearch(searchContextSize: "medium"),
                .imageGeneration(model: "gpt-image-2"),
                .raw(type: "local_preview")
            ]
        )
        let agent = CodexAgent(configuration: config, modelProvider: provider, toolRegistry: ToolRegistry(), threadManager: ThreadManager(store: InMemoryThreadStore()))
        let thread = try await agent.createThread()
        let handle = agent.startTurn(threadID: thread.id, input: TurnInput("no network tools"))
        for try await _ in handle.events {}

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.tools.map(\.type), ["local_preview"])
    }

    func testToolApprovalRequestsAreEmittedOnEventStream() async throws {
        let provider = ScriptedModelProvider(batches: [
            [
                .toolCallCompleted(ToolCall(callID: "approve", name: "approval_echo", arguments: #"{"text":"approved"}"#)),
                .completed(responseID: "r1", usage: nil)
            ],
            [
                .outputTextDelta("done"),
                .completed(responseID: "r2", usage: nil)
            ]
        ])
        let config = AgentConfiguration(approvalPolicy: .always)
        let agent = CodexAgent(
            configuration: config,
            modelProvider: provider,
            toolRegistry: ToolRegistry(tools: [ApprovalEchoTool()]),
            threadManager: ThreadManager(store: InMemoryThreadStore()),
            approvalHandler: { request in
                ApprovalDecision(approved: request.toolName == "approval_echo")
            }
        )
        let thread = try await agent.createThread()
        let handle = agent.startTurn(threadID: thread.id, input: TurnInput("write a file"))
        var sawApproval = false
        for try await event in handle.events {
            if case .approvalRequested(let request) = event {
                sawApproval = request.toolName == "approval_echo"
            }
        }
        XCTAssertTrue(sawApproval)
    }

    func testToolContinuationUsesPreviousResponseID() async throws {
        let provider = RecordingModelProvider(batches: [
            [
                .toolCallCompleted(ToolCall(callID: "call_echo", name: "echo", arguments: #"{"text":"pong"}"#)),
                .completed(responseID: "r1", usage: nil)
            ],
            [
                .outputTextDelta("pong"),
                .completed(responseID: "r2", usage: nil)
            ]
        ])
        let agent = CodexAgent(modelProvider: provider, toolRegistry: ToolRegistry(tools: [EchoTool()]), threadManager: ThreadManager(store: InMemoryThreadStore()))
        let thread = try await agent.createThread()
        let handle = agent.startTurn(threadID: thread.id, input: TurnInput("ping"))
        for try await _ in handle.events {}

        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertNil(provider.requests[0].previousResponseID)
        XCTAssertEqual(provider.requests[1].previousResponseID, "r1")
        XCTAssertEqual(provider.requests[1].input.count, 1)
        XCTAssertEqual(provider.requests[1].input.first?["type"]?.stringValue, "function_call_output")
    }

    func testThreadForkRollback() async throws {
        let manager = ThreadManager(store: InMemoryThreadStore())
        let thread = try await manager.createThread(title: "root")
        let item1 = ThreadItem(threadID: thread.id, kind: .userMessage, summary: "one")
        let item2 = ThreadItem(threadID: thread.id, kind: .assistantMessage, summary: "two")
        _ = try await manager.appendItems([item1, item2], to: thread.id)
        let fork = try await manager.forkThread(id: thread.id, title: "fork")
        XCTAssertEqual(fork.parentThreadID, thread.id)
        let rolled = try await manager.rollbackThread(id: fork.id, toItemID: item1.id)
        XCTAssertEqual(rolled.items.count, 1)
    }

    func testResponseBuiltInToolDefinitionsEncode() throws {
        let tools: [ResponseToolDefinition] = [
            .webSearch(searchContextSize: "medium", externalWebAccess: true),
            .imageGeneration(model: "gpt-image-2", size: "1024x1024", outputFormat: "png")
        ]
        let data = try JSONEncoder.codexCompact.encode(tools)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"type\":\"web_search\""))
        XCTAssertTrue(json.contains("\"type\":\"image_generation\""))
        XCTAssertTrue(json.contains("\"external_web_access\":true"))
    }

    func testResponsesRequestEncodesBackgroundAndStoreFlags() throws {
        let request = ResponsesRequest(
            model: "gpt-5.4",
            input: [ResponseInputBuilder.userMessage("work on this later")],
            stream: false,
            reasoning: ResponseReasoning(effort: .high, summary: .auto),
            background: true,
            store: true
        )

        let json = try JSONDecoder.codex.decode(JSONValue.self, from: JSONEncoder.codexCompact.encode(request))
        XCTAssertEqual(json["background"]?.boolValue, true)
        XCTAssertEqual(json["store"]?.boolValue, true)
        XCTAssertEqual(json["stream"]?.boolValue, false)
        XCTAssertEqual(json["reasoning"]?["effort"]?.stringValue, "high")
        XCTAssertEqual(json["reasoning"]?["summary"]?.stringValue, "auto")
    }

    func testOpenAIResponsesClientBackgroundLifecycleUsesResponseEndpoints() async throws {
        let endpoint = URL(string: "https://example.test/v1/responses")!
        let requests = Locked<[CapturedHTTPRequest]>([])
        StubURLProtocol.handler = { request in
            requests.withValue { $0.append(CapturedHTTPRequest(request)) }
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? ""

            switch (method, path) {
            case ("POST", "/v1/responses"):
                let body = try JSONDecoder.codex.decode(JSONValue.self, from: request.bodyData())
                XCTAssertEqual(body["background"]?.boolValue, true)
                XCTAssertEqual(body["stream"]?.boolValue, false)
                XCTAssertEqual(body["store"]?.boolValue, true)
                return StubURLProtocol.response(
                    for: request,
                    json: #"{"id":"resp_123","status":"queued","background":true}"#
                )
            case ("GET", "/v1/responses/resp_123"):
                return StubURLProtocol.response(
                    for: request,
                    json: #"{"id":"resp_123","status":"completed","background":true,"output_text":"done","usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}"#
                )
            case ("POST", "/v1/responses/resp_123/cancel"):
                return StubURLProtocol.response(
                    for: request,
                    json: #"{"id":"resp_123","status":"cancelled","background":true}"#
                )
            default:
                XCTFail("Unexpected request: \(method) \(path)")
                return StubURLProtocol.response(for: request, statusCode: 404, json: #"{"error":{"message":"not found"}}"#)
            }
        }
        defer { StubURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenAIResponsesClient(
            auth: StaticAuthProvider(),
            options: OpenAIResponsesClient.Options(endpoint: endpoint),
            session: session
        )
        let request = ResponsesRequest(model: "gpt-5.4", input: [ResponseInputBuilder.userMessage("slow work")])

        let created = try await client.createBackgroundResponse(request)
        XCTAssertEqual(created.id, "resp_123")
        XCTAssertEqual(created.status, "queued")
        XCTAssertFalse(created.isTerminal)

        let retrieved = try await client.retrieveResponse(id: "resp_123")
        XCTAssertEqual(retrieved.outputText, "done")
        XCTAssertEqual(retrieved.usage?.totalTokens, 3)
        XCTAssertTrue(retrieved.isTerminal)

        let cancelled = try await client.cancelResponse(id: "resp_123")
        XCTAssertEqual(cancelled.status, "cancelled")
        XCTAssertTrue(cancelled.isTerminal)

        let captured = requests.value
        XCTAssertEqual(captured.map(\.method), ["POST", "GET", "POST"])
        XCTAssertTrue(captured.allSatisfy { $0.authorization == "Bearer test-token" })
    }

    func testOpenAIResponsesClientExtractsSnapshotModelEvents() throws {
        let snapshot = OpenAIResponseSnapshot(
            id: "resp_123",
            status: "completed",
            background: true,
            raw: .object([
                "id": .string("resp_123"),
                "status": .string("completed"),
                "output": .array([
                    .object([
                        "type": .string("function_call"),
                        "id": .string("item_call"),
                        "call_id": .string("call_1"),
                        "name": .string("shell"),
                        "arguments": .string(#"{"command":"pwd"}"#)
                    ]),
                    .object([
                        "type": .string("message"),
                        "content": .array([
                            .object(["text": .string("done")])
                        ])
                    ])
                ])
            ])
        )

        let events = try OpenAIResponsesClient.modelEvents(from: snapshot)
        XCTAssertTrue(events.contains { event in
            if case .toolCallCompleted(let call) = event {
                return call.callID == "call_1" && call.name == "shell"
            }
            return false
        })
        XCTAssertTrue(events.contains(.messageCompleted("done")))
        XCTAssertTrue(events.contains(.completed(responseID: "resp_123", usage: nil)))
    }

    func testPromptAssemblyLoadsAgentsAndExplicitSkill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreTests-\(UUID().uuidString)")
        let work = root.appendingPathComponent("service")
        let skillDir = root.appendingPathComponent(".agents/skills/report-writer")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "Run swift test before reporting.".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: report-writer
        description: Write concise engineering status reports and summaries.
        ---

        Always include completed work, validation, and risks.
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = AgentConfiguration(
            workspaceURL: work,
            projectInstructionOptions: ProjectInstructionOptions(codexHome: root.appendingPathComponent(".codex"), currentWorkingDirectory: work),
            skillOptions: SkillInjectionOptions(includeUserSkills: false, includeAdminSkills: false)
        )
        let assembly = try PromptAssembler.build(configuration: config, userText: "$report-writer summarize this change")
        XCTAssertTrue(assembly.instructions.contains("$report-writer"))
        XCTAssertEqual(assembly.projectInstructions.count, 1)
        XCTAssertEqual(assembly.activatedSkills.map(\.name), ["report-writer"])
        let prefixText = assembly.inputPrefixItems.map(\.description).joined(separator: "\n")
        XCTAssertTrue(prefixText.contains("Run swift test"))
        XCTAssertTrue(prefixText.contains("Always include completed work"))
    }

    func testEmbeddedSkillsMaterializeAndActivateThroughNormalRegistry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreTests-\(UUID().uuidString)")
        let work = root.appendingPathComponent("workspace")
        let skillsRoot = root.appendingPathComponent("BundledSkills", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let embedded = EmbeddedAgentSkill(
            name: "artifact-writer",
            description: "Create document, presentation, and spreadsheet artifacts.",
            instructions: "Use the host-provided artifact runtime before inventing a renderer.",
            files: [
                EmbeddedSkillFile(relativePath: "scripts/render.mjs", contents: "export const runtime = 'ios';\n")
            ],
            allowImplicitInvocation: false
        )
        var config = AgentConfiguration(
            workspaceURL: work,
            skillOptions: SkillInjectionOptions(
                includeRepoSkills: false,
                includeUserSkills: false,
                includeAdminSkills: false,
                allowImplicitInvocation: true
            )
        )

        let installed = try config.installEmbeddedSkills([embedded], rootURL: skillsRoot)
        XCTAssertEqual(installed.map(\.skill.name), ["artifact-writer"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillsRoot.appendingPathComponent("artifact-writer/SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillsRoot.appendingPathComponent("artifact-writer/scripts/render.mjs").path))
        XCTAssertEqual(config.skillOptions.additionalSkillRoots, [skillsRoot])

        let implicit = try PromptAssembler.build(configuration: config, userText: "Please create a polished artifact")
        XCTAssertTrue(implicit.availableSkills.contains { $0.name == "artifact-writer" })
        XCTAssertTrue(implicit.activatedSkills.isEmpty)

        let explicit = try PromptAssembler.build(configuration: config, userText: "$artifact-writer make the deck")
        XCTAssertEqual(explicit.activatedSkills.map(\.name), ["artifact-writer"])
        let prefixText = explicit.inputPrefixItems.map(\.description).joined(separator: "\n")
        XCTAssertTrue(prefixText.contains("host-provided artifact runtime"))
    }

    func testSkillDiscoveryRecursesAdditionalRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreTests-\(UUID().uuidString)")
        let work = root.appendingPathComponent("workspace")
        let skillDir = root.appendingPathComponent("skills/productivity/report-writer")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        ---
        name: report-writer
        description: Write concise engineering status reports.
        ---

        Include validation and risks.
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let config = AgentConfiguration(
            workspaceURL: work,
            projectInstructionOptions: ProjectInstructionOptions(enabled: false),
            skillOptions: SkillInjectionOptions(
                includeRepoSkills: false,
                includeUserSkills: false,
                includeAdminSkills: false,
                includeSystemSkills: false,
                additionalSkillRoots: [root.appendingPathComponent("skills")]
            )
        )
        let assembly = try PromptAssembler.build(configuration: config, userText: "$report-writer summarize")
        XCTAssertEqual(assembly.activatedSkills.map(\.name), ["report-writer"])
    }

    func testEmbeddedSkillInstallDoesNotDeleteExistingSkillsWhenValidationFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreTests-\(UUID().uuidString)")
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "keep".write(to: existing.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let invalid = EmbeddedAgentSkill(
            name: "invalid",
            description: "Invalid skill",
            instructions: "No-op",
            directoryName: "existing/escape"
        )

        XCTAssertThrowsError(try EmbeddedSkillInstaller.install([invalid], into: root, overwrite: true))
        XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("SKILL.md"), encoding: .utf8), "keep")
    }

    func testEmbeddedSkillInstallerRejectsEscapingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCodexCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let embedded = EmbeddedAgentSkill(
            name: "bad-skill",
            description: "Invalid skill",
            instructions: "No-op",
            files: [EmbeddedSkillFile(relativePath: "../escape.txt", contents: "nope")]
        )

        XCTAssertThrowsError(try EmbeddedSkillInstaller.install([embedded], into: root))
    }

    func testCodexAuthCacheRoundTripAndJWTExtraction() throws {
        let exp = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let accessPayload: JSONValue = .object([
            "exp": .number(Double(exp)),
            "https://api.openai.com/auth": .object([
                "chatgpt_account_id": .string("acct_123"),
                "organization_id": .string("org_123")
            ])
        ])
        let access = try Self.fakeJWT(payload: accessPayload)
        let cache = CodexAuthDotJson(
            authMode: "chatgpt",
            tokens: CodexTokenData(idToken: accessPayload, accessToken: access, refreshToken: "refresh", accountID: nil),
            lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder.codexPretty.encode(cache)
        let decoded = try JSONDecoder.codex.decode(CodexAuthDotJson.self, from: data)
        let session = try XCTUnwrap(decoded.asAuthSession())
        XCTAssertEqual(session.mode, .chatGPT)
        XCTAssertEqual(session.accountID, "acct_123")
        XCTAssertEqual(session.workspaceID, "org_123")
        XCTAssertEqual(session.refreshToken, "refresh")
    }

    func testCodexAuthCacheAcceptsBaseCodexShape() throws {
        let idPayload: JSONValue = .object([
            "https://api.openai.com/auth": .object([
                "chatgpt_account_id": .string("acct_base"),
                "organization_id": .string("org_base")
            ])
        ])
        let rawIDToken = try Self.fakeJWT(payload: idPayload)
        let access = try Self.fakeJWT(payload: .object(["exp": .number(Date().addingTimeInterval(3600).timeIntervalSince1970)]))
        let data = """
        {
          "OPENAI_API_KEY": "sk-base",
          "tokens": {
            "id_token": "\(rawIDToken)",
            "access_token": "\(access)",
            "refresh_token": "refresh-base",
            "account_id": "acct_base"
          },
          "last_refresh": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder.codex.decode(CodexAuthDotJson.self, from: data)
        let session = try XCTUnwrap(decoded.asAuthSession())
        XCTAssertEqual(decoded.openaiAPIKey, "sk-base")
        XCTAssertEqual(session.accountID, "acct_base")
        XCTAssertEqual(session.workspaceID, "org_base")
        XCTAssertEqual(session.metadata["raw_id_token"]?.stringValue, rawIDToken)
    }

    func testCodexAuthCacheWritesBaseCodexTokenShape() throws {
        let idPayload: JSONValue = .object([
            "https://api.openai.com/auth": .object([
                "chatgpt_account_id": .string("acct_123")
            ])
        ])
        let rawIDToken = try Self.fakeJWT(payload: idPayload)
        let auth = CodexAuthDotJson(
            authMode: "chatgpt",
            openaiAPIKey: "sk-token-exchange",
            tokens: CodexTokenData(
                idToken: idPayload,
                accessToken: "access",
                refreshToken: "refresh",
                accountID: "acct_123",
                rawIDToken: rawIDToken
            ),
            lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let json = try JSONDecoder.codex.decode(JSONValue.self, from: JSONEncoder.codexPretty.encode(auth))
        XCTAssertEqual(json["OPENAI_API_KEY"]?.stringValue, "sk-token-exchange")
        XCTAssertEqual(json["tokens"]?["id_token"]?.stringValue, rawIDToken)
        XCTAssertNil(json["tokens"]?["raw_id_token"])
    }

    func testSHA256KnownVector() {
        let digest = SHA256.hash(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    private static func fakeJWT(payload: JSONValue) throws -> String {
        let header = try JSONEncoder.codexCompact.encode(JSONValue.object(["alg": .string("none")]))
        let payloadData = try JSONEncoder.codexCompact.encode(payload)
        return [Base64URL.encode(header), Base64URL.encode(payloadData), "sig"].joined(separator: ".")
    }

}

private final class RecordingModelProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[ModelStreamEvent]]
    private var storage: [ResponsesRequest] = []

    init(batches: [[ModelStreamEvent]]) {
        self.batches = batches
    }

    var requests: [ResponsesRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        lock.lock()
        storage.append(request)
        let events = batches.isEmpty ? [.completed(responseID: nil, usage: nil)] : batches.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private final class DelayedModelProvider: ModelProvider, @unchecked Sendable {
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func streamResponse(_ request: ResponsesRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                continuation.yield(.outputTextDelta("done"))
                continuation.yield(.completed(responseID: "delayed", usage: nil))
                continuation.finish()
            }
        }
    }
}

private struct ApprovalEchoTool: AgentTool {
    let definition = ToolDefinition(
        name: "approval_echo",
        description: "Echo text after approval.",
        parameters: ToolSchemas.object(properties: [
            "text": ToolSchemas.string(description: "Text to echo")
        ], required: ["text"]),
        requiresApproval: true,
        isStateChanging: true
    )

    func run(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        ToolResult(content: try arguments.requiredString("text"))
    }
}

private struct StaticAuthProvider: AuthorizationProvider {
    func authorizationHeaders() async throws -> [String: String] {
        ["Authorization": "Bearer test-token"]
    }
}

private struct CapturedHTTPRequest: Sendable, Equatable {
    var method: String
    var path: String
    var authorization: String?

    init(_ request: URLRequest) {
        method = request.httpMethod ?? ""
        path = request.url?.path ?? ""
        authorization = request.value(forHTTPHeaderField: "Authorization")
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: CodexCoreError.transportError("No stub handler registered"))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(for request: URLRequest, statusCode: Int = 200, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private extension URLRequest {
    func bodyData() throws -> Data {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                throw stream.streamError ?? CodexCoreError.transportError("Could not read request body stream")
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}
