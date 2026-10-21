// Simulates the self-training loop for one synthetic student and measures what the network adds.
// The student's "paper" posture is deliberately close to their "phone" posture, which is exactly where
// the hand-written rules fail. Run with Tests/run.sh.
import Foundation

var rng = SeededRandom(seed: 2026)
func gauss(_ mean: Double, _ sd: Double) -> Double {
    let u1 = max(Double(rng.next() >> 11) / Double(1 << 53), 1e-12), u2 = Double(rng.next() >> 11) / Double(1 << 53)
    return mean + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
}
func chance(_ p: Double) -> Bool { Double(rng.next() >> 11) / Double(1 << 53) < p }

// Experiment knobs.
var paperLooksLikePhone = false   // a student whose paper and phone postures are indistinguishable
var labelNoise = 0.0              // share of labels that are wrong

enum Context: String, CaseIterable {
    case typing = "Typing at the screen"
    case screenReading = "Reading the screen (no typing)"
    case phoneMuted = "Phone in lap, muted"
    case phoneSound = "Phone in lap, with sound"
    case paperWriting = "Writing notes (pen audible)"
    case paperReading = "Reading paper silently"
    var isPhone: Bool { self == .phoneMuted || self == .phoneSound }
}

func posture(_ c: Context) -> PostureFeatures {
    switch c {
    case .typing, .screenReading:
        return PostureFeatures(eyeEar: gauss(0.05, 0.02), noseShoulder: gauss(0.60, 0.03), faceY: gauss(0.60, 0.02), pitch: gauss(0, 0.05),
                               faceVisible: 1, eyeOpen: gauss(0.30, 0.03), yaw: gauss(0, 0.05), gazeY: gauss(0.50, 0.05), shoulderY: gauss(0.3, 0.01))
    case .phoneMuted, .phoneSound:
        let face = chance(0.7)
        return PostureFeatures(eyeEar: gauss(-0.10, 0.03), noseShoulder: gauss(0.42, 0.04), faceY: face ? gauss(0.46, 0.03) : nil,
                               pitch: face ? gauss(0.40, 0.07) : nil, faceVisible: face ? 1 : 0, eyeOpen: face ? gauss(0.13, 0.03) : nil,
                               yaw: face ? gauss(0.02, 0.08) : nil, gazeY: face ? gauss(0.30, 0.06) : nil, shoulderY: gauss(0.29, 0.01))
    case .paperWriting where paperLooksLikePhone, .paperReading where paperLooksLikePhone:
        return posture(.phoneMuted)
    case .paperWriting, .paperReading:
        // Close to the phone posture in head angle, but the face stays visible and the eyes stay more open.
        return PostureFeatures(eyeEar: gauss(-0.08, 0.03), noseShoulder: gauss(0.45, 0.04), faceY: gauss(0.50, 0.03), pitch: gauss(0.35, 0.07),
                               faceVisible: 1, eyeOpen: gauss(0.20, 0.03), yaw: gauss(0.15, 0.08), gazeY: gauss(0.34, 0.06), shoulderY: gauss(0.29, 0.01))
    }
}

func expression(_ c: Context) -> ExpressionFeatures {
    let smiling = c.isPhone && chance(0.35)
    return ExpressionFeatures(mouthCurve: gauss(smiling ? 0.10 : 0.0, 0.02), mouthWidth: gauss(smiling ? 0.48 : 0.42, 0.015),
                              mouthOpen: gauss(smiling ? 0.12 : 0.05, 0.03))
}

func audio(_ c: Context) -> AudioReading {
    var a = AudioReading()
    switch c {
    case .typing: a.typingHeard = chance(0.8); a.current = "other"
    case .phoneSound: a.mediaShare = gauss(0.7, 0.1); a.switches = Int(gauss(5, 1.5)); a.cuts = Int(gauss(3, 1)); a.shortFormLikely = chance(0.6); a.laughterHeard = chance(0.3)
    case .paperWriting: a.writingHeard = chance(0.95) // the app remembers a writing sound for 10 s
    default: break
    }
    return a
}

var baseline = TypingBaseline(), resting = ExpressionBaseline()
for _ in 0..<60 { baseline.add(posture(.typing)); resting.add(expression(.typing)) }

