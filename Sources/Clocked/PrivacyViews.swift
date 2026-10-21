import SwiftUI

/// The privacy promises, in plain words. Shown in onboarding and at the top of Settings → Privacy.
struct PrivacyPromises: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Promise(icon: "wifi.slash", title: "Offline unless you say otherwise",
                    detail: "Clocked works completely offline. Nothing is uploaded unless you turn on online features for study groups.")
            Promise(icon: "camera", title: "Camera and mic only while you study",
                    detail: "They switch on when a session starts and off when it ends or you take a break. Frames and sound are analysed in memory and thrown away. Nothing is recorded.")
            Promise(icon: "cpu", title: "Everything runs on this Mac",
                    detail: "Detection, the learning model and tab checks all happen here. macOS itself blocks the part that uses the camera and mic from reaching the internet.")
            Promise(icon: "trash", title: "Yours to delete",
                    detail: "Your stats, sessions and learned examples stay on this Mac, and Settings → Privacy can delete all of it at once.")
        }
    }
}

private struct Promise: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The master switch for online features, with exactly what goes online when it's on.
struct OnlineSwitch: View {
    @EnvironmentObject var c: SessionController
    @State private var confirmOn = false

    private var sync: GroupSync { c.groupSync }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top) {
                Image(systemName: sync.onlineEnabled ? "globe" : "wifi.slash")
                    .font(.title2)
                    .foregroundStyle(sync.onlineEnabled ? Theme.accent : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sync.onlineEnabled ? "Online features are on" : "Online features are off").font(.headline)
                    Text(sync.onlineEnabled
                         ? "Only for study groups, end-to-end encrypted. Detection still never goes online."
                         : "Clocked isn't connecting to anything. Turn this on only if you want study groups.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Online features", isOn: Binding(
                    get: { sync.onlineEnabled },
                    set: { on in if on { confirmOn = true } else { sync.onlineEnabled = false } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            OnlineDetails()
        }
        .confirmGoingOnline(isPresented: $confirmOn)
    }
}

/// Exactly what goes online, where, and who can read it.
struct OnlineDetails: View {
    @EnvironmentObject var c: SessionController
    var body: some View {
        let sync = c.groupSync
        DisclosureGroup("What goes online when this is on") {
            VStack(alignment: .leading, spacing: 6) {
                Bullet("Sent, encrypted on this Mac first: your nickname, the totals you choose to share (today, studying now, week and streak, subjects) and, if you choose, a small copy of your profile photo.")
                Bullet("Sent to: \(sync.databaseDescription), and nowhere else. It's stored scrambled under random IDs, so whoever runs the database\(sync.usingOwnDatabase ? "" : ", including Clocked's makers,") can't read it.")
                Bullet("Never sent: camera, microphone, posture, phone detection, the learning model, page titles, apps or anything else.")
                Bullet("Who can read it: only people with your group's invite code. The database itself only sees when you sync and your IP address, like any website.")
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

extension View {
    /// Asks before going online, and says what that means.
    func confirmGoingOnline(isPresented: Binding<Bool>) -> some View { modifier(ConfirmGoingOnline(isPresented: isPresented)) }
}

private struct ConfirmGoingOnline: ViewModifier {
    @EnvironmentObject var c: SessionController
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content.confirmationDialog("Turn on online features?", isPresented: $isPresented) {
            Button("Turn On") { c.groupSync.onlineEnabled = true }
            Button("Keep Offline", role: .cancel) {}
        } message: {
            Text("Clocked will send your encrypted study totals to \(c.groupSync.databaseDescription) so your groups can see them. Nobody else can read them\(c.groupSync.usingOwnDatabase ? "" : ", including Clocked's makers"). Camera, microphone and detection data never leave this Mac. You can turn this off at any time.")
        }
    }
}

private struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Settings → Privacy → Study Groups Database: Clocked's, or your own Supabase project.
/// Everyone in a group has to use the same database, so a friend's connection code can be pasted here.
struct DatabaseSettings: View {
    @EnvironmentObject var c: SessionController
    @State private var testResult: String?
    @State private var testing = false
    @State private var copiedScript = false
    @State private var copiedCode = false
    @State private var pasted = ""
    @State private var pasteError: String?

    private var sync: GroupSync { c.groupSync }

    var body: some View {
        if GroupSync.builtIn != nil {
            Picker("Database", selection: Binding(get: { sync.useOwnDatabase }, set: { sync.useOwnDatabase = $0 })) {
                Text("Clocked's database").tag(false)
                Text("My own Supabase project").tag(true)
            }
            .pickerStyle(.radioGroup)
            Text(sync.useOwnDatabase
                 ? "For people who'd rather keep group data in a database they control. Everyone in a group must use the same database."
                 : "Recommended. Nothing to set up. Your data is encrypted, so the database can't read it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if sync.usingOwnDatabase {
            VStack(alignment: .leading, spacing: 6) {
                Text("Joining a friend's database? Paste their connection code:").font(.callout)
                HStack {
                    TextField("", text: $pasted, prompt: Text("CLKDB1-…")).textFieldStyle(.roundedBorder).font(.body.monospaced())
                    Button("Use") {
                        do { try sync.useConnectionCode(pasted); pasted = ""; pasteError = nil; testResult = nil }
                        catch { pasteError = error.localizedDescription }
                    }
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let pasteError { Text(pasteError).font(.callout).foregroundStyle(Theme.warning) }
            }
            DisclosureGroup("Set up a new database") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Create a free project at supabase.com.")
                    HStack {
                        Text("2. In its SQL Editor, run the setup script.")
                        Button(copiedScript ? "Copied" : "Copy Script") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SupabaseGroups.setupSQL, forType: .string)
                            copiedScript = true
                        }
                        .controlSize(.small)
                    }
                    Text("3. Under Authentication, turn off new sign-ups (Clocked doesn't use them).")
                    Text("4. From Project Settings → API Keys, paste the Project URL and the publishable key below. Never the secret key.")
                }
                .font(.callout)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField("Project URL", text: Binding(get: { sync.supabaseURL }, set: { sync.supabaseURL = $0 }),
                      prompt: Text("https://your-project.supabase.co"))
            SecureField("Publishable key", text: Binding(get: { sync.supabaseKey }, set: { sync.supabaseKey = $0 }),
                        prompt: Text("sb_publishable_…"))
            if sync.hasSecretKey {
                Label("That's a secret key, which bypasses all the database's rules. Use the publishable key.", systemImage: "exclamationmark.octagon")
                    .font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button(testing ? "Testing…" : "Test Connection") {
                    testing = true
                    Task {
                        let error = await sync.testConnection()
                        testResult = error ?? "Connected."
                        testing = false
                        if error == nil { sync.startSyncing() }
                    }
                }
                .disabled(!sync.isConfigured || testing || !sync.onlineEnabled)
                .help(sync.onlineEnabled ? "" : "Turn on online features first.")
                if let testResult { Text(testResult).font(.callout).foregroundStyle(testResult == "Connected." ? .green : Theme.warning) }
                Spacer()
                if let code = sync.connectionCode {
                    Button(copiedCode ? "Copied" : "Copy Connection Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copiedCode = true
                    }
                    .help("Send this to friends so they use the same database. It contains the address and publishable key, never anything secret.")
                }
            }
        }
    }
}

/// One line at the bottom of the sidebar so it's always clear whether anything is going online.
struct OnlineStatusLine: View {
    @EnvironmentObject var c: SessionController
    var body: some View {
        Button { c.selectedPane = .privacy } label: {
            HStack(spacing: 6) {
                Image(systemName: c.groupSync.isOnline ? "globe" : "lock.fill")
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.groupSync.isOnline ? "Online" : "Offline").font(.caption.weight(.semibold))
                    Text(c.groupSync.isOnline ? "Study groups, encrypted" : "Nothing leaves this Mac")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .foregroundStyle(c.groupSync.isOnline ? Theme.accent : Color.secondary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Privacy settings")
    }
}

/// Settings → Privacy.
struct PrivacySettings: View {
    @EnvironmentObject var c: SessionController
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("At a Glance") { PrivacyPromises().padding(.vertical, 4) }

            Section("Internet") { OnlineSwitch().padding(.vertical, 4) }

            Section {
                DatabaseSettings()
            } header: {
                Text("Study Groups Database")
            } footer: {
                Text("Everyone in a group must use the same database. Your group's invite code works only on the database it was made on.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                PrivacyRow(icon: "camera", title: "Camera",
                           detail: "One 640×480 frame per second during a session, sensor test or posture recording. Analysed in memory, then discarded.")
                PrivacyRow(icon: "mic", title: "Microphone",
                           detail: "Built-in mic only, during a session or sensor test. Sound is classified in memory and never recorded.")
                PrivacyRow(icon: "macwindow", title: "Screen",
                           detail: "Never captured. Only the name of the app in front, and the active browser tab's title and address, checked on this Mac.")
                PrivacyRow(icon: "keyboard", title: "Keyboard and mouse",
                           detail: "How many keys were pressed and when the mouse last moved. Never which keys.")
                PrivacyRow(icon: "message", title: "Phone reminders (optional, off by default)",
                           detail: "Sent by the Messages app as an iMessage to you. Contains the reminder text and your subject name.")
            } header: {
                Text("What Clocked Uses")
            }

            Section {
                PrivacyRow(icon: "internaldrive", title: "Stored on this Mac only",
                           detail: "Settings and subjects, study time per day (400 days), up to \(HistoryStore.limit) session summaries, recorded postures as summary numbers, up to 1,500 learning examples (numbers only), and your profile photo if you add one (256 × 256). Under 1 MB in total.")
                PrivacyRow(icon: "eye.slash", title: "Never stored anywhere",
                           detail: "Camera images, audio, page titles, keystrokes, logs.")
                HStack {
                    Spacer()
                    Button("Delete All My Data…", role: .destructive) { confirmDelete = true }
                }
            } header: {
                Text("Your Data")
            }

            Section("Permissions") {
                HStack {
                    Button("Camera") { openPrivacyPane("Privacy_Camera") }
                    Button("Microphone") { openPrivacyPane("Privacy_Microphone") }
                    Button("Automation (browsers)") { openPrivacyPane("Privacy_Automation") }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all your Clocked data?", isPresented: $confirmDelete) {
            Button("Delete Everything", role: .destructive) { Task { await c.deleteAllData() } }
        } message: {
            Text("This erases your stats, sessions, subjects, postures, learning examples and settings from this Mac\(c.groupSync.isOnline ? ", and removes you from your study groups" : ""). Clocked will then quit. This can't be undone.")
        }
    }
}

struct PrivacyRow: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}
