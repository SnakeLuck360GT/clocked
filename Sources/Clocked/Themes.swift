import AppKit
import SwiftUI

/// Classic is the original look; Mac follows the system more closely (plain window background, session
/// controls in the toolbar, subjects in the sidebar, Settings in their own window).
enum InterfaceStyle: String, CaseIterable, Identifiable {
    case classic, mac
    var id: String { rawValue }
    var title: String { self == .classic ? "Classic" : "Mac" }
}

/// A theme's colours: the accent, the eight subject colours (in the order of `Subject.palette`)
/// and the Focus View's dark background.
struct ThemeColors {
    var accent: Color
    var palette: [Color]
    var night: [Color]
}

enum ThemePreset: String, CaseIterable, Identifiable {
    case ember, ocean, forest, midnight, sakura, graphite, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colors: ThemeColors {
        func c(_ hexes: [String]) -> [Color] { hexes.map(Color.init(hex:)) }
        switch self {
        case .ember, .custom:
            return ThemeColors(accent: Color(hex: "#EF4F2C"), palette: c(Subject.palette), night: c(["#2A1E1B", "#101015"]))
        case .ocean:
            return ThemeColors(accent: Color(hex: "#2F7CF6"),
                               palette: c(["#3B6FF5", "#14B8A6", "#6366F1", "#F5A524", "#E0578F", "#0EA5E9", "#2FB36A", "#F0705A"]),
                               night: c(["#0D1E33", "#05080F"]))
        case .forest:
            return ThemeColors(accent: Color(hex: "#2F9E5B"),
                               palette: c(["#3D7BD9", "#2F9E5B", "#8A6FD1", "#D9A21B", "#D2607A", "#2A9CB0", "#7DB52A", "#C8703D"]),
                               night: c(["#13261B", "#070D09"]))
        case .midnight:
            return ThemeColors(accent: Color(hex: "#7C5CFC"),
                               palette: c(["#6E8BFF", "#22D3B4", "#9F7BFF", "#F7C948", "#F472B6", "#38BDF8", "#4ADE80", "#FB8A6A"]),
                               night: c(["#1A1033", "#07050F"]))
        case .sakura:
            return ThemeColors(accent: Color(hex: "#E64980"),
                               palette: c(["#7A8CF0", "#4CC9A4", "#A586F0", "#F2B33D", "#E64980", "#5CB8E6", "#7CC46A", "#F48A72"]),
                               night: c(["#2B1420", "#0F0710"]))
        case .graphite:
            return ThemeColors(accent: Color(hex: "#6E6E76"),
                               palette: c(["#6A7FA8", "#5E9A88", "#8E7FA8", "#B39A5E", "#A87485", "#5E93A8", "#7A9A62", "#A8786A"]),
                               night: c(["#1C1C1E", "#0A0A0B"]))
        }
    }

    /// The theme for an accent chosen in an earlier build.
    static func from(accent: String?) -> ThemePreset {
        switch accent {
        case "blue": return .ocean
        case "purple": return .midnight
        case "green": return .forest
        case "pink": return .sakura
        case "graphite": return .graphite
        default: return .ember
        }
    }
}

// MARK: - App icon

enum AppIconChoice: String, CaseIterable, Identifiable {
    case light, dark, ember, theme, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .ember: return "Ember"
        case .theme: return "Theme"
        case .custom: return "Your Image"
        }
    }
}

/// The Dock icon. macOS only lets a running app change its own Dock icon, so Finder and Launchpad keep the original.
enum AppIcon {
    static let customURL = Storage.file("app-icon.png")

    @MainActor static func apply() {
        guard let app = NSApp else { return }
        app.applicationIconImage = image(for: AppSettings.shared.appIcon)
    }

    /// nil means the icon in the app bundle (the light one).
    @MainActor static func image(for choice: AppIconChoice, size: CGFloat = 512) -> NSImage? {
        switch choice {
        case .light: return nil
        case .dark: return dial(size: size, tile: "#18171C", edge: "#2A2930", mark: "#F6EFE8", hand: "#F2552C")
        case .ember: return dial(size: size, tile: "#F2552C", edge: "#D9461F", mark: "#FFFFFF", hand: "#18171C")
        case .theme: return dial(size: size, tile: NSColor(Theme.accent), edge: NSColor(Theme.accent).blended(withFraction: 0.15, of: .black)!,
                                 mark: .white, hand: NSColor(hex: "#18171C"))
        case .custom: return custom(size: size)
        }
    }

    /// Preview for Settings: the bundle icon for Light.
    @MainActor static func preview(_ choice: AppIconChoice) -> NSImage {
        image(for: choice, size: 128) ?? dial(size: 128, tile: "#F6EFE8", edge: "#E2D8CF", mark: "#18171C", hand: "#F2552C")
    }

