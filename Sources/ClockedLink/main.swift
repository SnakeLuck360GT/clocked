// ClockedLink: a tiny XPC helper inside Clocked.app that listens on your local network for two kinds of message
// from your own iPhone's Shortcuts automation: "a distracting app opened" and "it closed". Each message must carry
// your pairing key. It has no camera, microphone or file access, and can't connect out to anything; it only
// answers requests from devices on your local network. Off until you turn on the iPhone link in Settings.
import Foundation
import Network

final class LinkService: NSObject, ClockedLinkXPC {
    private let queue = DispatchQueue(label: "clocked.link")
    private var listener: NWListener?
    private var key = ""
    private var pending: [(String) -> Void] = []
    private var waiting: [String] = []

    func start(key: String, reply: @escaping (Int, String?) -> Void) {
        queue.async {
            self.key = key
            if self.listener != nil { reply(Int(LinkPolicy.port), nil); return }
            do {
                let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: LinkPolicy.port)!)
                listener.newConnectionHandler = { [weak self] in self?.handle($0) }
                var replied = false
                listener.stateUpdateHandler = { state in
                    guard !replied else { return }
                    switch state {
                    case .ready: replied = true; reply(Int(LinkPolicy.port), nil)
                    case .failed(let error): replied = true; reply(0, error.localizedDescription)
                    default: break
                    }
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                reply(0, error.localizedDescription)
            }
        }
    }

    func nextEvent(reply: @escaping (String) -> Void) {
        queue.async {
            if !self.waiting.isEmpty { reply(self.waiting.removeFirst()) } else { self.pending.append(reply) }
        }
    }

    private func deliver(_ event: String) {
        if !pending.isEmpty { pending.removeFirst()(event) }
        else { waiting.append(event); if waiting.count > 10 { waiting.removeFirst() } }
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        // Only devices on your own network: private IPv4 ranges, link-local and unique-local IPv6, or this Mac.
        guard Self.isLocal(connection.endpoint) else { connection.cancel(); return }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let status = data.flatMap { String(data: $0, encoding: .utf8) }.map(self.respond) ?? "400 Bad Request"
            let body = status.hasPrefix("200") ? "ok\n" : "no\n"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// "GET /opened?key=… HTTP/1.1" → delivers "opened" if the key matches.
    private func respond(_ request: String) -> String {
        let parts = request.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        guard parts.count >= 2, let components = URLComponents(string: String(parts[1])) else { return "400 Bad Request" }
        let given = components.queryItems?.first { $0.name == "key" }?.value ?? ""
        guard !key.isEmpty, Self.same(given, key) else { return "403 Forbidden" }
        switch components.path {
        case "/opened": deliver("opened")
        case "/closed": deliver("closed")
        default: return "404 Not Found"
        }
        return "200 OK"
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        case .ipv6(let a):
            if a.isLoopback || a.isLinkLocal { return true }
            if let v4 = a.asIPv4 { return isLocal(.hostPort(host: .ipv4(v4), port: 0)) }
            return ([UInt8](a.rawValue).first ?? 0) & 0xFE == 0xFC // unique local fc00::/7
        default:
            return false
        }
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    let service = LinkService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ClockedLinkXPC.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
