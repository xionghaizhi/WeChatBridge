import AppKit
import XCTest
import WeChatBridgeCore
@testable import WeChatBridgeApp

final class SceneSelectionTests: XCTestCase {
    @MainActor
    func testEachForwardAsksAndPreselectsTheLastChoiceWithoutBinding() async throws {
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let first = WeChatScene(id: "first", name: "一", instruction: "a", outputSpec: "", enabled: true)
        let second = WeChatScene(id: "second", name: "二", instruction: "b", outputSpec: "", enabled: true)
        preferences.scenes = SceneSettings(scenes: [first, second])
        var preselected: [String?] = []
        let coordinator = SceneCoordinator(preferences: preferences) { scenes, selected, allowsRemember, _ in
            XCTAssertEqual(scenes.map(\.id), [first.id, second.id])
            XCTAssertTrue(allowsRemember)
            preselected.append(selected)
            return .picked(preselected.count == 1 ? first : second, remember: false)
        }
        for _ in 0..<2 {
            _ = await coordinator.prepare(enabled: true, groupName: "项目群", captureTitle: false, urls: [], pointer: .zero)
        }
        XCTAssertEqual(preselected, [nil, first.id])
        let memory = try XCTUnwrap(preferences.groupMemory["项目群"])
        XCTAssertEqual(memory.lastSceneID, second.id)
        XCTAssertNil(memory.automaticSceneID)
        XCTAssertTrue(memory.boundSceneIDs.isEmpty)
    }

    @MainActor
    func testRememberIsOptInAndCanBeCancelledAfterReload() async throws {
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let scene = WeChatScene(id: "one", name: "一", instruction: "a", outputSpec: "", enabled: true)
        preferences.scenes = SceneSettings(scenes: [scene])
        var questions = 0
        let coordinator = SceneCoordinator(preferences: preferences) { _, _, _, _ in
            questions += 1
            return .picked(scene, remember: true)
        }
        _ = await coordinator.prepare(enabled: true, groupName: "项目群", captureTitle: false, urls: [], pointer: .zero)
        let restored = Preferences(defaults: defaults)
        XCTAssertEqual(restored.groupMemory["项目群"]?.automaticSceneID, scene.id)
        let afterRestart = SceneCoordinator(preferences: restored) { _, _, _, _ in
            questions += 1
            return .picked(scene, remember: false)
        }
        _ = await afterRestart.prepare(enabled: true, groupName: "项目群", captureTitle: false, urls: [], pointer: .zero)
        XCTAssertEqual(questions, 1)
        restored.groupMemory["项目群"]?.automaticSceneID = nil
        _ = await afterRestart.prepare(enabled: true, groupName: "项目群", captureTitle: false, urls: [], pointer: .zero)
        XCTAssertEqual(questions, 2)
    }

    @MainActor
    func testLegacyBindingStillAsksAndAllowsOtherScenes() async {
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let old = WeChatScene(id: "old", name: "旧", instruction: "a", outputSpec: "", enabled: true)
        let other = WeChatScene(id: "other", name: "其他", instruction: "b", outputSpec: "", enabled: true)
        preferences.scenes = SceneSettings(scenes: [old, other])
        preferences.groupMemory["项目群"] = GroupMemory(displayName: "项目群", boundSceneIDs: [old.id])
        var questions = 0
        let coordinator = SceneCoordinator(preferences: preferences) { scenes, selected, _, _ in
            questions += 1
            XCTAssertEqual(scenes.map(\.id), [old.id, other.id])
            XCTAssertEqual(selected, old.id)
            return .cancelled
        }
        let answer = await coordinator.prepare(enabled: true, groupName: "项目群", captureTitle: false, urls: [], pointer: .zero)
        guard case .ready(let selection) = answer else { return XCTFail("Expected direct forwarding") }
        XCTAssertTrue(selection.scenes.isEmpty)
        XCTAssertEqual(questions, 1)
        XCTAssertNil(preferences.groupMemory["项目群"]?.automaticSceneID)
    }

