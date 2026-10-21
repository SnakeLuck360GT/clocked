import AppKit

/// Corrections and the on-device learning loop.
extension SessionController {
    // MARK: - Corrections (each one makes it smarter)

    func markCurrent(as verdict: Verdict) {
        guard let activity else { return }
        judgeTask?.cancel()
        judge.override(activity, as: verdict)
        judgement = judge.cached(activity)
        // For sites like YouTube/Reddit/Google, only this exact page is remembered (for this session).
        if !Lists.isRabbitHole(activity) {
            settings.remember(activity.label, asStudy: verdict == .study)
        }
        if verdict == .study {
            distractedSince = nil
            episodeNudged = false
            curtain.hide()
        }
    }

    /// "I'm writing notes": learn this posture as paper work, and ignore looking down for 25 min.
    func writingNotes() {
        undoRecentLesson()
        learner.add(learner.store.recentFeatures(seconds: 20), label: 0, source: .correction)
        let downs = recentPostures.filter { $0.verdict.isDown }.map(\.features)
        learn(.paper, from: downs, gainChange: 0.95)
        setPaperMode(true)
        clearPhoneFlag()
    }

    /// "Not on my phone": be a little less eager from now on, and give it 5 minutes' rest.
    /// "Not My Phone": teach, don't switch off. The posture you were in now counts as looking at the screen for
    /// the rest of the session, the network gets those seconds as "not phone", and detection pauses only briefly.
    func notOnPhone() {
        undoRecentLesson()
        learner.add(learner.store.recentFeatures(seconds: 20), label: 0, source: .correction)
        let corrected = recentPostures.filter { Date().timeIntervalSince($0.time) <= 20 && $0.verdict.isDown }.map(\.features)
        typingBaseline.accept(asScreen: corrected)
        phoneGain *= 0.97
        phoneSnoozedUntil = Date().addingTimeInterval(30)
        refundHeldTime()
        clearPhoneFlag()
        hud.show(symbol: "checkmark.circle", title: "Got it",
                 message: corrected.isEmpty ? "Detection will be a little less eager."
                                            : "That posture now counts as looking at your screen.",
                 tint: .green, sound: false)
    }

    func setPaperMode(_ on: Bool) {
        paperModeUntil = on ? Date().addingTimeInterval(25 * 60) : nil
        if on { clearPhoneFlag() }
    }

    /// Undoes the automatic lesson only if it came from the nudge being corrected now.
    func undoRecentLesson() {
        if let undo = undoLesson, Date().timeIntervalSince(undo.time) < 180, undo.nudgeTime == lastPhoneNudge {
            postureProfile = undo.profile
            postureProfile.save()
            phoneGain = undo.gain
            if let episode = undo.episode { learner.remove(episode: episode) }
        }
        undoLesson = nil
    }

    func clearPhoneFlag() {
        pendingPhoneLesson = nil
        evidence.clear()
        distractedSince = nil
        episodeNudged = false
        curtain.hide()
        hud.hide(animated: true)
    }

    func learn(_ kind: PostureKind, from samples: [PostureFeatures], gainChange: Double) {
        phoneGain *= gainChange
        guard samples.count >= 3 else { return }
        postureProfile.learn(kind, from: samples, reference: typingBaseline.stats?.mean)
        postureProfile.save()
    }

    // MARK: - Learning

