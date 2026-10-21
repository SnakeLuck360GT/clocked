import AppKit
import Combine
import SwiftUI

/// User preferences, stored in UserDefaults (a few hundred bytes).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var useCamera: Bool { didSet { defaults.set(useCamera, forKey: "useCamera") } }
    @Published var useScreen: Bool { didSet { defaults.set(useScreen, forKey: "useScreen") } }
    /// Listen (built-in mic) for the rapid-fire audio pattern of TikTok / Reels / Shorts.
    @Published var useMic: Bool { didSet { defaults.set(useMic, forKey: "useMic") } }
    /// 0 = only obvious phone use, 1 = flag anything phone-like.
    @Published var phoneSensitivity: Double { didSet { defaults.set(phoneSensitivity, forKey: "phoneSensitivity") } }
    /// Use posture (looking down) as evidence of phone use. Combined with typing, sound and your corrections.
    @Published var headDownCountsAsPhone: Bool { didSet { defaults.set(headDownCountsAsPhone, forKey: "headDownCountsAsPhone") } }
    /// Seconds of continuous distraction before a nudge.
    @Published var nudgeDelay: Double { didSet { defaults.set(nudgeDelay, forKey: "nudgeDelay") } }
    @Published var nudgeSound: Bool { didSet { defaults.set(nudgeSound, forKey: "nudgeSound") } }
    @Published var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    @Published var breakMinutes: Double { didSet { defaults.set(breakMinutes, forKey: "breakMinutes") } }
    /// Newline-separated websites / app names that always count as studying.
    @Published var alwaysStudy: String { didSet { defaults.set(alwaysStudy, forKey: "alwaysStudy") } }
    /// Newline-separated websites / app names that always count as distractions.
    @Published var alwaysDistracting: String { didSet { defaults.set(alwaysDistracting, forKey: "alwaysDistracting") } }
    /// Suggest a break after this many minutes of unbroken focus (0 = off).
    @Published var breakReminderMinutes: Double { didSet { defaults.set(breakReminderMinutes, forKey: "breakReminderMinutes") } }
    /// Daily study target shown by the ring on Today (minutes).
    @Published var dailyGoalMinutes: Double { didSet { defaults.set(dailyGoalMinutes, forKey: "dailyGoalMinutes") } }
    /// Typing, writing on paper, or both. Can be changed mid-session.
    @Published var studyStyle: StudyStyle { didSet { defaults.set(studyStyle.rawValue, forKey: "studyStyle") } }
    @Published var strictness: Strictness { didSet { defaults.set(strictness.rawValue, forKey: "strictness") } }
    /// Minutes of actual study to aim for (0 = no goal). Distractions pause the study clock, so they extend the session.
    @Published var goalMinutes: Double { didSet { defaults.set(goalMinutes, forKey: "goalMinutes") } }
    /// Send reminders to your iPhone through Messages (iMessage to yourself). Off until you opt in.
    @Published var phoneReminders: Bool { didSet { defaults.set(phoneReminders, forKey: "phoneReminders") } }
    /// Your iMessage phone number or Apple ID email.
    @Published var phoneHandle: String { didSet { defaults.set(phoneHandle, forKey: "phoneHandle") } }
    /// Run Shortcuts when a session starts and ends (e.g. to turn a Focus on across your devices).
    @Published var runShortcuts: Bool { didSet { defaults.set(runShortcuts, forKey: "runShortcuts") } }
    @Published var startShortcut: String { didSet { defaults.set(startShortcut, forKey: "startShortcut") } }
    @Published var endShortcut: String { didSet { defaults.set(endShortcut, forKey: "endShortcut") } }

    // Appearance
    @Published var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); applyAppearance() } }
    @Published var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "accent"); ThemeState.shared.accent = accent } }
    @Published var timerFont: TimerFont { didSet { defaults.set(timerFont.rawValue, forKey: "timerFont"); ThemeState.shared.timerFont = timerFont } }
    @Published var focusBackground: FocusBackground { didSet { defaults.set(focusBackground.rawValue, forKey: "focusBackground") } }
    /// Show today's time next to the menu bar icon during a session.
    @Published var menuBarTime: Bool { didSet { defaults.set(menuBarTime, forKey: "menuBarTime") } }

    // Pomodoro: focus rounds with automatic breaks. Only focused time counts towards a round.
    @Published var pomodoro: Bool { didSet { defaults.set(pomodoro, forKey: "pomodoro") } }
    @Published var pomodoroMinutes: Double { didSet { defaults.set(pomodoroMinutes, forKey: "pomodoroMinutes") } }
    @Published var shortBreakMinutes: Double { didSet { defaults.set(shortBreakMinutes, forKey: "shortBreakMinutes") } }
    @Published var longBreakMinutes: Double { didSet { defaults.set(longBreakMinutes, forKey: "longBreakMinutes") } }
    /// A long break after this many rounds.
    @Published var roundsPerSet: Int { didSet { defaults.set(roundsPerSet, forKey: "roundsPerSet") } }

    private init() {
        defaults.register(defaults: [
            "useCamera": true,
            "useScreen": true,
            "useMic": true,
            "phoneSensitivity": 0.5,
            "headDownCountsAsPhone": true,
            "nudgeDelay": 20.0,
            "nudgeSound": true,
            "keepHistory": true,
            "breakMinutes": 5.0,
            "alwaysStudy": "",
            "alwaysDistracting": "",
            "strictness": Strictness.firm.rawValue,
            "studyStyle": StudyStyle.both.rawValue,
            "dailyGoalMinutes": 180.0,
            "breakReminderMinutes": 50.0,
            "goalMinutes": 50.0,
            "phoneReminders": false,
            "phoneHandle": "",
            "runShortcuts": false,
            "startShortcut": "Study Start",
            "endShortcut": "Study End",
            "appearance": AppearanceMode.system.rawValue,
            "accent": AccentChoice.ember.rawValue,
            "timerFont": TimerFont.rounded.rawValue,
            "focusBackground": FocusBackground.dark.rawValue,
            "menuBarTime": true,
            "pomodoro": false,
            "pomodoroMinutes": 25.0,
            "shortBreakMinutes": 5.0,
            "longBreakMinutes": 15.0,
            "roundsPerSet": 4,
        ])
        useCamera = defaults.bool(forKey: "useCamera")
        useScreen = defaults.bool(forKey: "useScreen")
        useMic = defaults.bool(forKey: "useMic")
        phoneSensitivity = defaults.double(forKey: "phoneSensitivity")
        headDownCountsAsPhone = defaults.bool(forKey: "headDownCountsAsPhone")
        nudgeDelay = defaults.double(forKey: "nudgeDelay")
        nudgeSound = defaults.bool(forKey: "nudgeSound")
        keepHistory = defaults.bool(forKey: "keepHistory")
        breakMinutes = defaults.double(forKey: "breakMinutes")
        alwaysStudy = defaults.string(forKey: "alwaysStudy") ?? ""
        alwaysDistracting = defaults.string(forKey: "alwaysDistracting") ?? ""
        breakReminderMinutes = defaults.double(forKey: "breakReminderMinutes")
        dailyGoalMinutes = defaults.double(forKey: "dailyGoalMinutes")
        studyStyle = StudyStyle(rawValue: defaults.string(forKey: "studyStyle") ?? "") ?? .both
        strictness = Strictness(rawValue: defaults.string(forKey: "strictness") ?? "") ?? .firm
        goalMinutes = defaults.double(forKey: "goalMinutes")
        phoneReminders = defaults.bool(forKey: "phoneReminders")
        phoneHandle = defaults.string(forKey: "phoneHandle") ?? ""
        runShortcuts = defaults.bool(forKey: "runShortcuts")
        startShortcut = defaults.string(forKey: "startShortcut") ?? ""
        endShortcut = defaults.string(forKey: "endShortcut") ?? ""
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        accent = AccentChoice(rawValue: defaults.string(forKey: "accent") ?? "") ?? .ember
        timerFont = TimerFont(rawValue: defaults.string(forKey: "timerFont") ?? "") ?? .rounded
        focusBackground = FocusBackground(rawValue: defaults.string(forKey: "focusBackground") ?? "") ?? .dark
        menuBarTime = defaults.bool(forKey: "menuBarTime")
        pomodoro = defaults.bool(forKey: "pomodoro")
        pomodoroMinutes = defaults.double(forKey: "pomodoroMinutes")
        shortBreakMinutes = defaults.double(forKey: "shortBreakMinutes")
        longBreakMinutes = defaults.double(forKey: "longBreakMinutes")
        roundsPerSet = max(2, defaults.integer(forKey: "roundsPerSet"))
        ThemeState.shared.accent = accent
        ThemeState.shared.timerFont = timerFont
    }

    /// Light, dark or the system setting, for every window including the menu bar popover.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    var policy: InterventionPolicy { InterventionPolicy.of(strictness) }
    var phoneRemindersReady: Bool { phoneReminders && !phoneHandle.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Detector confidence needed to count a phone sighting.
    var phoneThreshold: Float { Float(0.6 - 0.4 * phoneSensitivity) }

    var alwaysStudyEntries: [String] { Self.entries(alwaysStudy) }
    var alwaysDistractingEntries: [String] { Self.entries(alwaysDistracting) }

    /// Moves `entry` into the study or distraction list (removing it from the other).
    func remember(_ entry: String, asStudy: Bool) {
        let e = entry.lowercased()
        var study = alwaysStudyEntries.filter { $0 != e }
        var distracting = alwaysDistractingEntries.filter { $0 != e }
        if asStudy { study.append(e) } else { distracting.append(e) }
        alwaysStudy = study.joined(separator: "\n")
        alwaysDistracting = distracting.joined(separator: "\n")
    }

    private static func entries(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Accent colours. Ember matches the app icon.
enum AccentChoice: String, CaseIterable, Identifiable {
    case ember, blue, purple, green, pink, graphite
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var hex: String {
        switch self {
        case .ember: return "#EF4F2C"
        case .blue: return "#2F7CF6"
        case .purple: return "#7C5CFC"
        case .green: return "#2F9E5B"
        case .pink: return "#E64980"
        case .graphite: return "#6E6E76"
        }
    }
    var color: Color { Color(hex: hex) }
}

enum TimerFont: String, CaseIterable, Identifiable {
    case rounded, monospaced, standard
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        case .standard: return .default
        }
    }
}

enum FocusBackground: String, CaseIterable, Identifiable {
    case dark, black, subject
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: return "Dark"
        case .black: return "Black"
        case .subject: return "Subject colour"
        }
    }
}
