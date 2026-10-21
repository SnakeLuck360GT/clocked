import SwiftUI

/// Everything the detector sees and decides, live: the analysed camera frame with detections drawn on it,
/// the phone-evidence terms, the network's inputs, attributions and weights, posture votes and sound.
/// Frames are shown only while this window is open and are never saved.
struct DeveloperView: View {
    @EnvironmentObject var c: SessionController
    @State private var show = Overlays()

    struct Overlays {
        var face = true, landmarks = true, body = true, hands = true, phones = true
    }

    private var sensorsRunning: Bool { c.cameraState == .on || c.micState == .on }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                CameraOverlay(frame: c.debugFrame, show: show)
                    .frame(minWidth: 420, minHeight: 315)
                HStack(spacing: 14) {
                    Toggle("Face", isOn: $show.face)
                    Toggle("Landmarks", isOn: $show.landmarks)
                    Toggle("Body", isOn: $show.body)
                    Toggle("Hands", isOn: $show.hands)
                    Toggle("Phone", isOn: $show.phones)
                }
                .toggleStyle(.checkbox)
                .font(.callout)
                if !sensorsRunning {
                    HStack {
                        Text("Sensors are off. Start a session, or run a 45-second test.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Start Test") { c.startSensorTest() }
                            .disabled(c.phase == .running || c.calibration != nil)
                    }
                } else {
                    Text("The analysed frame, one per second. Shown here only, never saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(minWidth: 440)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    EvidencePanel()
                    NetworkPanel()
                    PosturePanel()
                    SoundPanel()
                }
                .padding(14)
            }
            .frame(minWidth: 380, idealWidth: 440)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { c.developerViewOpen = true }
        .onDisappear { c.developerViewOpen = false }
        .navigationTitle("Developer View")
    }
}

// MARK: - Camera

private struct CameraOverlay: View {
    let frame: DebugFrame?
    let show: DeveloperView.Overlays

    private static let skeleton: [(String, String)] = [
        ("left_ear_joint", "left_eye_joint"), ("left_eye_joint", "head_joint"), ("head_joint", "right_eye_joint"),
        ("right_eye_joint", "right_ear_joint"), ("head_joint", "neck_1_joint"),
        ("neck_1_joint", "left_shoulder_1_joint"), ("neck_1_joint", "right_shoulder_1_joint"),
        ("left_shoulder_1_joint", "left_forearm_joint"), ("left_forearm_joint", "left_hand_joint"),
        ("right_shoulder_1_joint", "right_forearm_joint"), ("right_forearm_joint", "right_hand_joint"),
    ]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            guard let frame else {
                ctx.draw(Text("No camera frame").foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            // Aspect-fit the frame, then map Vision coordinates (origin bottom left) into it.
            let aspect = CGFloat(frame.image.width) / CGFloat(frame.image.height)
            var rect = CGRect(origin: .zero, size: size)
            if size.width / size.height > aspect {
                rect.size.width = size.height * aspect
                rect.origin.x = (size.width - rect.width) / 2
            } else {
                rect.size.height = size.width / aspect
                rect.origin.y = (size.height - rect.height) / 2
            }
            ctx.draw(Image(decorative: frame.image, scale: 1), in: rect)
            func p(_ v: CGPoint) -> CGPoint { CGPoint(x: rect.minX + v.x * rect.width, y: rect.maxY - v.y * rect.height) }
            func r(_ b: CGRect) -> CGRect {
                CGRect(x: rect.minX + b.minX * rect.width, y: rect.maxY - b.maxY * rect.height, width: b.width * rect.width, height: b.height * rect.height)
            }
            func label(_ text: String, at point: CGPoint, color: Color) {
                let t = ctx.resolve(Text(text).font(.caption.bold().monospacedDigit()).foregroundStyle(.white))
                let sz = t.measure(in: CGSize(width: 300, height: 40))
                let bg = CGRect(x: point.x, y: point.y - sz.height - 2, width: sz.width + 8, height: sz.height + 2)
                ctx.fill(Path(roundedRect: bg, cornerRadius: 3), with: .color(color.opacity(0.85)))
                ctx.draw(t, at: CGPoint(x: bg.minX + 4, y: bg.minY + 1), anchor: .topLeading)
            }

            if show.phones, frame.zoomRegion != .zero {
                ctx.stroke(Path(r(frame.zoomRegion)), with: .color(.yellow.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            }
            if show.face, let box = frame.faceBox {
                let fr = r(box)
                ctx.stroke(Path(roundedRect: fr, cornerRadius: 4), with: .color(.green), lineWidth: 2)
                let angles = String(format: "pitch %.0f° yaw %.0f°", (frame.pitch ?? 0) * 180 / .pi, (frame.yaw ?? 0) * 180 / .pi)
                label(angles, at: CGPoint(x: fr.minX, y: fr.minY), color: .green)
            }
            if show.landmarks {
                for eye in frame.eyes where eye.count > 2 {
                    var path = Path(); path.addLines(eye.map(p)); path.closeSubpath()
                    ctx.stroke(path, with: .color(.cyan), lineWidth: 1.5)
                }
                for pupil in frame.pupils {
                    let c = p(pupil)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.red))
                }
                if frame.lips.count > 2 {
                    var path = Path(); path.addLines(frame.lips.map(p)); path.closeSubpath()
                    ctx.stroke(path, with: .color(.pink), lineWidth: 1.5)
                }
            }
            if show.body {
                for (a, b) in Self.skeleton {
                    guard let pa = frame.joints[a], let pb = frame.joints[b] else { continue }
                    var path = Path(); path.move(to: p(pa)); path.addLine(to: p(pb))
                    ctx.stroke(path, with: .color(.orange), lineWidth: 2.5)
                }
                for point in frame.joints.values {
                    let c = p(point)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(.orange))
                }
            }
            if show.hands {
                for hand in frame.hands {
                    for point in hand {
                        let c = p(point)
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(.mint))
                    }
                }
            }
            if show.phones {
                for phone in frame.phones {
                    let pr = r(phone.box)
                    ctx.stroke(Path(roundedRect: pr, cornerRadius: 4), with: .color(.red), lineWidth: 2.5)
                    label(String(format: "phone %.0f%%%@", phone.confidence * 100, phone.zoomed ? " (zoom)" : ""),
                          at: CGPoint(x: pr.minX, y: pr.minY), color: .red)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Panels

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A horizontal bar centred on zero: red to the right (towards phone), green to the left.
private struct SignedBar: View {
    let value: Double
    let scale: Double
    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let w = min(abs(value) / scale, 1) * half
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.12))
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1).offset(x: half)
                Rectangle().fill(value >= 0 ? Color.red.opacity(0.75) : Color.green.opacity(0.75))
                    .frame(width: w)
                    .offset(x: value >= 0 ? half : half - w)
            }
        }
        .frame(height: 8)
    }
}

