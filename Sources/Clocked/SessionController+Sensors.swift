import AppKit

/// Turning sensors on and off, recording postures, and handling camera samples.
extension SessionController {
    // MARK: - Sensors

    func startSensors() {
        if settings.useScreen { activityMonitor.start() }
        if settings.useCamera { startCamera() }
        if settings.useMic { startMic() }
    }

    func stopSensors() {
        sensorGeneration += 1
        judgeTask?.cancel()
        activityMonitor.stop()
        camera.stop()
        audio.stop()
        cameraState = .off
        micState = .off
        lastSample = nil
        lastSampleAt = nil
        lastAudio = nil
        lastPersonSeen = nil
        posture = .unknown
        activity = nil
        judgement = nil
        browserProblem = nil
    }

    func startCamera() {
        cameraState = .starting
        let generation = sensorGeneration
        Task {
            guard await CameraMonitor.requestAccess() else { cameraState = .denied; return }
            guard sensorsWanted, generation == sensorGeneration else { return }
            camera.start { [weak self] error in
                Task { @MainActor in
                    guard let self, self.sensorsWanted, generation == self.sensorGeneration else { return }
                    if let error { self.cameraState = .failed(error.localizedDescription); return }
                    self.cameraState = .on
                    self.cameraStartedAt = Date()
                }
            }
        }
    }

