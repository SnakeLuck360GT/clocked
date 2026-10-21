import Foundation
import Combine

/// One second of the session, turned into 32 numbers for the network. Everything is relative to *your* baseline
/// (posture while typing, resting mouth shape) and bounded to roughly 0…1, so no images, sounds or text are involved.
enum LearningFeatures {
    static let names = [
        "eyes vs ears Δ", "nose vs shoulders Δ", "face height Δ", "head pitch |Δ|", "face visible", "person in view",
        "eye openness Δ", "head turn |Δ|", "baseline ready",
        "mouth curve Δ", "mouth width Δ", "mouth open Δ",
        "phone confidence", "phone in hand",
        "key presses (10 s)", "since mouse", "since any input",
        "media sound share", "sound switches", "sound cuts", "short-form audio",
        "writing sound", "typing sound", "laughter", "notification sound", "Mac playing aloud",
        "camera on", "mic on",
        // Context from the last 10–30 s, so the network sees habits rather than single moments.
        "gaze Δ", "head down share (10 s)", "screen glances (30 s)", "since last key press",
    ]
    static var count: Int { names.count }

    struct Inputs {
        var sample: CameraSample?
        var cameraOn = false
        var postureReference: [Double?]?
        var expressionReference: ExpressionFeatures?
        var keysLast10s = 0
        var secondsSinceMouse: TimeInterval = 60
        var secondsSinceInput: TimeInterval = 60
        var audio: AudioReading?
        var micOn = false
        var macAloud = false
        var phoneAlertRecently = false
        var phoneThreshold: Float = 0.4
        /// In typing mode, writing sounds are ignored here too, so the network sees what the rules see.
        var ignoreWriting = false
        /// Share of the last 10 s with head down, screen glances in the last 30 s, seconds since a key press.
        var headDownShare: Double = 0
        var glances: Int = 0
        var secondsSinceKey: TimeInterval = 120
    }

    static func make(_ i: Inputs) -> [Float] {
        var x = [Float](repeating: 0, count: count)
        let p = i.cameraOn ? i.sample?.posture : nil
        if let p, let ref = i.postureReference {
            func delta(_ value: Double?, _ index: Int, absolute: Bool = false) -> Float {
                guard let value, index < ref.count, let r = ref[index] else { return 0 }
                let d = value - r
                return Float(max(-1, min(1, absolute ? abs(d) : d)))
            }
            x[0] = delta(p.eyeEar, 0)
            x[1] = delta(p.noseShoulder, 1)
            x[2] = delta(p.faceY, 2)
            x[3] = delta(p.pitch, 3, absolute: true)
            if let e = p.eyeOpen, ref.count > 5, let r = ref[5] { x[6] = Float(max(-1, min(1, e / max(r, 0.01) - 1))) }
            x[7] = delta(p.yaw, 6, absolute: true)
            x[8] = 1
        }
        x[4] = Float(p?.faceVisible ?? 0)
        x[5] = p?.hasPerson == true ? 1 : 0
        if i.cameraOn, let e = i.sample?.expression, let r = i.expressionReference {
            x[9] = Float(max(-1, min(1, e.mouthCurve - r.mouthCurve)))
            x[10] = Float(max(-1, min(1, e.mouthWidth / max(r.mouthWidth, 0.01) - 1)))
            x[11] = Float(max(-1, min(1, e.mouthOpen - r.mouthOpen)))
        }
        if i.cameraOn, let s = i.sample {
            x[12] = s.phoneConfidence
            x[13] = s.phoneConfidence >= i.phoneThreshold && s.phoneInHand ? 1 : 0
        }
        x[14] = Float(min(log1p(Double(i.keysLast10s)) / 3, 1))
        x[15] = Float(min(i.secondsSinceMouse, 60) / 60)
        x[16] = Float(min(i.secondsSinceInput, 60) / 60)
        if i.micOn, let a = i.audio {
            x[17] = Float(a.mediaShare)
            x[18] = Float(min(a.switches, 15)) / 15
            x[19] = Float(min(a.cuts, 15)) / 15
            x[20] = a.shortFormLikely ? 1 : 0
            x[21] = a.writingHeard && !i.ignoreWriting ? 1 : 0
            x[22] = a.typingHeard ? 1 : 0
            x[23] = a.laughterHeard ? 1 : 0
            x[24] = i.phoneAlertRecently ? 1 : 0
            x[25] = i.macAloud ? 1 : 0
        }
        x[26] = i.cameraOn ? 1 : 0
        x[27] = i.micOn ? 1 : 0
        if let p, let ref = i.postureReference, let g = p.gazeY, ref.count > 7, let r = ref[7] {
            x[28] = Float(max(-1, min(1, g - r)))
        }
        x[29] = i.cameraOn ? Float(i.headDownShare) : 0
        x[30] = i.cameraOn ? Float(min(i.glances, 6)) / 6 : 0
        x[31] = Float(min(i.secondsSinceKey, 120) / 120)
        return x
    }
}

