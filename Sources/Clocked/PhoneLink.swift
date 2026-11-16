import Foundation
import SystemConfiguration

/// The iPhone link: your iPhone's Shortcuts automations tell Clocked when you open or close a distracting app,
/// through the ClockedLink helper on your local network. The main app itself still has no network access.
/// Messages only count during a session; between sessions they're ignored (but still answered, so the
/// automation on your iPhone doesn't show an error).
final class PhoneLink: ObservableObject {
    enum State: Equatable { case off, starting, listening, failed(String) }

    @Published private(set) var state: State = .off
    /// A distracting app is open on your iPhone right now (as far as the last message says).
    @Published private(set) var appOpen = false
    @Published private(set) var lastMessage: (event: String, at: Date)?

    private var connection: NSXPCConnection?
    private var generation = 0
    private var openedAt: Date?
    private let settings = AppSettings.shared

    /// Shortcuts that send "opened" don't always get a matching "closed" (e.g. locking the phone inside the app).
    private static let assumeClosedAfter: TimeInterval = 20 * 60

    var hostName: String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { return "\(name).local" }
        return ProcessInfo.processInfo.hostName
    }

    func link(_ event: String) -> String {
        "http://\(hostName):\(LinkPolicy.port)/\(event)?key=\(settings.phoneLinkKey)"
    }

    func start() {
        guard settings.phoneLink else { return }
        if settings.phoneLinkKey.isEmpty { settings.phoneLinkKey = Self.newKey() }
        stop()
        generation += 1
        let gen = generation
        state = .starting
        let c = NSXPCConnection(serviceName: LinkPolicy.serviceName)
        c.remoteObjectInterface = NSXPCInterface(with: ClockedLinkXPC.self)
        c.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { if self?.generation == gen, self?.settings.phoneLink == true { self?.state = .failed("The link helper stopped.") } }
        }
        c.resume()
        connection = c
        let service = c.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async { if self?.generation == gen { self?.state = .failed(error.localizedDescription) } }
        } as? ClockedLinkXPC
        service?.start(key: settings.phoneLinkKey) { [weak self] port, error in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                if let error { self.state = .failed(error); return }
                self.state = .listening
                self.listen(service, gen)
            }
        }
    }

    func stop() {
        generation += 1
        connection?.invalidate()
        connection = nil
        state = .off
        appOpen = false
    }

    /// A new key makes the old links stop working (paste the new ones into your shortcuts).
    func resetKey() {
        settings.phoneLinkKey = Self.newKey()
        start()
    }

    /// Typing or clicking on the Mac for a while means you've put the phone down, whatever the last message said.
    func usingMac() { appOpen = false }

    /// Re-checked every second during a session.
    var distractingAppOpen: Bool {
        if appOpen, let openedAt, Date().timeIntervalSince(openedAt) > Self.assumeClosedAfter { appOpen = false }
        return appOpen
    }

    private func listen(_ service: ClockedLinkXPC?, _ gen: Int) {
        service?.nextEvent { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.lastMessage = (event, Date())
                if event == "opened" { self.appOpen = true; self.openedAt = Date() } else { self.appOpen = false }
                self.listen(service, gen)
            }
        }
    }

    private static func newKey() -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<12).map { _ in letters.randomElement()! })
    }
}
