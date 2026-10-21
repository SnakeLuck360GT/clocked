import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case today = "Today", stats = "Stats", sessions = "Sessions", groups = "Groups"
    // Settings, listed in the sidebar under their own heading.
    case general = "General", detection = "Detection", postures = "Postures", learning = "Learning"
    case accountability = "Accountability", sites = "Sites & Apps", privacy = "Privacy"
    var id: String { rawValue }

    static let main: [Pane] = [.today, .stats, .sessions, .groups]
    static let settings: [Pane] = [.general, .detection, .postures, .learning, .accountability, .sites, .privacy]

    var symbol: String {
        switch self {
        case .today: return "timer"
        case .stats: return "chart.bar.xaxis"
        case .sessions: return "list.bullet.rectangle"
        case .groups: return "person.3"
        case .general: return "gearshape"
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
    @AppStorage("onboardingDone") private var onboardingDone = false

    var body: some View {
        NavigationSplitView {
            List(selection: $c.selectedPane) {
                ForEach(Pane.main) { pane in
                    Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
                }
                Section("Settings") {
                    ForEach(Pane.settings) { pane in
                        Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
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
        .sheet(isPresented: Binding(get: { !onboardingDone }, set: { if !$0 { onboardingDone = true } })) {
            OnboardingView()
        }
        // Closing the window hides the Dock icon; the app keeps running from the menu bar.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}
