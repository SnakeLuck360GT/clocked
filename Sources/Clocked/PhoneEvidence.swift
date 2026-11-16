import Foundation

/// Where your head/eyes are pointing, from the camera.
enum PostureVerdict: Equatable {
    case unknown          // camera off, or still learning your normal posture
    case absent           // nobody in view
    case screen           // looking at the Mac
    case paper            // matches your "writing on paper" posture
    case phone            // matches your "on your phone" posture
    case down             // clearly lower than your normal posture (not calibrated)

    var isDown: Bool { self == .phone || self == .down }
}

/// How you're studying right now. Decides whether pen sounds count as work and how much looking down counts.
enum StudyStyle: String, CaseIterable, Identifiable {
    case typing, writing, both
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var help: String {
        switch self {
        case .typing: return "Writing sounds are ignored, and looking down counts a bit more."
        case .writing: return "Pen sounds count as working, and looking down counts a bit less."
        case .both: return "Pen and typing sounds both count as working."
        }
    }
}

/// Everything the phone detector looks at for one second.
struct FocusCues {
    var phoneVisible = false        // a phone held in view of the camera
    var phoneAppOpen = false        // your iPhone said a distracting app is open (iPhone link)
    var posture: PostureVerdict = .unknown
    var keysLast10s = 0             // number of key presses (not which keys)
    var secondsSinceMouse: TimeInterval = .infinity
    var secondsSinceInput: TimeInterval = .infinity
    var shortFormAudio = false      // TikTok-style choppy audio, sustained
    var choppiness = 0              // switches + cuts in the last 30 s
    var soundNotFromMac = false     // talking/music in the room while the Mac isn't playing out loud
    var writingSound = false
    var typingSound = false
    var phoneAlertRecently = false  // a ringtone / notification bell in the last 30 s
    var smiling = false             // smiling vs. your resting face
    var handOnFace = false          // chin on hand, hand on forehead: thinking
    var lookingAround = false       // head turning and tilting over the last few seconds: thinking, not reading a phone
    var phoneGlow = false           // the lower face lit from below, or flickering, like a phone in your lap
    var laughterNotFromMac = false  // laughter in the room while the Mac isn't playing out loud
    /// The learned network's probability that you're on your phone, and how much say it has earned (0…1).
    /// Typing / writing / both: how much looking down counts (writing sounds are already filtered upstream).
    var studyStyle: StudyStyle = .both
    var learnedProbability: Float?
    var learnedInfluence = 0.0

    var usingMac: Bool { keysLast10s > 3 || secondsSinceMouse < 4 }
}

/// Builds up (or drains) evidence that you're on your phone, one second at a time, from all the cues together.
/// No single weak cue can trigger it; several together, or one strong one held for a while, can.
///
/// Looking down and not typing is also what thinking looks like, so on its own it can only take the score to just
/// under the hold-back line. Getting further needs a sign of a phone in the last 20 s: a phone in view, your taught
/// phone posture, light from a phone on your face, phone-like sound, smiling, or the learned model. Without one,
/// it takes more than a minute of staying still with your head down, and a hand on your face or looking around
/// (thinking) stops even that.
///
/// Rough time to "on your phone" with the default settings (phone off camera):
///   head down + light from a phone ≈ 7 s · taught phone posture ≈ 8 s · + smiling or sound from another device ≈ 7 s
///   + short-form video audio ≈ 4 s · head down and still with no other sign ≈ 80 s · thinking or writing → never
/// A glance at the screen only nibbles at the score; staying on the screen, glancing up repeatedly, or typing drains it.
/// Once flagged, it stays flagged until you use the keyboard or mouse again.
struct PhoneEvidence {
    struct Term: Equatable {
        var label: String
        var weight: Double
    }