    func startMic() {
        micState = .starting
        let generation = sensorGeneration
        Task {
            guard await AudioMonitor.requestAccess() else { micState = .denied; return }
            guard sensorsWanted, calibration == nil, generation == sensorGeneration else { return }
            do {
                try audio.start()
                micState = .on
            } catch {
                micState = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs camera + mic for 45 s outside a session so you can see the live readings in Settings.
    func startSensorTest() {
        guard phase == .idle || phase == .finished, !sensorTestRunning, calibration == nil else { return }
        resetCorrections()
        typingBaseline.reset(); expressionBaseline.reset()
        sensorTestRunning = true
        evidence.reset()
        if settings.useCamera { startCamera() }
        if settings.useMic { startMic() }
        ticker?.invalidate()
        ticker = makeTicker()
        testTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.stopSensorTest()
        }
    }

    func stopSensorTest() {
        if teaching != nil { teachingTask?.cancel(); teaching = nil }
        guard sensorTestRunning else { return }
        testTask?.cancel()
        sensorTestRunning = false
        ticker?.invalidate()
        ticker = nil
        stopSensors()
    }

    // MARK: - Teaching your postures

    /// Watches you for 15 s in one posture (after a 5 s countdown) and remembers it as a few numbers.
    func calibrate(_ kind: PostureKind) {
        guard phase == .idle || phase == .finished, calibration == nil else { return }
        stopSensorTest()
        calibrationMessage = nil
        calibrationSamples = []
        calibrationInputs = []
        calibrationReferenceSamples = []
        calibration = CalibrationState(kind: kind, countdown: 5, progress: 0)
        camera.sampleInterval = 0.5
        startCamera()
        calibrationTask = Task { [weak self] in
            for i in stride(from: 5, to: 0, by: -1) {
                self?.calibration?.countdown = i
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.calibration?.countdown = 0
            self.calibrationCapturing = true
            NSSound(named: "Tink")?.play()
            for step in 1...30 {
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled else { return }
                self.calibration?.progress = Double(step) / 30
            }
            self.calibrationCapturing = false
            NSSound(named: "Glass")?.play()
            var profile = self.postureProfile
            profile.postures[kind] = nil // "Redo" replaces rather than blends
            profile.learn(kind, from: self.calibrationSamples, reference: nil, minimum: 8)
            if profile.postures[kind] != nil {
                self.postureProfile = profile
                self.postureProfile.save()
                self.learnFromRecording(kind)
                self.calibrationMessage = "Recorded: \(kind.title)."
            } else {
                self.calibrationMessage = "Not enough data. Keep your head and shoulders in view and try again."
            }
            self.finishCalibration()
        }
    }

    func cancelCalibration() {
        calibrationTask?.cancel()
        finishCalibration()
    }

    func finishCalibration() {
        calibrationCapturing = false
        calibration = nil
        camera.sampleInterval = 1
        stopSensors()
    }

    func forgetPostures() {
        postureProfile = PostureProfile()
        postureProfile.save()
        phoneGain = 1.0
        calibrationMessage = "Postures reset."
    }

    // MARK: - Camera samples

    func handle(_ sample: CameraSample) {
        guard sensorsWanted else { return }
        let now = Date()
        lastSample = sample
        lastSampleAt = now
        if developerViewOpen { debugFrame = sample.debug }
        // During the first seconds of the countdown you're looking at the screen: that's this sitting's reference.
        if !calibrationCapturing, let countdown = calibration?.countdown, countdown >= 3, let f = sample.posture {
            calibrationReferenceSamples.append(f)
        }
        if calibrationCapturing, let f = sample.posture {
            calibrationSamples.append(f)
            calibrationInputs.append((sample, secondsSince(.keyDown) < 10 ? 5 : 0,
                                      min(secondsSince(.mouseMoved), 60), min(secondsSinceUserInput(), 60)))
        }
        guard calibration == nil else { return }

        if sample.posture != nil { lastPersonSeen = now }
        // While you're typing you're almost always looking at the screen: learn that as your normal posture.
        // You just pressed Start (or a subject's play button), so the first seconds of a session are screen posture.
        let justStarted = phase == .running && now.timeIntervalSince(sessionStart) < 8 && !typingBaseline.isReady
        let usingMac = justStarted || secondsSince(.keyDown) < 3 || secondsSince(.scrollWheel) < 2 || secondsSince(.leftMouseDown) < 2
        if let f = sample.posture, usingMac {
            // Typing, yet your shoulders sit somewhere new in the frame: the lid was tilted or the laptop moved.
            // (Only checked while typing, so hunching over your phone can't wipe the baseline.)
            if typingBaseline.detectCameraMove(f) {
                cameraMovedAt = now
                expressionBaseline.reset()
                evidence.clear()
            }
            typingBaseline.add(f)
            if let e = sample.expression { expressionBaseline.add(e) }
        }
        // Clicking or scrolling means you're looking at the screen wherever the pointer is, corners included,
        // so those postures widen what counts as "looking at the screen".
        if let f = sample.posture, secondsSince(.leftMouseDown) < 1.5 || secondsSince(.scrollWheel) < 1.5 {
            typingBaseline.accept(asScreen: [f])
        }
        smiling = sample.expression.map(expressionBaseline.isSmiling) ?? false
        posture = verdict(for: sample.posture)
        if let f = sample.posture {
            recentPostures.append((now, f, posture))
            recentPostures.removeAll { now.timeIntervalSince($0.time) > 30 }
        }
    }

    func verdict(for f: PostureFeatures?) -> PostureVerdict {
        guard let f else { return .absent }
        var v: PostureVerdict
        if let kind = postureProfile.classify(f, liveScreen: typingBaseline.stats) {
            switch kind {
            case .screen: v = typingBaseline.isHeadDown(f) && postureProfile.postures[.phone] == nil ? .down : .screen
            case .paper: v = .paper
            case .phone: v = .phone
            }
        } else if typingBaseline.isReady {
            v = typingBaseline.isHeadDown(f) ? .down : .screen
        } else {
            v = .unknown
        }
        if v.isDown, let until = paperModeUntil, until > Date() { v = .paper }
        if v.isDown && !settings.headDownCountsAsPhone { v = .unknown }
        return v
    }

    func isPhoneSighting(_ s: CameraSample) -> Bool {
        s.phoneConfidence >= settings.phoneThreshold && (s.phoneInHand || !s.phoneLowInFrame)
    }

    func activityChanged(_ snapshot: ActivitySnapshot) {
        let sameSite = activity?.siteKey == snapshot.siteKey
        activity = snapshot
        judgeTask?.cancel()
        if let hit = judge.cached(snapshot) {
            judgement = hit
            return
        }
        // Same site, new title (autoplay, unread counters): keep the current verdict until the new one is in,
        // so the distraction timer and any warning aren't reset.
        if !sameSite { judgement = nil }
        // Wait a moment so quickly flicking through tabs doesn't trigger a check for each one.
        judgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, self.activity == snapshot else { return }
            let result = await self.judge.judge(snapshot, topic: self.topic)
            guard self.activity == snapshot else { return }
            self.judgement = result
        }
    }
}