private struct EvidencePanel: View {
    @EnvironmentObject var c: SessionController
    var body: some View {
        Panel(title: "Phone Evidence") {
            HStack {
                ProgressBar(progress: c.evidence.score / max(c.evidence.threshold, 1), color: c.evidence.active ? .red : .orange)
                Text(String(format: "%.1f / %.0f", c.evidence.score, c.evidence.threshold)).monospacedDigit().font(.callout)
                Text(c.evidence.active ? "ON PHONE" : (c.suspecting ? "HOLDING \(Int(c.heldTime))s" : "")).font(.caption.bold()).foregroundStyle(.red)
            }
            if c.evidence.allTerms.isEmpty {
                Text("No cues this second.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(c.evidence.allTerms.enumerated()), id: \.offset) { _, term in
                HStack {
                    Text(term.label).font(.callout).frame(width: 170, alignment: .leading)
                    SignedBar(value: term.weight, scale: 3)
                    Text(String(format: "%+.2f/s", term.weight)).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
                }
            }
            Text(String(format: "Posture: %@ · keys (10 s): %d · since input: %.0f s · gain ×%.2f",
                        c.posture.label(learned: c.postureLearned), c.cues.keysLast10s, min(c.cues.secondsSinceInput, 999), c.evidence.gain))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NetworkPanel: View {
    @EnvironmentObject var c: SessionController
    @State private var showWeights = false

    var body: some View {
        Panel(title: "Neural Network") {
            if let model = c.learner.model {
                let p = model.predict(c.lastFeatures.count == LearningFeatures.count ? c.lastFeatures : Array(repeating: 0, count: LearningFeatures.count))
                HStack {
                    Text("p(phone)").font(.callout)
                    ProgressBar(progress: Double(p), color: p > 0.5 ? .red : .green)
                    Text("\(Int((p * 100).rounded()))%").monospacedDigit().font(.callout)
                }
                Text("Say in detection: \(Int((c.learner.influence * 100).rounded()))% · \(model.parameterCount) weights")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not trained yet (\(c.learner.store.positives) phone / \(c.learner.store.negatives) not-phone examples).")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if c.lastFeatures.count == LearningFeatures.count {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    GridRow {
                        Text("Input").font(.caption.bold())
                        Text("Value").font(.caption.bold())
                        Text("Push (log-odds)").font(.caption.bold())
                    }
                    ForEach(0..<LearningFeatures.count, id: \.self) { i in
                        GridRow {
                            Text(LearningFeatures.names[i]).font(.caption).lineLimit(1)
                            Text(String(format: "%.2f", c.lastFeatures[i])).font(.caption.monospacedDigit())
                            if i < c.lastAttribution.count {
                                SignedBar(value: Double(c.lastAttribution[i]), scale: 2).frame(width: 140)
                            } else {
                                Text("—").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("Inputs appear while sensors are running.").font(.callout).foregroundStyle(.secondary)
            }

            if let model = c.learner.model {
                DisclosureGroup("Learned weights", isExpanded: $showWeights) {
                    WeightsHeatmap(model: model).padding(.top, 6)
                }
                .font(.callout)
            }
        }
    }
}

/// The network's weights: first layer as inputs × 16 hidden units (labelled rows), then 16 → 8 and 8 → 1.
private struct WeightsHeatmap: View {
    let model: PhoneNet

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.layers.enumerated()), id: \.offset) { index, layer in
                let scale = max(layer.weights.map { abs($0) }.max() ?? 1, 0.01)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Layer \(index + 1): \(layer.inputs) → \(layer.outputs)").font(.caption.bold())
                    // Rows are inputs, columns are this layer's units.
                    ForEach(0..<layer.inputs, id: \.self) { i in
                        HStack(spacing: 1) {
                            if index == 0 {
                                Text(LearningFeatures.names[i]).font(.system(size: 9)).frame(width: 130, alignment: .leading).lineLimit(1)
                            }
                            ForEach(0..<layer.outputs, id: \.self) { o in
                                let w = layer.weights[o * layer.inputs + i]
                                Rectangle()
                                    .fill((w >= 0 ? Color.red : Color.blue).opacity(Double(min(abs(w) / scale, 1))))
                                    .frame(width: 11, height: index == 0 ? 9 : 11)
                                    .help(String(format: "%.3f", w))
                            }
                        }
                    }
                }
            }
            Text("Red = positive weight, blue = negative; darker = stronger. Hover a cell for its value.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct PosturePanel: View {
    @EnvironmentObject var c: SessionController
    var body: some View {
        Panel(title: "Posture Votes") {
            if let explained = c.postureVotes {
                if explained.acceptedAsScreen {
                    Text("Matches a posture you marked as screen time: never counted as head down.")
                        .font(.caption).foregroundStyle(.green)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("Cue").font(.caption.bold()); Text("Now").font(.caption.bold())
                        Text("Yours").font(.caption.bold()); Text("How far down").font(.caption.bold())
                    }
                    ForEach(explained.votes) { vote in
                        GridRow {
                            Text(vote.name).font(.caption)
                            Text(vote.value.map { String(format: "%.2f", $0) } ?? "—").font(.caption.monospacedDigit())
                            Text(vote.reference.map { String(format: "%.2f", $0) } ?? "—").font(.caption.monospacedDigit())
                            if let d = vote.down {
                                HStack(spacing: 6) {
                                    SignedBar(value: d, scale: 2).frame(width: 110)
                                    Text(String(format: "%+.1f", d)).font(.caption.monospacedDigit())
                                }
                            } else {
                                Text("—").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if explained.faceHidden {
                    Text("Face hidden while shoulders are in view: counted as head down.").font(.caption).foregroundStyle(.orange)
                }
                Text(explained.score.map { String(format: "Head-down score %.2f (down at %.2f) · verdict: %@", $0, TypingBaseline.downThreshold, c.posture.label(learned: c.postureLearned)) }
                     ?? "Still learning your normal posture: type or click for a few seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No person in view.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SoundPanel: View {
    @EnvironmentObject var c: SessionController
    var body: some View {
        Panel(title: "Sound") {
            if let a = c.lastAudio {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Now", a.current.capitalized)
                    row("Speech/music/laughter (10 s)", "\(Int((a.mediaShare * 100).rounded()))%")
                    row("Switches / cuts (30 s)", "\(a.switches) / \(a.cuts)")
                    row("Short-form video pattern", a.shortFormLikely ? "Yes" : "No")
                    row("Writing · typing · laughter", [a.writingHeard ? "writing" : nil, a.typingHeard ? "typing" : nil, a.laughterHeard ? "laughter" : nil].compactMap { $0 }.joined(separator: ", ").ifEmpty("none"))
                    row("Sound from another device", c.cues.soundNotFromMac ? "Yes" : "No")
                }
            } else {
                Text("Microphone off.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).font(.caption)
            Text(value).font(.caption.monospacedDigit())
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