    @MainActor
    func testUnknownGroupCannotBeRememberedAndStillAsks() async {
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let scene = WeChatScene(id: "one", name: "一", instruction: "a", outputSpec: "", enabled: true)
        preferences.scenes = SceneSettings(scenes: [scene])
        var questions = 0
        let coordinator = SceneCoordinator(preferences: preferences) { _, _, allowsRemember, _ in
            questions += 1
            XCTAssertFalse(allowsRemember)
            return .picked(scene, remember: true)
        }
        _ = await coordinator.prepare(enabled: true, groupName: nil, captureTitle: false, urls: [], pointer: .zero)
        XCTAssertEqual(questions, 1)
        XCTAssertTrue(preferences.groupMemory.isEmpty)
    }

    @MainActor
    func testDisabledRememberedSceneAsksInsteadOfSilentlyUsingIt() async {
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let old = WeChatScene(id: "old", name: "旧", instruction: "a", outputSpec: "", enabled: false)
        let other = WeChatScene(id: "other", name: "其他", instruction: "b", outputSpec: "", enabled: true)
        preferences.scenes = SceneSettings(scenes: [old, other])
        preferences.groupMemory["项目群"] = GroupMemory(displayName: "项目群", automaticSceneID: old.id)
        var questions = 0
        let coordinator = SceneCoordinator(preferences: preferences) { scenes, selected, _, _ in
            questions += 1
            XCTAssertEqual(scenes.map(\.id), [other.id])
            XCTAssertNil(selected)
            return .expired
        }
        let answer = await coordinator.prepare(enabled: true, groupName: "项目群", captureTitle: false, urls: [], pointer: .zero)
        guard case .expired = answer else { return XCTFail("An unanswered picker must not deliver") }
        XCTAssertEqual(questions, 1)
    }

    @MainActor
    func testExplicitShortcutAppliesOnceWithoutReplacingRememberedChoice() async {
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let first = WeChatScene(id: "first", name: "一", instruction: "a", outputSpec: "", enabled: true)
        let second = WeChatScene(id: "second", name: "二", instruction: "b", outputSpec: "", enabled: true)
        preferences.scenes = SceneSettings(scenes: [first, second])
        preferences.groupMemory["项目群"] = GroupMemory(displayName: "项目群", automaticSceneID: first.id)
        preferences.selectSceneForNextForward(id: second.id)
        let coordinator = SceneCoordinator(preferences: preferences) { _, _, _, _ in
            XCTFail("An explicit shortcut or remembered scene must not ask twice")
            return .expired
        }
        let next = await coordinator.prepare(enabled: true, groupName: "项目群", captureTitle: false, urls: [], pointer: .zero)
        let later = await coordinator.prepare(enabled: true, groupName: "项目群", captureTitle: false, urls: [], pointer: .zero)
        guard case .ready(let nextSelection) = next, case .ready(let laterSelection) = later else {
            return XCTFail("Expected ready selections")
        }
        XCTAssertEqual(nextSelection.scene?.id, second.id)
        XCTAssertEqual(laterSelection.scene?.id, first.id)
        XCTAssertNil(preferences.pendingScene)
    }

    @MainActor
    func testRememberedSceneIsNotAGlobalDefaultForOtherChats() async {
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let scene = WeChatScene(id: "one", name: "一", instruction: "a", outputSpec: "", enabled: true)
        preferences.scenes = SceneSettings(scenes: [scene])
        preferences.groupMemory["甲群"] = GroupMemory(displayName: "甲群", automaticSceneID: scene.id)
        var questions = 0
        let coordinator = SceneCoordinator(preferences: preferences) { _, selected, _, _ in
            questions += 1
            XCTAssertNil(selected)
            return .picked(scene, remember: false)
        }
        _ = await coordinator.prepare(enabled: true, groupName: "乙群", captureTitle: false, urls: [], pointer: .zero)
        XCTAssertEqual(questions, 1)
        XCTAssertEqual(preferences.groupMemory["甲群"]?.automaticSceneID, scene.id)
        XCTAssertNil(preferences.groupMemory["乙群"]?.automaticSceneID)
    }
}