/// Where a label came from. Explicit ones are what you told the app; implicit ones are inferred.
enum LabelSource: UInt8, CaseIterable {
    case recording = 0   // a posture you recorded (Screen / Paper = 0, Phone = 1)
    case correction = 1  // "Not My Phone" / "Writing Notes" → 0
    case confirmed = 2   // you put the phone away after a nudge without correcting it → 1
    case typing = 3      // typing while facing the screen → 0
    case paper = 4       // "Working on paper" with head down → 0
    case guided = 5      // Teach Phone Detection: what you were asked to do (phone = 1, everything else = 0)

    var title: String {
        switch self {
        case .recording: return "Posture recordings"
        case .correction: return "Your corrections"
        case .confirmed: return "Confirmed nudges"
        case .typing: return "Typing at the screen"
        case .paper: return "Working on paper"
        case .guided: return "Guided teaching"
        }
    }
}

struct LabeledSample {
    var x: [Float]
    var y: UInt8
    var source: LabelSource
    var episode: Int32
}

/// Labelled examples on disk, plus the last 40 seconds of unlabelled features in memory (so a correction can
/// label what just happened). Capped at 1,500 examples (≈ 200 KB), keeping the classes balanced as it fills.
final class LearningStore {
    static let capacity = 1500
    private(set) var samples: [LabeledSample] = []
    private(set) var recent: [(time: Date, x: [Float])] = []
    private(set) var newSinceTraining = 0
    private var nextEpisode: Int32 = 1

    private let url = Storage.file("learning.bin")

    init() { load() }

    var positives: Int { samples.filter { $0.y == 1 }.count }
    var negatives: Int { samples.count - positives }
    func count(from source: LabelSource) -> Int { samples.filter { $0.source == source }.count }

    func newEpisode() -> Int32 {
        defer { nextEpisode += 1 }
        return nextEpisode
    }

    func remember(_ x: [Float], at time: Date) {
        recent.append((time, x))
        recent.removeAll { time.timeIntervalSince($0.time) > 40 }
    }

    func recentFeatures(seconds: TimeInterval, before time: Date = Date()) -> [[Float]] {
        recent.filter { time.timeIntervalSince($0.time) <= seconds && $0.time <= time }.map(\.x)
    }

    func add(_ xs: [[Float]], label: UInt8, source: LabelSource, episode: Int32? = nil) {
        guard !xs.isEmpty else { return }
        let episode = episode ?? newEpisode()
        for x in xs where x.count == LearningFeatures.count {
            // Typing examples are easy and plentiful: at most 40% of capacity, oldest replaced first.
            if source == .typing, Double(count(from: .typing)) >= Double(Self.capacity) * 0.4,
               let oldest = samples.firstIndex(where: { $0.source == .typing }) {
                samples.remove(at: oldest)
            }
            samples.append(LabeledSample(x: x, y: label, source: source, episode: episode))
            newSinceTraining += 1
        }
        while samples.count > Self.capacity {
            let dropLabel: UInt8 = negatives > positives ? 0 : 1
            if let index = samples.firstIndex(where: { $0.y == dropLabel }) { samples.remove(at: index) } else { samples.removeFirst() }
        }
        save()
    }

    func markTrained() { newSinceTraining = 0 }

    func remove(episode: Int32) {
        samples.removeAll { $0.episode == episode }
        save()
    }

    func clear() {
        samples = []
        recent = []
        newSinceTraining = 0
        try? FileManager.default.removeItem(at: url)
    }

