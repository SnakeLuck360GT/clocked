import AppKit
import AVFoundation

/// One situation to act out while Clocked watches.
struct TeachingStep: Equatable {
    let title: String
    let instruction: String
    /// Read aloud at the start, since in the phone steps you're not looking at the screen.
    let spoken: String
    let onPhone: Bool
    let seconds: Int
}

struct TeachingState: Equatable {
    var index: Int
    var steps: [TeachingStep]
    /// Seconds left to get ready (0 while recording).
    var countdown: Int
    var progress: Double
    var added: Int
    var step: TeachingStep { steps[index] }
}

/// Teach Phone Detection: a few minutes of clearly labelled situations. Without it the network mostly sees
/// moments the rules already flagged, so it learns "not typing = phone" and can't tell reading from scrolling.
extension SessionController {
    func teachingSteps() -> [TeachingStep] {
        var steps = [
            TeachingStep(title: "Type at your screen", instruction: "Type anything, like notes or a message to yourself. This sets your normal posture.",
                         spoken: "First, type at your screen.", onPhone: false, seconds: 30),
            TeachingStep(title: "Read the screen", instruction: "Read something on the screen. Keep your hands off the keyboard.",
                         spoken: "Now read the screen, without typing.", onPhone: false, seconds: 30),
            TeachingStep(title: "Phone in your lap", instruction: "Scroll your phone in your lap, the way you usually do.",
                         spoken: "Now scroll your phone in your lap.", onPhone: true, seconds: 35),
            TeachingStep(title: "Write on paper", instruction: "Write or doodle on paper.",
                         spoken: "Put the phone away and write on paper.", onPhone: false, seconds: 30),
            TeachingStep(title: "Phone another way", instruction: "Use your phone in your hand or on the desk. Sound on is fine.",
                         spoken: "Now use your phone another way. Sound on is fine.", onPhone: true, seconds: 35),
            TeachingStep(title: "Sit back and think", instruction: "Look around the room and think. No phone.",
                         spoken: "Put the phone down. Sit back and think.", onPhone: false, seconds: 30),
            TeachingStep(title: "Watch something on your phone", instruction: "Watch a video or reels on your phone.",
                         spoken: "Last one. Watch something on your phone.", onPhone: true, seconds: 35),
        ]
        if settings.studyStyle == .typing { steps.removeAll { $0.title == "Write on paper" } }
        return steps
    }

    func startTeaching() {
        guard phase == .idle || phase == .finished, calibration == nil, teaching == nil else { return }
        stopSensorTest()
        typingBaseline.reset(); expressionBaseline.reset()
        evidence.reset()
        teachingMessage = nil
        sensorTestRunning = true
        if settings.useCamera { startCamera() }
        if settings.useMic { startMic() }
        ticker?.invalidate()
        ticker = makeTicker()
        teaching = TeachingState(index: 0, steps: teachingSteps(), countdown: 5, progress: 0, added: 0)
        teachingTask = Task { [weak self] in await self?.runTeaching() }
    }

    func skipTeachingStep() { teachingSkip = true }

    func stopTeaching() {
        let added = teaching?.added ?? 0
        stopSensorTest()
        voice.stopSpeaking(at: .immediate)
        if added > 0 {
            teachingMessage = "Stopped. Kept \(added) examples from the finished steps."
            learner.trainIfNeeded(force: true)
        }
    }

    private func runTeaching() async {
        guard let steps = teaching?.steps else { return }
        for (index, step) in steps.enumerated() {
            guard teaching != nil, !Task.isCancelled else { return }
            teachingSkip = false
            teaching?.index = index
            teaching?.progress = 0
            say(step.spoken)
            for left in stride(from: 5, through: 1, by: -1) where !teachingSkip {
                teaching?.countdown = left
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled || teaching == nil { return }
            }
            teaching?.countdown = 0
            NSSound(named: "Tink")?.play()
            var elapsed = 0
            while elapsed < step.seconds, !teachingSkip {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled || teaching == nil { return }
                elapsed += 1
                teaching?.progress = Double(elapsed) / Double(step.seconds)
            }
            if teachingSkip { continue }
            // Leave out the first seconds, while you're still moving into position.
            let xs = learner.store.recentFeatures(seconds: Double(step.seconds - 4))
            if !xs.isEmpty {
                learner.add(xs, label: step.onPhone ? 1 : 0, source: .guided)
                teaching?.added += xs.count
            }
        }
        let added = teaching?.added ?? 0
        stopSensorTest()
        NSSound(named: "Glass")?.play()
        say("All done. Thanks!")
        if added > 0 {
            teachingMessage = "Added \(added) examples. Retraining now; the results appear below in a moment."
            learner.trainIfNeeded(force: true)
        } else {
            teachingMessage = "Nothing was recorded. Check that the camera or microphone is allowed and turned on in Detection settings."
        }
    }

    private func say(_ text: String) {
        voice.stopSpeaking(at: .immediate)
        voice.speak(AVSpeechUtterance(string: text))
    }
}
