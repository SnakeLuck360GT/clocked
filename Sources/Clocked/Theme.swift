import AppKit
import Observation
import SwiftUI

/// Design tokens, from the app icon. Colour roles:
/// - `accent` (Ember): interactive elements, selection, the heatmap and the "focused" series in Stats.
/// - Subject colours: a subject's identity only (ring segments, play buttons, bars, dots, a light row tint).
/// - Status: green = focused, `warning` (amber) = distracted, grey = paused, blue = break, red = destructive.
enum Theme {
    /// The theme's accent (Ember by default).
    static var accent: Color { ThemeState.shared.colors.accent }
    /// The Mac interface style (Settings → Appearance), rather than Classic.
    static var mac: Bool { ThemeState.shared.style == .mac }
    /// Font design for the large timers.
    static var timerDesign: Font.Design { ThemeState.shared.timerFont.design }
    static let warning = Color(hex: "#E39B2E")
    /// Deep backgrounds (Focus View, curtain), from the theme.
    static var night: [Color] { ThemeState.shared.colors.night }

    /// Window background behind cards: warm in Classic, the system's in Mac.
    static var canvas: Color { mac ? Color(nsColor: .windowBackgroundColor) : classicCanvas }
    /// Card surface: white or charcoal in Classic; a quiet fill like a grouped Form section in Mac.
    static var card: Color { mac ? Color.primary.opacity(0.035) : classicCard }
    /// Raised element on a card (stat tiles, chips).
    static var raised: Color { mac ? Color.primary.opacity(0.05) : classicRaised }
    private static let classicCanvas = dynamic(light: "#FBF7F4", dark: "#16161B")
    private static let classicCard = dynamic(light: "#FFFFFF", dark: "#24232A")
    private static let classicRaised = dynamic(light: "#F1E7DF", dark: "#2E2D35")
    /// Empty ring and bar tracks.
    static let track = Color.primary.opacity(0.08)

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }
    enum Radius {
        static var chip: CGFloat { Theme.mac ? 4 : 6 }
        static var row: CGFloat { Theme.mac ? 6 : 10 }
        static var card: CGFloat { Theme.mac ? 10 : 14 }
    }

    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

/// The theme colours, interface style and timer font, observable so any view that reads `Theme.accent`,
/// `Theme.mac` or `Theme.timerDesign` redraws when they change, without rebuilding the window. Kept in step by AppSettings.
final class ThemeState: Observable {
    static let shared = ThemeState()
    private let registrar = ObservationRegistrar()
    private var _colors = ThemePreset.ember.colors
    private var _style = InterfaceStyle.classic
    private var _timerFont = TimerFont.rounded

    var colors: ThemeColors {
        get { registrar.access(self, keyPath: \.colors); return _colors }
        set { registrar.withMutation(of: self, keyPath: \.colors) { _colors = newValue } }
    }
    var style: InterfaceStyle {
        get { registrar.access(self, keyPath: \.style); return _style }
        set { registrar.withMutation(of: self, keyPath: \.style) { _style = newValue } }
    }

    /// A subject's colour in the current theme: palette colours follow the theme, others stay as they are.
    func subjectColor(_ hex: String) -> Color {
        if let i = Subject.palette.firstIndex(of: hex.uppercased()), i < colors.palette.count { return colors.palette[i] }
        return Color(hex: hex)
    }
    var timerFont: TimerFont {
        get { registrar.access(self, keyPath: \.timerFont); return _timerFont }
        set { registrar.withMutation(of: self, keyPath: \.timerFont) { _timerFont = newValue } }
    }
}

/// Applies the accent as the window's tint.
struct Themed<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.tint(Theme.accent)
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
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(Theme.mac ? 0.05 : 0.06)))
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
                if Theme.mac { Circle().fill(color) } else { Circle().fill(color.gradient) }
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: size * (Theme.mac ? 0.34 : 0.36), weight: Theme.mac ? .semibold : .bold))
                    .foregroundStyle(.white)
                    .offset(x: isRunning ? 0 : size * 0.04)
            }
            .frame(width: size, height: size)
            .shadow(color: Theme.mac ? .clear : color.opacity(isRunning ? 0.45 : 0.2), radius: isRunning ? 6 : 2, y: 1)
        }
        .buttonStyle(.plain)
    }
}

/// Small rounded label (exam countdown, focus %).
struct Chip: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        if Theme.mac {
            Text(text)
                .font(.caption.weight(.medium).monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(color.opacity(0.5), lineWidth: 1))
                .foregroundStyle(color)
        } else {
            Text(text)
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .foregroundStyle(color)
        }
    }
}
