import Charts
import SwiftUI

struct StatsPane: View {
    @EnvironmentObject var c: SessionController
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var confirmClear = false

    private let calendar = Calendar.current
    private var dailyGoal: Double { AppSettings.shared.dailyGoalMinutes * 60 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryRow
                // Side by side when there's room, stacked when the window is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        Card { monthHeatmap }.frame(minWidth: 340)
                        Card { dayDetail }.frame(minWidth: 300)
                    }
                    VStack(spacing: 16) {
                        Card { monthHeatmap }
                        Card { dayDetail }
                    }
                }
                Card { hourChart }
                Card { weekChart }
            }
            .frame(maxWidth: 1100)
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .navigationTitle("Stats")
        .toolbar {
            Button("Clear Statistics", systemImage: "trash") { confirmClear = true }
                .disabled(c.studyLog.days.isEmpty)
        }
        .confirmationDialog("Clear all study statistics?", isPresented: $confirmClear) {
            Button("Clear Statistics", role: .destructive) { c.studyLog.clear() }
        }
    }

    // MARK: Summary

    private var summaryRow: some View {
        let today = calendar.startOfDay(for: Date())
        let week = calendar.dateInterval(of: .weekOfYear, for: today)!
        let monthInterval = calendar.dateInterval(of: .month, for: today)!
        let weekTotal = total(from: week.start, to: today)
        let monthTotal = total(from: monthInterval.start, to: today)
        let daysSoFar = (calendar.dateComponents([.day], from: monthInterval.start, to: today).day ?? 0) + 1
        let tiles = Group {
            SummaryTile(symbol: "sun.max.fill", title: "Today", value: formatHours(c.studyLog.total(on: today)))
            SummaryTile(symbol: "calendar", title: "This week", value: formatHours(weekTotal))
            SummaryTile(symbol: "calendar.circle", title: "This month", value: formatHours(monthTotal))
            SummaryTile(symbol: "chart.line.uptrend.xyaxis", title: "Daily average", value: formatHours(monthTotal / Double(daysSoFar)))
            SummaryTile(symbol: "flame.fill", title: "Streak", value: streak == 1 ? "1 day" : "\(streak) days", tint: Theme.accent)
        }
        return ViewThatFits(in: .horizontal) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 130), spacing: 12), count: 5), spacing: 12) { tiles }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) { tiles }
        }
    }

    private func total(from start: Date, to end: Date) -> Double {
        var t = 0.0
        var day = start
        while day <= end {
            t += c.studyLog.total(on: day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return t
    }

    /// Consecutive days (ending today, or yesterday if today has nothing yet) with at least 10 minutes of study.
    private var streak: Int {
        var day = calendar.startOfDay(for: Date())
        if c.studyLog.total(on: day) < 600 { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while c.studyLog.total(on: day) >= 600 {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    // MARK: Month heatmap

    private var monthHeatmap: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button("Previous Month", systemImage: "chevron.left") { shiftMonth(-1) }
                    .labelStyle(.iconOnly)
                Button("Next Month", systemImage: "chevron.right") { shiftMonth(1) }
                    .labelStyle(.iconOnly)
                    .disabled(calendar.isDate(month, equalTo: Date(), toGranularity: .month))
            }
            .buttonStyle(.borderless)

            let symbols = weekdaySymbols
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        Button { selected = day } label: {
                            DayCell(day: day, seconds: c.studyLog.total(on: day), goal: dailyGoal,
                                    isSelected: calendar.isDate(day, inSameDayAs: selected),
                                    isToday: calendar.isDateInToday(day),
                                    isFuture: day > Date())
                        }
                        .buttonStyle(.plain)
                        .disabled(day > Date())
                        .accessibilityLabel("\(day.formatted(date: .long, time: .omitted)), \(formatHours(c.studyLog.total(on: day)))")
                    } else {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    }
                }
            }

            HStack(spacing: 4) {
                Spacer()
                Text("0").font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<6) { level in
                    RoundedRectangle(cornerRadius: 3).fill(heatColor(level: level)).frame(width: 12, height: 12)
                }
                Text("goal").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 520)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var monthCells: [Date?] {
        let range = calendar.range(of: .day, in: .month, for: month)!
        let weekday = calendar.component(.weekday, from: month)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let days = range.map { calendar.date(byAdding: .day, value: $0 - 1, to: month)! }
        return Array(repeating: nil, count: leading) + days.map { Optional($0) }
    }

    private func shiftMonth(_ delta: Int) {
        month = calendar.date(byAdding: .month, value: delta, to: month)!
    }

    // MARK: Selected day

    private var dayDetail: some View {
        let record = c.studyLog.record(on: selected)
        // Time from subjects that no longer exist (or none) is shown as one "Other" row.
        var merged: [String: Double] = [:]
        for (id, seconds) in record.totals {
            merged[c.subjects.subject(id: id) == nil ? StudyLog.unassigned : id, default: 0] += seconds
        }
        let entries = merged.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(selected.formatted(.dateTime.weekday(.wide).month().day())).font(.headline)
                Spacer()
                Text(formatHMS(record.total)).font(.title3.monospacedDigit())
            }
            if let longest = record.longestFocus, longest >= 60 {
                LabeledContent("Longest focus", value: formatHours(longest))
                    .font(.callout)
            }
            if entries.isEmpty {
                Text("Nothing studied this day.").foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.key) { id, seconds in
                    let subject = c.subjects.subject(id: id)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Circle().fill(subject?.color ?? .gray).frame(width: 8, height: 8)
                            Text(subject?.name ?? "Other").font(.callout)
                            Spacer()
                            Text(formatHMS(seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(subject?.color ?? .gray)
                                .frame(width: max(4, geo.size.width * seconds / max(record.total, 1)))
                        }
                        .frame(height: 6)
                    }
                }
            }
            if record.total > 0 {
                Divider()
                Text("Timeline").font(.subheadline.weight(.medium))
                if record.blocks.isEmpty {
                    Text("The timeline is kept for the last 14 days.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Timeline(blocks: record.blocks,
                             colorFor: { c.subjects.subject(id: $0)?.color ?? .gray },
                             nameFor: { c.subjects.subject(id: $0)?.name ?? "Other" })
                }
            }
        }
    }

    // MARK: Focus by hour

    /// When in the day you focus and when you drift, for the selected day.
    private var hourChart: some View {
        let record = c.studyLog.record(on: selected)
        let focused = record.focusedByHour ?? [:], distracted = record.distractedByHour ?? [:]
        let hours = Set(focused.keys).union(distracted.keys)
        let span = hours.isEmpty ? [] : Array((hours.min()!)...(max(hours.max()!, hours.min()! + 3)))
        let labels = span.map { String(format: "%02d", $0) }
        let rows: [(hour: String, kind: String, minutes: Double)] = span.flatMap { h in
            [(String(format: "%02d", h), "Focused", (focused[h] ?? 0) / 60), (String(format: "%02d", h), "Distracted", (distracted[h] ?? 0) / 60)]
        }
        let totalDistracted = distracted.values.reduce(0, +)
        let totalFocused = focused.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Focus by Hour").font(.headline)
                Spacer()
                if totalFocused + totalDistracted > 0 {
                    let share = Int((totalDistracted / (totalFocused + totalDistracted) * 100).rounded())
                    Text(share == 0 ? "100% focused" : "\(share)% distracted")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                Text("No sessions on this day.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        BarMark(x: .value("Hour", row.hour), y: .value("Minutes", row.minutes))
                            .foregroundStyle(by: .value("State", row.kind))
                    }
                }
                .chartForegroundStyleScale(["Focused": Theme.accent, "Distracted": Color.gray])
                .chartXScale(domain: labels)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let m = value.as(Double.self) { Text("\(Int(m))m") } }
                    }
                }
                .frame(height: 150)
            }
        }
    }

    // MARK: Week chart

    private var weekChart: some View {
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
        let labels = days.map { calendar.isDateInToday($0) ? "Today" : $0.formatted(.dateTime.weekday(.abbreviated)) }
        let rows: [(day: String, name: String, hours: Double)] = zip(days, labels).flatMap { day, label in
            c.studyLog.record(on: day).totals.map { id, seconds in
                (label, c.subjects.subject(id: id)?.name ?? "Other", seconds / 3600)
            }
        }
        // Legend only lists subjects that appear this week.
        let shown = Set(rows.map(\.name))
        let known = c.subjects.subjects.filter { shown.contains($0.name) }
        let names = known.map(\.name) + (shown.contains("Other") ? ["Other"] : [])
        let colors = known.map(\.color) + (shown.contains("Other") ? [Color.gray] : [])
        return VStack(alignment: .leading, spacing: 10) {
            Text("Last 7 Days").font(.headline)
            Chart {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    BarMark(x: .value("Day", row.day), y: .value("Hours", row.hours))
                        .foregroundStyle(by: .value("Subject", row.name))
                }
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartXScale(domain: labels)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let h = value.as(Double.self) { Text("\(h, format: .number)h") } }
                }
            }
            .frame(height: 180)
        }
    }
}

