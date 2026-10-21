import Foundation
import Combine

/// One finished study session. Only totals are kept: no page titles, no images.
struct SessionSummary: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var topic: String
    var duration: TimeInterval
    var focused: TimeInterval
    var phone: TimeInterval
    var offTask: TimeInterval
    var away: TimeInterval
    var nudges: Int
    /// e.g. ["youtube.com · 4m", "Phone · 2m"]
    var topDistractions: [String]
    var subjectID: String? = nil

    var focusScore: Int {
        min(100, max(0, Int((focused / max(1, duration) * 100).rounded())))
    }
}

/// Keeps the last few session summaries in one small JSON file (a few KB at most).
final class HistoryStore: ObservableObject {
    static let limit = 30
    @Published private(set) var sessions: [SessionSummary] = []

    private let url = Storage.file("history.json")

    init() {
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode([SessionSummary].self, from: data) {
                sessions = decoded
            } else {
                // Unreadable: keep it aside rather than overwrite it on the next save.
                try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            }
        }
    }

    func add(_ summary: SessionSummary) {
        sessions.insert(summary, at: 0)
        if sessions.count > Self.limit { sessions.removeLast(sessions.count - Self.limit) }
        save()
    }

    func clear() {
        sessions = []
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "\(sec)s"
}

func formatClock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}
