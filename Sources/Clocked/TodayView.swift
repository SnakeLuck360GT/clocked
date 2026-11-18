import SwiftUI

extension SessionController {
    /// The time a big timer shows. Outside a session it's always today's total.
    func timerValue(_ shows: TimerShows) -> TimeInterval {
        guard phase == .running || phase.isBreak else { return todayTotal }
        switch shows {
        case .today: return todayTotal
        case .session: return focusedTime
        case .remaining: return studyGoal > 0 ? max(0, studyGoal - focusedTime) : focusedTime
        }
    }
}

/// 04:12:00, or 4h 12m with seconds turned off in Appearance.
func formatTimer(_ t: TimeInterval) -> String {
    if AppSettings.shared.showSeconds { return formatHMS(t) }
    let m = Int(max(0, t)) / 60
    return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
}

/// Today: the study ring, subjects with play buttons, and the session controls.
struct TodayPane: View {
    @EnvironmentObject var c: SessionController
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                TodayHero()
                    .padding(.vertical, Theme.mac ? Theme.Space.l : Theme.Space.xl)

                Card(padding: Theme.mac ? 8 : 12) { SubjectList() }

                switch c.phase {
                case .idle, .finished:
                    // Mac style: these live in the window toolbar.
                    if !Theme.mac { Card { SessionOptions() } }
                    if c.phase == .finished, let s = c.lastSummary {
                        Card {
                            VStack(alignment: .leading, spacing: Theme.Space.m) {
                                CardTitle("Last Session")
                                SummaryGrid(summary: s)
                            }
                        }
                    }
                case .running, .onBreak:
                    Card { RunningControls() }
                    if c.phase == .running {
                        if settings.useScreen { Card { ActivityCard() } }
                        if settings.useCamera || settings.useMic { Card { SensorsCard() } }
                    }
                }
            }
            .frame(maxWidth: Theme.mac ? 620 : 680)
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Today")
        .navigationSubtitle(Theme.mac ? Date().formatted(.dateTime.weekday(.wide).day().month(.wide)) : "")
        .toolbar { TodayToolbar() }
    }
}

