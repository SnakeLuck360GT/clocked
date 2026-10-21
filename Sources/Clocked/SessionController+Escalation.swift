import AppKit

/// What happens while you stay distracted: banners, iPhone reminders, the curtain, Strict-mode enforcement.
extension SessionController {
    // MARK: - Escalation

    /// The goal is fixed when a session starts, like strictness.
    var studyGoal: TimeInterval { phase == .running || isOnBreak ? sessionGoal : settings.goalMinutes * 60 }
    /// The study clock only runs while you're focused.
    var studyClockPaused: Bool { phase == .running && (status.isDistracted || status == .away || suspecting) }

    func escalate(_ status: FocusStatus, now: Date) {
        let since = distractedSince ?? now
        distractedSince = since
        backSince = nil
        // The phone score already waits for evidence to build up, so it acts as soon as it's flagged.
        let firstDelay = status == .phone ? 0 : settings.nudgeDelay
        let distractedFor = now.timeIntervalSince(since) - firstDelay
        guard distractedFor >= 0 else { return }

        if now.timeIntervalSince(lastNudge) >= (episodeNudged ? policy.repeatBanner : 10) {
            nudge(for: status)
            lastNudge = now
            episodeNudged = true
        }
        if status == .phone, settings.phoneRemindersReady, distractedFor >= policy.pingAfter,
           now.timeIntervalSince(lastPing) >= policy.pingEvery, !reminderInFlight, remindersSent < Self.reminderLimit {
            lastPing = now
            sendPhoneReminder()
        }
        if let after = policy.curtainAfter, distractedFor >= after, !curtain.isShowing, now >= curtainSnoozedUntil,
           NSApp.modalWindow == nil {
            let corrections: [(String, () -> Void)] = status == .phone
                ? [("Not My Phone", { [weak self] in self?.notOnPhone() }), ("Writing Notes", { [weak self] in self?.writingNotes() })]
                : [("Mark as Study", { [weak self] in self?.markCurrent(as: .study) })]
            curtain.show(title: curtainTitle(status), detail: curtainDetail, corrections: corrections,
                         onBack: { [weak self] in self?.curtainBack() },
                         onEnd: { [weak self] in self?.requestEnd() })
        }
        if curtain.isShowing { curtain.update(detail: curtainDetail) }
        if let after = policy.enforceAfter, case .offTask = status, let activity {
            enforce(activity, distractedFor: distractedFor, after: after)
        }
    }

    func curtainTitle(_ status: FocusStatus) -> String {
        switch status {
        case .offTask(let label): return "\(label) is off task"
        default: return "Phone down"
        }
    }

    var curtainDetail: String {
        var text = "Study clock paused at \(formatClock(focusedTime))"
        if studyGoal > 0, focusedTime < studyGoal { text += " · \(formatDuration(studyGoal - focusedTime)) to go" }
        return text
    }

    func curtainBack() {
        curtainSnoozedUntil = Date().addingTimeInterval(20)
        curtain.hide()
    }

