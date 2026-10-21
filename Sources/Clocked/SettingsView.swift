import SwiftUI

// Settings sections, each shown as its own item under "Settings" in the main window sidebar.

struct GeneralSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @EnvironmentObject var c: SessionController

    var body: some View {
        Form {
            Section("Nudges") {
                Picker("Nudge after", selection: $settings.nudgeDelay) {
                    ForEach([10.0, 20, 30, 60, 120], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Toggle("Play sound", isOn: $settings.nudgeSound)
            }
            Section("Daily Goal") {
                Picker("Study each day", selection: $settings.dailyGoalMinutes) {
                    ForEach([60.0, 120, 180, 240, 300, 360, 480], id: \.self) { Text(formatHours($0 * 60)).tag($0) }
                }
            }
            Section {
                Picker("Timer", selection: $settings.pomodoro) {
                    Text("Standard").tag(false)
                    Text("Pomodoro").tag(true)
                }
                .pickerStyle(.segmented)
                if settings.pomodoro {
                    Picker("Focus", selection: $settings.pomodoroMinutes) {
                        ForEach([15.0, 20, 25, 30, 45, 50, 60], id: \.self) { Text("\(Int($0)) minutes").tag($0) }
                    }
                    Picker("Short break", selection: $settings.shortBreakMinutes) {
                        ForEach([3.0, 5, 10, 15], id: \.self) { Text("\(Int($0)) minutes").tag($0) }
                    }
                    Picker("Long break", selection: $settings.longBreakMinutes) {
                        ForEach([10.0, 15, 20, 25, 30], id: \.self) { Text("\(Int($0)) minutes").tag($0) }
                    }
                    Picker("Long break after", selection: $settings.roundsPerSet) {
                        ForEach([2, 3, 4, 5, 6], id: \.self) { Text("\($0) rounds").tag($0) }
                    }
                } else {
                    Picker("Break length", selection: $settings.breakMinutes) {
                        ForEach([5.0, 10, 15, 20, 30], id: \.self) { Text("\(Int($0)) minutes").tag($0) }
                    }
                    Picker("Suggest a break after", selection: $settings.breakReminderMinutes) {
                        Text("Never").tag(0.0)
                        ForEach([25.0, 45, 50, 60, 90], id: \.self) { Text("\(Int($0)) minutes of focus").tag($0) }
                    }
                }
            } header: {
                Text("Timer")
            } footer: {
                if settings.pomodoro {
                    Text("Breaks start on their own. Only focused time counts towards a round, so distractions push the break back.")
                }
            }
            .disabled(c.phase == .running || c.phase.isBreak)
            Section("Activity Classification") {
                LabeledContent("Engine", value: c.judge.aiAvailable ? "Apple Intelligence (on-device)" : "Built-in rules")
                if !c.judge.aiAvailable {
                    HStack {
                        Text("Turn on Apple Intelligence for more accurate classification. It runs on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                        }
                    }
                }
            }
            Section("History") {
                Toggle("Keep the session list", isOn: $settings.keepHistory)
                Text("Daily study totals for Stats are always kept on this Mac. Clear them from the Stats toolbar.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettings: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent colour") {
                    HStack(spacing: 10) {
                        ForEach(AccentChoice.allCases) { choice in
                            AccentSwatch(choice: choice, selected: settings.accent == choice) { settings.accent = choice }
                        }
                    }
                }
            }
            Section("Timer") {
                Picker("Font", selection: $settings.timerFont) {
                    ForEach(TimerFont.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Preview") {
                    Text("04:12:00")
                        .font(.system(size: 28, weight: .medium, design: settings.timerFont.design).monospacedDigit())
                }
            }
            Section("Focus View") {
                Picker("Background", selection: $settings.focusBackground) {
                    ForEach(FocusBackground.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Menu Bar") {
                Toggle("Show today's time during a session", isOn: $settings.menuBarTime)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccentSwatch: View {
    let choice: AccentChoice
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle().fill(choice.color)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                .overlay { if selected { Circle().fill(.white).frame(width: 6, height: 6) } }
                .padding(2)
                .overlay(Circle().strokeBorder(selected ? choice.color : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(choice.title)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DetectionSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @EnvironmentObject var c: SessionController

    var body: some View {
        Form {
            Section("Sensors") {
                Toggle("Camera", isOn: $settings.useCamera)
                Toggle("Microphone", isOn: $settings.useMic)
                Toggle("Active app and browser tab", isOn: $settings.useScreen)
            }
            Section("Phone Detection") {
                LabeledContent("Sensitivity") {
                    Slider(value: $settings.phoneSensitivity, in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Low").font(.caption)
                    } maximumValueLabel: {
                        Text("High").font(.caption)
                    }
                    .frame(width: 220)
                }
                Toggle("Count head-down posture", isOn: $settings.headDownCountsAsPhone)
                LabeledContent("Object detector", value: c.hasObjectDetector ? "YOLOv3-Tiny" : "Vision classifier")
            }
            if c.phase == .running || c.phase.isBreak {
                Text("Detection settings can't be changed during a session.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(c.phase == .running || c.phase.isBreak)
    }
}

struct AccountabilitySettings: View {
    @ObservedObject var settings = AppSettings.shared
    @EnvironmentObject var c: SessionController

    var body: some View {
        Form {
            Section {
                Picker("Strictness", selection: $settings.strictness) {
                    ForEach(Strictness.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(c.phase == .running)
                Text(settings.strictness.summary).font(.callout).foregroundStyle(.secondary)
                GoalPicker().disabled(c.phase == .running || c.phase.isBreak)
            } header: {
                Text("While Distracted")
            } footer: {
                Text(c.phase == .running ? "Strictness and goal can't be changed during a session." : "The study clock pauses whenever you're distracted or away, so distractions extend the session.")
            }

            Section {
                Toggle("Send reminders to my iPhone", isOn: $settings.phoneReminders)
                TextField("iMessage phone number or email", text: $settings.phoneHandle)
                    .disabled(!settings.phoneReminders)
                HStack {
                    Button("Send Test") { c.sendTestReminder() }
                        .disabled(!settings.phoneRemindersReady)
                    if let status = c.reminderStatus {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Phone Reminders")
            } footer: {
                Text("While you're on your phone, Messages sends you an iMessage reminder (at most \(SessionController.reminderLimit) per session). iMessage goes through Apple's servers, end-to-end encrypted. Reminders contain only the reminder text and your subject name. Double-check the number: reminders go to whoever it belongs to.")
            }

            Section {
                Toggle("Run shortcuts when a session starts and ends", isOn: $settings.runShortcuts)
                TextField("Start shortcut", text: $settings.startShortcut).disabled(!settings.runShortcuts)
                TextField("End shortcut", text: $settings.endShortcut).disabled(!settings.runShortcuts)
                HStack {
                    Button("Run Start Shortcut") { c.runShortcut(settings.startShortcut) }
                    Button("Run End Shortcut") { c.runShortcut(settings.endShortcut) }
                }
                .disabled(!settings.runShortcuts)
                if let status = c.shortcutStatus {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Focus Mode")
            } footer: {
                Text("Create shortcuts that turn a Focus on and off. With Share Across Devices on, your iPhone follows.")
            }
        }
        .formStyle(.grouped)
    }
}

struct ListsSettings: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                TextEditor(text: $settings.alwaysStudy).font(.body.monospaced()).frame(height: 110)
            } header: {
                Text("Always Study")
            } footer: {
                Text("One website or app name per line.")
            }
            Section("Always Distraction") {
                TextEditor(text: $settings.alwaysDistracting).font(.body.monospaced()).frame(height: 110)
            }
        }
        .formStyle(.grouped)
    }
}
