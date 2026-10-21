import AppKit
import SwiftUI

/// Design tokens, from the app icon. Colour roles:
/// - `accent` (Ember): interactive elements, selection, the heatmap and the "focused" series in Stats.
/// - Subject colours: a subject's identity only (ring segments, play buttons, bars, dots, a light row tint).
/// - Status: green = focused, `warning` (amber) = distracted, grey = paused, blue = break, red = destructive.
enum Theme {
    static let accent = Color(hex: "#EF4F2C")
    static let accentLight = Color(hex: "#FF9150")
    static let warning = Color(hex: "#E39B2E")
    /// Deep backgrounds (Focus View, curtain).
    static let night = [Color(hex: "#2A1E1B"), Color(hex: "#101015")]

    /// Window background behind cards.
    static let canvas = dynamic(light: "#FBF7F4", dark: "#16161B")
    /// Card surface.
    static let card = dynamic(light: "#FFFFFF", dark: "#24232A")
    /// Raised element on a card (stat tiles, chips).
    static let raised = dynamic(light: "#F1E7DF", dark: "#2E2D35")
    /// Empty ring and bar tracks.
    static let track = Color.primary.opacity(0.08)

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }
    enum Radius {
        static let chip: CGFloat = 6, row: CGFloat = 10, card: CGFloat = 14
    }

    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

/// A card: white (light) or charcoal (dark) surface with a hairline border.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct CardTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.headline) }
}

/// A circular progress ring with rounded ends.
struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat
    var trackColor: Color = Theme.track

    var body: some View {
        ZStack {
            Circle().stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.6), value: progress)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

/// YPT-style ring: one coloured arc per subject, in study order, filling towards the daily goal.
struct SegmentedRing: View {
    struct Segment: Identifiable {
        let id: String
        let color: Color
        let fraction: Double
    }
    var segments: [Segment]
    var lineWidth: CGFloat
    var trackColor: Color = Theme.track
    var dimmed = false

    var body: some View {
        ZStack {
            Circle().stroke(trackColor, lineWidth: lineWidth)
            ForEach(Array(placed.enumerated()), id: \.offset) { _, arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.6), value: segments.map(\.fraction))
        .accessibilityElement()
        .accessibilityLabel("Today's progress")
        .accessibilityValue("\(Int((segments.map(\.fraction).reduce(0, +) * 100).rounded())) percent of the daily goal")
    }

    /// Consecutive arcs, clipped at one full turn, with a hairline gap between subjects.
    private var placed: [(start: Double, end: Double, color: Color)] {
        var start = 0.0
        var arcs: [(Double, Double, Color)] = []
        for s in segments where s.fraction > 0 && start < 1 {
            let end = min(start + s.fraction, 1)
            let gap = segments.count > 1 && end - start > 0.01 ? 0.004 : 0
            arcs.append((start, end - gap, s.color))
            start = end
        }
        return arcs
    }
}

/// A thin rounded progress bar that keeps its colour in inactive windows (unlike the system one).
struct ProgressBar: View {
    var progress: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(height, geo.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.6), value: progress)
        .accessibilityElement()
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

/// Filled circular play / stop button in a subject's colour.
struct SubjectPlayButton: View {
    let color: Color
    let isRunning: Bool
    var size: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color.gradient)
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: isRunning ? 0 : size * 0.04)
            }
            .frame(width: size, height: size)
            .shadow(color: color.opacity(isRunning ? 0.45 : 0.2), radius: isRunning ? 6 : 2, y: 1)
        }
        .buttonStyle(.plain)
    }
}

/// Small rounded label (exam countdown, focus %).
struct Chip: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .foregroundStyle(color)
    }
}