/// Mac style: session settings before a session, and its controls during one, in the window toolbar.
struct TodayToolbar: ToolbarContent {
    @EnvironmentObject var c: SessionController
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        if settings.interfaceStyle == .mac {
            switch c.phase {
            case .idle, .finished:
                ToolbarItemGroup {
                    Picker("Goal", selection: $settings.goalMinutes) {
                        Text("No goal").tag(0.0)
                        ForEach([25.0, 50, 90, 120], id: \.self) { Text("\(Int($0)) min goal").tag($0) }
                    }
                    .help("Minutes of actual study for this session. Distractions extend it.")
                    Picker("Strictness", selection: $settings.strictness) {
                        ForEach(Strictness.allCases) { Text($0.title).tag($0) }
                    }
                    .help(settings.strictness.summary)
                    Picker("Style", selection: $settings.studyStyle) {
                        Text("Typing").tag(StudyStyle.typing)
                        Text("Paper").tag(StudyStyle.writing)
                        Text("Typing & paper").tag(StudyStyle.both)
                    }
                    .help(settings.studyStyle.help)
                }
                ToolbarItemGroup {
                    Toggle("Camera", systemImage: "camera", isOn: $settings.useCamera).help("Camera")
                    Toggle("Microphone", systemImage: "mic", isOn: $settings.useMic).help("Microphone")
                    Toggle("Active app and tab", systemImage: "macwindow", isOn: $settings.useScreen).help("Active app and tab")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Start", systemImage: "play.fill") { c.start() }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent)
                        .help("Start a session (\(c.currentSubject?.name ?? "no subject"))")
                }
            case .running, .onBreak:
                ToolbarItemGroup {
                    Button("Focus View", systemImage: "arrow.up.left.and.arrow.down.right") { openWindow(id: "focus") }
                        .help("Focus View (⌃⌘F)")
                    if c.phase.isBreak {
                        Button("Resume", systemImage: "play.fill") { c.resume() }
                    } else {
                        Button("Break", systemImage: "cup.and.saucer") { c.takeBreak() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("End Session", systemImage: "stop.fill") { c.requestEnd() }
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }
}

// MARK: - Hero

/// Today's study time inside a ring made of one coloured arc per subject, filling towards the daily goal
/// (YPT-style). Greys out while the study clock is paused.
struct TodayHero: View {
    @EnvironmentObject var c: SessionController
    @ObservedObject var settings = AppSettings.shared
    var compact = false

    var body: some View {
        // Re-evaluated every minute so the date and total roll over at midnight even when idle.
        TimelineView(.everyMinute) { _ in content }
    }

    private var isActive: Bool { c.phase == .running || c.phase.isBreak }
    private var dailyGoal: TimeInterval { max(settings.dailyGoalMinutes, 1) * 60 }
    private var paused: Bool { c.studyClockPaused || c.phase.isBreak }

    private var segments: [SegmentedRing.Segment] {
        let totals = c.studyLog.record(on: Date()).totals
        var list = c.subjects.subjects.compactMap { s -> SegmentedRing.Segment? in
            guard let t = totals[s.id], t > 0 else { return nil }
            return .init(id: s.id, color: s.color, fraction: t / dailyGoal)
        }
        if let other = totals[StudyLog.unassigned], other > 0 { list.append(.init(id: "none", color: .gray, fraction: other / dailyGoal)) }
        return list
    }

    private var statusLine: (String, Color) {
        if c.phase.isBreak { return ("On break", .blue) }
        switch c.status {
        case .phone: return ("Paused · Phone", .secondary)
        case .offTask: return ("Paused · Off task", .secondary)
        case .away: return ("Paused · Away", .secondary)
        default:
            if c.suspecting { return ("Checking… (\(formatDuration(c.heldTime)) on hold)", .secondary) }
            return (c.currentSubject?.name ?? "Studying", c.currentSubject?.color ?? Theme.accent)
        }
    }

    /// Today's total, or (YPT-style) this session's time or the time left in it.
    private var shows: TimerShows { isActive ? settings.timerShows : .today }
    private var subjectColor: Color { c.currentSubject?.color ?? Theme.accent }

    private var label: String {
        switch shows {
        // Mac style shows the date as the window subtitle.
        case .today: return Theme.mac && !compact ? "Today" : Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .session: return "This session"
        case .remaining: return c.studyGoal > 0 ? "Left this session" : "This session"
        }
    }

    /// The ring: today's subjects towards the daily goal, or this session (or Pomodoro round) towards its goal.
    @ViewBuilder private func ring(_ lineWidth: CGFloat) -> some View {
        if shows == .today {
            SegmentedRing(segments: segments, lineWidth: lineWidth, dimmed: paused)
        } else {
            let done = settings.pomodoro ? c.pomodoroFocus / (settings.pomodoroMinutes * 60)
                : c.studyGoal > 0 ? c.focusedTime / c.studyGoal : 0
            // Counting down drains the ring; counting up fills it.
            let progress = shows == .remaining ? 1 - min(done, 1) : done
            ProgressRing(progress: progress, color: paused ? .gray : subjectColor, lineWidth: lineWidth)
        }
    }

    private var content: some View {
        let mac = Theme.mac
        let diameter: CGFloat = compact ? 150 : (mac ? 220 : 240)
        let percent = Int((c.todayTotal / dailyGoal * 100).rounded())
        return VStack(spacing: compact ? Theme.Space.s : Theme.Space.m) {
            ZStack {
                ring(mac ? (compact ? 7 : 10) : (compact ? 10 : 18))
                VStack(spacing: compact ? 2 : 4) {
                    Text(label)
                        .font(compact ? .caption2 : .callout).foregroundStyle(.secondary)
                    Text(formatTimer(c.timerValue(shows)))
                        .font(.system(size: mac ? (compact ? 30 : 48) : (compact ? 28 : 46), weight: mac ? .light : .medium,
                                      design: Theme.timerDesign).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(paused ? Color.secondary : Color.primary)
                        .contentTransition(.numericText())
                    if isActive, mac {
                        HStack(spacing: 5) {
                            Circle().fill(statusLine.1).frame(width: 7, height: 7)
                            Text(statusLine.0).foregroundStyle(.secondary)
                        }
                        .font(compact ? .caption : .callout)
                        .lineLimit(1)
                    } else if isActive {
                        Text(statusLine.0)
                            .font((compact ? Font.caption : .callout).weight(.semibold))
                            .foregroundStyle(statusLine.1)
                            .lineLimit(1)
                    } else {
                        Text("\(percent)% of \(formatHours(dailyGoal)) goal")
                            .font(compact ? .caption2 : .callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, compact ? 16 : 28)
            }
            .frame(width: diameter, height: diameter)

            if isActive, settings.pomodoro {
                PomodoroProgress(width: diameter)
            } else if isActive, shows != .today {
                Text(c.studyGoal > 0 && !c.goalReached && shows == .session
                     ? "Today \(formatTimer(c.todayTotal)) · \(Int(((c.studyGoal - c.focusedTime) / 60).rounded(.up))) min to go"
                     : "Today \(formatTimer(c.todayTotal))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if isActive, c.studyGoal > 0 {
                VStack(spacing: 4) {
                    ProgressBar(progress: c.focusedTime / c.studyGoal, color: c.currentSubject?.color ?? Theme.accent)
                        .frame(width: diameter)
                    Text(c.goalReached ? "Session goal reached" : "\(Int(((c.studyGoal - c.focusedTime) / 60).rounded(.up))) min to go")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Pomodoro: the current round's progress (or the break countdown), with a dot per round in the set.
struct PomodoroProgress: View {
    @EnvironmentObject var c: SessionController
    @ObservedObject var settings = AppSettings.shared
    var width: CGFloat
    var onDark = false

    private var secondary: Color { onDark ? .white.opacity(0.6) : .secondary }
    private var color: Color { c.currentSubject?.color ?? Theme.accent }
    /// Dots filled in the current set; all of them during the long break that ends it.
    private var done: Int { c.longBreak && c.phase.isBreak ? settings.roundsPerSet : c.pomodoroRounds % settings.roundsPerSet }

    var body: some View {
        VStack(spacing: onDark ? 10 : 4) {
            if onDark {
                // Focus View: the big clock already counts down, so just say which round.
                Text(c.phase.isBreak ? (c.longBreak ? "Long break" : "Break") : "Round \(c.pomodoroRounds % settings.roundsPerSet + 1) of \(settings.roundsPerSet)")
            } else if case .onBreak(let until) = c.phase {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(c.longBreak ? "Long break" : "Break") · \(formatClock(max(0, until.timeIntervalSince(context.date)))) left")
                }
            } else {
                ProgressBar(progress: c.pomodoroFocus / (settings.pomodoroMinutes * 60), color: color, height: onDark ? 8 : 6)
                    .frame(width: width)
                Text("Round \(c.pomodoroRounds + 1) · \(Int(((settings.pomodoroMinutes * 60 - c.pomodoroFocus) / 60).rounded(.up))) min left")
            }
            HStack(spacing: onDark ? 8 : 5) {
                ForEach(0..<settings.roundsPerSet, id: \.self) { i in
                    Circle()
                        .fill(i < done ? color : (onDark ? Color.white.opacity(0.2) : Theme.track))
                        .frame(width: onDark ? 9 : 6, height: onDark ? 9 : 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(done) of \(settings.roundsPerSet) rounds done")
        }
        .font(onDark ? .title3 : .caption)
        .foregroundStyle(secondary)
        .monospacedDigit()
    }
}

// MARK: - Subjects

/// Subjects: play button, name, exam countdown, today's time.
struct SubjectList: View {
    @EnvironmentObject var c: SessionController
    var compact = false
    var showsAdd = true
    @State private var adding = false
    @State private var newName = ""
    @State private var renaming: Subject?
    @State private var renameText = ""
    @State private var editingExam: Subject?
    @State private var examDate = Date()

    private var mac: Bool { Theme.mac }
    private var rowHeight: CGFloat { mac ? (compact ? 34 : 40) : (compact ? 40 : 52) }
    private var dividerInset: CGFloat { mac ? (compact ? 40 : 48) : (compact ? 44 : 60) }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(c.subjects.subjects.enumerated()), id: \.element.id) { index, subject in
                if index > 0 { Divider().padding(.leading, dividerInset) }
                row(subject)
            }
            if showsAdd {
                if !c.subjects.subjects.isEmpty { Divider().padding(.leading, dividerInset) }
                addRow
            }
        }
        .sheet(item: $editingExam) { subject in examSheet(subject) }
        .alert("Rename Subject", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if var s = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    s.name = renameText.trimmingCharacters(in: .whitespaces)
                    c.subjects.update(s)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ subject: Subject) -> some View {
        let isCurrent = subject.id == c.currentSubjectID && (c.phase == .running || c.phase.isBreak)
        let time = c.todayTime(for: subject)
        return HStack(spacing: Theme.Space.m) {
            SubjectPlayButton(color: subject.color, isRunning: isCurrent, size: mac ? (compact ? 22 : 26) : (compact ? 28 : 36)) {
                if isCurrent { c.requestEnd() } else { c.start(subject: subject) }
            }
            .accessibilityLabel(isCurrent ? "Stop \(subject.name)" : "Start \(subject.name)")
            .help(isCurrent ? "End session" : (c.phase == .running ? "Switch to \(subject.name)" : "Start \(subject.name)"))
            if let symbol = subject.symbol {
                Image(systemName: symbol).foregroundStyle(subject.color).frame(width: 18)
            }
            Text(subject.name)
                .font(mac ? (isCurrent ? .body.weight(.semibold) : .body) : (compact ? .body : .body.weight(.medium)))
                .lineLimit(1)
            if let days = subject.daysToExam {
                Chip(text: days == 0 ? "D-Day" : "D-\(days)", color: days <= 7 ? .red : .secondary)
                    .help("Exam on \(subject.examDate!.formatted(date: .long, time: .omitted))")
            }
            Spacer(minLength: Theme.Space.s)
            Text(formatHMS(time))
                .font((compact || mac ? Font.body : .title3).monospacedDigit())
                .foregroundStyle(isCurrent ? Color.primary : (time > 0 ? Color.secondary : Color.secondary.opacity(0.5)))
        }
        .frame(height: rowHeight)
        .padding(.horizontal, Theme.Space.s)
        .background(isCurrent ? (mac ? Color.primary.opacity(0.05) : subject.color.opacity(0.14)) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename…") { renameText = subject.name; renaming = subject }
            Button(subject.examDate == nil ? "Set Exam Date…" : "Change Exam Date…") {
                examDate = subject.examDate ?? Calendar.current.date(byAdding: .day, value: 14, to: Date())!
                editingExam = subject
            }
            Picker("Color", selection: Binding(
                get: { subject.colorHex },
                set: { var s = subject; s.colorHex = $0; c.subjects.update(s) })) {
                ForEach(Array(zip(Subject.palette, Subject.paletteNames)), id: \.0) { hex, name in
                    Text(name).tag(hex)
                }
            }
            .pickerStyle(.inline)
            SubjectIconMenu(subject: subject)
            Divider()
            Button("Delete", role: .destructive) { c.subjects.delete(subject) }
                .disabled(isCurrent)
        }
    }

    @ViewBuilder private var addRow: some View {
        if adding || c.subjects.subjects.isEmpty {
            HStack(spacing: Theme.Space.s) {
                TextField("", text: $newName, prompt: Text(c.subjects.subjects.isEmpty ? "Add your first subject, e.g. Chemistry" : "Subject name"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                if !c.subjects.subjects.isEmpty {
                    Button("Cancel") { adding = false; newName = "" }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: rowHeight)
        } else {
            Button { adding = true } label: {
                Label("Add Subject", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: mac ? (compact ? 30 : 34) : (compact ? 36 : 44))
        }
    }

    private func examSheet(_ subject: Subject) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Exam Date for \(subject.name)").font(.headline)
            DatePicker("Exam date", selection: $examDate, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if subject.examDate != nil {
                    Button("Remove Date", role: .destructive) {
                        var s = subject; s.examDate = nil; c.subjects.update(s); editingExam = nil
                    }
                }
                Spacer()
                Button("Cancel") { editingExam = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { var s = subject; s.examDate = examDate; c.subjects.update(s); editingExam = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        c.subjects.add(name: name)
        newName = ""
        adding = false
    }
}

// MARK: - Session options and controls

/// Goal, strictness and study style as compact menus, plus the three sensor switches.
struct SessionOptions: View {
    @ObservedObject var settings = AppSettings.shared
    var compact = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) { menus; Spacer(minLength: Theme.Space.s); sensors }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.m) { menus }
                sensors
            }
        }
    }

    @ViewBuilder private var menus: some View {
        GoalPicker()
        Picker("Strictness", selection: $settings.strictness) {
            ForEach(Strictness.allCases) { Text($0.title).tag($0) }
        }
        .fixedSize()
        .help(settings.strictness.summary)
        StudyStylePicker()
    }

    @ViewBuilder private var sensors: some View {
        if !compact {
            HStack(spacing: 6) {
                SensorToggle(symbol: "camera.fill", label: "Camera", isOn: $settings.useCamera)
                SensorToggle(symbol: "mic.fill", label: "Microphone", isOn: $settings.useMic)
                SensorToggle(symbol: "macwindow", label: "Active app and tab", isOn: $settings.useScreen)
            }
        }
    }
}

private struct SensorToggle: View {
    let symbol: String
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) { Image(systemName: symbol).frame(width: 18) }
            .toggleStyle(.button)
            .help("\(label): \(isOn ? "on" : "off")")
            .accessibilityLabel(label)
    }
}

/// Status, the session's controls and its numbers.
struct RunningControls: View {
    @EnvironmentObject var c: SessionController
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if Theme.mac {
                // The buttons are in the toolbar.
                HStack(spacing: Theme.Space.s) {
                    StatusBadge(status: c.phase.isBreak ? .onBreak : c.status)
                    Spacer()
                    if case .onBreak(let until) = c.phase {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Break ends in \(formatClock(max(0, until.timeIntervalSince(context.date))))")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
            HStack(spacing: Theme.Space.s) {
                StatusBadge(status: c.status)
                Spacer()
                Button { openWindow(id: "focus") } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Focus View (⌃⌘F)")
                    .accessibilityLabel("Focus View")
                if case .onBreak(let until) = c.phase {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Break \(formatClock(max(0, until.timeIntervalSince(context.date))))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button("Resume") { c.resume() }
                } else {
                    Button("Break") { c.takeBreak() }
                }
                Button("End Session") { c.requestEnd() }
            }
            }
            if c.status == .phone, !c.evidence.explanation.isEmpty {
                Text(c.evidence.explanation).font(.callout).foregroundStyle(.secondary)
            }
            if Theme.mac { Divider() }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 5), spacing: Theme.Space.s) {
                StatTile(title: "Session", value: formatClock(c.elapsed))
                StatTile(title: "Phone", value: formatDuration(c.phoneTime))
                StatTile(title: "Off task", value: formatDuration(c.offTaskTime))
                StatTile(title: "Away", value: formatDuration(c.awayTime))
                StatTile(title: "Nudges", value: "\(c.nudges)")
            }
            HStack(spacing: Theme.Space.l) {
                StudyStylePicker()
                if settings.useCamera {
                    Toggle("Working on paper", isOn: Binding(
                        get: { (c.paperModeUntil ?? .distantPast) > .now },
                        set: { c.setPaperMode($0) }))
                        .toggleStyle(.checkbox)
                        .help("Looking down won't count for 25 minutes.")
                }
                Spacer()
            }
        }
    }
}

/// The app or tab in front and how it was classified.
struct ActivityCard: View {
    @EnvironmentObject var c: SessionController
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            CardTitle("Current Activity")
            if let a = c.activity {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.domain ?? a.appName).font(.body.weight(.medium))
                        if let title = a.title, !title.isEmpty {
                            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    if let j = c.judgement {
                        Chip(text: j.verdict.label, color: j.verdict.color).help("\(j.reason) (\(j.source.rawValue))")
                    } else {
                        Text("Checking").font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if let j = c.judgement { Text(j.reason).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Mark as Study") { c.markCurrent(as: .study) }
                    Button("Mark as Distraction") { c.markCurrent(as: .distraction) }
                }
                .controlSize(.small)
            } else {
                Text("Nothing in front yet.").foregroundStyle(.secondary)
            }
            if let problem = c.browserProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Automation Settings") { openPrivacyPane("Privacy_Automation") }.controlSize(.small)
            }
        }
    }
}

struct SensorsCard: View {
    @EnvironmentObject var c: SessionController
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            CardTitle("Sensors")
            if settings.useCamera { SensorRow(name: "Camera", state: c.cameraState, pane: "Privacy_Camera") }
            if settings.useMic { SensorRow(name: "Microphone", state: c.micState, pane: "Privacy_Microphone") }
            if settings.useCamera, c.cameraState == .on, !c.postureLearned {
                Text(c.cameraMovedAt != nil ? "Camera moved. Relearning your normal posture." : "Learning your normal posture.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct StudyStylePicker: View {
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Picker("Style", selection: $settings.studyStyle) {
            ForEach(StudyStyle.allCases) { Text($0.title).tag($0) }
        }
        .fixedSize()
        .help(settings.studyStyle.help)
    }
}

struct GoalPicker: View {
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Picker("Goal", selection: $settings.goalMinutes) {
            Text("None").tag(0.0)
            ForEach([25.0, 50, 90, 120], id: \.self) { Text("\(Int($0)) min").tag($0) }
        }
        .fixedSize()
        .help("Minutes of actual study for this session. Distractions extend it.")
    }
}

/// Context menu: an icon for the subject, shown instead of (or next to) its coloured dot.
struct SubjectIconMenu: View {
    @EnvironmentObject var c: SessionController
    let subject: Subject
    var body: some View {
        Picker("Icon", selection: Binding(
            get: { subject.symbol ?? "" },
            set: { var s = subject; s.symbol = $0.isEmpty ? nil : $0; c.subjects.update(s) })) {
            Text("None").tag("")
            ForEach(SubjectSymbols.all, id: \.symbol) { item in
                Label(item.name, systemImage: item.symbol).tag(item.symbol)
            }
        }
    }
}