func experiment(_ title: String) {
print("\n### \(title)")

func features(_ c: Context) -> [Float] {
    var s = CameraSample()
    s.posture = posture(c)
    s.expression = expression(c)
    s.facePresent = s.posture?.faceVisible == 1
    var i = LearningFeatures.Inputs()
    i.sample = s
    i.cameraOn = true
    i.postureReference = baseline.reference
    i.expressionReference = resting.reference
    i.keysLast10s = c == .typing ? Int(gauss(18, 5)) : 0
    i.secondsSinceMouse = c == .typing || c == .screenReading ? gauss(4, 2) : 60
    i.secondsSinceInput = c == .typing ? 0.5 : (c == .screenReading ? gauss(6, 3) : gauss(40, 15))
    i.audio = audio(c)
    i.micOn = true
    return LearningFeatures.make(i)
}

/// A posture recording as the app makes it: camera only (mic off, no resting-face reference), measured against
/// "looking at the screen" from the same sitting (the countdown frames, or the Screen recording itself).
func recording(_ c: Context, frames: Int = 30) -> [[Float]] {
    let samples = (0..<frames).map { _ in posture(c) }
    var reference = TypingBaseline()
    for f in c == .screenReading ? samples : (0..<6).map({ _ in posture(.screenReading) }) { reference.add(f) }
    return samples.map { p in
        var s = CameraSample()
        s.posture = p
        var i = LearningFeatures.Inputs()
        i.sample = s
        i.cameraOn = true
        i.postureReference = reference.reference
        i.secondsSinceMouse = c == .screenReading ? 5 : 60
        i.secondsSinceInput = c == .screenReading ? 5 : 30
        return LearningFeatures.make(i)
    }
}

// Held-out test set, never trained on.
let testSet = Context.allCases.flatMap { c in (0..<300).map { _ in PhoneNet.Example(x: features(c), y: c.isPhone ? 1 : 0, episode: -1) } }

// Labels arrive the way they do in the app.
var examples: [PhoneNet.Example] = []
var episode = 0
func addEpisode(_ c: Context, _ n: Int, label: Float) {
    episode += 1
    for _ in 0..<n { examples.append(.init(x: features(c), y: chance(labelNoise) ? 1 - label : label, episode: episode)) }
}
// Posture recordings (30 frames each at 2 per second over 15 s).
for (c, label) in [(Context.screenReading, Float(0)), (.paperWriting, 0), (.phoneMuted, 1)] {
    episode += 1
    for x in recording(c) { examples.append(.init(x: x, y: chance(labelNoise) ? 1 - label : label, episode: episode)) }
}

print("Session  labels(+/-)  val-acc  cautious  say    test-acc   mean p(phone) per context")
var finalNet: PhoneNet?
var finalInfluence = 0.0
for session in 1...8 {
    for _ in 0..<12 { addEpisode(.typing, 1, label: 0) }                 // typing negatives, 1 per 15 s
    addEpisode(chance(0.5) ? .phoneMuted : .phoneSound, 20, label: 1)  // nudge accepted → last 20 s were phone
    addEpisode(.phoneMuted, 20, label: 1)
    if session <= 4 { addEpisode(.paperReading, 20, label: 0) }        // "Writing Notes" on a false alarm (early sessions)
    let (net, report) = PhoneNet.train(examples, inputs: LearningFeatures.count)
    let influence = Learner.influence(for: report)
    let test = net.evaluate(testSet)
    let means = Context.allCases.map { c -> String in
        let ps = testSet.enumerated().filter { $0.offset / 300 == Context.allCases.firstIndex(of: c)! }.map { net.predict($0.element.x) }
        return String(format: "%.2f", ps.reduce(0, +) / Float(ps.count))
    }
    let pos = examples.filter { $0.y > 0.5 }.count
    print(String(format: "%7d  %5d/%-5d  %7.3f  %8.3f  %4.0f%%  %8.3f   %@", session, pos, examples.count - pos,
                 report.balancedAccuracy, report.balancedAccuracyLowerBound, influence * 100, test.balancedAccuracy,
                 means.joined(separator: " ")))
    finalNet = net; finalInfluence = influence
}
print("Contexts: " + Context.allCases.map(\.rawValue).joined(separator: " | "))

// What the network changes: time to a phone nudge, rules only vs. rules + network.
func timeToFlag(_ c: Context, useNet: Bool, seconds: Int = 180) -> Int? {
    var e = PhoneEvidence()
    e.threshold = 10
    for t in 0..<seconds {
        var cue = FocusCues()
        let x = features(c)
        let p = posture(c)
        cue.posture = baseline.isHeadDown(p) ? .down : .screen
        cue.keysLast10s = c == .typing ? 15 : 0
        cue.secondsSinceMouse = c == .typing || c == .screenReading ? 4 : 60
        cue.secondsSinceInput = c == .typing ? 0.5 : 30
        let a = audio(c)
        cue.writingSound = a.writingHeard; cue.typingSound = a.typingHeard
        cue.shortFormAudio = a.shortFormLikely; cue.soundNotFromMac = a.mediaShare >= 0.5
        if useNet, let net = finalNet {
            cue.learnedProbability = net.predict(x)
            cue.learnedInfluence = finalInfluence
        }
        e.update(cue, dt: 1)
        if e.active { return t }
    }
    return nil
}
print("\nTime to phone nudge (s), rules only → rules + network:")
for c in Context.allCases {
    let a = timeToFlag(c, useNet: false).map { "\($0) s" } ?? "never"
    let b = timeToFlag(c, useNet: true).map { "\($0) s" } ?? "never"
    print(String(format: "  %-34@ %8@ → %@", c.rawValue as NSString, a as NSString, b))
}
}

experiment("Typical student")
labelNoise = 0.2
experiment("20% of labels wrong")
labelNoise = 0
paperLooksLikePhone = true
experiment("Paper and phone postures indistinguishable")

// Looking at the bottom corner of the screen: eyes and head a little lower than when typing.
// This is what triggered a false alarm in real use; "Not My Phone" (or clicking there) should fix it.
func bottomOfScreen() -> PostureFeatures {
    PostureFeatures(eyeEar: gauss(-0.02, 0.02), noseShoulder: gauss(0.52, 0.03), faceY: gauss(0.54, 0.02), pitch: gauss(0.18, 0.05),
                    faceVisible: 1, eyeOpen: gauss(0.21, 0.03), yaw: gauss(0.25, 0.05), gazeY: gauss(0.36, 0.05), shoulderY: gauss(0.3, 0.01))
}
var check = TypingBaseline()
for _ in 0..<60 { check.add(posture(.typing)) }
func downRate(_ make: () -> PostureFeatures) -> Int { (0..<500).filter { _ in check.isHeadDown(make()) }.count / 5 }
print("\n### Looking at the bottom corner of the screen")
print("  before correction: read as head down \(downRate(bottomOfScreen))% of the time; phone posture \(downRate { posture(.phoneMuted) })%")
check.accept(asScreen: (0..<15).map { _ in bottomOfScreen() })
print("  after one 'Not My Phone': read as head down \(downRate(bottomOfScreen))% of the time; phone posture \(downRate { posture(.phoneMuted) })%")
