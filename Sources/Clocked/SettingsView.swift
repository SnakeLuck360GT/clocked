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
            Section {
                Picker("Style", selection: $settings.interfaceStyle) {
                    ForEach(InterfaceStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Interface")
            } footer: {
                Text(settings.interfaceStyle == .mac
                     ? "Session controls in the toolbar, subjects in the sidebar, and Settings in their own window (⌘,)."
                     : "The original Clocked look, with Settings in the sidebar.")
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                    ForEach(ThemePreset.allCases) { preset in
                        ThemeSwatch(preset: preset, selected: settings.theme == preset) { settings.theme = preset }
                    }
                }
                .padding(.vertical, 4)
                if settings.theme == .custom {
                    ColorPicker("Accent colour", selection: hexBinding(\.customAccent), supportsOpacity: false)
                    ColorPicker("Focus View, top", selection: hexBinding(\.customFocusTop), supportsOpacity: false)
                    ColorPicker("Focus View, bottom", selection: hexBinding(\.customFocusBottom), supportsOpacity: false)
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("A theme sets the accent, the subject colours and the Focus View background.")
            }
            AppIconSection()
            Section {
                Picker("During a session, show", selection: $settings.timerShows) {
                    ForEach(TimerShows.allCases) { Text($0.title).tag($0) }
                }
                Picker("Font", selection: $settings.timerFont) {
                    ForEach(TimerFont.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show seconds", isOn: $settings.showSeconds)
                LabeledContent("Preview") {
                    Text(settings.showSeconds ? "04:12:00" : "04:12")
                        .font(.system(size: 28, weight: .medium, design: settings.timerFont.design).monospacedDigit())
                }
            } header: {
                Text("Timer")
            } footer: {
                Text("Outside a session the timer always shows today's total.")
            }
            Section("Focus View") {
                Picker("Background", selection: $settings.focusBackground) {
                    ForEach(FocusBackground.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Open when a session starts", isOn: $settings.openFocusOnStart)
            }
            Section("Menu Bar") {
                Picker("Icon", selection: $settings.menuBarIcon) {
                    ForEach(MenuBarIcon.allCases) { icon in
                        Label { Text(icon.title) } icon: { icon.image(active: false) }.tag(icon)
                    }
                }
                Picker("During a session, show", selection: $settings.menuBarShows) {
                    ForEach(MenuBarShows.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func hexBinding(_ key: ReferenceWritableKeyPath<AppSettings, String>) -> Binding<Color> {
        Binding(get: { Color(hex: settings[keyPath: key]) }, set: { settings[keyPath: key] = $0.hexString })
    }
}

/// A theme: its accent as a large dot, four of its subject colours beside it, and its name.
private struct ThemeSwatch: View {
    let preset: ThemePreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let colors = preset == .custom ? AppSettings.shared.customColors : preset.colors
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: 3) {
                    Circle().fill(colors.accent).frame(width: 22, height: 22)
                    VStack(spacing: 3) {
                        HStack(spacing: 3) { dot(colors.palette[0]); dot(colors.palette[1]) }
                        HStack(spacing: 3) { dot(colors.palette[3]); dot(colors.palette[4]) }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: colors.night, startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
                Text(preset.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func dot(_ color: Color) -> some View { Circle().fill(color).frame(width: 9, height: 9) }
}

/// The Dock icon: the Clocked mark in a few colours, or a picture of your own.
private struct AppIconSection: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var choosing = false
    @State private var version = 0

    var body: some View {
        Section {
            HStack(spacing: 14) {
                ForEach(AppIconChoice.allCases) { choice in
                    Button {
                        if choice == .custom && !AppIcon.hasCustom { choosing = true } else { settings.appIcon = choice }
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if choice == .custom && !AppIcon.hasCustom {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                        .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                                        .padding(6)
                                } else {
                                    Image(nsImage: AppIcon.preview(choice)).resizable().id(version)
                                }
                            }
                            .frame(width: 56, height: 56)
                            .padding(3)
                            .background(settings.appIcon == choice ? Theme.accent.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(choice.title).font(.caption).foregroundStyle(settings.appIcon == choice ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(choice.title) icon")
                }
            }
            .padding(.vertical, 4)
            if settings.appIcon == .custom || AppIcon.hasCustom {
                Button("Choose Image…") { choosing = true }
            }
        } header: {
            Text("App Icon")
        } footer: {
            Text("Shown in the Dock while Clocked is open. macOS doesn't let an app change its icon in Finder.")
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if AppIcon.saveCustom(from: url) {
                version += 1
                if settings.appIcon == .custom { AppIcon.apply() } else { settings.appIcon = .custom }
            }
        }
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

            PhoneLinkSection(link: c.phoneLink)

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

/// The iPhone link: a Shortcuts automation on your iPhone tells Clocked when you open a distracting app.
private struct PhoneLinkSection: View {
    @ObservedObject var link: PhoneLink
    @ObservedObject var settings = AppSettings.shared
    @State private var wizard = false
    @State private var copied: String?

    var body: some View {
        Section {
            if settings.phoneLink {
                LabeledContent("Status") {
                    switch link.state {
                    case .off, .starting: Text("Starting…").foregroundStyle(.secondary)
                    case .listening: Text("Listening on this Wi-Fi").foregroundStyle(.green)
                    case .failed(let message): Text(message).foregroundStyle(.red)
                    }
                }
                linkRow("App opened link", "opened")
                linkRow("App closed link", "closed")
                HStack {
                    Button("Set Up Again…") { wizard = true }
                    Button("New Pairing Key") { link.resetKey() }
                        .help("The old links stop working. Paste the new ones into your shortcuts.")
                    Button("Turn Off") { settings.phoneLink = false; link.stop() }
                    Spacer()
                    if let last = link.lastMessage {
                        Text("Last message: app \(last.event), \(last.at.formatted(.relative(presentation: .named)))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Text("Let your iPhone tell Clocked the moment you open a distracting app.")
                    Spacer()
                    Button("Set Up…") { wizard = true }
                }
            }
        } header: {
            Text("iPhone")
        } footer: {
            Text("Works through a Shortcuts automation on your Wi-Fi. A separate helper receives the messages; nothing goes over the internet.")
        }
        .sheet(isPresented: $wizard) { PhoneLinkWizard(link: link) }
    }

    private func linkRow(_ title: String, _ event: String) -> some View {
        LabeledContent(title) {
            HStack {
                Text(link.link(event)).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button(copied == event ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.link(event), forType: .string)
                    copied = event
                }
            }
        }
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
