import AppKit
import SwiftUI

enum Icons {
    /// Menu-bar glyph: the logo's C-shaped clock face with its hand pointing into the gap.
    /// Outline when idle, heavier while studying. Template images, so macOS tints them for any menu bar.
    static let menuBar = dial(weight: 1.8)
    static let menuBarActive = dial(weight: 2.6)

    private static func dial(weight: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c = NSGraphicsContext.current!.cgContext
            let p = CGPoint(x: 9, y: 9), r: CGFloat = 7.2 - weight / 2, gap: CGFloat = 26 * .pi / 180
            c.setStrokeColor(.black)
            c.setFillColor(.black)
            c.setLineWidth(weight)
            c.addArc(center: p, radius: r, startAngle: gap, endAngle: -gap, clockwise: false)
            c.strokePath()
            c.setLineCap(.round)
            c.move(to: p); c.addLine(to: CGPoint(x: p.x + r - weight * 0.6, y: p.y))
            c.strokePath()
            c.fillEllipse(in: CGRect(x: p.x - weight * 0.9, y: p.y - weight * 0.9, width: weight * 1.8, height: weight * 1.8))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppInfo.name
        return image
    }

    /// The full-colour app icon, for the welcome screen.
    static var app: NSImage { NSApp.applicationIconImage }
}
