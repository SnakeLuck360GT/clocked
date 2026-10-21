import AppKit
import AVFoundation
import Combine

enum FocusStatus: Equatable {
    case idle, focused, neutral, phone, offTask(String), away, onBreak

    var isDistracted: Bool {
        switch self {
        case .phone, .offTask: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .focused: return "Focused"
        case .neutral: return "Studying"
        case .phone: return "Phone"
        case .offTask(let label): return "Off task: \(label)"
        case .away: return "Away"
        case .onBreak: return "On break"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "book.closed"
        case .focused: return "checkmark.circle.fill"
        case .neutral: return "book.fill"
        case .phone: return "iphone.gen3"
        case .offTask: return "exclamationmark.triangle.fill"
        case .away: return "figure.walk"
        case .onBreak: return "cup.and.saucer.fill"
        }
    }
}

enum SensorState: Equatable {
    case off, starting, on, denied, failed(String)
}

/// Runs a study session: turns sensors on only while studying, decides your status each second,
/// and nudges you after a stretch of distraction. Everything lives in memory; only the final totals can be saved.
@MainActor
final class SessionController: ObservableObject {
    enum Phase: Equatable { case idle, running, onBreak(until: Date), finished }

    struct CalibrationState: Equatable {
        var kind: PostureKind
        var countdown: Int
        var progress: Double
    }

    @Published var phase: Phase = .idle
    @Published var topic: String = UserDefaults.standard.string(forKey: "lastTopic") ?? ""
    @Published var status: FocusStatus = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var focusedTime: TimeInterval = 0
    @Published var phoneTime: TimeInterval = 0
    @Published var offTaskTime: TimeInterval = 0
    @Published var awayTime: TimeInterval = 0
    @Published var nudges = 0
    @Published var activity: ActivitySnapshot?
    @Published var judgement: Judgement?
    @Published var cameraState: SensorState = .off
    @Published var micState: SensorState = .off
    @Published var lastSample: CameraSample?
    @Published var lastAudio: AudioReading?
    @Published var browserProblem: String?
    @Published var lastSummary: SessionSummary?
    @Published var sensorTestRunning = false
    /// The running "are you on your phone?" evidence, with the reasons behind it.
    @Published var evidence = PhoneEvidence()
    @Published var posture: PostureVerdict = .unknown
    @Published var cues = FocusCues()
    @Published var postureProfile = PostureProfile.load()
    @Published var paperModeUntil: Date?
    @Published var calibration: CalibrationState?
    @Published var calibrationMessage: String?
    /// Shown briefly after the camera angle changes and your normal posture is being re-learned.
    @Published var cameraMovedAt: Date?

    let settings = AppSettings.shared
    let history = HistoryStore()
    let learner = Learner()
    /// Study groups (optional, off until you connect a backend and join a group).
    let groupSync = GroupSync()
    /// The learned network's latest estimate (nil until it has earned a say).
    @Published var learnedProbability: Float?
    var sessionEpisode: Int32 = 0
    var lastAutoLabel = Date.distantPast
    var lastMacAloud = false
    var calibrationInputs: [(sample: CameraSample, keys: Int, sinceMouse: Double, sinceInput: Double)] = []
    let subjects = SubjectStore()
    let studyLog = StudyLog()
    /// The subject being timed (topic follows its name).
    @Published var currentSubjectID: String? = UserDefaults.standard.string(forKey: "lastSubject")
    var ticksSinceSave = 0
    var storeObservers: [AnyCancellable] = []
    let judge = RelevanceJudge()
    let camera = CameraMonitor()
    let audio = AudioMonitor()
    let activityMonitor = ActivityMonitor()
    let hud = NudgeHUD()
    let curtain = FocusCurtain()
    let scripts = AppleScriptRunner()

