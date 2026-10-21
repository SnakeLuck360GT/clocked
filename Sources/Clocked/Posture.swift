import Foundation

/// A handful of numbers describing how your head sits, taken from Vision's body-pose and face detection.
/// Lengths are divided by shoulder width so they don't depend on how far you sit from the camera.
struct PostureFeatures: Equatable {
    /// Eyes' height relative to the ears. Drops when you tilt your head down.
    var eyeEar: Double?
    /// Nose height above the shoulder line. Drops when you look down into your lap.
    var noseShoulder: Double?
    /// Vertical position of your face in the frame (0 = bottom, 1 = top).
    var faceY: Double?
    /// Head pitch from face detection, in radians.
    var pitch: Double?
    /// 1 when a face is detected, 0 when only your body is (e.g. looking far down).
    var faceVisible: Double
    /// How open your eyes look (height ÷ width). Eyelids drop when you look down at your lap, even if your head barely moves.
    var eyeOpen: Double?
    /// Head turn left/right in radians (phone on the desk beside the laptop).
    var yaw: Double?
    /// Pupils' height inside the eyes (0.5 ≈ straight ahead, lower = looking down).
    var gazeY: Double?
    /// Shoulder line's height in the frame. Not used to judge posture; a sudden lasting jump means the camera moved
    /// (lid tilted, laptop moved).
    var shoulderY: Double?

    var values: [Double?] { [eyeEar, noseShoulder, faceY, pitch, faceVisible, eyeOpen, yaw, gazeY] }
    /// Someone is at the desk: a face, head joints, or just shoulders (looking far down often hides the face and
    /// nose from the camera, but the shoulders stay in view; that's head down, not away).
    var hasPerson: Bool { faceVisible > 0 || eyeEar != nil || noseShoulder != nil || shoulderY != nil }

    static let count = 8
    /// Smallest spread used per value, so a very still calibration doesn't make everything look "different".
    static let floors: [Double] = [0.03, 0.04, 0.03, 0.05, 0.25, 0.03, 0.06, 0.05]
    /// faceVisible is a yes/no, so it isn't shifted when re-anchoring to a new camera angle.
    static let shiftable: [Bool] = [true, true, true, true, false, true, true, true]
}

enum PostureKind: String, Codable, CaseIterable, Identifiable {
    case screen, paper, phone
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Screen"
        case .paper: return "Paper"
        case .phone: return "Phone"
        }
    }

    var instruction: String {
        switch self {
        case .screen: return "Sit normally and read or type on screen."
        case .paper: return "Write in a notebook or read on the desk."
        case .phone: return "Hold and scroll your phone as you usually do."
        }
    }
}

/// Mean and spread of each posture value for one posture. About 150 bytes.
struct PostureStats: Codable, Equatable {
    var mean: [Double?]
    var spread: [Double?]
    var count: Int
    /// Your "looking at the screen" means at the time this posture was learned. Postures are compared *relative*
    /// to that, so tilting the lid, a different chair or a different desk doesn't throw them off.
    var anchor: [Double?]?

    init?(samples: [PostureFeatures], minimum: Int = 8) {
        let people = samples.filter(\.hasPerson)
        guard people.count >= minimum else { return nil }
        count = people.count
        mean = []
        spread = []
        for i in 0..<PostureFeatures.count {
            let xs = people.compactMap { $0.values[i] }
            // Ignore a value that was rarely visible in this posture.
            guard Double(xs.count) >= Double(people.count) * 0.3 else { mean.append(nil); spread.append(nil); continue }
            let m = xs.reduce(0, +) / Double(xs.count)
            let variance = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
            mean.append(m)
            spread.append(variance.squareRoot())
        }
    }

    private func value(_ array: [Double?], _ i: Int) -> Double? { i < array.count ? array[i] : nil }

    /// This posture as it should look *now*, given how you currently look at the screen.
    func anchored(to liveScreen: [Double?]?) -> PostureStats {
        guard let anchor, let liveScreen else { return self }
        var out = self
        for i in 0..<min(out.mean.count, PostureFeatures.count) where PostureFeatures.shiftable[i] {
            if let m = out.mean[i], let a = value(anchor, i), let l = value(liveScreen, i) { out.mean[i] = m + (l - a) }
        }
        return out
    }

