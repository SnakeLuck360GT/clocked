// Runs everyday study scenarios through the evidence engine and reports when (if ever) a phone nudge fires.
// Run with Tests/run.sh.

import Foundation

// Simulate N seconds with a cue generator; report when "on phone" first triggers (+ nudge at half the 20 s delay).
func run(_ name: String, seconds: Int = 180, sensitivity: Double = 0.5, gain: Double = 1, _ cue: (Int) -> FocusCues) {
    var e = PhoneEvidence()
    e.threshold = 10 * (1.5 - sensitivity)
    e.gain = gain
    var first: Int?
    var activeSeconds = 0
    for t in 0..<seconds {
        e.update(cue(t), dt: 1)
        if e.active { activeSeconds += 1; if first == nil { first = t } }
    }
    let verdict = first.map { "nudge at \($0)s, flagged \(activeSeconds)s of \(seconds)" } ?? "never flagged"
    print(String(format: "%-58@ %@", name as NSString, verdict))
}

func idle(_ c: inout FocusCues) { c.keysLast10s = 0; c.secondsSinceMouse = 60; c.secondsSinceInput = 60 }

print("— should flag (phone off camera) —")
run("TikTok in lap, sound on, Mac silent") { t in
    var c = FocusCues(); idle(&c); c.posture = .down; c.soundNotFromMac = true
    c.shortFormAudio = t > 45; c.choppiness = t > 20 ? 6 : 2; return c }
run("TikTok in lap, MUTED") { _ in var c = FocusCues(); idle(&c); c.posture = .down; return c }
run("Scrolling, calibrated phone posture, muted") { _ in var c = FocusCues(); idle(&c); c.posture = .phone; return c }
run("Ding! then picks up phone (muted)") { t in
    var c = FocusCues(); idle(&c); c.posture = t < 3 ? .screen : .down; c.phoneAlertRecently = true; return c }
run("Camera off, TikTok audio from phone") { t in
    var c = FocusCues(); idle(&c); c.posture = .unknown; c.soundNotFromMac = true; c.shortFormAudio = t > 45; c.choppiness = 6; return c }
run("Phone held up in view") { _ in var c = FocusCues(); idle(&c); c.posture = .screen; c.phoneVisible = true; return c }
run("Head down in lap, glances up every 30 s") { t in
    var c = FocusCues(); idle(&c); c.posture = t % 30 < 2 ? .screen : .down; return c }

run("Scrolling, 1 s glance at screen every 8 s") { t in
    var c = FocusCues(); idle(&c); c.posture = t % 8 == 0 ? .screen : .down; return c }
run("Scrolling, 2 s glance every 15 s") { t in
    var c = FocusCues(); idle(&c); c.posture = t % 15 < 2 ? .screen : .down; return c }
run("Scrolling while smiling (muted)") { _ in
    var c = FocusCues(); idle(&c); c.posture = .down; c.smiling = true; return c }
print("— should NOT flag —")
run("Writing notes, pen heard (10 s memory), uncalibrated") { _ in
    var c = FocusCues(); idle(&c); c.posture = .down; c.writingSound = true; return c }
run("Writing notes, calibrated paper posture") { _ in var c = FocusCues(); idle(&c); c.posture = .paper; return c }
run("Copying notes from screen, pen heard, glance every 10 s") { t in
    var c = FocusCues(); idle(&c); c.posture = t % 10 < 2 ? .screen : .down; c.writingSound = true; return c }
run("Copying notes from screen, SILENT, glance every 6 s") { t in
    var c = FocusCues(); idle(&c); c.posture = t % 6 < 2 ? .screen : .down; return c }
run("Copying notes from screen, SILENT, glance every 10 s") { t in
    var c = FocusCues(); idle(&c); c.posture = t % 10 < 2 ? .screen : .down; return c }
run("Typing an essay, music on Mac speakers") { _ in
    var c = FocusCues(); c.keysLast10s = 25; c.secondsSinceMouse = 8; c.secondsSinceInput = 0.5; c.posture = .screen; return c }
run("Watching a lecture video on Mac") { _ in var c = FocusCues(); idle(&c); c.posture = .screen; return c }
run("Glancing at notes on desk 8 s, then typing 15 s, repeat") { t in
    var c = FocusCues(); let p = t % 23
    if p < 8 { idle(&c); c.posture = .down } else { c.keysLast10s = 12; c.secondsSinceMouse = 30; c.secondsSinceInput = 0.5; c.posture = .screen }
    return c }