    private(set) var score = 0.0
    private(set) var active = false
    private(set) var terms: [Term] = []
    /// Every cue's push this second, positive and negative (Developer View).
    private(set) var allTerms: [Term] = []
    /// How long the score has been low while flagged; a quick glance up shouldn't clear the flag.
    private var lowFor = 0.0
    private var clock = 0.0
    private var screenSince: Double?
    /// When each recent look at the screen started; several in a row means reading from the screen (e.g. copying notes).
    private var glanceStarts: [Double] = []
    /// When something last pointed to a phone specifically, not just to looking down.
    private var lastPhoneSign = -Double.infinity
    /// How long you've been looking down and still (not thinking, not using the Mac).
    private var downFor = 0.0

    /// Personal multiplier learned from your corrections ("false alarm" lowers it, "you got me" raises it).
    var gain = 1.0
    /// Score needed to decide you're on your phone (set from the Sensitivity slider).
    var threshold = 10.0

    mutating func reset() {
        score = 0
        active = false
        terms = []
        lowFor = 0
        screenSince = nil
        glanceStarts = []
        lastPhoneSign = -.infinity
        downFor = 0
    }

    /// Drop the score after a false alarm so it doesn't immediately re-trigger.
    mutating func clear() { score = 0; active = false; lowFor = 0; terms = []; downFor = 0; lastPhoneSign = -.infinity }

