import SwiftUI

/// Past sessions, grouped by day.
struct SessionsPane: View {
    @EnvironmentObject var c: SessionController
    @State private var confirmClear = false

    private var days: [(day: Date, sessions: [SessionSummary])] {
        Dictionary(grouping: c.history.sessions) { Calendar.current.startOfDay(for: $0.start) }
            .map { ($0.key, $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        Group {
            if c.history.sessions.isEmpty {
                ContentUnavailableView("No Sessions Yet", systemImage: "clock",
                                       description: Text(AppSettings.shared.keepHistory ? "Finished sessions longer than a minute appear here." : "The session list is turned off in Settings."))
            } else {
                List {
                    ForEach(days, id: \.day) { group in
                        Section {
                            ForEach(group.sessions) { SessionRow(session: $0) }
                        } header: {
                            HStack {
                                Text(dayTitle(group.day))
                                Spacer()
                                Text(formatHours(group.sessions.reduce(0) { $0 + $1.focused })).monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            Button("Clear Sessions", systemImage: "trash") { confirmClear = true }
                .disabled(c.history.sessions.isEmpty)
        }
        .confirmationDialog("Delete the session list?", isPresented: $confirmClear) {
            Button("Delete Sessions", role: .destructive) { c.history.clear() }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

private struct SessionRow: View {
    @EnvironmentObject var c: SessionController
    let session: SessionSummary

    var body: some View {
        let subject = c.subjects.subject(id: session.subjectID)
        HStack(spacing: Theme.Space.m) {
            Circle().fill(subject?.color ?? .gray).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.topic.isEmpty ? "Study session" : session.topic).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(formatHours(session.focused)).font(.body.monospacedDigit())
            Chip(text: "\(session.focusScore)%", color: session.focusScore >= 80 ? .green : (session.focusScore >= 50 ? Theme.warning : .red))
                .help("Share of the session spent focused")
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        var parts = [session.start.formatted(date: .omitted, time: .shortened) + " · " + formatDuration(session.duration) + " session"]
        if session.phone >= 60 { parts.append("phone \(formatDuration(session.phone))") }
        if let top = session.topDistractions.first, !top.hasPrefix("Phone") { parts.append(top) }
        return parts.joined(separator: " · ")
    }
}
