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
        let handle = await runtime.startTurn(threadID: thread.id, input: TurnInput("go"))

        for try await _ in handle.events {}

        let active = await runtime.activeTurn(threadID: thread.id)
        XCTAssertNil(active)
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
