import Foundation
import XCTest
@testable import CodexCore

final class PromptPathMappingTests: XCTestCase {
  func testVirtualPathsAreRenderedWhileInstructionReadsUsePhysicalFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Users/coder/Documents/Project")
    let skillRoot = root.appendingPathComponent("Users/coder/skills")
    let skillDirectory = skillRoot.appendingPathComponent("mapping")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
    try "Follow the project convention.".write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "---\nname: mapping\ndescription: Mapping fixture\n---\nRead scripts/helper.js relative to this skill.".write(
      to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let configuration = AgentConfiguration(workspaceURL: root,
      projectInstructionOptions: ProjectInstructionOptions(currentWorkingDirectory: project, includeGlobal: false),
      skillOptions: SkillInjectionOptions(includeRepoSkills: false, includeUserSkills: false,
        includeAdminSkills: false, additionalSkillRoots: [skillRoot],
        pathMappings: [PromptPathMapping(physicalRoot: root, virtualRoot: "/")]))
    let assembly = try PromptAssembler.build(configuration: configuration, userText: "$mapping")
    XCTAssertTrue(assembly.instructions.contains("/Users/coder/skills/mapping/SKILL.md"))
    XCTAssertFalse(assembly.instructions.contains(root.path))
    let rendered = JSONValue.array(assembly.inputPrefixItems).description
    XCTAssertTrue(rendered.contains("/Users/coder/Documents/Project"))
    XCTAssertTrue(rendered.contains("Skill directory: /Users/coder/skills/mapping"))
    XCTAssertFalse(rendered.contains(root.path))
    XCTAssertEqual(assembly.activatedSkills.first?.path.resolvingSymlinksInPath(),
      skillDirectory.appendingPathComponent("SKILL.md").resolvingSymlinksInPath())
  }

  func testMappingsMatchDirectoryBoundaries() {
    let mappings = [PromptPathMapping(physicalRoot: URL(fileURLWithPath: "/container/root"), virtualRoot: "/")]
    XCTAssertEqual(PromptPathMapping.displayPath(URL(fileURLWithPath: "/container/root-other/file"), mappings: mappings), "/container/root-other/file")
    XCTAssertEqual(PromptPathMapping.displayPath(URL(fileURLWithPath: "/container/root"), mappings: mappings), "/")
  }
}
