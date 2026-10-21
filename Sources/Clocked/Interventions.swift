import AppKit
import SwiftUI

enum Strictness: String, CaseIterable, Identifiable {
    case gentle, firm, strict
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var summary: String {
        switch self {
        case .gentle: return "A banner when you get distracted, repeated at most every 90 seconds."
        case .firm: return "Repeated banners and phone reminders. After 45 seconds a curtain covers the screen until you're back."
        case .strict: return "Frequent reminders and an early curtain. Distracting tabs are closed and distracting apps hidden after a 10-second warning."
        }
    }
}

/// How hard to push back while you stay distracted. Times are seconds since the distraction started.
struct InterventionPolicy {
    var repeatBanner: TimeInterval
    var pingAfter: TimeInterval
    var pingEvery: TimeInterval
    var curtainAfter: TimeInterval?
    var enforceAfter: TimeInterval?
    var confirmEarlyEnd: Bool

    static func of(_ strictness: Strictness) -> InterventionPolicy {
        switch strictness {
        case .gentle:
            return InterventionPolicy(repeatBanner: 90, pingAfter: 60, pingEvery: 120, curtainAfter: nil, enforceAfter: nil, confirmEarlyEnd: false)
        case .firm:
            return InterventionPolicy(repeatBanner: 30, pingAfter: 15, pingEvery: 45, curtainAfter: 45, enforceAfter: nil, confirmEarlyEnd: true)
        case .strict:
            return InterventionPolicy(repeatBanner: 20, pingAfter: 5, pingEvery: 30, curtainAfter: 15, enforceAfter: 20, confirmEarlyEnd: true)
        }
    }
}

/// Runs short AppleScripts against Messages and Shortcuts on a background queue, one at a time.
/// These are the only ways a sandboxed Mac app without network access can reach your iPhone.
final class AppleScriptRunner: @unchecked Sendable {
    /// All AppleScript in the app runs on this one serial queue.
    static let queue = DispatchQueue(label: "applescript", qos: .utility)
    private var queue: DispatchQueue { Self.queue }

    /// Sends an iMessage to `handle` (your own number or Apple ID email) through the Messages app.
    func sendMessage(_ text: String, to handle: String, completion: @escaping @MainActor (String?) -> Void) {
        run("""
        with timeout of 15 seconds
            tell application id "com.apple.MobileSMS"
                set targetService to 1st account whose service type = iMessage
                send "\(Self.escape(text))" to participant "\(Self.escape(handle))" of targetService
            end tell
        end timeout
        """, completion: completion)
    }

    /// Runs a shortcut by name with the Shortcuts app (e.g. one that turns a Focus on or off).
    func runShortcut(_ name: String, completion: @escaping @MainActor (String?) -> Void) {
        run("""
        with timeout of 30 seconds
            tell application id "com.apple.shortcuts.events" to run shortcut "\(Self.escape(name))"
        end timeout
        """, completion: completion)
    }

    private func run(_ source: String, completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let message: String? = error.map { error in
                if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                    return "Not allowed. Turn it on in System Settings → Privacy & Security → Automation."
                }
                return error[NSAppleScript.errorMessage] as? String ?? "Failed."
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(message) } }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// A dark full-screen cover shown while you stay distracted. It lifts by itself once you're back,
/// and always has buttons (and Esc) so it can never lock you out.
@MainActor
final class FocusCurtain {
    final class Model: ObservableObject {
        @Published var title = ""
        @Published var detail = ""
        /// Correction offered on the curtain itself (e.g. "Not My Phone"), since it covers the nudge banner.
        @Published var corrections: [(String, () -> Void)] = []
        /// "I'm Back" and Esc only work after a few seconds, so the curtain can't be dismissed on reflex.
        @Published var canDismiss = false
    }

    private var panels: [NSPanel] = []
    private let model = Model()
    var isShowing: Bool { !panels.isEmpty }

    func show(title: String, detail: String, corrections: [(String, () -> Void)],
              onBack: @escaping () -> Void, onEnd: @escaping () -> Void) {
        model.title = title
        model.detail = detail
        model.corrections = corrections
        guard panels.isEmpty else { return }
        model.canDismiss = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [model] in model.canDismiss = true }
        let onEscape = { [model] in if model.canDismiss { onBack() } }
        for screen in NSScreen.screens {
            let panel = CurtainPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hidesOnDeactivate = false
            panel.onEscape = onEscape
            let isMain = screen == (NSScreen.main ?? NSScreen.screens.first)
            panel.contentView = NSHostingView(rootView: CurtainView(model: model, showsContent: isMain, onBack: onBack, onEnd: onEnd))
            panel.setFrame(screen.frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            if isMain { panel.makeKey() }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; panel.animator().alphaValue = 1 }
            panels.append(panel)
        }
    }

    func update(detail: String) {
        if model.detail != detail { model.detail = detail }
    }

    func hide() {
        let closing = panels
        panels = []
        for panel in closing {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                completionHandler: { panel.orderOut(nil) })
        }
    }
}

private final class CurtainPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private struct CurtainView: View {
    @ObservedObject var model: FocusCurtain.Model
    let showsContent: Bool
    let onBack: () -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
            if showsContent {
                VStack(spacing: 18) {
                    Image(systemName: "pause.circle").font(.system(size: 64, weight: .light))
                    Text(model.title).font(.system(size: 34, weight: .semibold))
                    Text(model.detail).font(.title3).foregroundStyle(.secondary).monospacedDigit()
                    HStack(spacing: 12) {
                        Button("I'm Back", action: onBack)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.canDismiss)
                        ForEach(Array(model.corrections.enumerated()), id: \.offset) { _, correction in
                            Button(correction.0, action: correction.1)
                        }
                        Button("End Session", action: onEnd)
                    }
                    .controlSize(.large)
                    .padding(.top, 8)
                }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
