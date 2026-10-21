import AppKit

/// The once-a-second loop: gather cues, update the phone evidence, decide the status, count time.
extension SessionController {
    // MARK: - Every second

    func gatherCues(now: Date) -> FocusCues {
        var c = FocusCues()
        c.studyStyle = settings.studyStyle
        // Camera says "on" but no frames for 10 s: treat it as failed rather than trusting stale data.
        if cameraState == .on, now.timeIntervalSince(lastSampleAt ?? cameraStartedAt) > 10 {
            cameraState = .failed("No frames")
        }
        let cameraFresh = settings.useCamera && cameraState == .on && (lastSampleAt.map { now.timeIntervalSince($0) < 6 } ?? false)
        if cameraFresh, let s = lastSample {
            c.phoneVisible = isPhoneSighting(s)
            c.posture = posture
            c.smiling = smiling
        }

        let keys = keyPressCount()
        keyHistory.append((now, keys))
        keyHistory.removeAll { now.timeIntervalSince($0.time) > 11 }
        c.keysLast10s = Int(keys &- (keyHistory.first?.count ?? keys))
        c.secondsSinceMouse = [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]
            .map(secondsSince).min() ?? .infinity
        c.secondsSinceInput = secondsSinceUserInput()

        if settings.useMic, micState == .on, let a = lastAudio, now.timeIntervalSince(a.at) < 10 {
            // Video playing from the Mac itself (or a study video in the front tab) isn't phone audio.
            let macAloud = AudioMonitor.macPlayingAloud()
            lastMacAloud = macAloud
            let watchingStudyVideo = activity?.isBrowser == true && judgement?.verdict == .study
            c.shortFormAudio = a.shortFormLikely && !watchingStudyVideo && !macAloud
            c.choppiness = watchingStudyVideo || macAloud ? 0 : a.switches + a.cuts
            c.soundNotFromMac = a.mediaShare >= 0.5 && !macAloud
            c.laughterNotFromMac = a.laughterHeard && !macAloud
            // In typing mode a "writing" sound is more likely a misheard tap on a phone than real note-taking.
            c.writingSound = a.writingHeard && settings.studyStyle != .typing
            c.typingSound = a.typingHeard
            c.phoneAlertRecently = a.phoneAlertAt.map { now.timeIntervalSince($0) < 30 } ?? false
        }
        return c
    }

