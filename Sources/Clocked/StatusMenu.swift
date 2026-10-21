import SwiftUI

/// The menu-bar popover: status at a glance and the common session actions.
struct StatusPopover: View {
    @EnvironmentObject var c: SessionController
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow
    private func showSettings() {
        c.selectedPane = .general
        showMainWindow(openWindow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TodayHero(compact: true)
                .padding(.top, Theme.Space.s)

            ScrollView {
                SubjectList(compact: true, showsAdd: false)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            switch c.phase {
            case .idle, .finished:
                HStack(spacing: Theme.Space.s) {
                    GoalPicker()
                    StudyStylePicker()
                }
                .labelsHidden()
                .controlSize(.small)
            case .running, .onBreak:
                running
            }

            Divider()
            HStack(spacing: Theme.Space.l) {
                footerButton("macwindow", "Open \(AppInfo.name)") { showMainWindow(openWindow) }
                footerButton("gearshape", "Settings") { showSettings() }
                Spacer()
                footerButton("power", "Quit \(AppInfo.name)") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func footerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                StatusBadge(status: c.phase.isBreak ? .onBreak : c.status)
                Spacer()
                Text("Session \(formatClock(c.elapsed))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if c.status == .phone, !c.evidence.explanation.isEmpty {
                Text(c.evidence.explanation).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                StudyStylePicker().labelsHidden().controlSize(.small)
                if settings.useCamera, !c.phase.isBreak {
                    Toggle("Paper", isOn: Binding(
                        get: { (c.paperModeUntil ?? .distantPast) > .now },
                        set: { c.setPaperMode($0) }))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("Working on paper: looking down won't count for 25 minutes.")
                }
            }
            HStack {
                if case .onBreak(let until) = c.phase {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Break \(formatClock(max(0, until.timeIntervalSince(context.date))))").monospacedDigit()
                    }
                    Button("Resume") { c.resume() }
                } else {
                    Button("Break") { c.takeBreak() }
                }
                Spacer()
                Button("End Session") { c.requestEnd() }
            }
        }
    }
}

/// Shows the main window and puts the app back in the Dock.
@MainActor func showMainWindow(_ openWindow: OpenWindowAction) {
    NSApp.setActivationPolicy(.regular)
    openWindow(id: "main")
    NSApp.activate()
}

/// App menu → Settings… (⌘,): opens Settings inside the main window.
struct SettingsCommand: View {
    @ObservedObject var c: SessionController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") {
            c.selectedPane = .general
            showMainWindow(openWindow)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// The Session menu in the main menu bar.
struct SessionCommands: Commands {
    @ObservedObject var c: SessionController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Developer View") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "developer")
                NSApp.activate()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("Session") {
            let idle = c.phase == .idle || c.phase == .finished
            Menu("Start") {
                ForEach(Array(c.subjects.subjects.prefix(9).enumerated()), id: \.element.id) { index, subject in
                    Button(subject.name) { c.start(subject: subject) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                if c.subjects.subjects.isEmpty {
                    Button("Without Subject") { c.start() }
                }
            }
            if c.phase.isBreak {
                Button("Resume Session") { c.resume() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
            } else {
                Button("Take a Break") { c.takeBreak() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .disabled(c.phase != .running)
            }
            Button("End Session") { c.requestEnd() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(idle)
            Button("Enter Focus View") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "focus")
                NSApp.activate()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            Divider()
            Toggle("Working on Paper", isOn: Binding(
                get: { (c.paperModeUntil ?? .distantPast) > .now },
                set: { c.setPaperMode($0) }))
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(c.phase != .running)
            Button("Not My Phone") { c.notOnPhone() }
                .disabled(c.status != .phone)
            Divider()
            Button("Mark Current Activity as Study") { c.markCurrent(as: .study) }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(c.activity == nil)
            Button("Mark Current Activity as Distraction") { c.markCurrent(as: .distraction) }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(c.activity == nil)
        }
    }
}