    // Escalation while you stay distracted (see InterventionPolicy).
    /// Strictness is fixed when a session starts, so it can't be loosened halfway through.
    var policy = InterventionPolicy.of(.firm)
    var episodeNudged = false
    var lastPing = Date.distantPast
    var pingCount = 0
    var curtainSnoozedUntil = Date.distantPast
    var backSince: Date?
    var enforcementWarned: String?
    var enforced: String?
    var enforcementWarnedAt = Date.distantPast
    @Published var goalReached = false
    /// Unbroken focus so far (resets when distracted or away).
    @Published var focusStreak: TimeInterval = 0
    var breakSuggested = false
    /// Pomodoro: rounds finished this session, and focused time in the current round.
    @Published var pomodoroRounds = 0
    @Published var pomodoroFocus: TimeInterval = 0
    /// Whether the current break is a Pomodoro long break.
    @Published var longBreak = false
    @Published var reminderStatus: String?
    @Published var shortcutStatus: String?

    var ticker: Timer?
    var lastTick = Date()
    /// System uptime stops while the Mac sleeps, so it measures awake time only.
    var lastTickUptime = ProcessInfo.processInfo.systemUptime
    var sessionStart = Date()
    var lastPersonSeen: Date?
    var lastSampleAt: Date?
    var cameraStartedAt = Date()
    var typingBaseline = TypingBaseline()
    var expressionBaseline = ExpressionBaseline()
    @Published var smiling = false
    var recentPostures: [(time: Date, features: PostureFeatures, verdict: PostureVerdict)] = []
    var keyHistory: [(time: Date, count: UInt32)] = []
    var distractedSince: Date?
    var lastNudge = Date.distantPast
    var phoneSnoozedUntil = Date.distantPast
    /// After a phone nudge, if you simply put the phone away (no "false alarm"), we learn from it.
    var pendingPhoneLesson: (time: Date, postures: [PostureFeatures], features: [[Float]])?
    /// The profile before the last automatic lesson, so a late "Writing Notes" / "Not My Phone" can undo it.
    var undoLesson: (time: Date, profile: PostureProfile, gain: Double, episode: Int32?, nudgeTime: Date)?
    /// When the last phone nudge was shown (lessons are tied to it).
    var lastPhoneNudge: Date?
    /// Frames from the countdown before a Paper/Phone recording, used as that sitting's "looking at the screen".
    var calibrationReferenceSamples: [PostureFeatures] = []
    /// Bumped whenever sensors stop, so a permission prompt answered later can't switch on a stale sensor.
    var sensorGeneration = 0
    var distractionTally: [String: TimeInterval] = [:]
    var judgeTask: Task<Void, Never>?
    var testTask: Task<Void, Never>?
    var calibrationTask: Task<Void, Never>?
    /// Teach Phone Detection (see SessionController+Teaching).
    @Published var teaching: TeachingState?
    @Published var teachingMessage: String?
    var teachingTask: Task<Void, Never>?
    var teachingSkip = false
    let voice = AVSpeechSynthesizer()
    var calibrationSamples: [PostureFeatures] = []
    var calibrationCapturing = false
    var historyObserver: AnyCancellable?

    /// Personal sensitivity learned from your corrections (0.7 – 1.5).
    var phoneGain: Double {
        get { UserDefaults.standard.object(forKey: "phoneGain") as? Double ?? 1.0 }
        set { UserDefaults.standard.set(min(max(newValue, 0.7), 1.5), forKey: "phoneGain") }
    }

    var hasObjectDetector: Bool { camera.hasObjectDetector }
    var postureLearned: Bool { typingBaseline.isReady || postureProfile.postures.count >= 2 }

    /// Share of the whole session spent focused (time away counts against it).
    var focusScore: Int {
        min(100, Int((focusedTime / max(1, elapsed) * 100).rounded()))
    }

    var menuSymbol: String {
        switch phase {
        case .idle, .finished: return "book.closed"
        case .onBreak: return "cup.and.saucer"
        case .running: return status.symbol
        }
    }

    var sensorsWanted: Bool { phase == .running || sensorTestRunning || calibration != nil }

    /// For the app delegate (quit handling).
    static weak var current: SessionController?

