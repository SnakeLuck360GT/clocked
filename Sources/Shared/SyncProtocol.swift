import Foundation

/// One HTTPS request for the sync helper to perform. The body is already end-to-end encrypted by the main app.
struct SyncRequest: Codable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
}

struct SyncResponse: Codable {
    var status: Int
    var body: Data
}

/// XPC interface of the ClockedSync helper: the only part of Clocked that can reach the internet.
@objc protocol ClockedSyncXPC {
    /// `request` is a JSON-encoded `SyncRequest`; the reply is a JSON-encoded `SyncResponse` or an error message.
    func perform(_ request: Data, reply: @escaping (Data?, String?) -> Void)
}

enum SyncPolicy {
    /// The helper only talks HTTPS to Supabase databases (Clocked's, or your own if you chose one in Settings).
    static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" && (url.host?.lowercased().hasSuffix(".supabase.co") ?? false)
    }
}