    /// Saves a picked image, cropped to a square, for the Your Image icon.
    static func saveCustom(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        let px = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = image.size, side = min(s.width, s.height)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                   from: NSRect(x: (s.width - side) / 2, y: (s.height - side) / 2, width: side, height: side),
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: customURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? png.write(to: customURL, options: .atomic)) != nil
    }

    static var hasCustom: Bool { FileManager.default.fileExists(atPath: customURL.path) }

    /// Your picture inside the standard macOS icon shape, so it sits in the Dock like other apps.
    private static func custom(size: CGFloat) -> NSImage? {
        guard let picture = NSImage(contentsOf: customURL) else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let k = size / 1024
            let tile = NSBezierPath(roundedRect: NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k), xRadius: 185 * k, yRadius: 185 * k)
            NSGraphicsContext.saveGraphicsState()
            tile.addClip()
            picture.draw(in: NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k))
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.1).setStroke()
            tile.lineWidth = 2 * k
            tile.stroke()
            return true
        }
    }

    private static func dial(size: CGFloat, tile: String, edge: String, mark: String, hand: String) -> NSImage {
        dial(size: size, tile: NSColor(hex: tile), edge: NSColor(hex: edge), mark: NSColor(hex: mark), hand: NSColor(hex: hand))
    }

    /// The Clocked mark (same geometry as Tools/make-icon.swift): a C-shaped dial with its hand pointing into the gap.
    private static func dial(size: CGFloat, tile: NSColor, edge: NSColor, mark: NSColor, hand: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let c = NSGraphicsContext.current!.cgContext
            c.scaleBy(x: size / 1024, y: size / 1024)
            c.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil))
            c.setFillColor(tile.cgColor); c.fillPath()
            c.addPath(CGPath(roundedRect: CGRect(x: 101, y: 101, width: 822, height: 822), cornerWidth: 184, cornerHeight: 184, transform: nil))
            c.setStrokeColor(edge.cgColor); c.setLineWidth(2); c.strokePath()
            let center = CGPoint(x: 512, y: 512), radius: CGFloat = 258, ring: CGFloat = 76, gap: CGFloat = 24 * .pi / 180
            c.setStrokeColor(mark.cgColor); c.setLineWidth(ring); c.setLineCap(.butt)
            c.addArc(center: center, radius: radius, startAngle: gap, endAngle: -gap, clockwise: false)
            c.strokePath()
            c.setStrokeColor(hand.cgColor); c.setLineWidth(ring * 0.86); c.setLineCap(.round)
            c.move(to: center); c.addLine(to: CGPoint(x: center.x + radius - ring * 0.9, y: center.y))
            c.strokePath()
            c.setFillColor(mark.cgColor)
            c.fillEllipse(in: CGRect(x: center.x - 54, y: center.y - 54, width: 108, height: 108))
            return true
        }
    }
}

extension NSColor {
    convenience init(hex: String) { self.init(Color(hex: hex)) }
}

extension Color {
    /// "#RRGGBB" in sRGB, for storing colours picked in Settings.
    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

// MARK: - Menu bar icon

enum MenuBarIcon: String, CaseIterable, Identifiable {
    case logo, stopwatch, timer, hourglass, book, graduation, brain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .logo: return "Clocked"
        case .stopwatch: return "Stopwatch"
        case .timer: return "Timer"
        case .hourglass: return "Hourglass"
        case .book: return "Book"
        case .graduation: return "Graduation Cap"
        case .brain: return "Brain"
        }
    }
    /// SF Symbol (nil for the Clocked logo).
    var symbol: String? {
        switch self {
        case .logo: return nil
        case .stopwatch: return "stopwatch"
        case .timer: return "timer"
        case .hourglass: return "hourglass"
        case .book: return "book.closed"
        case .graduation: return "graduationcap"
        case .brain: return "brain.head.profile"
        }
    }

    @ViewBuilder func image(active: Bool) -> some View {
        if let symbol {
            Image(systemName: symbol).symbolVariant(active ? .fill : .none)
        } else {
            Image(nsImage: active ? Icons.menuBarActive : Icons.menuBar)
        }
    }
}

// MARK: - Subjects

extension Subject {
    /// The subject's colour in the current theme.
    var color: Color { ThemeState.shared.subjectColor(colorHex) }
}

// MARK: - Subject icons

enum SubjectSymbols {
    /// Icons a subject can have, with names for the menu.
    static let all: [(symbol: String, name: String)] = [
        ("book.closed", "Book"), ("function", "Maths"), ("x.squareroot", "Algebra"), ("sum", "Sum"),
        ("flask", "Chemistry"), ("atom", "Physics"), ("leaf", "Biology"), ("globe.europe.africa", "Geography"),
        ("building.columns", "History"), ("character.book.closed", "Languages"), ("text.quote", "Literature"),
        ("pencil", "Writing"), ("paintpalette", "Art"), ("music.note", "Music"), ("laptopcomputer", "Computing"),
        ("chevron.left.forwardslash.chevron.right", "Code"), ("chart.bar", "Statistics"), ("dollarsign.circle", "Economics"),
        ("brain.head.profile", "Psychology"), ("heart", "Health"), ("figure.run", "Sport"), ("theatermasks", "Drama"),
        ("graduationcap", "Exam"), ("star", "Star"),
    ]
}
