import SwiftUI

@main
struct ClockedApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var controller = SessionController()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            Themed { MainView() }.environmentObject(controller)
        }
        .defaultSize(width: 860, height: 600)
        .commands {
            SessionCommands(c: controller)
            CommandGroup(replacing: .appSettings) {
                SettingsCommand(c: controller)
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to \(AppInfo.name)") {
                    UserDefaults.standard.set(false, forKey: "onboardingDone")
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
            }
        }

        Window("Developer View", id: "developer") {
            Themed { DeveloperView() }.environmentObject(controller)
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Focus", id: "focus") {
            Themed { FocusView() }.environmentObject(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)


        MenuBarExtra {
            Themed { StatusPopover() }.environmentObject(controller)
        } label: {
            MenuBarLabel(c: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon, with today's time next to it during a session (unless turned off in Appearance).
struct MenuBarLabel: View {
    @ObservedObject var c: SessionController
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        label
            // The menu bar item always exists, so it's the place to open Focus View when a session starts.
            .onChange(of: c.phase) { old, new in
                if new == .running, old == .idle || old == .finished, settings.openFocusOnStart {
                    openWindow(id: "focus")
                }
            }
    }

    @ViewBuilder private var label: some View {
        if c.phase == .running || c.phase.isBreak {
            // Filled stopwatch while focused; the status symbol (phone, away, break…) otherwise.
            HStack(spacing: 4) {
                if c.phase == .running, !c.studyClockPaused {
                    Image(nsImage: Icons.menuBarActive)
                } else {
                    Image(systemName: c.menuSymbol)
                }
                switch settings.menuBarShows {
                case .icon: EmptyView()
                case .today: Text(formatTimer(c.todayTotal)).monospacedDigit()
                case .session: Text(formatTimer(c.focusedTime)).monospacedDigit()
                case .remaining: Text(formatTimer(c.timerValue(.remaining))).monospacedDigit()
                }
            }
        } else {
            Image(nsImage: Icons.menuBar)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyAppearance()
    }

    /// Closing the main window leaves the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SessionController.current?.shouldTerminate(sender) ?? .terminateNow
    }
}