    mutating func update(_ c: FocusCues, dt: Double) {
        var t: [Term] = []
        if c.phoneVisible { t.append(Term(label: "phone in view", weight: 3.0)) }
        if c.phoneAppOpen { t.append(Term(label: "app open on your iPhone", weight: 3.0)) }
        switch c.posture {
        case .phone: t.append(Term(label: "phone posture", weight: 1.2))
        case .down:
            // Writing on paper means looking down a lot; typing gives little reason to.
            let weight = c.studyStyle == .typing ? 1.0 : (c.studyStyle == .writing ? 0.6 : 0.8)
            t.append(Term(label: "head down", weight: weight))
        case .paper: t.append(Term(label: "writing posture", weight: -0.8))
        case .absent: t.append(Term(label: "not at desk", weight: -1.0))
        case .screen, .unknown: break
        }
        if c.usingMac {
            t.append(Term(label: "using keyboard/mouse", weight: -2.0))
        } else if c.secondsSinceInput > 4, c.posture.isDown {
            // Only with head down: reading the screen without typing is studying.
            t.append(Term(label: "not typing", weight: 0.3))
        }
        if c.shortFormAudio, c.posture != .absent {
            t.append(Term(label: "short-form video audio", weight: 1.5))
        } else if c.choppiness >= 4, c.posture.isDown {
            t.append(Term(label: "choppy audio", weight: 0.4))
        }
        // Sound cues only mean something if you're not clearly looking at the Mac. If posture is unknown
        // (camera off or still learning), they need short-form audio too, so a TV in the room isn't enough.
        if c.posture.isDown || (c.posture == .unknown && c.shortFormAudio) {
            if c.soundNotFromMac { t.append(Term(label: "sound from another device", weight: 0.6)) }
            if c.phoneAlertRecently { t.append(Term(label: "notification sound", weight: 1.0)) }
            if c.smiling, c.posture.isDown, !c.writingSound, !c.handOnFace, !c.lookingAround {
                t.append(Term(label: "smiling", weight: 0.6))
            }
            if c.laughterNotFromMac { t.append(Term(label: "laughter", weight: 0.5)) }
        }
        // Thinking looks like looking down too; these are what set it apart.
        let thinking = c.posture.isDown && !c.phoneVisible && (c.handOnFace || c.lookingAround)
        if thinking, c.handOnFace { t.append(Term(label: "hand on face", weight: -1.0)) }
        if thinking, c.lookingAround { t.append(Term(label: "looking around", weight: -0.6)) }
        if c.posture.isDown, c.phoneGlow { t.append(Term(label: "light from a phone", weight: 1.0)) }
        if c.writingSound { t.append(Term(label: "writing sounds", weight: -1.2)) }
        // The network pushes either way, in proportion to its confidence (log-odds, capped at ±1.2/s at full
        // influence), so it can also cancel a false alarm the rules would raise, e.g. your way of reading on paper.
        if let p = c.learnedProbability, c.learnedInfluence > 0 {
            let q = min(max(Double(p), 0.01), 0.99)
            var push = min(max(0.4 * log(q / (1 - q)), -1.2), 1.2)
            // On its own (no rule sees anything), the network can't outrun the drift, so it can't nudge alone.
            if push > 0, !t.contains(where: { $0.weight > 0 }) { push = min(push, 0.15) }
            // Writing or typing heard is direct evidence of work; the network can't argue against it.
            if push > 0, c.writingSound || c.typingSound { push = 0 }
            t.append(Term(label: "learned model", weight: c.learnedInfluence * push))
        }
        if c.typingSound { t.append(Term(label: "typing sounds", weight: -0.8)) }

        let evidence = t.reduce(0) { $0 + $1.weight }
        let drift = 0.2 // small constant pull back to zero, so stray weak cues never add up
        score += (evidence > 0 ? evidence * gain : evidence) * dt - drift * dt
        // Looking at the screen: a short glance only nibbles at the score. Staying on the screen for 4 s, or glancing
        // up 3+ times in 30 s (reading from the screen), drains it fast.
        // (Unless a phone is in view: holding it up in front of you can look like "looking at the screen".)
        clock += dt
        glanceStarts.removeAll { clock - $0 > 30 }
        if c.posture == .screen {
            if screenSince == nil { screenSince = clock }
        } else if c.posture != .unknown {
            screenSince = nil
        }
        // A single "screen" reading is often noise, so a glance only counts from the second second on.
        if c.posture == .screen, !c.phoneVisible, !c.phoneAppOpen, let since = screenSince, clock - since >= 1 {
            if glanceStarts.last.map({ $0 < since }) ?? true { glanceStarts.append(since) }
            let onScreenFor = clock - since
            if onScreenFor >= 4 || glanceStarts.count >= 3 { score *= pow(0.5, dt) } else { score -= 1.0 * dt }
        }
        if c.usingMac { score *= pow(0.7, dt) }

        // Signs of a phone specifically, as opposed to just looking down.
        let learnedPush = t.first { $0.label == "learned model" }?.weight ?? 0
        let down = c.posture.isDown
        let phoneSign = c.phoneVisible || c.phoneAppOpen || c.shortFormAudio || learnedPush > 0.3
            || (c.posture == .phone && !thinking)
            || (down && (c.phoneGlow || c.choppiness >= 4 || c.soundNotFromMac || c.phoneAlertRecently
                         || c.laughterNotFromMac || (c.smiling && !c.writingSound && !thinking)))
        if phoneSign { lastPhoneSign = clock }
        // Looking back at the screen for a while, or glancing up at it again and again (copying notes), resets it.
        if c.usingMac || c.posture == .absent || glanceStarts.count >= 3
            || (c.posture == .screen && screenSince.map { clock - $0 >= 4 } == true) {
            downFor = 0
        } else if down, !thinking, !c.writingSound {
            downFor += dt
        }
        // Without a recent sign, stop just under the hold-back line; after a minute of staying still with your head
        // down the limit lifts over 30 s, since that's rarely thinking.
        if !active, clock - lastPhoneSign > 20 {
            let lift = min(max((downFor - 60) / 30, 0), 1)
            score = min(score, threshold * (0.45 + 0.55 * lift))
        }
        score = min(max(score, 0), threshold * 1.5)

        if !active && score >= threshold { active = true; lowFor = 0 }
        if active {
            // Stays flagged until you're back on the keyboard or mouse: looking up at the screen with the phone
            // still in your hand doesn't count. Safety net: if nothing points to the phone for 3 minutes, let go.
            lowFor = score < threshold * 0.2 ? lowFor + dt : 0
            if c.usingMac || lowFor >= 180 {
                active = false
                lowFor = 0
                score = min(score, threshold * 0.3)
            }
        }
        terms = t.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        allTerms = t
    }

