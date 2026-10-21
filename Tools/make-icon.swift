// Clocked app icon: a clock face whose ring is a "C"; an ember hand points into the gap.
// Flat: one shape, two colours, no gradients or glow.
// Build: swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk Tools/make-icon.swift -o /tmp/make-icon
// Usage: /tmp/make-icon out.png [size=1024] [light (default) | dark]
import AppKit

let args = CommandLine.arguments
let outPath = args[1]
let px = Int(args.count > 2 ? args[2] : "1024") ?? 1024
let dark = args.count > 3 && args[3] == "dark"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let tile = rgb(dark ? 0x18171C : 0xF6EFE8)   // cream or ink
let edge = rgb(dark ? 0x2A2930 : 0xE2D8CF)   // hairline so the tile holds its shape on any background
let mark = rgb(dark ? 0xF6EFE8 : 0x18171C)
let ember = rgb(0xF2552C)

let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

// Tile on the macOS icon grid (824 pt, corner radius 185).
c.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil))
c.setFillColor(tile); c.fillPath()
c.addPath(CGPath(roundedRect: CGRect(x: 101, y: 101, width: 822, height: 822), cornerWidth: 184, cornerHeight: 184, transform: nil))
c.setStrokeColor(edge); c.setLineWidth(2); c.strokePath()

let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 258, ring: CGFloat = 76, gap: CGFloat = 24 // gap half-angle in degrees, centred on 3 o'clock
func rad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

// The "C": a ring open on the right.
c.setStrokeColor(mark); c.setLineWidth(ring); c.setLineCap(.butt)
c.addArc(center: center, radius: radius, startAngle: rad(gap), endAngle: rad(-gap), clockwise: false)
c.strokePath()

// The hand, pointing into the gap.
c.setStrokeColor(ember); c.setLineWidth(ring * 0.86); c.setLineCap(.round)
c.move(to: center); c.addLine(to: CGPoint(x: center.x + radius - ring * 0.9, y: center.y))
c.strokePath()

// Hub.
let hub: CGFloat = 54
c.setFillColor(mark); c.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))

try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
