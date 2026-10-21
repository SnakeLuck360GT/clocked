// Head-down detection on simulated postures from "looking at the screen" (depth 0) to "phone in lap" (depth 1),
// comparing the earlier all-or-nothing vote rule with the graded score, plus a threshold sweep. Run with Tests/run.sh.
import Foundation
var rng = SeededRandom(seed: 77)
func g(_ m: Double, _ sd: Double) -> Double {
    let u1 = max(Double(rng.next() >> 11) / Double(1 << 53), 1e-12), u2 = Double(rng.next() >> 11) / Double(1 << 53)
    return m + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
}
func chance(_ p: Double) -> Bool { Double(rng.next() >> 11) / Double(1 << 53) < p }
// depth 0 = looking at the screen, 1 = phone in lap (full head-down). Real noise on every cue.
func posture(depth d: Double, faceLossAtDepth: Bool = true) -> PostureFeatures {
    let faceGone = faceLossAtDepth && d > 0.8 && chance((d - 0.8) * 3)
    let lerp = { (a: Double, b: Double) in a + (b - a) * d }
    return PostureFeatures(eyeEar: faceGone ? nil : g(lerp(0.05, -0.12), 0.03), noseShoulder: faceGone ? nil : g(lerp(0.60, 0.38), 0.04),
                           faceY: faceGone ? nil : g(lerp(0.60, 0.44), 0.025), pitch: faceGone ? nil : g(lerp(0, 0.45), 0.07),
                           faceVisible: faceGone ? 0 : 1, eyeOpen: faceGone ? nil : g(lerp(0.30, 0.13), 0.035),
                           yaw: faceGone ? nil : g(0, 0.06), gazeY: faceGone ? nil : g(lerp(0.50, 0.30), 0.06), shoulderY: g(0.3, 0.01))
}
func bottomCorner() -> PostureFeatures {
    PostureFeatures(eyeEar: g(-0.02, 0.02), noseShoulder: g(0.53, 0.03), faceY: g(0.55, 0.02), pitch: g(0.17, 0.05), faceVisible: 1,
                    eyeOpen: g(0.22, 0.03), yaw: g(0.25, 0.05), gazeY: g(0.37, 0.05), shoulderY: g(0.3, 0.01))
}
var b = TypingBaseline()
// Typing baseline: mostly screen, 30% glances at the keyboard (depth 0.35).
for _ in 0..<80 { b.add(posture(depth: chance(0.3) ? 0.35 : 0)) }

// The previous rule (half of the cues past fixed margins), for comparison.
func oldRule(_ f: PostureFeatures) -> Bool {
    guard let ref = b.reference, f.hasPerson else { return false }
    var votes = 0, available = 0
    func vote(_ v: Double?, _ r: Double?, _ test: (Double, Double) -> Bool) { if let v, let r { available += 1; if test(v, r) { votes += 1 } } }
    vote(f.eyeEar, ref[0]) { $0 < $1 - 0.10 }; vote(f.noseShoulder, ref[1]) { $0 < $1 - 0.12 }
    vote(f.faceY, ref[2]) { $0 < $1 - 0.08 }; vote(f.pitch, ref[3]) { abs($0 - $1) > 0.30 }
    vote(f.eyeOpen, ref[5]) { $0 < $1 * 0.75 }; vote(f.gazeY, ref[7]) { $0 < $1 - 0.15 }
    if let usual = ref[4], usual > 0.7 { available += 1; if f.faceVisible == 0 { votes += 1 } }
    // Old presence check: shoulders alone didn't count as a person.
    if f.faceVisible == 0 && f.eyeEar == nil && f.noseShoulder == nil { return false }
    return available > 0 && votes * 2 >= available
}
func rate(_ make: () -> PostureFeatures, _ test: (PostureFeatures) -> Bool) -> String {
    String(format: "%3d%%", (0..<2000).filter { _ in test(make()) }.count / 20)
}
print("Read as head down (old rule → new score):")
for d in [0.4, 0.5, 0.6, 0.7, 0.8, 1.0] {
    print(String(format: "  phone, head-down depth %.1f      %@ → %@", d, rate({ posture(depth: d) }, oldRule), rate({ posture(depth: d) }, b.isHeadDown)))
}
print("  should stay low:")
print("  looking at the screen           \(rate({ posture(depth: 0) }, oldRule)) → \(rate({ posture(depth: 0) }, b.isHeadDown))")
print("  glancing at the keyboard (0.35) \(rate({ posture(depth: 0.35) }, oldRule)) → \(rate({ posture(depth: 0.35) }, b.isHeadDown))")
print("  bottom corner of the screen     \(rate(bottomCorner, oldRule)) → \(rate(bottomCorner, b.isHeadDown))")

print("\nThreshold sweep (new score): depth 0.6 / 0.8 / 1.0 | keyboard / bottom corner / screen")
for t in [0.75, 0.9, 1.0, 1.1, 1.2, 1.3] {
    func test(_ f: PostureFeatures) -> Bool { b.faceHiddenButPresent(f) || (b.downScore(f) ?? 0) >= t }
    print(String(format: "  %.2f:  %@ %@ %@ | %@ %@ %@", t, rate({ posture(depth: 0.6) }, test), rate({ posture(depth: 0.8) }, test),
                 rate({ posture(depth: 1.0) }, test), rate({ posture(depth: 0.35) }, test), rate(bottomCorner, test), rate({ posture(depth: 0) }, test)))
}
