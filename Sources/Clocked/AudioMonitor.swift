import AVFoundation
import CoreAudio
import SoundAnalysis

/// Summary of the last ~30 s of room audio. No audio is kept: each buffer is classified and dropped.
struct AudioReading: Equatable {
    /// When this reading was made; old readings are ignored.
    var at = Date()
    /// The sound keeps flipping between speech / music / laughter with abrupt cuts, like scrolling TikTok or Reels.
    var shortFormLikely = false
    /// How often the kind of sound changed in the last 30 s.
    var switches = 0
    /// Abrupt loudness jumps (clip boundaries) in the last 30 s.
    var cuts = 0
    /// What's mostly playing right now ("music", "speech", "laughter", "quiet", "other").
    var current = "quiet"
    /// Share of the last ~10 s that was speech / music / laughter (i.e. something like a video playing).
    var mediaShare = 0.0
    /// Pen-on-paper sounds in the last ~10 s.
    var writingHeard = false
    /// Keyboard sounds in the last ~10 s.
    var typingHeard = false
    /// Laughter in the last ~10 s.
    var laughterHeard = false
    /// When a ringtone / phone bell was last heard.
    var phoneAlertAt: Date?
}

/// Listens to the Mac's built-in mic during a session and recognises the *pattern* of short-form video audio.
/// Steady music (with or without vocals or rap), lectures and podcasts are fine: they don't switch every few seconds.
final class AudioMonitor: NSObject, SNResultsObserving {
    var onReading: ((AudioReading) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private let queue = DispatchQueue(label: "audio.analysis", qos: .utility)
    private var groups: [(time: Date, group: String, writing: Bool, typing: Bool)] = []
    private var lastPhoneAlert: Date?
    private var levels: [(time: Date, db: Float, typing: Bool)] = []
    private var activeRequest: SNRequest?
    private var configObserver: NSObjectProtocol?
    /// Set by start(), cleared by stop(), both on the main thread; a late hardware-change restart checks it.
    private var wanted = false
    private var levelAccumulator: (sum: Float, count: Int, start: Date, typing: Bool)?
    private var positiveStreak = 0
    private var lastEvaluation = Date.distantPast

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        stop()
        wanted = true
        // Use the built-in mic so AirPods/Bluetooth headphones don't drop into low-quality "headset" mode while you listen to music.
        if let builtIn = Self.builtInMicrophoneID(), let unit = engine.inputNode.audioUnit {
            var id = builtIn
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let input = engine.inputNode
        // Read the hardware format *after* switching device; a stale format makes installTap throw.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CameraError.cannotConfigure }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        try analyzer.add(request, withObserver: self)
        queue.sync {
            self.analyzer = analyzer
            self.activeRequest = request
        }

        input.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, time in
            // Keyboard clicks right next to a MacBook mic look like loud cuts, so note when you're typing.
            let typing = secondsSinceUserInput() < 0.75
            self?.queue.async {
                guard let self, self.analyzer === analyzer else { return }
                analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
                self.measureLevel(buffer, typing: typing)
            }
        }
        engine.prepare()
        try engine.start()

        // Audio hardware changed (headphones plugged in, device switched): restart on the built-in mic.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self, self.wanted else { return }
                try? self.start()
            }
        }
    }

    func stop() {
        wanted = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        // The analyzer isn't thread-safe: tear it down on the same queue that feeds it.
        queue.async { [self] in
            activeRequest = nil
            analyzer?.completeAnalysis()
            analyzer = nil
            groups.removeAll(); levels.removeAll(); levelAccumulator = nil; positiveStreak = 0; lastPhoneAlert = nil
            lastEvaluation = .distantPast
        }
    }

    // MARK: - SNResultsObserving

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let top = result.classifications.first
        let group = (top?.confidence ?? 0) > 0.3 ? Self.group(for: top!.identifier) : "other"
        // Quiet sounds rarely win outright, so check these labels directly.
        func confidence(_ ids: String...) -> Double { ids.compactMap { result.classification(forIdentifier: $0)?.confidence }.max() ?? 0 }
        let writing = confidence("writing") > 0.25
        let typing = confidence("typing", "typing_computer_keyboard", "typewriter") > 0.3
        let alert = confidence("ringtone", "telephone_bell_ringing") > 0.4
        queue.async { [self] in
            guard request === activeRequest else { return } // late result from a stopped session
            let now = Date()
            groups.append((now, group, writing, typing))
            if alert { lastPhoneAlert = now }
            evaluateIfDue()
        }
    }

    // MARK: - Analysis (runs on `queue`)

    private func measureLevel(_ buffer: AVAudioPCMBuffer, typing: Bool) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        let now = Date()
        var acc = levelAccumulator ?? (0, 0, now, false)
        acc.sum += sum
        acc.count += Int(buffer.frameLength)
        acc.typing = acc.typing || typing
        // Average loudness over half-second blocks, so drum hits don't look like cuts.
        if now.timeIntervalSince(acc.start) >= 0.5 {
            let rms = sqrt(acc.sum / Float(max(acc.count, 1)))
            levels.append((now, 20 * log10(max(rms, 1e-7)), acc.typing))
            levelAccumulator = nil
        } else {
            levelAccumulator = acc
        }
    }

    private func evaluateIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastEvaluation) >= 2.5 else { return }
        lastEvaluation = now
        let cutoff = now.addingTimeInterval(-30)
        groups.removeAll { $0.time < cutoff }
        levels.removeAll { $0.time < cutoff }

        let result = Self.assess(groups: groups.map(\.group), levels: levels.map(\.db), typing: levels.map(\.typing))
        positiveStreak = result.looksShortForm ? positiveStreak + 1 : 0

        let recent = groups.filter { now.timeIntervalSince($0.time) <= 10 }
        var reading = AudioReading(
            // Needs ~15 s of positive checks in a row on top of the 30 s window before it counts.
            shortFormLikely: positiveStreak >= Self.requiredStreak,
            switches: result.switches, cuts: result.cuts,
            current: groups.last?.group ?? "quiet")
        if !recent.isEmpty {
            reading.mediaShare = Double(recent.filter { ["speech", "music", "laughter"].contains($0.group) }.count) / Double(recent.count)
            reading.writingHeard = recent.contains { $0.writing }
            reading.typingHeard = recent.contains { $0.typing }
            reading.laughterHeard = recent.contains { $0.group == "laughter" }
        }
        reading.phoneAlertAt = lastPhoneAlert
        onReading?(reading)
    }

    /// Checks run every 2.5 s, so 6 in a row ≈ 15 s.
    static let requiredStreak = 6

    /// Looks at ~30 s of sound-kind labels (one per 0.75 s) and loudness (one per 0.5 s).
    static func assess(groups: [String], levels: [Float], typing: [Bool] = []) -> (switches: Int, cuts: Int, looksShortForm: Bool) {
        // Majority-of-3 smoothing so a single odd label inside a song doesn't count as a switch.
        let smoothed = groups.indices.map { i -> String in
            guard i > 0, i < groups.count - 1 else { return groups[i] }
            let (a, b, c) = (groups[i - 1], groups[i], groups[i + 1])
            return a == c ? a : b
        }
        // Collapse runs, ignoring quiet/unknown windows, and count switches between kinds of sound.
        let audible = smoothed.filter { $0 == "speech" || $0 == "music" || $0 == "laughter" }
        var runs: [String] = []
        for g in audible where runs.last != g { runs.append(g) }
        let switches = max(0, runs.count - 1)
        let kinds = Set(audible)

        // Abrupt jumps of 12+ dB between half-second blocks while something is actually playing.
        var cuts = 0
        for i in levels.indices.dropFirst() where max(levels[i - 1], levels[i]) > -50 && abs(levels[i - 1] - levels[i]) >= 12 {
            let typed = i < typing.count && (typing[i] || typing[i - 1])
            if !typed { cuts += 1 }
        }

        // Score per 30 s = switches + cuts. Tested offline: 11 real songs scored 0–4 (always 0 switches), a podcast ≤1,
        // music with someone chatting over it ≤5; scrolling-style clip mashes scored 6–8 for long stretches.
        let enoughSound = Double(audible.count) >= Double(max(groups.count, 1)) * 0.5
        let mixed = kinds.contains("speech") && (kinds.contains("music") || kinds.contains("laughter"))
        let looksShortForm = enoughSound && mixed && switches >= 1 && switches + cuts >= 6
        return (switches, cuts, looksShortForm)
    }

    static func group(for id: String) -> String {
        switch id {
        case "silence": return "quiet"
        case "speech", "shout", "yell", "whispering", "children_shouting", "conversation", "narration_monologue":
            return "speech"
        case "laughter", "baby_laughter", "giggling", "belly_laugh", "chuckle_chortle":
            return "laughter"
        default:
            let musical = ["music", "sing", "choir", "rapping", "guitar", "piano", "drum", "keyboard_musical", "bass",
                           "synthesizer", "violin", "cello", "trumpet", "saxophone", "flute", "orchestra", "beatbox"]
            return musical.contains(where: id.contains) ? "music" : "other"
        }
    }

    /// True when the Mac is currently sending sound to its speakers (not headphones).
    /// If so, music the mic hears is probably yours; if not, sound in the room is coming from somewhere else, like a phone.
    static func macPlayingAloud() -> Bool {
        func get(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope, _ initial: UInt32) -> UInt32? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value = initial
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        guard let device = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)),
              device != 0,
              let running = get(device, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)),
              running != 0 else { return false }
        let transport = get(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return false }
        let source = get(device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, UInt32(0)) ?? 0
        return source != 0x6864706E // 'hdpn' = wired headphones
    }

    private static func builtInMicrophoneID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }

        return ids.first { id in
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioDevicePropertyScopeInput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr && sSize > 0
        }
    }
}
