import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case today = "Today", stats = "Stats", sessions = "Sessions", groups = "Groups"
    // Settings, listed in the sidebar under their own heading.
    case general = "General", appearance = "Appearance", detection = "Detection", postures = "Postures", learning = "Learning"
    case accountability = "Accountability", sites = "Sites & Apps", privacy = "Privacy"
    var id: String { rawValue }

    static let main: [Pane] = [.today, .stats, .sessions, .groups]
    static let settings: [Pane] = [.general, .appearance, .detection, .postures, .learning, .accountability, .sites, .privacy]

    var symbol: String {
        switch self {
        case .today: return "timer"
        case .stats: return "chart.bar.xaxis"
        case .sessions: return "list.bullet.rectangle"
        case .groups: return "person.3"
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .detection: return "eye"
        case .postures: return "figure.seated.side.left"
        case .learning: return "brain"
        case .accountability: return "bell.badge"
        case .sites: return "list.bullet"
        case .privacy: return "hand.raised"
        }
    }
}

/// The main window: Today, Stats, Sessions and Settings.
struct MainView: View {
    @EnvironmentObject var c: SessionController
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("onboardingDone") private var onboardingDone = false

    private var mac: Bool { settings.interfaceStyle == .mac }

    var body: some View {
        NavigationSplitView {
            List(selection: $c.selectedPane) {
                if mac {
                    // Mac style: today's time on Today, and your subjects (Settings are in their own window).
                    ForEach(Pane.main) { pane in
                        Label(pane.rawValue, systemImage: pane.symbol)
                            .badge(pane == .today ? Text(formatHours(c.todayTotal)) : nil)
                            .tag(pane)
                    }
                    if !c.subjects.subjects.isEmpty {
                        Section("Subjects") {
                            ForEach(c.subjects.subjects) { SidebarSubjectRow(subject: $0) }
                        }
                    }
                } else {
                    ForEach(Pane.main) { pane in
                        Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
                    }
                    Section("Settings") {
                        ForEach(Pane.settings) { pane in
                            Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { OnlineStatusLine() }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            Group {
                switch c.selectedPane ?? .today {
                case .today: TodayPane()
                case .stats: StatsPane()
                case .sessions: SessionsPane()
                case .groups: GroupsPane()
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
                case .detection: DetectionSettings()
                case .postures: PosturesPane()
                case .learning: LearningPane()
                case .accountability: AccountabilitySettings()
                case .sites: ListsSettings()
                case .privacy: PrivacySettings()
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .navigationTitle((c.selectedPane ?? .today).rawValue)
        }
        .frame(minWidth: 640, minHeight: 480)
        // Switching to Mac style while on a settings pane: carry on in the Settings window.
        .onChange(of: settings.interfaceStyle) { _, style in
            if style == .mac, let pane = c.selectedPane, Pane.settings.contains(pane) {
                c.selectedPane = .today
                c.showSettings(pane)
            }
        }
        .sheet(isPresented: Binding(get: { !onboardingDone }, set: { if !$0 { onboardingDone = true } })) {
            OnboardingView()
        }
        // Closing the window hides the Dock icon; the app keeps running from the menu bar.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { hideDockIconIfNoWindows() }
    }
}

/// Mac style sidebar: a subject with its icon (or colour) and today's time. Double-click starts it.
private struct SidebarSubjectRow: View {
    @EnvironmentObject var c: SessionController
    let subject: Subject

    var body: some View {
        let isCurrent = subject.id == c.currentSubjectID && (c.phase == .running || c.phase.isBreak)
        Label {
            Text(subject.name)
        } icon: {
            if let symbol = subject.symbol {
                Image(systemName: symbol).foregroundStyle(subject.color)
            } else {
                Image(systemName: isCurrent ? "record.circle" : "circle.fill").foregroundStyle(subject.color).imageScale(.small)
            }
        }
        .badge(Text(formatHours(c.todayTime(for: subject))))
        .selectionDisabled()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { c.start(subject: subject) }
        .help(isCurrent ? "Studying now" : "Double-click to start \(subject.name)")
        .contextMenu {
            Button(isCurrent ? "End Session" : "Start \(subject.name)") {
                if isCurrent { c.requestEnd() } else { c.start(subject: subject) }
            }
            SubjectIconMenu(subject: subject)
        }
    }
}

/// Mac style: Settings in their own window, with a sidebar like System Settings.
struct SettingsWindow: View {
    @EnvironmentObject var c: SessionController
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        NavigationSplitView {
            List(Pane.settings, selection: Binding(get: { c.settingsPane }, set: { if let p = $0 { c.settingsPane = p } })) { pane in
                Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch c.settingsPane {
                case .appearance: AppearanceSettings()
                case .detection: DetectionSettings()
                case .postures: PosturesPane()
                case .learning: LearningPane()
                case .accountability: AccountabilitySettings()
                case .sites: ListsSettings()
                case .privacy: PrivacySettings()
                default: GeneralSettings()
                }
            }
            .navigationTitle(c.settingsPane.rawValue)
        }
        .frame(minWidth: 620, minHeight: 420)
        // Back to Classic: Settings return to the main window's sidebar.
        .onChange(of: settings.interfaceStyle) { _, style in
            if style == .classic {
                c.showSettings(c.settingsPane)
                dismissWindow(id: "settings")
            }
        }
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { hideDockIconIfNoWindows() }
    }
}

/// Back to menu bar only once neither the main window nor the Settings window is open.
@MainActor func hideDockIconIfNoWindows() {
    DispatchQueue.main.async {
        let open = NSApp.windows.contains { w in
            guard w.isVisible, let id = w.identifier?.rawValue else { return false }
            return id.hasPrefix("main") || id.hasPrefix("settings")
        }
        if !open { NSApp.setActivationPolicy(.accessory) }
    }
}