    init() {
        defer { Self.current = self }
        camera.onSample = { [weak self] sample in
            Task { @MainActor in self?.handle(sample) }
        }
        audio.onReading = { [weak self] reading in
            Task { @MainActor in
                guard let self, self.micState == .on else { return }
                self.lastAudio = reading
            }
        }
        // Let views that watch the controller refresh when history changes.
        historyObserver = history.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        storeObservers = [
            learner.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
            groupSync.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
            subjects.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
            studyLog.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
        ]
        groupSync.snapshot = { [unowned self] in self.groupSnapshot() }
        groupSync.startSyncing()
        // Quitting mid-session ends it properly, so the session is saved.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.end()
                self?.studyLog.saveIfNeeded()
            }
        }
        // Time asleep never counts.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastTick = Date()
                self?.lastTickUptime = ProcessInfo.processInfo.systemUptime
            }
        }
        activityMonitor.onChange = { [weak self] snapshot in self?.activityChanged(snapshot) }
        activityMonitor.onProblem = { [weak self] problem in
            if self?.browserProblem != problem { self?.browserProblem = problem }
        }
    }

    /// Which section of the main window is showing (so ⌘, and the menu-bar popover can jump to Settings).
    @Published var selectedPane: Pane? = .today

    /// Latest analysed frame with geometry, only while the Developer View is open.
    @Published var debugFrame: DebugFrame?
    /// The learned network's per-input push for the current second (Developer View).
    @Published var lastAttribution: [Float] = []
    @Published var lastFeatures: [Float] = []
    var developerViewOpen = false {
        didSet {
            camera.debugCapture = developerViewOpen
            if !developerViewOpen { debugFrame = nil }
        }
    }
    var postureVotes: (votes: [TypingBaseline.Vote], acceptedAsScreen: Bool, score: Double?, faceHidden: Bool)? {
        lastSample?.posture.map { typingBaseline.explain($0) }
    }

    /// Evidence is past half the threshold: study time is being held back until it's clear either way.
    @Published var suspecting = false
    /// Study time held back while suspecting (becomes phone time on a flag, study time if it fades).
    @Published var heldTime: TimeInterval = 0
    var ledger = SuspicionLedger()

    // Escalation, learning and sensor state used by the extensions in SessionController+*.swift.
    var sessionGoal: TimeInterval = 0
    var endShortcutDone: (() -> Void)?
    var remindersSent = 0
    var reminderInFlight = false

    // MARK: - Session lifecycle

    /// Starts timing a subject (or switches to it if a session is already running).
    func start(subject: Subject) {
        if phase == .running || isOnBreak {
            switchSubject(to: subject)
            return
        }
        select(subject)
        start()
    }

    func switchSubject(to subject: Subject) {
        guard subject.id != currentSubjectID else { return }
        select(subject)
        judge.resetKeepingOverrides()
        judgement = nil
        if let activity { activityChanged(activity) }
    }

    func select(_ subject: Subject) {
        currentSubjectID = subject.id
        topic = subject.name
        UserDefaults.standard.set(subject.id, forKey: "lastSubject")
    }

    var currentSubject: Subject? { subjects.subject(id: currentSubjectID) }
    var todayTotal: TimeInterval { studyLog.total(on: Date()) }
    func todayTime(for subject: Subject) -> TimeInterval { studyLog.record(on: Date()).totals[subject.id] ?? 0 }

    func start() {
        guard phase == .idle || phase == .finished, calibration == nil else { return }
        if let subject = currentSubject { topic = subject.name } else { currentSubjectID = nil }
        ticker?.invalidate()
        stopSensorTest()
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        topic = trimmed
        if settings.keepHistory { UserDefaults.standard.set(trimmed, forKey: "lastTopic") }

        elapsed = 0; focusedTime = 0; phoneTime = 0; offTaskTime = 0; awayTime = 0; nudges = 0
        distractionTally = [:]
        distractedSince = nil
        lastNudge = .distantPast
        policy = settings.policy
        ledger = SuspicionLedger()
        suspecting = false
        heldTime = 0
        phoneGain = 1 + (phoneGain - 1) / 2
        focusStreak = 0
        breakSuggested = false
        pomodoroRounds = 0
        pomodoroFocus = 0
        longBreak = false
        sessionEpisode = learner.store.newEpisode()
        sessionGoal = settings.goalMinutes * 60
        remindersSent = 0
        resetEscalation()
        goalReached = false
        resetCorrections()
        evidence.reset()
        typingBaseline.reset(); expressionBaseline.reset()
        recentPostures = []
        keyHistory = []
        judge.reset()
        judge.prewarm()
        sessionStart = Date()
        lastTick = Date()
        phase = .running
        status = .neutral
        startSensors()

        ticker = makeTicker()
        if settings.runShortcuts { runShortcut(settings.startShortcut) }
    }

    /// Starts a break of `minutes` (the Break length setting, or the short Pomodoro break, if not given).
    func takeBreak(minutes: Double? = nil, long: Bool = false) {
        guard phase == .running else { return }
        refundHeldTime()
        focusStreak = 0
        breakSuggested = false
        resetEscalation()
        stopSensors()
        longBreak = long
        let length = minutes ?? (settings.pomodoro ? settings.shortBreakMinutes : settings.breakMinutes)
        phase = .onBreak(until: Date().addingTimeInterval(length * 60))
        status = .onBreak
        hud.hide(animated: true)
    }

    func resume() {
        guard case .onBreak = phase else { return }
        phase = .running
        status = .neutral
        lastTick = Date()
        evidence.reset()
        startSensors()
    }

    func end() {
        guard phase != .idle, phase != .finished else { return }
        ticker?.invalidate()
        ticker = nil
        refundHeldTime()
        stopSensors()
        hud.hide(animated: true)
        resetEscalation()
        if settings.runShortcuts {
            runShortcut(settings.endShortcut) { [weak self] in self?.endShortcutDone?(); self?.endShortcutDone = nil }
        }

        let top = distractionTally.sorted { $0.value > $1.value }.prefix(3)
            .filter { $0.value >= 30 }
            .map { "\($0.key) · \(formatDuration($0.value))" }
        studyLog.saveIfNeeded()
        learner.trainIfNeeded()
        let summary = SessionSummary(start: sessionStart, topic: topic, duration: elapsed, focused: focusedTime,
                                     phone: phoneTime, offTask: offTaskTime, away: awayTime, nudges: nudges,
                                     topDistractions: Array(top), subjectID: currentSubjectID)
        if settings.keepHistory && elapsed >= 60 { history.add(summary) }
        lastSummary = summary
        judge.reset()
        distractionTally = [:]
        typingBaseline.reset(); expressionBaseline.reset()
        recentPostures = []
        resetCorrections()
        phase = .finished
        status = .idle
    }

    /// Snoozes, paper mode and pending lessons belong to one session or test.
    func resetCorrections() {
        phoneSnoozedUntil = .distantPast
        paperModeUntil = nil
        pendingPhoneLesson = nil
        undoLesson = nil
        cameraMovedAt = nil
    }

    func dismissSummary() {
        phase = .idle
    }


    /// Today's totals for study groups (encrypted before they leave the Mac).
    func groupSnapshot() -> MemberPayload {
        let today = studyLog.record(on: Date())
        var subjects: [String: Double] = [:]
        for (id, seconds) in today.totals { subjects[self.subjects.subject(id: id)?.name ?? "Other", default: 0] += seconds }
        return MemberPayload(name: "", groupName: "", day: StudyLog.key(Date()),
                             todaySeconds: today.total, weekSeconds: studyLog.weekTotal(), streak: studyLog.streak(),
                             studyingNow: phase == .running && !studyClockPaused,
                             currentSubject: phase == .running ? currentSubject?.name : nil,
                             subjects: subjects, updated: Date())
    }

    /// Settings → Privacy → Delete All My Data: erase everything Clocked stored, leave study groups, then quit.
    func deleteAllData() async {
        if phase == .running || isOnBreak { end() }
        stopSensorTest()
        await groupSync.removeEverything()
        learner.reset()
        forgetPostures()
        studyLog.clear()
        history.clear()
        subjects.removeAll()
        try? FileManager.default.removeItem(at: Storage.directory)
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        NSApp.terminate(nil)
    }
}
