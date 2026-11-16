// Runs everyday study scenarios through the evidence engine, reports when (if ever) a phone flag fires,
// and fails if a scenario doesn't do what it should. Run with Tests/run.sh.

import Foundation

enum Expect {
    case within(Int)        // should flag by this many seconds
    case between(Int, Int)  // should flag, but only slowly (no phone-specific sign)
    case never
    case report             // just print it
}

var failures = 0

// Simulate N seconds with a cue generator; report when "on phone" first triggers.
func run(_ name: String, seconds: Int = 180, sensitivity: Double = 0.5, gain: Double = 1, _ expect: Expect,
         _ cue: (Int) -> FocusCues) {
    var e = PhoneEvidence()
    e.threshold = 10 * (1.5 - sensitivity)
    e.gain = gain
    var first: Int?
    var activeSeconds = 0
    for t in 0..<seconds {
        e.update(cue(t), dt: 1)
        if e.active { activeSeconds += 1; if first == nil { first = t } }
    }
    let ok: Bool
    switch expect {
    case .within(let s): ok = first.map { $0 <= s } ?? false
    case .between(let a, let b): ok = first.map { $0 >= a && $0 <= b } ?? false
    case .never: ok = first == nil
    case .report: ok = true
    }
    if !ok { failures += 1 }
    let verdict = first.map { "flag at \($0)s, flagged \(activeSeconds)s of \(seconds)" } ?? "never flagged"
    print(String(format: "%@ %-58@ %@", ok ? " " : "✗", name as NSString, verdict))
}

func idle(_ c: inout FocusCues) { c.keysLast10s = 0; c.secondsSinceMouse = 60; c.secondsSinceInput = 60 }
func typing(_ c: inout FocusCues) { c.keysLast10s = 12; c.secondsSinceMouse = 30; c.secondsSinceInput = 0.5; c.posture = .screen }

print("— should flag quickly (a sign of a phone) —")
run("TikTok in lap, sound on, Mac silent", .within(20)) { t in
    var c = FocusCues(); idle(&c); c.posture = .down; c.soundNotFromMac = true
    c.shortFormAudio = t > 45; c.choppiness = t > 20 ? 6 : 2; return c }
run("Scrolling muted, light from the phone on your face", .within(15)) { _ in
    var c = FocusCues(); idle(&c); c.posture = .down; c.phoneGlow = true; return c }
run("Scrolling, taught phone posture, muted", .within(15)) { _ in var c = FocusCues(); idle(&c); c.posture = .phone; return c }
run("Ding! then picks up phone (muted)", .within(15)) { t in
    var c = FocusCues(); idle(&c); c.posture = t < 3 ? .screen : .down; c.phoneAlertRecently = true; return c }
run("Camera off, TikTok audio from phone", .within(60)) { t in
    var c = FocusCues(); idle(&c); c.posture = .unknown; c.soundNotFromMac = true; c.shortFormAudio = t > 45; c.choppiness = 6; return c }
run("Phone held up in view", .within(10)) { _ in var c = FocusCues(); idle(&c); c.posture = .screen; c.phoneVisible = true; return c }
run("Scrolling while smiling (muted)", .within(15)) { _ in
    var c = FocusCues(); idle(&c); c.posture = .down; c.smiling = true; return c }
run("iPhone link: Instagram opened, facing the screen", .within(5)) { _ in
    var c = FocusCues(); idle(&c); c.posture = .screen; c.phoneAppOpen = true; return c }
run("iPhone link: opened 30 s, then closed and typing", seconds: 90, .within(5)) { t in
    var c = FocusCues(); if t < 30 { idle(&c); c.posture = .down; c.phoneAppOpen = true } else { typing(&c) }; return c }
run("Scrolling with phone light, 1 s glance every 8 s", .within(25)) { t in
    var c = FocusCues(); idle(&c); c.posture = t % 8 == 0 ? .screen : .down; c.phoneGlow = true; return c }

print("— no sign of a phone: slow (looking down still for over a minute) —")
run("Muted scrolling in daylight, nothing but head down", .between(60, 120)) { _ in
    var c = FocusCues(); idle(&c); c.posture = .down; return c }
run("Head down, glances up every 30 s", .between(60, 150)) { t in
    var c = FocusCues(); idle(&c); c.posture = t % 30 < 2 ? .screen : .down; return c }
run("Reading a paper textbook silently (teach paper posture)", .report) { _ in
    var c = FocusCues(); idle(&c); c.posture = .down; return c }

print("— thinking: should NOT flag —")
run("Thinking, head down, chin on hand", .never) { _ in
    var c = FocusCues(); idle(&c); c.posture = .down; c.handOnFace = true; return c }
run("Thinking, head down, looking around", .never) { _ in
    var c = FocusCues(); idle(&c); c.posture = .down; c.lookingAround = true; return c }
run("Thinking with head down 40 s, then typing 15 s, repeat", .never) { t in
    var c = FocusCues(); if t % 55 < 40 { idle(&c); c.posture = .down } else { typing(&c) }; return c }
run("Thinking, hand on face, taught phone posture matches", .never) { _ in
    var c = FocusCues(); idle(&c); c.posture = .phone; c.handOnFace = true; return c }
run("Thinking, chin on hand, while smiling at an idea", .never) { _ in
    var c = FocusCues(); idle(&c); c.posture = .down; c.handOnFace = true; c.smiling = true; return c }

print("— other studying: should NOT flag —")
run("Writing notes, pen heard (10 s memory), uncalibrated", .never) { _ in
    var c = FocusCues(); idle(&c); c.posture = .down; c.writingSound = true; return c }
