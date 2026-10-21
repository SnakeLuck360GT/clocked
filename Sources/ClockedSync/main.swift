// ClockedSync: a tiny XPC helper inside Clocked.app that performs HTTPS requests to the study-groups database
// (Clocked's, or your own Supabase project if you chose one in Settings).
// It is the only Clocked process with network access; the main app (camera, microphone, detection) has none,
// and only ever hands this helper already-encrypted study totals.
import Foundation

final class SyncService: NSObject, ClockedSyncXPC {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral // no cookies, no cache on disk
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func perform(_ request: Data, reply: @escaping (Data?, String?) -> Void) {
        guard let req = try? JSONDecoder().decode(SyncRequest.self, from: request) else {
            reply(nil, "Malformed request"); return
        }
        guard SyncPolicy.isAllowed(req.url) else {
            reply(nil, "Blocked: only https://*.supabase.co is allowed"); return
        }
        var urlRequest = URLRequest(url: req.url)
        urlRequest.httpMethod = req.method
        urlRequest.httpBody = req.body
        req.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        session.dataTask(with: urlRequest) { data, response, error in
            if let error { reply(nil, error.localizedDescription); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            reply(try? JSONEncoder().encode(SyncResponse(status: status, body: data ?? Data())), nil)
        }.resume()
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ClockedSyncXPC.self)
        connection.exportedObject = SyncService()
        connection.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