// MARK: - Pieces

private func heatColor(level: Int) -> Color {
    Theme.accent.opacity([0.08, 0.25, 0.45, 0.65, 0.85, 1.0][level])
}

/// 0 = nothing; then quarters of the daily goal; 5 = goal reached.
private func heatLevel(_ seconds: Double, goal: Double) -> Int {
    guard seconds >= 60 else { return 0 }
    let share = seconds / max(goal, 60)
    switch share {
    case ..<0.25: return 1
    case ..<0.5: return 2
    case ..<0.75: return 3
    case ..<1: return 4
    default: return 5
    }
}

private struct DayCell: View {
    let day: Date
    let seconds: Double
    let goal: Double
    let isSelected: Bool
    let isToday: Bool
    let isFuture: Bool

    var body: some View {
        let level = heatLevel(seconds, goal: goal)
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isFuture ? Color.clear : heatColor(level: level))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 40, maxHeight: 40)
            .overlay {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.caption2.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isFuture ? AnyShapeStyle(.tertiary) : (level >= 3 ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2)
            }
            .help(isFuture ? "" : (seconds > 0 ? formatHMS(seconds) : "No study"))
            .contentShape(Rectangle())
    }
}

/// 24 rows (hours) × 6 columns (10-minute blocks), coloured by subject.
private struct Timeline: View {
    let blocks: [Int: String]
    let colorFor: (String) -> Color
    let nameFor: (String) -> String

    var body: some View {
        // Only the hours around when you studied (at least six rows).
        let studied = blocks.keys.map { $0 / 6 }
        let first = max(0, (studied.min() ?? 8) - 1), last = min(23, max((studied.max() ?? 8) + 1, first + 5))
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(first...last, id: \.self) { hour in
                GridRow {
                    Text(String(format: "%02d", hour))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    ForEach(0..<6, id: \.self) { tenth in
                        let block = hour * 6 + tenth
                        RoundedRectangle(cornerRadius: 2)
                            .fill(blocks[block].map(colorFor) ?? Color.primary.opacity(0.07))
                            .frame(height: 8)
                            .help(blocks[block].map(nameFor) ?? "")
                    }
                }
            }
        }
    }
}

private struct SummaryTile: View {
    let symbol: String
    let title: String
    let value: String
    var tint: Color = .secondary
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(tint == .secondary ? Color.secondary : tint)
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

func formatHours(_ t: TimeInterval) -> String {
    let minutes = Int(t / 60)
    guard minutes >= 60 else { return "\(minutes)m" }
    return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
}