    /// Turns this second into network features, keeps them briefly for labelling, collects the easy automatic
    /// labels, and asks the network for its estimate.
    func observeForLearning(now: Date) {
        let cameraOn = settings.useCamera && cameraState == .on && (lastSampleAt.map { now.timeIntervalSince($0) < 6 } ?? false)
        let micOn = settings.useMic && micState == .on && (lastAudio.map { now.timeIntervalSince($0.at) < 10 } ?? false)
        guard cameraOn || micOn else {
            learnedProbability = nil
            return
        }
        var inputs = LearningFeatures.Inputs()
        inputs.sample = lastSample
        inputs.cameraOn = cameraOn
        inputs.postureReference = typingBaseline.reference
        inputs.expressionReference = expressionBaseline.reference
        inputs.keysLast10s = cues.keysLast10s
        inputs.secondsSinceMouse = cues.secondsSinceMouse
        inputs.secondsSinceInput = cues.secondsSinceInput
        inputs.audio = micOn ? lastAudio : nil
        inputs.micOn = micOn
        inputs.macAloud = lastMacAloud
        inputs.phoneAlertRecently = cues.phoneAlertRecently
        inputs.phoneThreshold = settings.phoneThreshold
        inputs.ignoreWriting = settings.studyStyle == .typing
        let lastTen = recentPostures.filter { now.timeIntervalSince($0.time) <= 10 }
        inputs.headDownShare = lastTen.isEmpty ? 0 : Double(lastTen.filter { $0.verdict.isDown }.count) / Double(lastTen.count)
        inputs.glances = zip(recentPostures, recentPostures.dropFirst()).filter { $0.0.verdict != .screen && $0.1.verdict == .screen }.count
        inputs.secondsSinceKey = secondsSince(.keyDown)
        let x = LearningFeatures.make(inputs)
        learner.store.remember(x, at: now)

        learnedProbability = learner.probability(x)
        if developerViewOpen {
            lastFeatures = x
            lastAttribution = learner.model?.attribution(x) ?? []
        }
        cues.learnedProbability = learnedProbability
        cues.learnedInfluence = learner.influence

        // Automatic negatives, one every 15 s at most: typing while facing the screen, or declared paper work.
        guard phase == .running, now.timeIntervalSince(lastAutoLabel) >= 15, !evidence.active else { return }
        if cues.keysLast10s > 5, posture == .screen {
            lastAutoLabel = now
            learner.add([x], label: 0, source: .typing, episode: sessionEpisode)
        } else if let until = paperModeUntil, until > now, posture.isDown || posture == .paper,
                  x[21] == 1, x[12] < settings.phoneThreshold {
            // Paper mode lasts 25 minutes, so only label seconds that sound like writing and show no phone.
            lastAutoLabel = now
            learner.add([x], label: 0, source: .paper, episode: sessionEpisode)
        }
    }

    /// A posture recording is the cleanest training data there is: Phone = 1, Screen and Paper = 0.
    func learnFromRecording(_ kind: PostureKind) {
        // Measure against "looking at the screen" from this same sitting, the same way live sessions do:
        // the Screen recording itself, or the countdown before a Paper/Phone recording (you're watching it).
        var screen = TypingBaseline()
        for f in kind == .screen ? calibrationSamples : calibrationReferenceSamples { screen.add(f) }
        guard let reference = screen.reference ?? postureProfile.postures[.screen]?.mean else { return }
        // Over a recording you hold one posture, so its head-down share is that posture's own.
        let downShare = calibrationSamples.isEmpty ? 0
            : Double(calibrationSamples.filter { screen.isHeadDown($0) }.count) / Double(calibrationSamples.count)
        let xs = calibrationInputs.map { capture -> [Float] in
            var inputs = LearningFeatures.Inputs()
            inputs.sample = capture.sample
            inputs.sample?.expression = nil // no resting-face reference outside a session
            inputs.cameraOn = true
            inputs.postureReference = reference
            inputs.keysLast10s = capture.keys
            inputs.secondsSinceMouse = capture.sinceMouse
            inputs.secondsSinceInput = capture.sinceInput
            inputs.phoneThreshold = settings.phoneThreshold
            inputs.headDownShare = kind == .screen ? 0 : downShare
            inputs.secondsSinceKey = Double(capture.keys > 0 ? 2 : 60)
            return LearningFeatures.make(inputs)
        }
        learner.add(xs, label: kind == .phone ? 1 : 0, source: .recording)
        learner.trainIfNeeded(force: true)
    }
}