run("Writing notes, taught paper posture", .never) { _ in var c = FocusCues(); idle(&c); c.posture = .paper; return c }
run("Copying notes from screen, pen heard, glance every 10 s", .never) { t in
    var c = FocusCues(); idle(&c); c.posture = t % 10 < 2 ? .screen : .down; c.writingSound = true; return c }
run("Copying notes from screen, SILENT, glance every 6 s", .never) { t in
    var c = FocusCues(); idle(&c); c.posture = t % 6 < 2 ? .screen : .down; return c }
run("Copying notes from screen, SILENT, glance every 10 s", .never) { t in
    var c = FocusCues(); idle(&c); c.posture = t % 10 < 2 ? .screen : .down; return c }
run("Typing an essay, music on Mac speakers", .never) { _ in var c = FocusCues(); typing(&c); return c }
run("Watching a lecture video on Mac", .never) { _ in var c = FocusCues(); idle(&c); c.posture = .screen; return c }
run("Glancing at notes on desk 8 s, then typing 15 s, repeat", .never) { t in
    var c = FocusCues(); if t % 23 < 8 { idle(&c); c.posture = .down } else { typing(&c) }; return c }
run("Away from desk", .never) { _ in var c = FocusCues(); idle(&c); c.posture = .absent; return c }
run("Camera off, roommate TV (sound not from Mac, choppy, laughter)", .never) { _ in
    var c = FocusCues(); idle(&c); c.posture = .unknown; c.soundNotFromMac = true; c.choppiness = 5; c.laughterNotFromMac = true; return c }
run("Reading screen, mouse only, no typing", .never) { _ in
    var c = FocusCues(); c.keysLast10s = 0; c.secondsSinceMouse = 6; c.secondsSinceInput = 6; c.posture = .screen; return c }

print("— Typing / Writing / Both toggle —")
for style in StudyStyle.allCases {
    // Phone in lap, lit face; taps on the screen sometimes misheard as "writing" (the app applies the toggle upstream).
    run("Phone in lap, phone light, taps misheard as writing [\(style.title)]", .report) { t in
        var c = FocusCues(); idle(&c); c.posture = .down; c.studyStyle = style; c.phoneGlow = true
        c.writingSound = style != .typing && t % 10 < 6; return c }
}
for style in StudyStyle.allCases {
    run("Real note-taking, pen audible [\(style.title)]", style == .typing ? .report : .never) { _ in
        var c = FocusCues(); idle(&c); c.posture = .down; c.studyStyle = style
        c.writingSound = style != .typing; return c }
}

print("— stays flagged until keyboard or mouse —")
run("Scroll 40 s (phone light), look up 40 s (phone in hand), then type", seconds: 120, .within(15)) { t in
    var c = FocusCues()
    if t < 40 { idle(&c); c.posture = .down; c.phoneGlow = true }
    else if t < 80 { idle(&c); c.posture = .screen }
    else { typing(&c) }
    return c }

print("— time held back while suspected —")
do {
    // Every second from 50% evidence should end up as phone time if it becomes a flag, and as study time if not.
    func simulate(_ name: String, seconds: Int, minStudy: Double, _ cue: (Int) -> FocusCues) {
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
        let ok = study >= minStudy
        if !ok { failures += 1 }
        print(String(format: "%@ %-58@ study %3.0f s, phone %3.0f s", ok ? " " : "✗", name as NSString, study, phone))
    }
    simulate("Scrolling with phone light from t=20 s for 60 s (120 s)", seconds: 120, minStudy: 55) { t in
        var c = FocusCues()
        if (20..<80).contains(t) { idle(&c); c.posture = .down; c.phoneGlow = true } else { typing(&c) }
        return c }
    simulate("Thinking head down 30 s, then typing (no time lost, 60 s)", seconds: 60, minStudy: 60) { t in
        var c = FocusCues()
        if (20..<50).contains(t) { idle(&c); c.posture = .down } else { typing(&c) }
        return c }
}

print("— recovery —")
run("Scroll 60 s (phone light), then look at screen + type", seconds: 90, .within(15)) { t in
    var c = FocusCues()
    if t < 60 { idle(&c); c.posture = .down; c.phoneGlow = true } else { typing(&c) }
    return c }

print("— helpers —")
do {
    var g = PhoneGlow()
    for _ in 0..<10 { g.add(lower: 0.40, upper: 0.50, usingMac: true) } // typing: ratio 0.8
    g.add(lower: 0.35, upper: 0.50, usingMac: false)                     // head down, chin darker
    let darkerOK = !g.glowing
    g.add(lower: 0.55, upper: 0.50, usingMac: false)                     // lit from below
    let litOK = g.glowing
    var steady = PhoneGlow()
    for _ in 0..<10 { steady.add(lower: 0.40, upper: 0.50, usingMac: true) }
    for i in 0..<6 { steady.add(lower: i % 2 == 0 ? 0.36 : 0.42, upper: 0.50, usingMac: false) } // scrolling flicker
    let flickerOK = steady.glowing
    let still = lookingAround((0..<8).map { _ in (yaw: 0.02, pitch: 0.30) })
    let moving = lookingAround((0..<8).map { i in (yaw: i % 2 == 0 ? -0.2 : 0.2, pitch: 0.30) })
    for (name, ok) in [("Phone glow: darker chin isn't a phone", darkerOK), ("Phone glow: chin lit from below", litOK),
                       ("Phone glow: flicker while scrolling", flickerOK), ("Looking around: still head is not", !still),
                       ("Looking around: turning head is", moving)] {
        if !ok { failures += 1 }
        print("\(ok ? " " : "✗") \(name)")
    }
}

if failures > 0 { print("\(failures) scenario(s) failed."); exit(1) }
print("All detection scenarios behave as expected.")
