import AppKit
import SwiftUI
import WeChatBridgeCore

/// A destination is confirmed before any keystroke can reach a Codex conversation.
@MainActor
final class CodexConversationPanel {
    enum Step: Equatable {
        case destination, confirmNew, confirmExisting
    }

    enum Answer: Equatable, Sendable {
        case newChat, existingChat, confirmed, cancelled, expired
    }

    private var window: TargetPickerWindow?
    private var pending: CheckedContinuation<Answer, Never>?
    private var deadline: Task<Void, Never>?

    func ask(_ step: Step, near pointer: NSPoint) async -> Answer {
        await withCheckedContinuation { continuation in
            present(step, near: pointer, continuation: continuation)
        }
    }

    private func present(
        _ step: Step, near pointer: NSPoint,
        continuation: CheckedContinuation<Answer, Never>
    ) {
        if pending != nil { finish(.cancelled) }
        pending = continuation
        let window = TargetPickerWindow()
        self.window = window
        let hosting = ToastHostingView(rootView: CodexConversationView(step: step) { [weak self] in
            self?.finish($0)
        })
        window.contentView = hosting
        let size = FloatingCapsule.measure(hosting)
        window.setFrame(FloatingCapsule.fitted(FloatingCapsule.near(pointer, size: size), to: hosting), display: true)
        window.onConfirm = { [weak self] in self?.finish(step == .destination ? .newChat : .confirmed) }
        window.onCancel = { [weak self] in self?.finish(.cancelled) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(BatchIntent.freshnessWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.expired)
        }
    }

    private func finish(_ answer: Answer) {
        guard let continuation = pending else { return }
        pending = nil
        deadline?.cancel()
        deadline = nil
        window?.close()
        window = nil
        continuation.resume(returning: answer)
    }
}

private struct CodexConversationView: View {
    let step: CodexConversationPanel.Step
    let answer: (CodexConversationPanel.Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(L10n.text("发送到 Codex")).font(Typo.paneBodyStrong)
            if step == .destination {
                destinationChoices
            } else {
                confirmation
            }
            Text(L10n.text("只粘贴，不自动发送。"))
                .font(Typo.paneCaption)
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(Space.m)
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Palette.hairline, lineWidth: Stroke.hairline))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var destinationChoices: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button(L10n.text("新建对话")) { answer(.newChat) }
                .buttonStyle(SettingsActionButtonStyle(primary: true, width: nil))
            Button(L10n.text("选择已有对话")) { answer(.existingChat) }
                .buttonStyle(SettingsActionButtonStyle(width: nil))
            Button(L10n.text("取消")) { answer(.cancelled) }
                .buttonStyle(SettingsActionButtonStyle(width: nil))
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(step == .confirmNew
                ? L10n.text("请确认 Codex 已打开新对话，并选好项目。若未新建，请先手动新建。")
                : L10n.text("请在 Codex 中选好要接收资料的对话，再继续粘贴。"))
                .font(Typo.paneCaption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                Button(L10n.text("取消")) { answer(.cancelled) }
                    .buttonStyle(SettingsActionButtonStyle(width: nil))
                Button(L10n.text("粘贴到这个对话")) { answer(.confirmed) }
                    .buttonStyle(SettingsActionButtonStyle(primary: true, width: nil))
            }
        }
    }
}
