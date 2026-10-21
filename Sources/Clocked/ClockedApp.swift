import SwiftUI

@main
struct ClockedApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var controller = SessionController()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            MainView().environmentObject(controller).tint(Theme.accent)
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
            DeveloperView().environmentObject(controller).tint(Theme.accent)
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Focus", id: "focus") {
            FocusView().environmentObject(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)


        MenuBarExtra {
            StatusPopover().environmentObject(controller).tint(Theme.accent)
        } label: {
            if controller.phase == .running || controller.phase.isBreak {
                // Filled stopwatch while focused; the status symbol (phone, away, break…) otherwise.
                HStack(spacing: 4) {
                    if controller.phase == .running, !controller.studyClockPaused {
                        Image(nsImage: Icons.menuBarActive)
                    } else {
                        Image(systemName: controller.menuSymbol)
                    }
                    Text(formatHMS(controller.todayTotal)).monospacedDigit()
                }
            } else {
                Image(nsImage: Icons.menuBar)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the main window leaves the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SessionController.current?.shouldTerminate(sender) ?? .terminateNow
    }
}
