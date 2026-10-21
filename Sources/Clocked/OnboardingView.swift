import AVFoundation
import SwiftUI

/// First-run setup: what the app does, subjects, permissions (asked in context, with the reason shown first),
/// postures, and goal/strictness. Can be reopened from Help → Welcome to Clocked.
struct OnboardingView: View {
    @EnvironmentObject var c: SessionController
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.welcome
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)

    enum Step: Int, CaseIterable {
        case welcome, privacy, subjects, permissions, postures, goal
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .privacy: privacy
                case .subjects: subjects
                case .permissions: permissions
                case .postures: postures
                case .goal: goal
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(32)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.rawValue) { s in
                        Circle().fill(s == step ? Theme.accent : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
                Spacer()
                if step != .welcome {
                    Button("Back") { move(-1) }
                }
                if step == .goal {
                    Button("Done") { finish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(step == .welcome ? "Get Started" : "Continue") { move(1) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == .subjects && c.subjects.subjects.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .interactiveDismissDisabled()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Access may have been granted in System Settings meanwhile.
            camera = AVCaptureDevice.authorizationStatus(for: .video)
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(nsImage: Icons.app).resizable().frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Welcome to \(AppInfo.name)").font(.largeTitle.weight(.semibold))
                Text("A study timer that only counts the time you actually study.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                Feature(icon: "pause.circle", title: "Pauses when you drift",
                        detail: "Picking up your phone, opening an off-task site or leaving your desk stops the study clock.")
                Feature(icon: "brain", title: "Learns how you study",
                        detail: "It notices phone use from your posture, typing and sound, and gets better from your corrections.")
                Feature(icon: "lock.shield", title: "Private and offline",
                        detail: "Everything runs on this Mac and nothing is recorded. It doesn't use the internet unless you turn on study groups.")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "Your privacy", detail: "Clocked watches for distraction, so here's exactly what it does and doesn't do.")
            PrivacyPromises()
            Label {
                Text("Internet is **off**. Study groups are the only online feature, and they stay off until you turn them on in Groups. You'll see **Offline** or **Online** at the bottom of the sidebar at all times.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "wifi.slash").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var subjects: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "What are you studying?", detail: "Add a subject for each class. Each one gets its own colour and its own time in Stats.")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { SubjectList() }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "Permissions", detail: "macOS asks once for each. They're only used while a session, sensor test or posture recording is running.")
            PermissionRow(icon: "camera", title: "Camera",
                          detail: "Your posture, to notice phone use even when the phone is out of view. One frame per second, analysed and discarded.",
                          status: camera) {
                Task { _ = await CameraMonitor.requestAccess(); camera = AVCaptureDevice.authorizationStatus(for: .video) }
            } openSettings: { openPrivacyPane("Privacy_Camera") }
            PermissionRow(icon: "mic", title: "Microphone",
                          detail: "The kind of sound around you (speech, music, writing), never what's said. Nothing is recorded.",
                          status: microphone) {
                Task { _ = await AudioMonitor.requestAccess(); microphone = AVCaptureDevice.authorizationStatus(for: .audio) }
            } openSettings: { openPrivacyPane("Privacy_Microphone") }
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browser tabs")
                    Text("The first time a session checks Safari, Chrome, Brave or Arc, macOS asks whether Clocked may read the active tab's title and address.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "macwindow").frame(width: 24)
            }
        }
    }

    private var postures: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "Show it how you sit",
                       detail: "Three 15-second recordings: looking at the screen, writing on paper, and on your phone. They teach detection your posture and camera angle. You can skip this and do it later in Settings → Postures.")
            if camera != .authorized {
                Text("Allow camera access first.").foregroundStyle(Theme.warning)
            }
            ForEach(PostureKind.allCases) { kind in
                let recorded = c.postureProfile.postures[kind] != nil
                HStack {
                    Image(systemName: recorded ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(recorded ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(kind.instruction).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let cal = c.calibration, cal.kind == kind {
                        if cal.countdown > 0 { Text("Starting in \(cal.countdown)").monospacedDigit() }
                        else { ProgressView(value: cal.progress).frame(width: 80) }
                    } else {
                        Button(recorded ? "Record Again" : "Record") { c.calibrate(kind) }
                            .disabled(camera != .authorized || c.calibration != nil || c.phase == .running || c.phase.isBreak
                                      || (kind != .screen && c.postureProfile.postures[.screen] == nil))
                    }
                }
            }
            if let message = c.calibrationMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var goal: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "How hard should it push?", detail: "The study clock pauses whenever you're distracted, so a goal means distractions make the session longer.")
            GoalPicker()
            Picker("Strictness", selection: $settings.strictness) {
                ForEach(Strictness.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text(settings.strictness.summary).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Phone reminders and Focus-mode shortcuts can be set up later in Settings → Accountability.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Navigation

    private func move(_ delta: Int) {
        if let next = Step(rawValue: step.rawValue + delta) { step = next }
    }

    private func finish() {
        if c.calibration != nil { c.cancelCalibration() }
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        dismiss()
    }
}

private struct StepHeader: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Feature: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: AVAuthorizationStatus
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch status {
            case .authorized: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .notDetermined: Button("Allow…", action: request)
            default: Button("Open System Settings", action: openSettings)
            }
        }
    }
}