    /// Strict: warn, then 10 seconds later close the distracting tab or hide the distracting app.
    func enforce(_ a: ActivitySnapshot, distractedFor: TimeInterval, after: TimeInterval) {
        let now = Date()
        if distractedFor >= after - 10, enforcementWarned != a.siteKey {
            enforcementWarned = a.siteKey
            enforcementWarnedAt = now
            hud.show(symbol: "xmark.octagon", title: a.isBrowser ? "Closing \(a.label) in 10 seconds" : "Hiding \(a.appName) in 10 seconds",
                     message: "Mark as Study to keep it open.", actions: [("Mark as Study", { [weak self] in self?.markCurrent(as: .study) })],
                     sound: settings.nudgeSound)
        }
        if enforcementWarned == a.siteKey, now.timeIntervalSince(enforcementWarnedAt) >= 10, enforced != a.siteKey {
            enforced = a.siteKey
            if a.isBrowser, let url = a.url {
                activityMonitor.closeActiveTab(bundleID: a.bundleID, ifURL: url)
            } else if !a.isBrowser {
                NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleID).forEach { $0.hide() }
            }
        }
    }

    /// At most this many iPhone reminders per session.
    static let reminderLimit = 10

    func sendPhoneReminder() {
        pingCount += 1
        remindersSent += 1
        reminderInFlight = true
        let lines = [
            "Phone down. Study clock paused at \(formatClock(focusedTime)).",
            "Back to \(topicName). The study clock is paused.",
            studyGoal > focusedTime ? "\(formatDuration(studyGoal - focusedTime)) of studying left. Phone down." : "Phone down. Back to \(topicName).",
        ]
        scripts.sendMessage(lines[pingCount % lines.count], to: settings.phoneHandle) { [weak self] error in
            self?.reminderInFlight = false
            self?.reminderStatus = error ?? "Last reminder sent at \(Date().formatted(date: .omitted, time: .shortened))."
        }
    }

    func sendTestReminder() {
        reminderStatus = "Sending…"
        scripts.sendMessage("\(AppInfo.name) test reminder.", to: settings.phoneHandle) { [weak self] error in
            self?.reminderStatus = error ?? "Sent. Check that your iPhone showed a notification."
        }
    }

    func runShortcut(_ name: String, completion: (() -> Void)? = nil) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { completion?(); return }
        scripts.runShortcut(name) { [weak self] error in
            self?.shortcutStatus = error.map { "“\(name)”: \($0)" } ?? "Ran “\(name)”."
            completion?()
        }
    }

    /// Called when the app is asked to quit. Quitting mid-session goes through the same early-end check,
    /// and waits (briefly) for the end shortcut so a Focus mode isn't left on.
    func shouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard phase == .running || isOnBreak else { return .terminateNow }
        requestEnd()
        if phase == .running || isOnBreak { return .terminateCancel }
        guard settings.runShortcuts, !settings.endShortcut.trimmingCharacters(in: .whitespaces).isEmpty else { return .terminateNow }
        var replied = false
        let reply = { if !replied { replied = true; app.reply(toApplicationShouldTerminate: true) } }
        endShortcutDone = reply
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { reply() }
        return .terminateLater
    }

    func resetEscalation() {
        curtain.hide()
        distractedSince = nil
        episodeNudged = false
        lastPing = .distantPast
        curtainSnoozedUntil = .distantPast
        backSince = nil
        enforcementWarned = nil
        enforced = nil
    }

    /// Ending before the goal asks first (Firm and Strict).
    func requestEnd() {
        guard phase == .running || isOnBreak else { return }
        if policy.confirmEarlyEnd, studyGoal > 0, focusedTime < studyGoal {
            // The alert must never open behind the curtain, and the curtain must not return over it.
            curtain.hide()
            curtainSnoozedUntil = .distantFuture
            defer { curtainSnoozedUntil = Date().addingTimeInterval(20) }
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "End the session early?"
            alert.informativeText = "\(formatDuration(studyGoal - focusedTime)) left of your \(Int(sessionGoal / 60))-minute goal."
            alert.addButton(withTitle: "Keep Studying").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: "End Session")
            alert.buttons[1].hasDestructiveAction = true
            alert.window.level = .modalPanel
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        end()
    }

    var isOnBreak: Bool {
        if case .onBreak = phase { return true }
        return false
    }

    /// A 1-second timer that keeps firing while menus and alerts are open.
    func makeTicker() -> Timer {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    var topicName: String { topic.isEmpty ? "studying" : topic }

    func nudge(for status: FocusStatus) {
        nudges += 1
        switch status {
        case .phone:
            let nudgeTime = Date()
            lastPhoneNudge = nudgeTime
            pendingPhoneLesson = (nudgeTime, recentPostures.filter { $0.verdict.isDown }.map(\.features),
                                  learner.store.recentFeatures(seconds: 20))
            hud.show(symbol: "iphone.gen3", title: "Phone use detected",
                     message: "Signals: \(evidence.explanation).",
                     actions: [("Writing Notes", { [weak self] in self?.writingNotes() }),
                               ("Not My Phone", { [weak self] in self?.notOnPhone() })],
                     sound: settings.nudgeSound)
        case .offTask(let label):
            hud.show(symbol: "exclamationmark.triangle", title: "Off task: \(label)", message: judgement?.reason ?? "Not related to \(topicName).",
                     actions: [("Mark as Study", { [weak self] in self?.markCurrent(as: .study) })], sound: settings.nudgeSound)
        default:
            break
        }
    }
}
