import AppKit
import WeChatBridgeCore
import Foundation

/// Resolves and remembers scene choices for incoming share batches.
@MainActor
final class SceneCoordinator {
    struct Selection: Sendable {
        var scenes: [WeChatScene]
        var groupName: String?
        var previousSummaryAt: Date?
        var insights = WeChatBatchInsights()

        init(
            scenes: [WeChatScene] = [],
            groupName: String? = nil,
            previousSummaryAt: Date? = nil,
            insights: WeChatBatchInsights = WeChatBatchInsights()
        ) {
            self.scenes = scenes
            self.groupName = groupName
            self.previousSummaryAt = previousSummaryAt
            self.insights = insights
        }

        var scene: WeChatScene? { scenes.first }
    }

    enum Answer: Sendable {
        case ready(Selection)
        case expired
    }

    private let preferences: Preferences
    private let pickScene: @MainActor ([WeChatScene], String?, Bool, NSPoint) async -> ScenePickerPanel.Answer
    private let worker = DispatchQueue(
        label: "dev.wechatflow.scene-reader",
        qos: .userInitiated,
        attributes: .concurrent
    )

    init(
        preferences: Preferences,
        pickScene: (@MainActor ([WeChatScene], String?, Bool, NSPoint) async -> ScenePickerPanel.Answer)? = nil
    ) {
        self.preferences = preferences
        self.pickScene = pickScene ?? { scenes, preselectedID, allowsRemember, pointer in
            await ScenePickerPanel().choose(
                from: scenes, preselectedID: preselectedID, allowsRemember: allowsRemember
            ) { FloatingCapsule.near(pointer, size: $0) }
        }
    }

    func prepare(
        enabled: Bool,
        groupName: String?,
        captureTitle: Bool,
        urls: [URL],
        pointer: NSPoint,
        allowDefault: Bool = true
    ) async -> Answer {
        var selection = Selection()
        selection.groupName = groupName
        guard enabled || captureTitle else { return .ready(selection) }

        let insightsTask = enabled ? Task {
            await withCheckedContinuation { continuation in
                worker.async {
                    continuation.resume(
                        returning: (try? WeChatBatchInsightsReader.read(urls: urls)) ?? WeChatBatchInsights()
                    )
                }
            }
        } : nil

        let title: GroupTitleParser.Title?
        if captureTitle {
            title = await withCheckedContinuation { continuation in
                worker.async {
                    continuation.resume(returning: try? WeChatTitleReader.read())
                }
            }
        } else {
            title = nil
        }
        selection.groupName = title?.name ?? selection.groupName
        guard enabled else { return .ready(selection) }

        selection.insights = await insightsTask?.value ?? WeChatBatchInsights()

        if let sceneID = preferences.consumePendingSceneID(),
           let scene = preferences.scenes.scene(id: sceneID) {
            selection.scenes = [scene]
            if let groupName = selection.groupName {
                selection.previousSummaryAt = preferences.groupMemory[GroupName.normalize(groupName)]?.lastSummaryAt
            }
            return .ready(selection)
        }

        let resolution = SceneResolver.resolve(
            groupName: selection.groupName,
            settings: preferences.scenes,
            memories: preferences.groupMemory,
            senders: selection.insights.senders,
            allowDefault: false
        )
        selection.groupName = resolution.groupName ?? selection.groupName
        let memory = selection.groupName.map(GroupName.normalize).flatMap { preferences.groupMemory[$0] }
        if let automatic = preferences.scenes.scene(id: memory?.automaticSceneID) {
            selection.scenes = [automatic]
        } else if !preferences.scenes.enabledScenes.isEmpty {
            let preselectedID = preferences.scenes.scene(id: memory?.lastSceneID)?.id
                ?? resolution.scene?.id
                ?? (allowDefault ? preferences.scenes.defaultScene()?.id : nil)
            let answer = await pickScene(
                preferences.scenes.enabledScenes, preselectedID, selection.groupName != nil, pointer
            )
            switch answer {
            case .picked(let scene, let remember):
                selection.scenes = [scene]
                rememberSelection(scene: scene, groupName: selection.groupName, automatically: remember)
            case .cancelled:
                break
            case .expired:
                return .expired
            }
        }
        if let groupName = selection.groupName {
            selection.previousSummaryAt = preferences.groupMemory[GroupName.normalize(groupName)]?.lastSummaryAt
        }
        return .ready(selection)
    }

    func advance(_ selection: Selection) {
        guard let groupName = selection.groupName else { return }
        let key = GroupName.normalize(groupName)
        guard !key.isEmpty else { return }
        if let scene = selection.scenes.first, let end = selection.insights.end {
            preferences.groupMemory[key] = GroupMemory.advancing(
                preferences.groupMemory[key],
                displayName: groupName,
                sceneID: scene.id,
                senders: selection.insights.senders,
                end: end
            )
        } else {
            var memory = preferences.groupMemory[key] ?? GroupMemory(displayName: groupName)
            memory.senders.formUnion(selection.insights.senders)
            memory.updatedAt = Date()
            preferences.groupMemory[key] = memory
        }
    }

    private func rememberSelection(scene: WeChatScene, groupName: String?, automatically: Bool) {
        guard let groupName else { return }
        let key = GroupName.normalize(groupName)
        guard !key.isEmpty else { return }
        var memory = preferences.groupMemory[key] ?? GroupMemory(displayName: groupName)
        memory.lastSceneID = scene.id
        memory.automaticSceneID = automatically ? scene.id : nil
        if automatically, !memory.boundSceneIDs.contains(scene.id) { memory.boundSceneIDs.append(scene.id) }
        memory.updatedAt = Date()
        preferences.groupMemory[key] = memory
    }
}