    /// e.g. "head down · not typing · sound not from the Mac"
    var explanation: String { terms.prefix(3).map(\.label).joined(separator: " · ") }
}

/// Holds back study time while phone use is suspected (evidence past half the threshold).
/// If it turns into a phone flag, the held time becomes phone time; if the evidence fades below a quarter of
/// the threshold (or you become distracted some other way, or away), it's released back as study time.
struct SuspicionLedger {
    private(set) var suspecting = false
    private(set) var held: TimeInterval = 0

    enum Release: Equatable { case none, toStudy(TimeInterval), toPhone(TimeInterval) }

    /// One second of a running session. Returns whether this second counts as study *now*, and any released time.
    mutating func step(score: Double, threshold: Double, onPhone: Bool, otherwiseUnfocused: Bool, dt: TimeInterval) -> (countsAsStudy: Bool, release: Release) {
        var release = Release.none
        if onPhone {
            if held > 0 { release = .toPhone(held) }
            reset()
            return (false, release)
        }
        if otherwiseUnfocused || score < threshold * 0.25 {
            if held > 0 { release = .toStudy(held) }
            reset()
            return (!otherwiseUnfocused, release)
        }
        if !suspecting, score >= threshold * 0.5 { suspecting = true }
        if suspecting {
            held += dt
            return (false, release)
        }
        return (true, release)
    }

    /// Ends suspicion without a flag (break, end of session, "Not My Phone"): give the time back.
    mutating func releaseToStudy() -> TimeInterval {
        defer { reset() }
        return held
    }

    private mutating func reset() {
        suspecting = false
        held = 0
    }
}

/// Light from a phone. Held in your lap, its screen lights your chin and the lower half of your face from below,
/// and the light changes as you scroll. Compared with how your face is lit while you're using the Mac, so a bright
/// room or a dark one doesn't matter. In bright daylight the difference is too small to see, and it stays quiet.
struct PhoneGlow {
    /// Lower-to-upper face brightness while you're using the Mac.
    private(set) var baseline: Double?
    private var lower: [Double] = []
    private var upper: [Double] = []

    mutating func reset() { baseline = nil; lower = []; upper = [] }

    /// One camera sample. `usingMac`: typing or clicking, so you're facing the screen.
    mutating func add(lower l: Double, upper u: Double, usingMac: Bool) {
        lower.append(l); upper.append(u)
        if lower.count > 6 { lower.removeFirst(); upper.removeFirst() }
        guard usingMac, u > 0.04 else { return }
        let ratio = l / u
        baseline = baseline.map { $0 * 0.9 + ratio * 0.1 } ?? ratio
    }

    /// Whether the lower face looks lit by a phone right now.
    var glowing: Bool {
        guard let baseline, let l = lower.last, let u = upper.last, u > 0.04 else { return false }
        let brighter = l / u - baseline > 0.15
        // Scrolling: the lower face flickers while the forehead stays steady.
        let flicker = lower.count >= 5 && Self.spread(lower) > 0.02 && Self.spread(lower) > 2 * Self.spread(upper)
        return brighter || flicker
    }

    private static func spread(_ v: [Double]) -> Double {
        let mean = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot()
    }
}

/// Thinking: the head turns and tilts over a few seconds. Reading a phone keeps it still.
/// `heads`: yaw and pitch in radians from the last 8 or so seconds.
func lookingAround(_ heads: [(yaw: Double?, pitch: Double?)]) -> Bool {
    let yaws = heads.compactMap(\.yaw), pitches = heads.compactMap(\.pitch)
    guard yaws.count >= 4 || pitches.count >= 4 else { return false }
    let range: ([Double]) -> Double = { $0.count >= 4 ? $0.max()! - $0.min()! : 0 }
    return range(yaws) > 0.3 || range(pitches) > 0.25
}
