import SwiftUI
import Combine

struct Subject: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var colorHex: String
    /// Optional exam date, shown as a countdown ("D-12").
    var examDate: Date?

    /// Days until the exam (0 on the day), or nil if none is set or it has passed.
    var daysToExam: Int? {
        guard let examDate else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: examDate)).day ?? -1
        return days >= 0 ? days : nil
    }

    var color: Color { Color(hex: colorHex) }

    /// Spread around the colour wheel so neighbouring subjects never look alike (and away from the orange accent).
    static let palette = ["#4C6EF5", "#20C997", "#845EF7", "#FAB005", "#F06595", "#22B8CF", "#51CF66", "#FF6B6B"]
    static let paletteNames = ["Blue", "Teal", "Violet", "Amber", "Pink", "Sky", "Green", "Coral"]
}

/// Your subjects, in UserDefaults (a few hundred bytes).
final class SubjectStore: ObservableObject {
    @Published private(set) var subjects: [Subject] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: "subjects"),
           let decoded = try? JSONDecoder().decode([Subject].self, from: data) {
            subjects = decoded
        }
    }

    func subject(id: String?) -> Subject? { subjects.first { $0.id == id } }

    @discardableResult
    func add(name: String) -> Subject {
        let used = Set(subjects.map(\.colorHex))
        let color = Subject.palette.first { !used.contains($0) } ?? Subject.palette[subjects.count % Subject.palette.count]
        let subject = Subject(name: name, colorHex: color)
        subjects.append(subject)
        save()
        return subject
    }

    func update(_ subject: Subject) {
        guard let i = subjects.firstIndex(where: { $0.id == subject.id }) else { return }
        subjects[i] = subject
        save()
    }

    func delete(_ subject: Subject) {
        subjects.removeAll { $0.id == subject.id }
        save()
    }

    func removeAll() {
        subjects = []
        UserDefaults.standard.removeObject(forKey: "subjects")
    }

    func move(from source: IndexSet, to destination: Int) {
        subjects.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(subjects) { UserDefaults.standard.set(data, forKey: "subjects") }
    }
}

/// One day of study: seconds per subject, plus which subject filled each 10-minute block (for the day timeline).
struct DayRecord: Codable, Equatable {
    var totals: [String: Double] = [:]
    /// 10-minute block of the day (0–143) → subject ID. Kept for the last 14 days only.
    var blocks: [Int: String] = [:]
    /// Seconds of focus and of distraction per hour of the day (0–23).
    var focusedByHour: [Int: Double]? = nil
    var distractedByHour: [Int: Double]? = nil
    /// Longest stretch of unbroken focus, in seconds.
    var longestFocus: Double? = nil

    var total: Double { totals.values.reduce(0, +) }
}

/// Study time per day, for the heatmap, charts and timeline. Totals are kept for 400 days (a few bytes per day);
/// the 10-minute timeline only for 14 days. One small JSON file.
final class StudyLog: ObservableObject {
    static let unassigned = "none"
    @Published private(set) var days: [String: DayRecord] = [:]
    private var dirty = false

    private let url = Storage.file("studylog.json")

    init() {
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode([String: DayRecord].self, from: data) {
                days = decoded
            } else {
                // Unreadable: keep it aside rather than overwrite it on the next save.
                let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: backup)
            }
        }
        prune()
    }

    static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func record(on date: Date) -> DayRecord { days[Self.key(date)] ?? DayRecord() }

    /// Study time from the start of this week up to today.
    func weekTotal(containing date: Date = Date()) -> Double {
        let calendar = Calendar.current
        guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return 0 }
        var total = 0.0, day = start
        while day <= date {
            total += self.total(on: day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return total
    }

    /// Consecutive days with at least 10 minutes of study, ending today (or yesterday if today has none yet).
    func streak() -> Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date())
        if total(on: day) < 600 { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while total(on: day) >= 600 {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }
    func total(on date: Date) -> Double { record(on: date).total }

    /// Adds focused study time. Called once a second during a session.
    func add(_ seconds: Double, subject: String?, at date: Date) {
        let key = Self.key(date)
        let id = subject ?? Self.unassigned
        var day = days[key] ?? DayRecord()
        day.totals[id, default: 0] += seconds
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        day.blocks[(c.hour ?? 0) * 6 + (c.minute ?? 0) / 10] = id
        day.focusedByHour = (day.focusedByHour ?? [:]).merging([c.hour ?? 0: seconds], uniquingKeysWith: +)
        days[key] = day
        dirty = true
    }

    /// Adds time spent distracted (phone or off-task), for the focus-by-hour insight.
    func addDistracted(_ seconds: Double, at date: Date) {
        let key = Self.key(date)
        var day = days[key] ?? DayRecord()
        let hour = Calendar.current.component(.hour, from: date)
        day.distractedByHour = (day.distractedByHour ?? [:]).merging([hour: seconds], uniquingKeysWith: +)
        days[key] = day
        dirty = true
    }

    func noteFocusStreak(_ seconds: Double, at date: Date) {
        let key = Self.key(date)
        guard seconds > (days[key]?.longestFocus ?? 0) else { return }
        var day = days[key] ?? DayRecord()
        day.longestFocus = seconds
        days[key] = day
        dirty = true
    }

    func saveIfNeeded() {
        guard dirty else { return }
        dirty = false
        prune()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: url, options: .atomic) }
    }

    func clear() {
        days = [:]
        dirty = false
        try? FileManager.default.removeItem(at: url)
    }

    private func prune() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let keepTotals = Self.key(calendar.date(byAdding: .day, value: -400, to: today)!)
        let keepBlocks = Self.key(calendar.date(byAdding: .day, value: -14, to: today)!)
        for (key, day) in days {
            if key < keepTotals { days[key] = nil }
            else if key < keepBlocks, !day.blocks.isEmpty { days[key]?.blocks = [:] }
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// "3:42:10" for the big timers.
func formatHMS(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}
