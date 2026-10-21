import SwiftUI

/// Settings → Postures: record your postures and test the sensors.
struct PosturesPane: View {
    @EnvironmentObject var c: SessionController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                ForEach(PostureKind.allCases) { kind in
                    let learned = c.postureProfile.postures[kind] != nil
                    HStack {
                        Image(systemName: learned ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(learned ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                            Text(kind.instruction).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let cal = c.calibration, cal.kind == kind {
                            if cal.countdown > 0 {
                                Text("Starting in \(cal.countdown)").monospacedDigit()
                            } else {
                                ProgressView(value: cal.progress).frame(width: 90)
                            }
                            Button("Cancel") { c.cancelCalibration() }
                        } else {
                            Button(learned ? "Record Again" : "Record") { c.calibrate(kind) }
                                .disabled(!canRecord || (kind != .screen && c.postureProfile.postures[.screen] == nil))
                        }
                    }
                }
                if let message = c.calibrationMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Your Postures")
            } footer: {
                Text("Record Screen first. Each recording counts down from 5, then captures 15 seconds; a sound marks the start and end.")
            }

            Section("Test") {
                HStack {
                    Text(c.sensorTestRunning ? "Testing camera and microphone…" : "Run the camera and microphone for 45 seconds.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if c.sensorTestRunning {
                        Button("Stop") { c.stopSensorTest() }
                    } else {
                        Button("Start Test") { c.startSensorTest() }.disabled(!canRecord)
                    }
                    Button("Developer View") { openWindow(id: "developer") }
                }
            }

            if !c.postureProfile.postures.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        Button("Reset Postures", role: .destructive) { c.forgetPostures() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var canRecord: Bool {
        (c.phase == .idle || c.phase == .finished) && c.calibration == nil && !c.sensorTestRunning
    }
}
