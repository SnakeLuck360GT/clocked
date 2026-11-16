import Foundation

/// XPC interface of the ClockedLink helper: it listens on your local network for your iPhone's
/// "a distracting app opened / closed" messages (sent by a Shortcuts automation) and passes them on.
@objc protocol ClockedLinkXPC {
    /// Starts listening with this pairing key (or updates the key). Replies with the port, or an error message.
    func start(key: String, reply: @escaping (Int, String?) -> Void)
    /// Waits for the next message from your iPhone: "opened" or "closed". Called again after each reply.
    func nextEvent(reply: @escaping (String) -> Void)
}

enum LinkPolicy {
    /// Fixed, so the links in your shortcuts keep working.
    static let port: UInt16 = 52714
    static let serviceName = "com.davidxie.clocked.link"
}
