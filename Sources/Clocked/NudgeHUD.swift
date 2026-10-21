import AppKit
import SwiftUI

/// A small banner at the top of the screen that fades away on its own.
/// Uses its own window rather than system notifications so it still works while a Focus mode is on.
@MainActor
final class NudgeHUD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(symbol: String, title: String, message: String, actions: [(String, () -> Void)] = [],
              tint: Color = .orange, sound: Bool) {
        hide(animated: false)
        let wrapped = actions.map { title, action in
            NudgeView.Action(title: title) { [weak self] in action(); self?.hide(animated: true) }
        }
        let view = NudgeView(symbol: symbol, tint: tint, title: title, message: message, actions: wrapped,
                             dismiss: { [weak self] in self?.hide(animated: true) })
        let hosting = FirstMouseHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        self.panel = panel
        if sound { NSSound(named: "Tink")?.play() }

        let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: work)
    }

    func hide(animated: Bool) {
        hideWork?.cancel()
        hideWork = nil
        guard let panel else { return }
        self.panel = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 },
                                                completionHandler: { panel.orderOut(nil) })
        } else {
            panel.orderOut(nil)
        }
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct NudgeView: View {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let run: () -> Void
    }
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let actions: [Action]
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(actions) { action in
                    Button(action.title, action: action.run).controlSize(.small)
                }
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 470)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}