    /// Blends in new examples (e.g. from your corrections). Old data is capped at 40 samples' weight so it keeps adapting.
    func merged(with samples: [PostureFeatures]) -> PostureStats {
        guard let new = PostureStats(samples: samples, minimum: 3) else { return self }
        var out = self
        let w0 = Double(min(count, 40)), w1 = Double(new.count)
        for i in 0..<PostureFeatures.count {
            let m0 = value(mean, i), s0 = value(spread, i)
            let m1 = new.mean[i], s1 = new.spread[i]
            var m: Double?, sd: Double?
            switch (m0, m1) {
            case let (a?, b?):
                let mm = (w0 * a + w1 * b) / (w0 + w1)
                let v0 = (s0 ?? 0) * (s0 ?? 0) + (a - mm) * (a - mm)
                let v1 = (s1 ?? 0) * (s1 ?? 0) + (b - mm) * (b - mm)
                m = mm
                sd = ((w0 * v0 + w1 * v1) / (w0 + w1)).squareRoot()
            case (let a?, nil): m = a; sd = s0
            case (nil, let b?): m = b; sd = s1
            default: break
            }
            if i < out.mean.count { out.mean[i] = m; out.spread[i] = sd } else { out.mean.append(m); out.spread.append(sd) }
        }
        out.count = min(count, 40) + new.count
        return out
    }

    /// How many "spreads" away a sample is from this posture, averaged over the values both have. nil if too little overlap.
    func distance(_ f: PostureFeatures) -> Double? {
        var sum = 0.0, n = 0
        for i in 0..<min(PostureFeatures.count, mean.count) {
            guard let m = mean[i], let x = f.values[i] else { continue }
            let sd = max(value(spread, i) ?? 0, PostureFeatures.floors[i])
            sum += ((x - m) / sd) * ((x - m) / sd)
            n += 1
        }
        return n >= 2 ? (sum / Double(n)).squareRoot() : nil
    }
}

extension PostureFeatures {
    /// Moves a sample from one "looking at the screen" reference to another.
    func shifted(from reference: [Double?]?, to target: [Double?]?) -> PostureFeatures {
        guard let reference, let target else { return self }
        func shift(_ v: Double?, _ i: Int) -> Double? {
            guard let v, i < reference.count, i < target.count, let r = reference[i], let t = target[i] else { return v }
            return v - r + t
        }
        var f = self
        f.eyeEar = shift(eyeEar, 0); f.noseShoulder = shift(noseShoulder, 1); f.faceY = shift(faceY, 2)
        f.pitch = shift(pitch, 3); f.eyeOpen = shift(eyeOpen, 5); f.yaw = shift(yaw, 6); f.gazeY = shift(gazeY, 7)
        return f
    }
}

/// Your taught postures, saved in UserDefaults (a few hundred bytes, numbers only).
struct PostureProfile: Codable, Equatable {
    var postures: [PostureKind: PostureStats] = [:]

    /// How close a sample must be (in spreads) to count as a known posture. Further away → fall back to "vs. your normal".
    static let acceptDistance = 2.5

    /// Closest known posture to this sample, with every posture re-anchored to how you look at the screen right now.
    /// `liveScreen` is learned automatically while you type; it also stands in for "studying on screen" if you haven't taught it.
    func classify(_ f: PostureFeatures, liveScreen: PostureStats?) -> PostureKind? {
        // Without a live reference the camera angle is unknown, so taught postures can't be trusted yet.
        guard f.hasPerson, let liveScreen else { return nil }
        var known = postures.mapValues { $0.anchored(to: liveScreen.mean) }
        known[.screen] = liveScreen
        guard known.count >= 2 else { return nil }
        let scored = known.compactMap { kind, stats in stats.distance(f).map { (kind, $0) } }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 < Self.acceptDistance else { return nil }
        // With no phone posture known yet, only call it "paper" on a close match; otherwise let the
        // head-down check decide, so phone use isn't mistaken for writing.
        if best.0 == .paper, postures[.phone] == nil, best.1 >= 1.5 { return nil }
        return best.0
    }

    /// Adds examples of a posture. `reference` is how you looked at the screen when they were taken.
    mutating func learn(_ kind: PostureKind, from samples: [PostureFeatures], reference: [Double?]?, minimum: Int = 3) {
        let reference = reference ?? postures[.screen]?.mean
        if let existing = postures[kind] {
            // Bring the new samples into the frame of reference this posture was first learned in.
            let aligned = samples.map { $0.shifted(from: reference, to: existing.anchor ?? reference) }
            postures[kind] = existing.merged(with: aligned)
        } else if var fresh = PostureStats(samples: samples, minimum: minimum) {
            fresh.anchor = kind == .screen ? fresh.mean : reference
            postures[kind] = fresh
        }
        // Teaching the screen posture gives earlier un-anchored postures something to be relative to.
        if kind == .screen, let screen = postures[.screen] {
            for (k, stats) in postures where stats.anchor == nil { postures[k]?.anchor = screen.mean }
        }
    }

