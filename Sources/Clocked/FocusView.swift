import SwiftUI

/// Full-screen, distraction-free timer: this session's study time in a large ring, the subject and status.
/// Opened with Session → Enter Focus View (⌃⌘F); Esc leaves it.
struct FocusView: View {
    @EnvironmentObject var c: SessionController
    @Environment(\.dismissWindow) private var dismissWindow

    private var subjectColor: Color { c.currentSubject?.color ?? Theme.accent }
    private var paused: Bool { c.studyClockPaused || c.phase.isBreak }

    private var progress: Double {
        c.studyGoal > 0 ? c.focusedTime / c.studyGoal : c.todayTotal / max(AppSettings.shared.dailyGoalMinutes * 60, 60)
    }

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height) * 0.55
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: Theme.night, startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                VStack(spacing: 28) {
                    if c.phase == .running || c.phase.isBreak {
                        HStack(spacing: 8) {
                            Circle().fill(subjectColor).frame(width: 10, height: 10)
                            Text(c.currentSubject?.name ?? "Studying").font(.title2.weight(.medium))
                        }
                        ZStack {
                            ProgressRing(progress: progress, color: paused ? .gray : subjectColor,
                                         lineWidth: max(14, diameter * 0.045), trackColor: .white.opacity(0.12))
                            VStack(spacing: 10) {
                                Text(formatHMS(c.focusedTime))
                                    .font(.system(size: diameter * 0.17, weight: .medium, design: .rounded).monospacedDigit())
                                    .foregroundStyle(paused ? .white.opacity(0.5) : .white)
                                    .contentTransition(.numericText())
                                Text(statusText)
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(paused ? Theme.warning : .white.opacity(0.6))
                            }
                        }
                        .frame(width: diameter, height: diameter)
                        if c.studyGoal > 0 {
                            Text(c.goalReached ? "Session goal reached" : "\(Int(((c.studyGoal - c.focusedTime) / 60).rounded(.up))) min to go")
                                .font(.title3).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                        }
                        HStack(spacing: 12) {
                            if c.phase.isBreak {
                                Button("Resume") { c.resume() }
                            } else {
                                Button("Break") { c.takeBreak() }
                            }
                            Button("End Session") { c.requestEnd() }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                    } else {
                        Text("No session running").font(.title.weight(.medium))
                        Text("Pick a subject to start.").foregroundStyle(.white.opacity(0.6))
                        SubjectList(compact: true, showsAdd: false).frame(width: 380)
                    }
                }
                .foregroundStyle(.white)
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button { dismissWindow(id: "focus") } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .padding(24)
                .help("Exit Focus View (Esc)")
                .accessibilityLabel("Exit Focus View")
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
        .onExitCommand { dismissWindow(id: "focus") }
        .onAppear {
            // Go full screen once the window exists.
            DispatchQueue.main.async {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("focus") == true }),
                   !window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            }
        }
    }

    private var statusText: String {
        if c.phase.isBreak { return "On break" }
        switch c.status {
        case .phone: return "Paused · Phone"
        case .offTask: return "Paused · Off task"
        case .away: return "Paused · Away"
        default: return c.suspecting ? "Checking…" : "Focused"
        }
    }
}