run("Away from desk") { _ in var c = FocusCues(); idle(&c); c.posture = .absent; return c }

run("Camera off, roommate TV (sound not from Mac, choppy, laughter)") { _ in
    var c = FocusCues(); idle(&c); c.posture = .unknown; c.soundNotFromMac = true; c.choppiness = 5; c.laughterNotFromMac = true; return c }
run("Reading screen, mouse only, no typing") { _ in
    var c = FocusCues(); c.keysLast10s = 0; c.secondsSinceMouse = 6; c.secondsSinceInput = 6; c.posture = .screen; return c }
print("— Typing / Writing / Both toggle —")
for style in StudyStyle.allCases {
    // Phone in lap; taps on the screen sometimes misheard as "writing" (the app applies the toggle upstream).
    run("Phone in lap, taps misheard as writing [\(style.title)]") { t in
        var c = FocusCues(); idle(&c); c.posture = .down; c.studyStyle = style
        c.writingSound = style != .typing && t % 10 < 6; return c }
}
for style in StudyStyle.allCases {
    run("Real note-taking, pen audible [\(style.title)]") { _ in
        var c = FocusCues(); idle(&c); c.posture = .down; c.studyStyle = style
        c.writingSound = style != .typing; return c }
}

print("— Stays flagged until keyboard or mouse —")
run("Scroll 40 s, look up at screen 40 s (phone in hand), then type", seconds: 120) { t in
    var c = FocusCues()
    if t < 40 { idle(&c); c.posture = .down }
    else if t < 80 { idle(&c); c.posture = .screen }
    else { c.keysLast10s = 10; c.secondsSinceMouse = 30; c.secondsSinceInput = 0.5; c.posture = .screen }
    return c }

print("— Time held back while suspected —")
do {
    // Evidence climbs from 0; a flag follows. Every second from 50% evidence should end up as phone time.
    func simulate(_ name: String, seconds: Int, _ cue: (Int) -> FocusCues) {
        var e = PhoneEvidence(); e.threshold = 10
        var ledger = SuspicionLedger()
        var study = 0.0, phone = 0.0
        for t in 0..<seconds {
            e.update(cue(t), dt: 1)
            let r = ledger.step(score: e.score, threshold: e.threshold, onPhone: e.active, otherwiseUnfocused: false, dt: 1)
            if e.active { phone += 1 }
            if r.countsAsStudy { study += 1 }
            switch r.release { case .toPhone(let h): phone += h; case .toStudy(let h): study += h; case .none: break }
        }
        study += ledger.releaseToStudy() // session ends
        print(String(format: "%-58@ study %3.0f s, phone %3.0f s", name as NSString, study, phone))
    }
    simulate("Muted scrolling from t=20 s for 60 s, then typing (120 s)", seconds: 120) { t in
        var c = FocusCues()
        if (20..<80).contains(t) { idle(&c); c.posture = .down } else { c.keysLast10s = 10; c.secondsSinceMouse = 30; c.secondsSinceInput = 0.5; c.posture = .screen }
        return c }
    simulate("Head down 6 s then back to typing (no flag, 60 s)", seconds: 60) { t in
        var c = FocusCues()
        if (20..<26).contains(t) { idle(&c); c.posture = .down } else { c.keysLast10s = 10; c.secondsSinceMouse = 30; c.secondsSinceInput = 0.5; c.posture = .screen }
        return c }
}

print("— known limitation (fix: teach paper posture / paper mode) —")
run("Reading paper textbook silently, never looking up") { _ in var c = FocusCues(); idle(&c); c.posture = .down; return c }
run("…same after 3 'Not on phone' corrections (gain 0.61)", gain: 0.61) { _ in var c = FocusCues(); idle(&c); c.posture = .down; return c }
print("— recovery —")
run("Scroll 60 s, then look at screen + type", seconds: 90) { t in
    var c = FocusCues()
    if t < 60 { idle(&c); c.posture = .down } else { c.keysLast10s = 10; c.secondsSinceMouse = 30; c.secondsSinceInput = 0.5; c.posture = .screen }
    return c }