    static func load() -> PostureProfile {
        guard let data = UserDefaults.standard.data(forKey: "postureProfile"),
              let profile = try? JSONDecoder().decode(PostureProfile.self, from: data) else { return PostureProfile() }
        return profile
    }

    func save() {
        if postures.isEmpty {
            UserDefaults.standard.removeObject(forKey: "postureProfile")
        } else if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "postureProfile")
        }
    }
}

/// Learns your "looking at the screen" posture from moments you're typing (re-learned every session, so it follows
/// your current seat and lid angle), and calls a sample "head down" when most visible cues have dropped clearly below it.
struct TypingBaseline {
    private var samples: [PostureFeatures] = []
    /// Postures you said were *not* phone use ("Not My Phone"), e.g. looking at the bottom of the screen.
    /// Anything close to these isn't counted as head down for the rest of the session.
    private var acceptedAsScreen: [PostureFeatures] = []
    /// Recent shoulder heights, to notice the camera being re-angled.
    private var recentShoulders: [(time: Date, y: Double)] = []
    var isReady: Bool { samples.count >= 5 }

    mutating func add(_ f: PostureFeatures) {
        guard f.hasPerson else { return }
        samples.append(f)
        if samples.count > 120 { samples.removeFirst() }
    }

    mutating func reset() {
        samples = []
        recentShoulders = []
        acceptedAsScreen = []
    }

    mutating func accept(asScreen postures: [PostureFeatures]) {
        acceptedAsScreen.append(contentsOf: postures.filter(\.hasPerson))
        if acceptedAsScreen.count > 60 { acceptedAsScreen.removeFirst(acceptedAsScreen.count - 60) }
    }

    /// Your "looking at the screen" posture, as learned from typing.
    var stats: PostureStats? { PostureStats(samples: samples, minimum: 5) }

    private func median(_ i: Int) -> Double? {
        let xs = samples.compactMap { $0.values[i] }.sorted()
        return xs.count >= 3 ? xs[xs.count / 2] : nil
    }

    /// The more upright end of your typing posture (75th percentile), so glances at the keyboard while typing
    /// don't get learned as "normal".
    private func upright(_ i: Int) -> Double? {
        let xs = samples.compactMap { $0.values[i] }.sorted()
        return xs.count >= 3 ? xs[min(xs.count - 1, xs.count * 3 / 4)] : nil
    }

    /// The reference "looking at the screen" values the network's posture features are measured against.
    var reference: [Double?]? {
        guard isReady else { return nil }
        return [upright(0), upright(1), upright(2), median(3), median(4), upright(5), median(6), upright(7)]
    }

    /// Feed every sample. Returns true when your shoulders have sat at a clearly different height in the frame for
    /// ~10 s: the lid was tilted or the laptop moved, so the baseline is thrown away and re-learned from your next typing.
    mutating func detectCameraMove(_ f: PostureFeatures) -> Bool {
        guard let y = f.shoulderY else { return false }
        let now = Date()
        recentShoulders.append((now, y))
        recentShoulders.removeAll { now.timeIntervalSince($0.time) > 20 }
        if recentShoulders.count > 5 { recentShoulders.removeFirst() }
        let usual = samples.compactMap(\.shoulderY).sorted()
        guard isReady, usual.count >= 5, recentShoulders.count == 5 else { return false }
        let base = usual[usual.count / 2]
        if recentShoulders.allSatisfy({ abs($0.y - base) > 0.06 }) {
            reset()
            return true
        }
        return false
    }

    struct Vote: Identifiable {
        var id: String { name }
        var name: String
        var value: Double?
        var reference: Double?
        /// How far towards "down" this cue is, in units of its margin (1 = clearly down).
        var down: Double?
    }

    /// Each head-down cue with your current value, your baseline and how far "down" it reads (Developer View).
    func explain(_ f: PostureFeatures) -> (votes: [Vote], acceptedAsScreen: Bool, score: Double?, faceHidden: Bool) {
        let accepted = PostureStats(samples: acceptedAsScreen, minimum: 3).flatMap { $0.distance(f) }.map { $0 < 2.0 } ?? false
        let down = Dictionary(uniqueKeysWithValues: downCues(f).map { ($0.name, $0.value) })
        let rows: [(String, Double?, Double?)] = [
            ("Eyes vs ears", f.eyeEar, upright(0)), ("Nose vs shoulders", f.noseShoulder, upright(1)),
            ("Face height", f.faceY, upright(2)), ("Head pitch", f.pitch, median(3)),
            ("Eye openness", f.eyeOpen, upright(5)), ("Gaze (pupils)", f.gazeY, upright(7)),
        ]
        return (rows.map { Vote(name: $0.0, value: $0.1, reference: $0.2, down: down[$0.0]) },
                accepted, isReady ? downScore(f) : nil, isReady && faceHiddenButPresent(f))
    }

