import Foundation
import WeChatBridgeCore
import XCTest

final class ForkScenePackageTests: XCTestCase {
    func testCloseReadingPackageImportsAndRendersWithoutSkills() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appendingPathComponent("shared/Scenes/group-close-reading.wechatflow-scene.json")
        let package = try ScenePackage.decoder().decode(ScenePackage.self, from: Data(contentsOf: url))

        XCTAssertEqual(package.schemaVersion, ScenePackage.currentSchemaVersion)
        XCTAssertEqual(package.id, "xionghaizhi.group-close-reading")
        XCTAssertEqual(package.name, "群聊精读")
        XCTAssertEqual(package.version, "1.1.0")
        XCTAssertNotNil(SceneVersion(package.version))
        XCTAssertFalse(package.isOfficial)
        XCTAssertEqual(package.requiredSkillIDs, [])
        XCTAssertEqual(Set(package.compatibleAgents), Set(AgentID.allCases))
        XCTAssertTrue(package.keywords.isEmpty)
        let prompt = try XCTUnwrap(ScenePrompt.render(scene: package.scene, previousSummaryAt: nil))
        XCTAssertTrue(prompt.contains(package.instruction))
        XCTAssertTrue(prompt.contains(package.outputSpec))
        XCTAssertTrue(package.outputSpec.contains("- [ ] **标题**"))
        XCTAssertTrue(package.outputSpec.contains("负责人：姓名或待确认；截止时间"))
        XCTAssertTrue(package.outputSpec.contains("不用表格"))
        XCTAssertTrue(package.instruction.contains("只有用户在本次直接要求"))
    }
}
