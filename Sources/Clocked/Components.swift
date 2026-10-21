import SwiftUI

extension SessionController.Phase {
    var isBreak: Bool {
        if case .onBreak = self { return true }
        return false
    }
}

struct StatusBadge: View {
    let status: FocusStatus
    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
    private var tint: Color {
        if status.isDistracted { return Theme.warning }
        switch status {
        case .focused: return .green
        case .away, .onBreak: return .blue
        default: return Theme.accent
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}

struct SummaryGrid: View {
    let summary: SessionSummary
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 5), spacing: Theme.Space.s) {
            StatTile(title: "Studied", value: formatHours(summary.focused))
            StatTile(title: "Focus", value: "\(summary.focusScore)%")
            StatTile(title: "Phone", value: formatDuration(summary.phone))
            StatTile(title: "Off task", value: formatDuration(summary.offTask))
            StatTile(title: "Away", value: formatDuration(summary.away))
        }
        if !summary.topDistractions.isEmpty {
            Text("Top distractions: " + summary.topDistractions.joined(separator: ", "))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct SensorRow: View {
    let name: String
    let state: SensorState
    let pane: String
    var body: some View {
        LabeledContent(name) {
            switch state {
            case .on: Text("On").foregroundStyle(.green)
            case .starting: Text("Starting").foregroundStyle(.secondary)
            case .off: Text("Off").foregroundStyle(.secondary)
            case .failed(let message): Text(message).foregroundStyle(Theme.warning)
            case .denied:
                HStack {
                    Text("No access").foregroundStyle(Theme.warning)
                    Button("Open System Settings") { openPrivacyPane(pane) }
                }
            }
        }
    }
}

extension Verdict {
    var label: String {
        switch self {
        case .study: return "Study"
        case .neutral: return "Neutral"
        case .distraction: return "Distraction"
        }
    }
    var color: Color {
        switch self {
        case .study: return .green
        case .neutral: return .secondary
        case .distraction: return Theme.warning
        }
    }
}

extension PostureVerdict {
    func label(learned: Bool) -> String {
        switch self {
        case .unknown: return learned ? "Unclear" : "Learning"
        case .absent: return "No one in view"
        case .screen: return "Facing screen"
        case .paper: return "Writing posture"
        case .phone: return "Phone posture"
        case .down: return "Head down"
        }
    }
}

extension AudioReading {
    var label: String {
        var parts = [current.capitalized]
        if writingHeard { parts.append("writing") }
        if typingHeard { parts.append("typing") }
        return parts.joined(separator: ", ")
    }
}

func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}