    /// How far each cue has moved in the "looking down" direction, in units of its own margin
    /// (1 = clearly down for that cue), capped to −1…2 so one wild reading can't decide alone.
    func downCues(_ f: PostureFeatures) -> [(name: String, value: Double)] {
        var cues: [(String, Double)] = []
        func add(_ name: String, _ d: Double?) { if let d { cues.append((name, min(max(d, -1), 2))) } }
        add("Eyes vs ears", zip2(f.eyeEar, upright(0)).map { ($1 - $0) / 0.10 })
        add("Nose vs shoulders", zip2(f.noseShoulder, upright(1)).map { ($1 - $0) / 0.12 })
        add("Face height", zip2(f.faceY, upright(2)).map { ($1 - $0) / 0.08 })
        add("Head pitch", zip2(f.pitch, median(3)).map { abs($0 - $1) / 0.30 })
        add("Eye openness", zip2(f.eyeOpen, upright(5)).map { (1 - $0 / max($1, 0.01)) / 0.25 })
        add("Gaze (pupils)", zip2(f.gazeY, upright(7)).map { ($1 - $0) / 0.15 })
        return cues
    }

    /// Average of the cues above. Head down when it reaches 1.0 (tuned in Tests/HeadDownTests.swift), or when the face has disappeared while your
    /// shoulders are still in view (you normally face the camera).
    func downScore(_ f: PostureFeatures) -> Double? {
        let cues = downCues(f)
        return cues.isEmpty ? nil : cues.map(\.value).reduce(0, +) / Double(cues.count)
    }

    func faceHiddenButPresent(_ f: PostureFeatures) -> Bool {
        guard let usual = median(4), usual > 0.7 else { return false }
        return f.faceVisible == 0 && f.hasPerson && f.eyeOpen == nil
    }

    static let downThreshold = 1.0

    func isHeadDown(_ f: PostureFeatures) -> Bool {
        guard isReady, f.hasPerson else { return false }
        if let accepted = PostureStats(samples: acceptedAsScreen, minimum: 3), let d = accepted.distance(f), d < 2.0 {
            return false
        }
        if faceHiddenButPresent(f) { return true }
        return (downScore(f) ?? 0) >= Self.downThreshold
    }

    private func zip2(_ a: Double?, _ b: Double?) -> (Double, Double)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}

/// Mouth shape from face landmarks, in face-box units. Compared against your own baseline, never judged absolutely.
struct ExpressionFeatures: Equatable {
    /// Mouth corners' height relative to the middle of the lips, ÷ mouth width. Rises when you smile.
    var mouthCurve: Double
    /// Mouth width as a fraction of face width. Widens when you smile.
    var mouthWidth: Double
    /// Gap between the lips ÷ mouth width. Opens when you laugh.
    var mouthOpen: Double
}

/// Your resting mouth shape, learned while you type (people rarely grin at a keyboard), so a smile is judged against *your* face.
struct ExpressionBaseline {
    private var samples: [ExpressionFeatures] = []
    var isReady: Bool { samples.count >= 5 }

    mutating func add(_ e: ExpressionFeatures) {
        samples.append(e)
        if samples.count > 25 { samples.removeFirst() }
    }

    mutating func reset() { samples = [] }

    var reference: ExpressionFeatures? {
        guard isReady else { return nil }
        return ExpressionFeatures(mouthCurve: median(\.mouthCurve), mouthWidth: median(\.mouthWidth), mouthOpen: median(\.mouthOpen))
    }

    private func median(_ key: KeyPath<ExpressionFeatures, Double>) -> Double {
        let xs = samples.map { $0[keyPath: key] }.sorted()
        return xs[xs.count / 2]
    }

    /// Mouth corners clearly lifted, or a wider mouth with slightly lifted corners, or an open laughing mouth.
    func isSmiling(_ e: ExpressionFeatures) -> Bool {
        guard isReady else { return false }
        let curve = e.mouthCurve - median(\.mouthCurve)
        let widthRatio = e.mouthWidth / max(median(\.mouthWidth), 0.01)
        let open = e.mouthOpen - median(\.mouthOpen)
        // Looking down makes the mouth corners look raised, so curve alone isn't trusted: a smile also widens the mouth.
        return (widthRatio > 1.06 && curve > 0.03) || (widthRatio > 1.03 && open > 0.15 && curve > 0.03)
    }
}
