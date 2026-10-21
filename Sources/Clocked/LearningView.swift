import SwiftUI

/// What the on-device network has learned so far, and how much say it has in detection.
struct LearningPane: View {
    @EnvironmentObject var c: SessionController
    @Environment(\.openWindow) private var openWindow
    @State private var confirmReset = false

    private var learner: Learner { c.learner }

    var body: some View {
        Form {
            Section {
                TeachingPanel()
            } header: {
                Text("Teach Phone Detection")
            } footer: {
                Text("The best way to make it smarter. About 4 minutes: Clocked asks you, out loud, to type, read, write, and use your phone a few different ways, and learns from exactly what you did. Do it again on another day or in different light to help more.")
            }

            Section {
                LabeledContent("Status") { Text(status).foregroundStyle(statusColor) }
                LabeledContent("Influence") {
                    HStack {
                        ProgressView(value: learner.influence).frame(width: 120)
                        Text("\(Int((learner.influence * 100).rounded()))%").monospacedDigit()
                    }
                }
                if let p = c.learnedProbability {
                    LabeledContent("Right now", value: "\(Int((p * 100).rounded()))% likely on phone")
                }
            } header: {
                Text("Model")
            } footer: {
                Text("A small neural network trained on this Mac from your recordings and corrections. It starts influencing detection once it predicts examples it hasn't seen with at least 70% accuracy, and gets full influence at 90%.")
            }

            if let r = learner.report {
                Section("Last Training") {
                    LabeledContent("Trained", value: r.date.formatted(date: .abbreviated, time: .shortened))
                    if let folds = r.folds {
                        LabeledContent("Checked on", value: "All \(r.validationCount) examples, each by a network that never saw its session (\(folds) rounds)")
                    } else {
                        LabeledContent("Examples", value: "\(r.trainCount) training, \(r.validationCount) held out")
                    }
                    LabeledContent("Balanced accuracy", value: percent(r.balancedAccuracy) + " (cautious estimate " + percent(r.balancedAccuracyLowerBound) + ")")
                    LabeledContent("Precision", value: percent(r.precision))
                    LabeledContent("Recall", value: percent(r.recall))
                    LabeledContent("Epochs", value: "\(r.epochs)")
                }
            }

            Section {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        Text("Source").foregroundStyle(.secondary)
                        Text("Phone").foregroundStyle(.secondary)
                        Text("Not phone").foregroundStyle(.secondary)
                    }
                    ForEach(LabelSource.allCases, id: \.rawValue) { source in
                        GridRow {
                            Text(source.title)
                            Text("\(count(source, 1))").monospacedDigit()
                            Text("\(count(source, 0))").monospacedDigit()
                        }
                    }
                    GridRow {
                        Text("Total").fontWeight(.medium)
                        Text("\(learner.store.positives)").monospacedDigit().fontWeight(.medium)
                        Text("\(learner.store.negatives)").monospacedDigit().fontWeight(.medium)
                    }
                }
            } header: {
                Text("Examples")
            } footer: {
                Text("Each example is \(LearningFeatures.count) numbers describing one second (posture and gaze relative to your normal, typing, sound type, the last 30 seconds), never an image or recording. Up to \(LearningStore.capacity) are kept, about 200 KB.")
            }

            Section {
                HStack {
                    Button("Open Developer View") { openWindow(id: "developer") }
                    Button("Retrain Now") { learner.trainIfNeeded(force: true) }
                        .disabled(!learner.hasEnoughData || learner.isTraining)
                    Spacer()
                    Button("Reset Learning", role: .destructive) { confirmReset = true }
                        .disabled(learner.store.samples.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all learned examples and the model?", isPresented: $confirmReset) {
            Button("Reset Learning", role: .destructive) { learner.reset() }
        }
    }

    private var status: String {
        if learner.isTraining { return "Training…" }
        if !learner.hasEnoughData {
            return "Needs more examples (\(learner.store.positives) of \(Learner.minimumPerClass) phone, \(learner.store.negatives) of \(Learner.minimumPerClass) not phone)"
        }
        if learner.model == nil { return "Ready to train" }
        return learner.influence > 0 ? "Active" : "Trained, not accurate enough yet. Teach it above."
    }

    private var statusColor: Color {
        learner.influence > 0 ? .green : .secondary
    }

    private func count(_ source: LabelSource, _ label: UInt8) -> Int {
        _ = learner.revision
        return learner.store.samples.filter { $0.source == source && $0.y == label }.count
    }

    private func percent(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }
}

/// Start button, or the current step while teaching.
private struct TeachingPanel: View {
    @EnvironmentObject var c: SessionController

    var body: some View {
        if let t = c.teaching {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Text("Step \(t.index + 1) of \(t.steps.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Label(t.step.onPhone ? "Phone" : "No phone", systemImage: t.step.onPhone ? "iphone" : "iphone.slash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(t.step.onPhone ? Theme.accent : .green)
                }
                Text(t.step.title).font(.title2.weight(.semibold))
                Text(t.step.instruction).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if t.countdown > 0 {
                    Text("Starting in \(t.countdown)…").font(.headline.monospacedDigit())
                } else {
                    ProgressBar(progress: t.progress, color: t.step.onPhone ? Theme.accent : .green, height: 8)
                }
                HStack {
                    Text("\(t.added) examples so far").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Skip Step") { c.skipTeachingStep() }
                    Button("Stop") { c.stopTeaching() }
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show Clocked what your phone use looks like").font(.headline)
                    if let message = c.teachingMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Sit as you normally study, with your phone nearby. You'll hear what to do next, so you can keep looking at your phone.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Start Teaching") { c.startTeaching() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(c.phase == .idle || c.phase == .finished) || c.calibration != nil
                              || !(c.settings.useCamera || c.settings.useMic))
                    .help(c.phase == .running ? "Finish your session first." : "")
            }
        }
    }
}
