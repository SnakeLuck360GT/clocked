import AppKit

/// What's in front of you right now. Never captures pixels: just the app name, and for browsers the active tab's title + URL.
/// Kept in memory only.
struct ActivitySnapshot: Equatable {
    var appName: String
    var bundleID: String
    var isBrowser: Bool
    var title: String?
    var url: String?

    var domain: String? {
        guard let url, let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Short name used in the UI and in session totals ("youtube.com", "Discord").
    var label: String { domain ?? appName }

    var key: String { "\(bundleID)|\(domain ?? "")|\(title ?? "")" }
    /// App + site, ignoring the page title.
    var siteKey: String { "\(bundleID)|\(domain ?? "")" }
}

/// Watches which app is frontmost and, for supported browsers, the active tab. Only runs during a session.
@MainActor
final class ActivityMonitor {
    enum BrowserKind { case safari, chromium }

    static let browsers: [String: BrowserKind] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "company.thebrowser.Browser": .chromium, // Arc
        "org.chromium.Chromium": .chromium,
    ]

    var onChange: ((ActivitySnapshot) -> Void)?
    /// Called with a human-readable message when a browser refuses access (nil when fine).
    var onProblem: ((String?) -> Void)?

    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var last: ActivitySnapshot?
    private let reader = TabReader()
    private var reading = false
    private var generation = 0

    func start() {
        stop()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        last = nil
        reading = false
        generation += 1
    }

    func poll() {
        guard !reading, let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let bundleID = app.bundleIdentifier ?? ""
        let snapshot = ActivitySnapshot(appName: app.localizedName ?? "Unknown app", bundleID: bundleID,
                                        isBrowser: Self.browsers[bundleID] != nil)
        guard let kind = Self.browsers[bundleID] else {
            deliver(snapshot)
            return
        }
        // Apple Events can block (or show a permission prompt), so ask the browser off the main thread.
        reading = true
        let gen = generation
        reader.read(bundleID: bundleID, kind: kind) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.reading = false
                    var snapshot = snapshot
                    switch result {
                    case .tab(let title, let url):
                        snapshot.title = title
                        snapshot.url = url
                        self.onProblem?(nil)
                    case .denied:
                        self.onProblem?("Allow access to \(snapshot.appName) in System Settings → Privacy & Security → Automation so tabs can be checked.")
                    case .unavailable:
                        break
                    }
                    self.deliver(snapshot)
                }
            }
        }
    }

    /// Strict mode: close the front tab of a browser (it was a distracting site).
    /// Only closes it if the front tab still shows `url`, so switching tabs during the warning is safe.
    func closeActiveTab(bundleID: String, ifURL url: String) {
        guard let kind = Self.browsers[bundleID] else { return }
        reader.closeTab(bundleID: bundleID, kind: kind, ifURL: url)
    }

    private func deliver(_ snapshot: ActivitySnapshot) {
        if snapshot != last {
            last = snapshot
            onChange?(snapshot)
        }
    }
}

/// Runs the AppleScript tab queries on its own serial queue (NSAppleScript instances stay on that one thread).
private final class TabReader: @unchecked Sendable {
    enum Result { case tab(title: String, url: String), denied, unavailable }

    private let queue = AppleScriptRunner.queue
    private var scripts: [String: NSAppleScript] = [:]

    func read(bundleID: String, kind: ActivityMonitor.BrowserKind, completion: @escaping (Result) -> Void) {
        queue.async { [self] in completion(run(bundleID: bundleID, kind: kind)) }
    }

    func closeTab(bundleID: String, kind: ActivityMonitor.BrowserKind, ifURL url: String) {
        let tab = kind == .safari ? "current tab" : "active tab"
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: """
            with timeout of 3 seconds
                tell application id "\(bundleID)"
                    if (count of windows) is 0 then return
                    set t to \(tab) of front window
                    if (URL of t) is "\(escaped)" then close t
                end tell
            end timeout
            """)?.executeAndReturnError(&error)
        }
    }

    private func run(bundleID: String, kind: ActivityMonitor.BrowserKind) -> Result {
        let script = scripts[bundleID] ?? {
            let tab = kind == .safari ? "current tab" : "active tab"
            let titleProperty = kind == .safari ? "name" : "title"
            let source = """
            with timeout of 3 seconds
                tell application id "\(bundleID)"
                    if (count of windows) is 0 then return ""
                    set t to \(tab) of front window
                    return (\(titleProperty) of t) & linefeed & (URL of t)
                end tell
            end timeout
            """
            let s = NSAppleScript(source: source)!
            scripts[bundleID] = s
            return s
        }()

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return (error[NSAppleScript.errorNumber] as? Int) == -1743 ? .denied : .unavailable
        }
        let parts = (result.stringValue ?? "").components(separatedBy: "\n")
        guard parts.count >= 2 else { return .unavailable }
        return .tab(title: parts[0], url: parts[1])
    }
}

/// Seconds since the last keyboard/mouse/trackpad input (no content, just the time).
func secondsSinceUserInput() -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

/// Seconds since the last event of one kind (e.g. a key press or mouse move). Timing only, never content.
func secondsSince(_ type: CGEventType) -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
}

/// Running total of key presses since login: just a number, never which keys.
func keyPressCount() -> UInt32 {
    CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
}