    // Binary format: "LKIN", version, feature count, sample count, next episode; then per sample
    // label (1 byte), source (1 byte), episode (Int32), features (Float32 × count).
    private func save() {
        var data = Data("LKIN".utf8)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        append(UInt16(1)); append(UInt16(LearningFeatures.count)); append(UInt32(samples.count)); append(nextEpisode)
        for s in samples {
            append(s.y); append(s.source.rawValue); append(s.episode)
            s.x.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url), data.count >= 16, data.prefix(4) == Data("LKIN".utf8) else { return }
        var offset = 4
        func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            guard offset + MemoryLayout<T>.size <= data.count else { return nil }
            let value = data[offset..<(offset + MemoryLayout<T>.size)].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            offset += MemoryLayout<T>.size
            return value
        }
        guard read(UInt16.self) == 1, let width = read(UInt16.self), Int(width) == LearningFeatures.count,
              let count = read(UInt32.self), let next = read(Int32.self) else { return } // other versions: start fresh
        nextEpisode = next
        let rowBytes = Int(width) * 4
        for _ in 0..<count {
            guard let y = read(UInt8.self), let rawSource = read(UInt8.self), let episode = read(Int32.self),
                  offset + rowBytes <= data.count, let source = LabelSource(rawValue: rawSource) else { break }
            let x = data[offset..<(offset + rowBytes)].withUnsafeBytes { raw in
                (0..<Int(width)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
            offset += rowBytes
            samples.append(LabeledSample(x: x, y: y, source: source, episode: episode))
        }
    }
}

/// Owns the network: retrains it in the background when enough new labels arrive, and decides how much
/// say it gets. It only influences detection once it has proven itself on episodes it never trained on.
@MainActor
final class Learner: ObservableObject {
    @Published private(set) var model: PhoneNet?
    @Published private(set) var report: PhoneNet.Report?
    @Published private(set) var isTraining = false
    /// Bumped whenever examples are added, so views showing counts refresh.
    @Published private(set) var revision = 0
    let store = LearningStore()

    nonisolated static let minimumPerClass = 30
    static let retrainEvery = 40

    private let modelURL = Storage.file("model.json")

    private struct Saved: Codable { var model: PhoneNet; var report: PhoneNet.Report }

    init() {
        if let data = try? Data(contentsOf: modelURL), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           saved.model.mean.count == LearningFeatures.count {
            model = saved.model
            report = saved.report
        }
    }

    /// 0 = ignored, 1 = full say.
    var influence: Double {
        guard model != nil, let report else { return 0 }
        return Self.influence(for: report)
    }

    /// Rises from 0 to 1 as the pessimistic validation accuracy goes from 70% to 90%.
    nonisolated static func influence(for r: PhoneNet.Report) -> Double {
        guard r.trainPositives >= minimumPerClass, r.trainNegatives >= minimumPerClass,
              r.validationPositives >= 10, r.validationNegatives >= 10 else { return 0 }
        return Double(min(max((r.balancedAccuracyLowerBound - 0.7) / 0.2, 0), 1))
    }

    var hasEnoughData: Bool { store.positives >= Self.minimumPerClass && store.negatives >= Self.minimumPerClass }

    func probability(_ x: [Float]) -> Float? {
        guard influence > 0, let model else { return nil }
        return model.predict(x)
    }

    @discardableResult
    func add(_ xs: [[Float]], label: UInt8, source: LabelSource, episode: Int32? = nil) -> Int32 {
        let episode = episode ?? store.newEpisode()
        store.add(xs, label: label, source: source, episode: episode)
        revision += 1
        if store.newSinceTraining >= Self.retrainEvery { trainIfNeeded() }
        return episode
    }

    func remove(episode: Int32) {
        store.remove(episode: episode)
        revision += 1
        trainIfNeeded(force: true) // don't keep a model trained on a label that was just withdrawn
    }

    func trainIfNeeded(force: Bool = false) {
        guard hasEnoughData, force || store.newSinceTraining > 0 else { return }
        guard !isTraining else {
            retrainQueued = true // run again with the newest data once this round finishes
            return
        }
        isTraining = true
        let generation = self.generation
        let examples = store.samples.map { PhoneNet.Example(x: $0.x, y: Float($0.y), episode: Int($0.episode)) }
        store.markTrained()
        Task.detached(priority: .utility) {
            var (trained, report) = PhoneNet.train(examples, inputs: LearningFeatures.count)
            // Judge it on every example (each scored by a network that never saw its episode), not one small split.
            if let cv = PhoneNet.crossValidate(examples, inputs: LearningFeatures.count) {
                report.balancedAccuracy = cv.balancedAccuracy
                report.balancedAccuracyLowerBound = cv.balancedAccuracyLowerBound
                report.precision = cv.precision
                report.recall = cv.recall
                report.validationPositives = cv.validationPositives
                report.validationNegatives = cv.validationNegatives
                report.validationCount = cv.validationCount
                report.folds = cv.folds
            }
            let (net, finalReport) = (trained, report)
            await MainActor.run {
                self.isTraining = false
                guard generation == self.generation else { return } // reset while training: discard
                self.model = net
                self.report = finalReport
                if let data = try? JSONEncoder().encode(Saved(model: net, report: finalReport)) {
                    try? data.write(to: self.modelURL, options: .atomic)
                }
                if self.retrainQueued {
                    self.retrainQueued = false
                    self.trainIfNeeded(force: true)
                }
            }
        }
    }

    private var generation = 0
    private var retrainQueued = false

    func reset() {
        generation += 1
        retrainQueued = false
        store.clear()
        model = nil
        report = nil
        revision += 1
        try? FileManager.default.removeItem(at: modelURL)
    }
}