    func tick() {
        let now = Date()
        if case .onBreak(let until) = phase {
            if now >= until {
                resume()
                hud.show(symbol: "timer", title: "Break over", message: "Session resumed.", sound: settings.nudgeSound)
            }
            return
        }
        guard phase == .running || sensorTestRunning else { return }

        let uptime = ProcessInfo.processInfo.systemUptime
        let dt = min(max(uptime - lastTickUptime, 0), 60)
        lastTickUptime = uptime
        lastTick = now

        cues = gatherCues(now: now)
        observeForLearning(now: now)
        evidence.threshold = 10 * (1.5 - settings.phoneSensitivity)
        evidence.gain = phoneGain
        if now >= phoneSnoozedUntil { evidence.update(cues, dt: dt) } else { evidence.clear() }
        guard phase == .running else { return } // sensor test: readings only

        elapsed += dt
        let idle = cues.secondsSinceInput
        let cameraOn = settings.useCamera && cameraState == .on
        let noPersonFor = now.timeIntervalSince(lastPersonSeen ?? cameraStartedAt)

        let newStatus: FocusStatus
        // Out of the camera's view for more than a few seconds is never focus time (and isn't phone use either).
        if cameraOn && noPersonFor > 5 { newStatus = .away }
        else if evidence.active { newStatus = .phone }
        else if judgement?.verdict == .distraction, let activity { newStatus = .offTask(activity.label) }
        else if !cameraOn && idle > 180 && !(cues.shortFormAudio) { newStatus = .away }
        else if judgement?.verdict == .study { newStatus = .focused }
        else { newStatus = .neutral }
        if status != newStatus { status = newStatus }

        // Focus streak, longest streak of the day, and a break suggestion after a long one.
        if newStatus.isDistracted || newStatus == .away {
            focusStreak = 0
            breakSuggested = false
        } else {
            focusStreak += dt
            studyLog.noteFocusStreak(focusStreak, at: now)
            let breakAfter = settings.breakReminderMinutes * 60
            if breakAfter > 0, focusStreak >= breakAfter, !breakSuggested {
                breakSuggested = true
                hud.show(symbol: "cup.and.saucer", title: "Time for a break",
                         message: "\(Int(focusStreak / 60)) minutes of focus. A short break now helps you stay on track.",
                         actions: [("Take a Break", { [weak self] in self?.takeBreak() })], tint: .green, sound: settings.nudgeSound)
            }
        }
        if newStatus.isDistracted { studyLog.addDistracted(dt, at: now) }

        // Suspected phone use: from half the evidence threshold, study time is held back (see SuspicionLedger).
        let step = ledger.step(score: evidence.score, threshold: evidence.threshold, onPhone: newStatus == .phone,
                               otherwiseUnfocused: newStatus != .phone && (newStatus.isDistracted || newStatus == .away), dt: dt)
        switch step.release {
        case .toPhone(let t):
            phoneTime += t
            distractionTally["Phone", default: 0] += t
            studyLog.addDistracted(t, at: now)
        case .toStudy(let t):
            focusedTime += t
            studyLog.add(t, subject: currentSubjectID, at: now)
        case .none:
            break
        }
        suspecting = ledger.suspecting
        heldTime = ledger.held

        switch newStatus {
        case .phone:
            phoneTime += dt
            distractionTally["Phone", default: 0] += dt
        case .offTask(let label):
            offTaskTime += dt
            distractionTally[label, default: 0] += dt
        case .away:
            awayTime += dt
        default:
            if step.countsAsStudy {
                focusedTime += dt
                studyLog.add(dt, subject: currentSubjectID, at: now)
            }
        }
        ticksSinceSave += 1
        if ticksSinceSave >= 30 {
            ticksSinceSave = 0
            studyLog.saveIfNeeded()
        }

        if studyGoal > 0, !goalReached, focusedTime >= studyGoal {
            goalReached = true
            hud.show(symbol: "checkmark.seal", title: "Goal reached",
                     message: "\(Int(sessionGoal / 60)) minutes of study.",
                     actions: [("End Session", { [weak self] in self?.end() })], tint: .green, sound: settings.nudgeSound)
        }

        // Phone put away after a nudge, no correction given, and back to typing: learn that posture as "phone".
        // Waits until the nudge banner is gone so a false alarm can still be corrected first.
        if let lesson = pendingPhoneLesson {
            let age = now.timeIntervalSince(lesson.time)
            if age > 120 {
                pendingPhoneLesson = nil
            } else if age > 20, newStatus != .phone, cues.keysLast10s > 3 {
                pendingPhoneLesson = nil
                let previous = postureProfile, gain = phoneGain
                learn(.phone, from: lesson.postures, gainChange: 1.05)
                // Only the seconds that actually look like phone use: no keys, nothing touched for 4 s.
                let phoneSeconds = lesson.features.filter { $0[14] == 0 && $0[16] > 4 / 60 }
                let episode = phoneSeconds.count < 3 ? nil : learner.add(phoneSeconds, label: 1, source: .confirmed)
                undoLesson = (now, previous, gain, episode, lesson.time)
            }
        }

        if newStatus.isDistracted {
            escalate(newStatus, now: now)
        } else {
            distractedSince = nil
            episodeNudged = false
            enforcementWarned = nil
            enforced = nil
            // Lift the curtain once you've been back (not distracted, in view) for 2 seconds.
            if curtain.isShowing, newStatus != .away {
                let since = backSince ?? now
                backSince = since
                if now.timeIntervalSince(since) >= 2 { curtain.hide() }
            }
        }
    }

    /// Suspicion faded without a phone flag: the held-back time was study after all.
    func refundHeldTime(now: Date = Date()) {
        let t = ledger.releaseToStudy()
        suspecting = false
        heldTime = 0
        guard t > 0 else { return }
        focusedTime += t
        studyLog.add(t, subject: currentSubjectID, at: now)
    }
}
