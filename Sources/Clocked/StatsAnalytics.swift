import Charts
import SwiftUI

/// Longer-range charts for Stats: the last 30 days, where the time went, when you focus best,
/// and what pulls you away. Everything comes from the study log and the session list already on this Mac.
struct StatsAnalytics: View {
    enum Part { case trends, focus }
    var part: Part
    @EnvironmentObject var c: SessionController
    private let calendar = Calendar.current
    private var dailyGoal: Double { AppSettings.shared.dailyGoalMinutes * 60 }

    var body: some View {
        VStack(spacing: 16) {
            switch part {
            case .trends:
                Card { thirtyDays }
                Card { subjectShare }
            case .focus:
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        Card { focusTrend }.frame(minWidth: 380)
                        Card { distractions }.frame(minWidth: 300)
                    }
                    VStack(spacing: 16) { Card { focusTrend }; Card { distractions } }
                }
                Card { bestHours }
            }
        }
    }

    private var days30: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<30).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
    }

    private func subjectName(_ id: String) -> String { c.subjects.subject(id: id)?.name ?? "Other" }
    private var subjectDomain: (names: [String], colors: [Color]) {
        (c.subjects.subjects.map(\.name) + ["Other"], c.subjects.subjects.map(\.color) + [.gray])
    }

    // MARK: Last 30 days

    private var thirtyDays: some View {
        let rows: [(day: Date, name: String, hours: Double)] = days30.flatMap { day in
            c.studyLog.record(on: day).totals.map { (day, subjectName($0.key), $0.value / 3600) }
        }
        let total = days30.map { c.studyLog.total(on: $0) }.reduce(0, +)
        let studied = days30.filter { c.studyLog.total(on: $0) > 0 }.count
        let average = total / 30 / 3600
        let goalDays = days30.filter { c.studyLog.total(on: $0) >= dailyGoal }.count
        let previous = (30..<60).map { calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: Date()))! }
            .map { c.studyLog.total(on: $0) }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 30 Days").font(.headline)
                Spacer()
                Text("\(studied) of 30 days studied · goal met on \(goalDays)").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                figure("Total", formatHours(total), change: previous > 0 ? (total - previous) / previous : nil)
                figure("Daily average", formatHours(average * 3600))
                figure("Best day", formatHours(days30.map { c.studyLog.total(on: $0) }.max() ?? 0))
            }
            Chart {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    BarMark(x: .value("Day", row.day, unit: .day), y: .value("Hours", row.hours))
                        .foregroundStyle(by: .value("Subject", row.name))
                }
                RuleMark(y: .value("Goal", dailyGoal / 3600))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Goal").font(.caption2).foregroundStyle(.secondary)
                    }
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Theme.accent.opacity(0.7))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Average").font(.caption2).foregroundStyle(Theme.accent)
                    }
            }
            .chartForegroundStyleScale(domain: subjectDomain.names, range: subjectDomain.colors)
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let h = v.as(Double.self) { Text("\(h, format: .number)h") } } } }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 200)
        }
    }

    private func figure(_ title: String, _ value: String, change: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.title3.monospacedDigit())
                if let change {
                    Label("\(Int((abs(change) * 100).rounded()))%", systemImage: change >= 0 ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(change >= 0 ? .green : .orange)
                        .help("Compared with the 30 days before")
                }
            }
        }
    }

    // MARK: Where the time went

    private var subjectShare: some View {
        var totals: [String: Double] = [:]
        for day in days30 { for (id, s) in c.studyLog.record(on: day).totals { totals[subjectName(id), default: 0] += s } }
        let rows = totals.sorted { $0.value > $1.value }
        let all = max(1, rows.map(\.value).reduce(0, +))
        return VStack(alignment: .leading, spacing: 12) {
            Text("Where the Time Went").font(.headline)
            HStack(alignment: .center, spacing: 20) {
                Chart(rows, id: \.key) { row in
                    SectorMark(angle: .value("Time", row.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(by: .value("Subject", row.key))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(domain: subjectDomain.names, range: subjectDomain.colors)
                .chartLegend(.hidden)
                .frame(width: 130, height: 130)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.key) { row in
                        HStack(spacing: 6) {
                            Circle().fill(c.subjects.subjects.first { $0.name == row.key }?.color ?? .gray).frame(width: 8, height: 8)
                            Text(row.key).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(formatHours(row.value)).monospacedDigit().foregroundStyle(.secondary)
                            Text("\(Int((row.value / all * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: 380)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: When you focus best

    private var bestHours: some View {
        var focused = [Int: Double](), distracted = [Int: Double]()
        for day in days30 {
            let r = c.studyLog.record(on: day)
            for (h, s) in r.focusedByHour ?? [:] { focused[h, default: 0] += s }
            for (h, s) in r.distractedByHour ?? [:] { distracted[h, default: 0] += s }
        }
        let hours = Set(focused.keys).union(distracted.keys).sorted()
        let rows = hours.map { h -> (hour: Int, minutes: Double, rate: Double) in
            let f = focused[h] ?? 0, d = distracted[h] ?? 0
            return (h, f / 60 / 30, f + d > 0 ? f / (f + d) : 0)
        }
        let best = rows.filter { $0.minutes > 5 }.max { $0.rate < $1.rate }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("When You Focus Best").font(.headline)
                Spacer()
                if let best { Text("Sharpest around \(String(format: "%02d:00", best.hour))").font(.callout).foregroundStyle(.secondary) }
            }
            Chart {
                ForEach(rows, id: \.hour) { row in
                    BarMark(x: .value("Hour", String(format: "%02d", row.hour)), y: .value("Minutes", row.minutes))
                        .foregroundStyle(Theme.accent.opacity(0.25 + 0.75 * row.rate))
                }
            }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let m = v.as(Double.self) { Text("\(Int(m))m") } } } }
            .frame(height: 150)
            Text("Average focused minutes per hour. Darker means fewer distractions in that hour.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Focus score trend

    private var focusTrend: some View {
        let sessions = c.history.sessions.reversed().enumerated().map { (i: $0.offset + 1, s: $0.element) }
        let average = sessions.isEmpty ? 0 : sessions.map(\.s.focusScore).reduce(0, +) / sessions.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Focus Score").font(.headline)
                Spacer()
                Text("Average \(average)% over \(sessions.count) sessions").font(.callout).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(sessions, id: \.i) { row in
                    AreaMark(x: .value("Session", row.i), y: .value("Score", row.s.focusScore))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Session", row.i), y: .value("Score", row.s.focusScore))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Session", row.i), y: .value("Score", row.s.focusScore))
                        .foregroundStyle(Theme.accent).symbolSize(16)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel { if let p = v.as(Int.self) { Text("\(p)%") } } } }
            .frame(height: 150)
        }
    }

    // MARK: What pulls you away

    private var distractions: some View {
        let s = c.history.sessions
        let rows: [(kind: String, seconds: Double, color: Color)] = [
            ("Phone", s.map(\.phone).reduce(0, +), Theme.warning),
            ("Off task", s.map(\.offTask).reduce(0, +), .purple),
            ("Away", s.map(\.away).reduce(0, +), .blue),
        ]
        let nudges = s.map(\.nudges).reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("What Pulls You Away").font(.headline)
                Spacer()
                Text("\(nudges) nudges").font(.callout).foregroundStyle(.secondary)
            }
            Chart(rows, id: \.kind) { row in
                BarMark(x: .value("Time", row.seconds / 60), y: .value("Kind", row.kind))
                    .foregroundStyle(row.color)
                    .annotation(position: .trailing) { Text(formatHours(row.seconds)).font(.caption).foregroundStyle(.secondary) }
            }
            .chartXAxis(.hidden)
            .frame(height: 110)
            Text("Last \(s.count) sessions").font(.caption).foregroundStyle(.secondary)
        }
    }
}
